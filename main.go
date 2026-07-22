// mlqs daemon: serves mail data to the quickshell UI over a unix socket
// speaking newline-JSON, same dialect as slqs/dsqrd.
//
//	socat - UNIX-CONNECT:$XDG_RUNTIME_DIR/mlqs.sock   # to eyeball the stream
//
// Subcommands:
//
//	mlqs               run the daemon
//	mlqs auth <name>   interactive OAuth consent for a configured account
package main

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	stdhtml "html"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"

	"mlqs/internal/auth"
	"mlqs/internal/cache"
	"mlqs/internal/config"
	"mlqs/internal/debuglog"
	"mlqs/internal/gcal"
	"mlqs/internal/gmail"
	"mlqs/internal/graph"
	imapvendor "mlqs/internal/imap"
	"mlqs/internal/imgcache"
	"mlqs/internal/notify"
	"mlqs/internal/provider"
	"mlqs/internal/sanitize"

	"golang.org/x/term"
)

func sockPath() string {
	if d := os.Getenv("XDG_RUNTIME_DIR"); d != "" {
		return filepath.Join(d, "mlqs.sock")
	}
	return "/tmp/mlqs.sock"
}

type daemon struct {
	cfg       *config.Config
	db        *cache.DB
	providers map[string]provider.Provider         // keyed by account name
	cals      map[string]provider.CalendarProvider // keyed by account name

	calMu       sync.Mutex
	calNotified map[string]bool // event occurrence keys already reminded

	mu    sync.Mutex
	conns map[net.Conn]struct{}

	notifMu  sync.Mutex
	notified map[string]string
	notifier *notify.Notifier

	updateEvent map[string]any // latest updateAvailable event, replayed to new clients
	updMu       sync.Mutex
	updEtag     string
	updTarget   string // SHA to update toward from the last 200 ("" = up to date); replayed on a 304
	updLast     time.Time
}

// gitRev is injected at build time (ldflags -X main.gitRev=<sha>); empty on
// source runs, which disables the update check.
var gitRev string

func shortRev(s string) string {
	if len(s) > 7 {
		return s[:7]
	}
	return s
}

func (d *daemon) broadcast(v any) {
	b, err := json.Marshal(v)
	if err != nil {
		return
	}
	b = append(b, '\n')
	d.mu.Lock()
	defer d.mu.Unlock()
	for c := range d.conns {
		c.Write(b)
	}
}

// Update-tracking repos, overridable at build time via ldflags (-X) or at
// runtime via env (handy for testing). A stock build leaves upstreamRepo empty
// → a plain main-SHA poll of updateRepo. A fork sets both so the daemon signals
// on two legs: (1) our binary is behind the repo we build from, or (2) upstream
// (daphen) has commits we haven't merged yet — both things a flake bump +
// rebuild (or a fork merge) resolves.
var (
	updateRepo   = "daphen/mlqs" // -X main.updateRepo
	upstreamRepo = ""            // -X main.upstreamRepo
)

func updateRepos() (repo, upstream string) {
	repo, upstream = updateRepo, upstreamRepo
	if v := os.Getenv("MLQS_UPDATE_REPO"); v != "" {
		repo = v
	}
	if v := os.Getenv("MLQS_UPSTREAM_REPO"); v != "" {
		upstream = v
	}
	if repo == "" {
		repo = "daphen/mlqs"
	}
	return
}

// checkUpdate does one update check and reconciles the updateAvailable state.
// Detect-only; applying is the host's job (flake bump + rebuild). It sets the
// event when a newer build target exists and CLEARS it when we're current, so
// the badge never sticks. On a transient error (or an unusable response) it
// leaves the prior verdict untouched. Safe to call concurrently.
func (d *daemon) checkUpdate(ctx context.Context) {
	if gitRev == "" {
		return
	}
	d.updMu.Lock()
	d.updLast = time.Now()
	d.updMu.Unlock()
	repo, upstream := updateRepos()
	var target string
	var ok bool
	if upstream != "" && upstream != repo {
		target, ok = d.checkFork(ctx, repo, upstream)
	} else {
		target, ok = d.checkPlain(ctx, repo)
	}
	if !ok {
		return // transient error — keep the previous verdict
	}
	d.updMu.Lock()
	if target != "" && target != gitRev {
		d.updateEvent = map[string]any{"type": "updateAvailable",
			"current": shortRev(gitRev), "latest": shortRev(target)}
	} else {
		d.updateEvent = nil // current on all legs — clear any stale badge
	}
	ev := d.updateEvent
	d.updMu.Unlock()
	if ev != nil {
		d.broadcast(ev)
	}
}

// ghGet performs an ETag-conditional GitHub API GET. Returns (body, 200) on a
// fresh response, (nil, 304) when unchanged since the last check (free against
// the rate limit), or (nil, other/0) on an error. The read limit is generous:
// a compare response carries the full file diff and easily exceeds 64 KiB, and
// a short read truncates the JSON so it won't parse. A build only ever hits one
// endpoint (fork xor plain), so the shared ETag is safe.
func (d *daemon) ghGet(ctx context.Context, url, accept string) ([]byte, int) {
	req, err := http.NewRequestWithContext(ctx, "GET", url, nil)
	if err != nil {
		return nil, 0
	}
	req.Header.Set("User-Agent", "mlqs")
	req.Header.Set("Accept", accept)
	d.updMu.Lock()
	etag := d.updEtag
	d.updMu.Unlock()
	if etag != "" {
		req.Header.Set("If-None-Match", etag)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, 0
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusNotModified {
		return nil, http.StatusNotModified
	}
	if resp.StatusCode != http.StatusOK {
		return nil, resp.StatusCode
	}
	if tag := resp.Header.Get("ETag"); tag != "" {
		d.updMu.Lock()
		d.updEtag = tag
		d.updMu.Unlock()
	}
	b, _ := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
	return b, http.StatusOK
}

// cacheTarget records the SHA computed from a 200 so a later 304 can replay the
// same verdict instead of losing it.
func (d *daemon) cacheTarget(target string) {
	d.updMu.Lock()
	d.updTarget = target
	d.updMu.Unlock()
}

func (d *daemon) cachedTarget() string {
	d.updMu.Lock()
	defer d.updMu.Unlock()
	return d.updTarget
}

// checkPlain (stock, single-repo build) returns the update target — the repo's
// main SHA when it differs from our build, else "". Second value is false only
// on a genuine fetch error, so the caller can distinguish "up to date" from
// "couldn't check".
func (d *daemon) checkPlain(ctx context.Context, repo string) (string, bool) {
	b, code := d.ghGet(ctx, "https://api.github.com/repos/"+repo+"/commits/main", "application/vnd.github.sha")
	switch code {
	case http.StatusOK:
		sha := strings.TrimSpace(string(b))
		target := ""
		if sha != "" && sha != gitRev {
			target = sha
		}
		d.cacheTarget(target)
		return target, true
	case http.StatusNotModified:
		return d.cachedTarget(), true
	default:
		return "", false
	}
}

// checkFork answers both legs with one compare(main...upstream:main):
// base_commit is our fork's main tip (build the fork first if our binary is
// behind it), and ahead_by is upstream's lead (its newest commit is the merge
// target otherwise). Returns the target SHA (or "" when current), and false
// only on a genuine fetch/parse error.
func (d *daemon) checkFork(ctx context.Context, repo, upstream string) (string, bool) {
	head := strings.SplitN(upstream, "/", 2)[0] + ":main" // e.g. daphen:main
	b, code := d.ghGet(ctx, "https://api.github.com/repos/"+repo+"/compare/main..."+head, "application/vnd.github+json")
	switch code {
	case http.StatusNotModified:
		return d.cachedTarget(), true
	case http.StatusOK:
		// fall through to parse
	default:
		return "", false
	}
	var cmp struct {
		BaseCommit struct {
			SHA string `json:"sha"`
		} `json:"base_commit"`
		AheadBy int `json:"ahead_by"`
		Commits []struct {
			SHA string `json:"sha"`
		} `json:"commits"`
	}
	if err := json.Unmarshal(b, &cmp); err != nil {
		return "", false
	}
	target := ""
	if cmp.BaseCommit.SHA != "" && cmp.BaseCommit.SHA != gitRev {
		target = cmp.BaseCommit.SHA // a newer fork build exists — rebuild toward it
	} else if cmp.AheadBy > 0 && len(cmp.Commits) > 0 {
		target = cmp.Commits[len(cmp.Commits)-1].SHA // upstream has unmerged commits
	}
	d.cacheTarget(target)
	return target, true
}

func (d *daemon) sendTo(c net.Conn, v any) {
	b, err := json.Marshal(v)
	if err != nil {
		return
	}
	c.Write(append(b, '\n'))
}

// accountsPayload shapes accounts as "workspaces" — the rail concept the
// shared UI already understands.
func (d *daemon) accountsPayload() map[string]any {
	ws := []map[string]any{}
	for _, a := range d.cfg.Accounts {
		ws = append(ws, map[string]any{
			"id": a.Name, "name": a.Name, "vendor": a.Vendor, "email": a.Email,
		})
	}
	return map[string]any{"type": "workspaces", "workspaces": ws}
}

type command struct {
	Type    string   `json:"type"`
	Account string   `json:"account"`
	Folder  string   `json:"folder"`
	ID      string   `json:"id"`
	Cursor  string   `json:"cursor"`
	Text    string   `json:"text"`
	Query   string   `json:"query"`
	Unread  bool     `json:"unread"`
	To      string   `json:"to"`
	Cc      string   `json:"cc"`
	Bcc     string   `json:"bcc"`
	Subject string   `json:"subject"`
	Body    string   `json:"body"`
	ReplyTo string   `json:"replyTo"`
	Conv    string   `json:"conv"`
	Paths   []string `json:"paths"`
	Start   string   `json:"start"`
	End     string   `json:"end"`
	Meet    bool     `json:"meet"`
	Forward string   `json:"forward"`
}

func (d *daemon) serve(conn net.Conn) {
	d.mu.Lock()
	d.conns[conn] = struct{}{}
	d.mu.Unlock()
	defer func() {
		d.mu.Lock()
		delete(d.conns, conn)
		d.mu.Unlock()
		conn.Close()
	}()

	d.sendTo(conn, d.accountsPayload())

	// replay update-available state to a (re)connecting client, and re-check on
	// connect (throttled) so restarting the app surfaces a new build immediately
	// rather than waiting on the warm daemon's next poll
	d.updMu.Lock()
	ue := d.updateEvent
	stale := time.Since(d.updLast) > time.Minute
	d.updMu.Unlock()
	if ue != nil {
		d.sendTo(conn, ue)
	}
	if gitRev != "" && stale {
		go d.checkUpdate(context.Background())
	}

	sc := bufio.NewScanner(conn)
	sc.Buffer(make([]byte, 1<<20), 1<<24)
	for sc.Scan() {
		var cmd command
		if err := json.Unmarshal(sc.Bytes(), &cmd); err != nil {
			debuglog.IPC("bad command: %v", err)
			continue
		}
		debuglog.IPC("cmd type=%s account=%s folder=%s id=%s", cmd.Type, cmd.Account, cmd.Folder, cmd.ID)
		switch cmd.Type {
		case "ping":
			d.sendTo(conn, map[string]any{"type": "pong"})
		case "summonui":
			// launch script pokes this; a hidden UI remaps itself. Ack with
			// how many OTHER clients heard the summon — zero means every
			// "running" UI is a zombie (alive but disconnected) and the
			// launcher must reap and cold-start instead of trusting the poke.
			d.broadcast(map[string]any{"type": "summon"})
			d.mu.Lock()
			n := len(d.conns) - 1
			d.mu.Unlock()
			d.sendTo(conn, map[string]any{"type": "summonack", "clients": n})
		case "dismissui":
			d.broadcast(map[string]any{"type": "dismiss"})
		case "checkupdate":
			// ⌃⇧r: force an update check now and toast the result
			go func(c net.Conn) {
				if gitRev == "" {
					d.sendTo(c, map[string]any{"type": "toast", "text": "Dev build — update check unavailable"})
					return
				}
				d.checkUpdate(context.Background())
				d.updMu.Lock()
				ue := d.updateEvent
				d.updMu.Unlock()
				if ue != nil {
					d.sendTo(c, map[string]any{"type": "toast", "text": "Update available — restart to apply"})
				} else {
					d.sendTo(c, map[string]any{"type": "toast", "text": "Up to date"})
				}
			}(conn)
		case "notifact":
			// bar history fallback: re-dispatch a notification's action when
			// its live D-Bus object is gone (cmd.ID = server id, Text = action)
			if id, err := strconv.ParseUint(cmd.ID, 10, 32); err == nil {
				act := cmd.Text
				if act == "" {
					act = "default"
				}
				d.notifier.InvokeByID(uint32(id), act)
			}
		case "folders", "conversations", "conversation", "openhtml", "openatt", "search", "threads", "contacts", "markread", "star", "archive", "unarchive", "trash", "untrash", "send",
			"agenda", "rsvp", "rsvpmail", "createevent", "calendars":
			go d.handle(conn, cmd)
		default:
			d.sendTo(conn, map[string]any{"type": "toast",
				"text": fmt.Sprintf("mlqs: %q not implemented yet", cmd.Type)})
		}
	}
}

// handle proxies provider calls per command. Live API reads for now; the
// cache-backed render path replaces the read side once the sync loop lands.
func (d *daemon) handle(conn net.Conn, cmd command) {
	p := d.providers[cmd.Account]
	if p == nil {
		d.sendTo(conn, map[string]any{"type": "toast",
			"text": fmt.Sprintf("mlqs: account %q not authorized (run: mlqs auth %s)", cmd.Account, cmd.Account)})
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	fail := func(err error) {
		debuglog.API("%s %s: %v", cmd.Type, cmd.Account, err)
		d.sendTo(conn, map[string]any{"type": "toast", "text": fmt.Sprintf("mlqs %s: %v", cmd.Type, err)})
	}
	switch cmd.Type {
	case "folders":
		// warm-start: cached sidebar first (also auto-selects inbox → cached
		// inbox paint), then the authoritative live list
		if cached := d.db.CachedFolders(cmd.Account); len(cached) > 0 {
			d.sendTo(conn, map[string]any{"type": "folders", "account": cmd.Account, "folders": cached})
		}
		fs, err := p.ListFolders(ctx)
		if err != nil {
			fail(err)
			return
		}
		d.db.UpsertFolders(cmd.Account, fs)
		d.sendTo(conn, map[string]any{"type": "folders", "account": cmd.Account, "folders": fs})
	case "conversations":
		if cmd.Cursor != "" {
			pg, err := p.ListConversations(ctx, cmd.Folder, cmd.Cursor, 50, false)
			if err != nil {
				fail(err)
				return
			}
			d.db.UpsertConversations(cmd.Account, pg.Conversations)
			d.sendTo(conn, map[string]any{"type": "conversations", "account": cmd.Account,
				"folder": cmd.Folder, "items": pg.Conversations, "next": pg.NextCursor})
			return
		}
		// warm-start: paint the cached folder instantly, then fetch live below
		if cached := d.db.CachedConversations(cmd.Account, cmd.Folder, 200); len(cached) > 0 {
			d.sendTo(conn, map[string]any{"type": "conversations", "account": cmd.Account,
				"folder": cmd.Folder, "items": cached, "cached": true})
		}
		// First page: unreads pin to the top — fetch the folder's full unread
		// set (capped) and the newest page of everything, stitched. Deep-buried
		// unreads surface instead of hiding hundreds of rows down.
		var wg sync.WaitGroup
		var unread []provider.Conversation
		var normal provider.Page
		var uerr, nerr error
		wg.Add(2)
		go func() {
			defer wg.Done()
			cur := ""
			for len(unread) < 200 {
				pg, err := p.ListConversations(ctx, cmd.Folder, cur, 100, true)
				if err != nil {
					uerr = err
					return
				}
				unread = append(unread, pg.Conversations...)
				if pg.NextCursor == "" {
					break
				}
				cur = pg.NextCursor
			}
		}()
		go func() {
			defer wg.Done()
			normal, nerr = p.ListConversations(ctx, cmd.Folder, "", 50, false)
		}()
		wg.Wait()
		if nerr != nil {
			fail(nerr)
			return
		}
		if uerr != nil {
			debuglog.API("unread stitch %s: %v", cmd.Folder, uerr)
		}
		seen := map[string]bool{}
		for _, c := range unread {
			seen[c.ID] = true
		}
		items := unread
		for _, c := range normal.Conversations {
			if !seen[c.ID] {
				items = append(items, c)
			}
		}
		d.db.UpsertConversations(cmd.Account, items)
		// The unread fetch is the folder's FULL unread set (when uncapped):
		// any cached row still flagged unread that it didn't return was read
		// elsewhere (another client, the web UI). Without this, those rows
		// flash stale-unread in the warm paint on every open, forever —
		// upserts only touch rows the live page contains.
		if uerr == nil && len(unread) < 200 {
			ids := make([]string, 0, len(unread))
			for _, c := range unread {
				ids = append(ids, c.ID)
			}
			d.db.ReconcileFolderRead(cmd.Account, cmd.Folder, ids)
		}
		d.sendTo(conn, map[string]any{"type": "conversations", "account": cmd.Account,
			"folder": cmd.Folder, "items": items, "next": normal.NextCursor})
	case "conversation":
		msgs, err := p.GetConversation(ctx, cmd.ID)
		if err != nil {
			fail(err)
			return
		}
		now := time.Now().Unix()
		for _, m := range msgs {
			d.db.UpsertContact(cmd.Account, m.From.Email, m.From.Name, now)
			for _, a := range append(append([]provider.Address{}, m.To...), m.Cc...) {
				d.db.UpsertContact(cmd.Account, a.Email, a.Name, now)
			}
		}
		out := make([]map[string]any, 0, len(msgs))
		for _, m := range msgs {
			html := m.BodyHTML
			if html != "" {
				html = imgcache.RewriteRemote(ctx, html)
				html = rewriteCids(ctx, p, m, html)
			}
			rich := sanitize.Rich(html, m.BodyText)
			atts := append([]provider.Attachment(nil), m.Attachments...)
			for i := range atts {
				if atts[i].ContentID == "" {
					continue
				}
				if cp := imgcache.Lookup(imgcache.Key("cid:" + m.ID + ":" + atts[i].ContentID)); cp != "" && strings.Contains(rich, cp) {
					atts[i].ShownInline = true
				}
			}
			hasInvite := false
			for _, a := range m.Attachments {
				if isICS(a) {
					hasInvite = true
				}
			}
			out = append(out, map[string]any{
				"id": m.ID, "convId": m.ConvID, "from": m.From, "replyTo": m.ReplyTo, "to": m.To, "cc": m.Cc,
				"subject": m.Subject, "snippet": m.Snippet, "date": m.Date,
				"unread": m.Unread, "starred": m.Starred, "attachments": atts,
				"bodyRich":  rich,
				"hasHtml":   strings.TrimSpace(m.BodyHTML) != "",
				"hasInvite": hasInvite,
			})
		}
		d.sendTo(conn, map[string]any{"type": "conversation", "account": cmd.Account,
			"id": cmd.ID, "messages": out})
	case "openhtml":
		// `o` on a message: write the ORIGINAL html to cache and open in the
		// browser — the escape hatch for mail the sanitizer mangles.
		msgs, err := p.GetConversation(ctx, cmd.ID)
		if err != nil {
			fail(err)
			return
		}
		for _, m := range msgs {
			if m.ID != cmd.Text || m.BodyHTML == "" {
				continue
			}
			dir := filepath.Join(os.Getenv("HOME"), ".cache", "mlqs", "view")
			os.MkdirAll(dir, 0o700)
			path := filepath.Join(dir, m.ID+".html")
			if err := os.WriteFile(path, []byte(m.BodyHTML), 0o600); err != nil {
				fail(err)
				return
			}
			exec.Command("xdg-open", path).Start()
			return
		}
		d.sendTo(conn, map[string]any{"type": "toast", "text": "no html body to open"})
	case "threads":
		// mail Threads = conversations I participate in: unread ones first
		// (loud), then the 50 most recently-active threads containing my
		// mail — across all folders, no time window
		acct, _ := d.cfg.Account(cmd.Account)
		me := strings.ToLower(acct.Email)
		var unreadPg, minePg provider.Page
		var uerr, merr error
		var wg sync.WaitGroup
		wg.Add(2)
		go func() { defer wg.Done(); unreadPg, uerr = p.Search(ctx, "is:unread", 50) }()
		go func() {
			defer wg.Done()
			minePg, merr = p.Search(ctx, `from:me -subject:accepted -subject:invitation -subject:"canceled event"`, 50)
		}()
		wg.Wait()
		if uerr != nil && merr != nil {
			fail(uerr)
			return
		}
		hasMe := func(c provider.Conversation) bool {
			for _, s := range c.Senders {
				if strings.EqualFold(s.Email, me) {
					return true
				}
			}
			return false
		}
		// calendar responses and invite plumbing aren't conversations
		junk := func(c provider.Conversation) bool {
			s := strings.ToLower(c.Subject)
			for _, p := range []string{"accepted:", "declined:", "tentatively accepted:",
				"invitation:", "updated invitation", "canceled event", "accept your invitation"} {
				if strings.HasPrefix(s, p) {
					return true
				}
			}
			return false
		}
		// a thread is an EXCHANGE: multiple messages, or someone besides me —
		// a sent mail nobody answered is a monologue, not a thread
		dialogue := func(c provider.Conversation) bool {
			if c.MsgCount > 1 {
				return true
			}
			for _, s := range c.Senders {
				if s.Email != "" && !strings.EqualFold(s.Email, me) {
					return true
				}
			}
			return false
		}
		seen := map[string]bool{}
		var items []provider.Conversation
		for _, c := range unreadPg.Conversations {
			if c.Unread && hasMe(c) && dialogue(c) && !junk(c) {
				seen[c.ID] = true
				items = append(items, c)
			}
		}
		for _, c := range minePg.Conversations {
			if !seen[c.ID] && dialogue(c) && !junk(c) {
				items = append(items, c)
			}
		}
		d.sendTo(conn, map[string]any{"type": "conversations", "account": cmd.Account,
			"folder": "__threads", "items": items, "next": ""})
	case "openatt":
		// open an attachment: cid images are already in imgcache; anything
		// else downloads to the files cache. cmd.ID=message, Text=attachment
		if p := imgcache.Lookup(imgcache.Key("cid:" + cmd.ID + ":" + cmd.Query)); p != "" && cmd.Query != "" {
			openMedia(p)
			return
		}
		data, err := p.FetchAttachment(ctx, cmd.ID, cmd.Text)
		if err != nil {
			fail(err)
			return
		}
		dir := filepath.Join(os.Getenv("HOME"), ".cache", "mlqs", "files")
		os.MkdirAll(dir, 0o700)
		name := cmd.Folder
		if name == "" {
			name = "attachment"
		}
		path := filepath.Join(dir, imgcache.Key(cmd.ID + cmd.Text)[:12]+"-"+filepath.Base(name))
		if err := os.WriteFile(path, data, 0o600); err != nil {
			fail(err)
			return
		}
		openMedia(path)
	case "contacts":
		items := d.db.QueryContacts(cmd.Account, cmd.Query, 8)
		d.sendTo(conn, map[string]any{"type": "contacts", "account": cmd.Account,
			"query": cmd.Query, "items": items})
	case "search":
		pg, err := p.Search(ctx, cmd.Query, 50)
		if err != nil {
			fail(err)
			return
		}
		d.sendTo(conn, map[string]any{"type": "conversations", "account": cmd.Account,
			"folder": "", "items": pg.Conversations, "next": pg.NextCursor})
	case "markread":
		if err := p.MarkRead(ctx, cmd.ID, cmd.Text != "false"); err != nil {
			fail(err)
		} else {
			d.db.SetConvFlags(cmd.Account, cmd.ID, "unread", cmd.Text == "false")
			// rebroadcast counts once Gmail has digested the change — a sync
			// tick in the gap otherwise overwrites the UI's local decrement
			go func(account string) {
				time.Sleep(2500 * time.Millisecond)
				rctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
				defer cancel()
				if fs, err := p.ListFolders(rctx); err == nil {
					d.broadcast(map[string]any{"type": "folders", "account": account, "folders": fs})
				}
			}(cmd.Account)
		}
	case "star":
		if err := p.Star(ctx, cmd.ID, cmd.Text != "false"); err != nil {
			fail(err)
		} else {
			d.db.SetConvFlags(cmd.Account, cmd.ID, "starred", cmd.Text != "false")
		}
	case "archive":
		if err := p.Archive(ctx, cmd.ID); err != nil {
			fail(err)
		}
	case "trash":
		if err := p.Trash(ctx, cmd.ID); err != nil {
			fail(err)
		}
	case "untrash":
		if err := p.Untrash(ctx, cmd.ID); err != nil {
			fail(err)
		}
	case "unarchive":
		if err := p.Unarchive(ctx, cmd.ID); err != nil {
			fail(err)
		}
	case "send":
		to := parseAddrs(cmd.To)
		if len(to) == 0 {
			fail(fmt.Errorf("no recipient"))
			return
		}
		for _, path := range cmd.Paths {
			if _, err := os.Stat(path); err != nil {
				fail(fmt.Errorf("attachment not found: %s", path))
				return
			}
		}
		draft := provider.Draft{
			To: to, Cc: parseAddrs(cmd.Cc), Bcc: parseAddrs(cmd.Bcc),
			Subject: cmd.Subject, BodyText: cmd.Body,
			InReplyTo: cmd.ReplyTo, ConvID: cmd.Conv,
			AttachmentPaths: cmd.Paths,
		}
		if cmd.Forward != "" {
			// Conv locates the original; the forward itself starts a new thread
			draft.ConvID = ""
			draft.InReplyTo = ""
			if err := d.prepareForward(ctx, p, cmd.Conv, cmd.Forward, &draft); err != nil {
				fail(err)
				return
			}
		}
		if err := p.Send(ctx, draft); err != nil {
			fail(err)
			return
		}
		d.sendTo(conn, map[string]any{"type": "sent", "account": cmd.Account, "conv": cmd.Conv})
	case "agenda":
		cal := d.cals[cmd.Account]
		if cal == nil {
			fail(fmt.Errorf("no calendar client (re-run: mlqs auth %s)", cmd.Account))
			return
		}
		days := 14
		if n, err := strconv.Atoi(cmd.Text); err == nil && n >= 1 && n <= 62 {
			days = n
		}
		evs, err := d.agenda(ctx, cal, days)
		if err != nil {
			fail(err)
			return
		}
		d.sendTo(conn, map[string]any{"type": "agenda", "account": cmd.Account, "events": evs})
	case "calendars":
		cal := d.cals[cmd.Account]
		if cal == nil {
			fail(fmt.Errorf("no calendar client"))
			return
		}
		cs, err := cal.Calendars(ctx)
		if err != nil {
			fail(err)
			return
		}
		d.sendTo(conn, map[string]any{"type": "calendars", "account": cmd.Account, "calendars": cs})
	case "rsvp":
		// Folder carries the calendar id, Text the response status
		cal := d.cals[cmd.Account]
		if cal == nil {
			fail(fmt.Errorf("no calendar client"))
			return
		}
		if err := cal.RSVP(ctx, cmd.Folder, cmd.ID, cmd.Text); err != nil {
			fail(err)
			return
		}
		d.sendTo(conn, map[string]any{"type": "rsvped", "account": cmd.Account, "id": cmd.ID, "status": cmd.Text})
	case "rsvpmail":
		// ID = message id carrying a text/calendar attachment; the .ics UID
		// resolves the event on the primary calendar, then a normal RSVP
		cal := d.cals[cmd.Account]
		if cal == nil {
			fail(fmt.Errorf("no calendar client"))
			return
		}
		msgs, err := p.GetConversation(ctx, cmd.Conv)
		if err != nil {
			fail(err)
			return
		}
		uid := ""
		for _, m := range msgs {
			if m.ID != cmd.ID {
				continue
			}
			for _, a := range m.Attachments {
				if !isICS(a) {
					continue
				}
				data, err := p.FetchAttachment(ctx, m.ID, a.ID)
				if err != nil {
					fail(err)
					return
				}
				uid = gcal.ICSUID(data)
			}
		}
		if uid == "" {
			fail(fmt.Errorf("no invite found on message"))
			return
		}
		ev, err := cal.FindByICalUID(ctx, "primary", uid)
		if err != nil {
			fail(err)
			return
		}
		if err := cal.RSVP(ctx, ev.CalID, ev.ID, cmd.Text); err != nil {
			fail(err)
			return
		}
		d.sendTo(conn, map[string]any{"type": "rsvped", "account": cmd.Account, "id": cmd.ID, "status": cmd.Text})
	case "createevent":
		cal := d.cals[cmd.Account]
		if cal == nil {
			fail(fmt.Errorf("no calendar client"))
			return
		}
		start, err := time.ParseInLocation("2006-01-02 15:04", cmd.Start, time.Local)
		if err != nil {
			fail(fmt.Errorf("bad start %q (want YYYY-MM-DD HH:MM)", cmd.Start))
			return
		}
		end, err := time.ParseInLocation("2006-01-02 15:04", cmd.End, time.Local)
		if err != nil {
			fail(fmt.Errorf("bad end %q", cmd.End))
			return
		}
		var atts []string
		for _, a := range parseAddrs(cmd.To) {
			atts = append(atts, a.Email)
		}
		calID := cmd.Folder
		if calID == "" {
			calID = "primary"
		}
		ev, err := cal.Create(ctx, calID, gcal.NewEvent{
			Title: cmd.Subject, Location: cmd.Query, Notes: cmd.Body,
			Start: start, End: end, Attendees: atts, Meet: cmd.Meet,
		})
		if err != nil {
			fail(err)
			return
		}
		d.sendTo(conn, map[string]any{"type": "eventcreated", "account": cmd.Account, "event": ev})
	}
}

// agenda merges the coming span across the account's visible calendars.
// days==1 means "today": the window closes at local midnight, not +24h.
func (d *daemon) agenda(ctx context.Context, cal provider.CalendarProvider, days int) ([]provider.CalEvent, error) {
	calendars, err := cal.Calendars(ctx)
	if err != nil {
		return nil, err
	}
	now := time.Now()
	from := now.Add(-2 * time.Hour)
	to := now.AddDate(0, 0, days)
	if days == 1 {
		y, m, dd := now.Date()
		to = time.Date(y, m, dd+1, 0, 0, 0, 0, time.Local)
	}
	var mu sync.Mutex
	var wg sync.WaitGroup
	var out []provider.CalEvent
	for _, c := range calendars {
		wg.Add(1)
		go func(id string) {
			defer wg.Done()
			evs, err := cal.Events(ctx, id, from, to)
			if err != nil {
				debuglog.API("agenda %s: %v", id, err)
				return
			}
			mu.Lock()
			out = append(out, evs...)
			mu.Unlock()
		}(c.ID)
	}
	wg.Wait()
	// duplicates appear when an event lives on several visible calendars
	seen := map[string]bool{}
	var uniq []provider.CalEvent
	for _, e := range out {
		if seen[e.ICalUID+e.Start.String()] {
			continue
		}
		seen[e.ICalUID+e.Start.String()] = true
		uniq = append(uniq, e)
	}
	sortEvents(uniq)
	return uniq, nil
}

func sortEvents(evs []provider.CalEvent) {
	for i := 1; i < len(evs); i++ {
		for j := i; j > 0 && evs[j].Start.Before(evs[j-1].Start); j-- {
			evs[j], evs[j-1] = evs[j-1], evs[j]
		}
	}
}

func isICS(a provider.Attachment) bool {
	return strings.Contains(strings.ToLower(a.MIME), "text/calendar") ||
		strings.HasSuffix(strings.ToLower(a.Name), ".ics")
}

// calNotifyLoop reminds 10 minutes before events start, with a Join action
// when the event carries a meet link. Watches every visible calendar
// (shared ones included); declined and all-day events stay silent.
func (d *daemon) calNotifyLoop(account string, cal provider.CalendarProvider) {
	var calIDs []string
	var lastList time.Time
	for {
		time.Sleep(60 * time.Second)
		ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
		// the calendar list barely changes — refresh it every 15 minutes
		if len(calIDs) == 0 || time.Since(lastList) > 15*time.Minute {
			if cs, err := cal.Calendars(ctx); err == nil {
				calIDs = calIDs[:0]
				for _, c := range cs {
					calIDs = append(calIDs, c.ID)
				}
				lastList = time.Now()
			} else {
				debuglog.API("calnotify %s: list: %v", account, err)
			}
		}
		var evs []provider.CalEvent
		for _, id := range calIDs {
			es, err := cal.Events(ctx, id, time.Now(), time.Now().Add(30*time.Minute))
			if err != nil {
				debuglog.API("calnotify %s/%s: %v", account, id, err)
				continue
			}
			evs = append(evs, es...)
		}
		cancel()
		for _, e := range evs {
			if e.AllDay || e.MyStatus == "declined" {
				continue
			}
			lead := time.Until(e.Start)
			if lead > 10*time.Minute || lead < -time.Minute {
				continue
			}
			// keyed on the event's iCalUID, not calendar/account: the same
			// meeting on primary + a shared calendar (or both accounts)
			// must remind exactly once
			occ := e.ICalUID + "/" + e.Start.Format(time.RFC3339)
			d.calMu.Lock()
			dup := d.calNotified[occ]
			if !dup {
				d.calNotified[occ] = true
			}
			d.calMu.Unlock()
			if dup {
				continue
			}
			key, _ := json.Marshal(map[string]string{"Cal": "1", "Link": firstNonEmpty(e.MeetLink, e.HTMLLink)})
			body := e.Start.Format("15:04")
			if e.Location != "" {
				body += " · " + e.Location
			}
			body += "  (" + account + ")"
			d.notifier.NotifyEvent(string(key), e.Title, body)
		}
	}
}

func firstNonEmpty(a, b string) string {
	if a != "" {
		return a
	}
	return b
}

var reTags = regexp.MustCompile(`(?s)<[^>]*>`)

// prepareForward appends the forwarded message as a quoted block and
// re-attaches its files (fetched vendor-side, staged in the cache).
func (d *daemon) prepareForward(ctx context.Context, p provider.Provider, convID, msgID string, draft *provider.Draft) error {
	msgs, err := p.GetConversation(ctx, convID)
	if err != nil {
		return err
	}
	for _, m := range msgs {
		if m.ID != msgID {
			continue
		}
		body := m.BodyText
		if strings.TrimSpace(body) == "" {
			body = stdhtml.UnescapeString(reTags.ReplaceAllString(m.BodyHTML, ""))
		}
		var q strings.Builder
		q.WriteString(draft.BodyText)
		q.WriteString("\n\n---------- Forwarded message ----------\n")
		fmt.Fprintf(&q, "From: %s <%s>\n", m.From.Name, m.From.Email)
		fmt.Fprintf(&q, "Date: %s\n", m.Date.Format("Mon, 2 Jan 2006 15:04"))
		fmt.Fprintf(&q, "Subject: %s\n", m.Subject)
		fmt.Fprintf(&q, "To: %s\n\n", addrList(m.To))
		q.WriteString(strings.TrimSpace(body))
		draft.BodyText = q.String()

		dir := filepath.Join(os.Getenv("HOME"), ".cache", "mlqs", "fwd")
		os.MkdirAll(dir, 0o700)
		for _, a := range m.Attachments {
			if a.Name == "" || a.ID == "" {
				continue
			}
			data, err := p.FetchAttachment(ctx, m.ID, a.ID)
			if err != nil {
				return fmt.Errorf("fetching %s: %w", a.Name, err)
			}
			path := filepath.Join(dir, imgcache.Key(m.ID + a.ID)[:12]+"-"+filepath.Base(a.Name))
			if err := os.WriteFile(path, data, 0o600); err != nil {
				return err
			}
			draft.AttachmentPaths = append(draft.AttachmentPaths, path)
		}
		return nil
	}
	return fmt.Errorf("message to forward not found")
}

func addrList(as []provider.Address) string {
	parts := make([]string, 0, len(as))
	for _, a := range as {
		if a.Name != "" {
			parts = append(parts, a.Name+" <"+a.Email+">")
		} else {
			parts = append(parts, a.Email)
		}
	}
	return strings.Join(parts, ", ")
}

// openMedia routes images to the family viewer (imv via media-viewer.sh,
// same as the chat clients); everything else goes to xdg-open.
func openMedia(path string) {
	switch strings.ToLower(filepath.Ext(path)) {
	case ".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp":
		viewer := os.Getenv("SLK_MEDIA_VIEWER")
		if viewer == "" {
			viewer = filepath.Join(os.Getenv("HOME"), ".config", "endcord", "media-viewer.sh")
		}
		if _, err := os.Stat(viewer); err != nil {
			// no family viewer on this machine — plain xdg-open works fine
			exec.Command("xdg-open", path).Start()
			return
		}
		exec.Command(viewer, path, "img").Start()
	default:
		exec.Command("xdg-open", path).Start()
	}
}

func parseAddrs(s string) []provider.Address {
	var out []provider.Address
	for _, part := range strings.Split(s, ",") {
		if p := strings.TrimSpace(part); p != "" {
			out = append(out, provider.Address{Email: p})
		}
	}
	return out
}

var reCidImg = regexp.MustCompile(`(?i)<img[^>]*\bsrc="cid:([^"]+)"[^>]*/?>`)

// rewriteCids resolves cid: inline images (pasted screenshots, embedded
// logos) to cached local files via the vendor attachment API.
func rewriteCids(ctx context.Context, p provider.Provider, m provider.Message, html string) string {
	if !strings.Contains(strings.ToLower(html), "cid:") {
		return html
	}
	byCid := map[string]string{}
	for _, a := range m.Attachments {
		if a.ContentID != "" {
			byCid[a.ContentID] = a.ID
		}
	}
	return reCidImg.ReplaceAllStringFunc(html, func(tag string) string {
		cid := reCidImg.FindStringSubmatch(tag)[1]
		aid := byCid[cid]
		if aid == "" {
			return tag
		}
		key := imgcache.Key("cid:" + m.ID + ":" + cid)
		path := imgcache.Lookup(key)
		if path == "" {
			data, err := p.FetchAttachment(ctx, m.ID, aid)
			if err != nil {
				debuglog.API("cid fetch %s: %v", cid, err)
				return tag
			}
			path, err = imgcache.StoreBytes(key, data)
			if err != nil {
				return tag
			}
		}
		return `<img src="file://` + path + `"` + imgcache.SizeAttrs(tag) + `>`
	})
}

func runAuth(args []string) {
	if len(args) != 1 {
		fmt.Fprintln(os.Stderr, "usage: mlqs auth <account-name>")
		os.Exit(2)
	}
	cfg, err := config.Load()
	if err != nil {
		log.Fatal(err)
	}
	acct, err := cfg.Account(args[0])
	if err != nil {
		log.Fatal(err)
	}
	if acct.Vendor == "imap" {
		if err := authIMAP(acct); err != nil {
			log.Fatal(err)
		}
		fmt.Printf("stored password for %s (%s)\n", acct.Name, acct.Email)
		return
	}
	tok, err := auth.Authorize(context.Background(), acct)
	if err != nil {
		log.Fatal(err)
	}
	if err := auth.SaveToken(acct.Name, tok); err != nil {
		log.Fatal(err)
	}
	fmt.Printf("authorized %s (%s)\n", acct.Name, acct.Email)
}

// authIMAP stores the IMAP password (from the MLQS_IMAP_PASSWORD env, or read
// from the terminal without echo) into the cred file next to the OAuth tokens.
func authIMAP(acct config.Account) error {
	pw := os.Getenv("MLQS_IMAP_PASSWORD")
	if pw == "" {
		fmt.Printf("password for %s (%s): ", acct.Name, acct.Email)
		b, err := term.ReadPassword(int(os.Stdin.Fd()))
		fmt.Println()
		if err != nil {
			return fmt.Errorf("reading password: %w", err)
		}
		pw = string(b)
	}
	if pw == "" {
		return fmt.Errorf("empty password")
	}
	p := config.IMAPCredPath(acct.Name)
	if err := os.MkdirAll(filepath.Dir(p), 0o700); err != nil {
		return err
	}
	b, err := json.Marshal(map[string]string{"password": pw})
	if err != nil {
		return err
	}
	return os.WriteFile(p, b, 0o600)
}

func main() {
	logFile, err := debuglog.Init()
	if err != nil {
		log.Fatal(err)
	}
	if logFile != nil {
		defer logFile.Close()
	}

	if len(os.Args) > 1 && os.Args[1] == "auth" {
		runAuth(os.Args[2:])
		return
	}

	cfg, err := config.Load()
	if err != nil {
		log.Fatal(err)
	}
	db, err := cache.Open()
	if err != nil {
		log.Fatal(err)
	}
	defer db.Close()

	d := &daemon{
		cfg:         cfg,
		db:          db,
		providers:   map[string]provider.Provider{},
		cals:        map[string]provider.CalendarProvider{},
		conns:       map[net.Conn]struct{}{},
		notified:    map[string]string{},
		calNotified: map[string]bool{},
	}
	if len(cfg.Accounts) == 0 {
		log.Printf("no accounts configured — create %s", config.Path())
	}
	ctx := context.Background()
	for _, a := range cfg.Accounts {
		switch a.Vendor {
		case "gmail":
			ts, err := auth.Source(ctx, a)
			if err != nil {
				log.Printf("%v", err)
				continue
			}
			d.providers[a.Name] = gmail.New(ctx, ts)
			d.cals[a.Name] = gcal.New(ctx, ts)
			log.Printf("account %s (%s) ready", a.Name, a.Email)
		case "outlook":
			ts, err := auth.Source(ctx, a)
			if err != nil {
				log.Printf("%v", err)
				continue
			}
			g := graph.New(ctx, ts)
			d.providers[a.Name] = g
			d.cals[a.Name] = g
			log.Printf("account %s (%s, outlook) ready", a.Name, a.Email)
		case "imap":
			// validate host fields up front so a typo surfaces here, not on the
			// first failed fetch after we've logged the account "ready"
			if a.IMAPHost == "" || a.SMTPHost == "" {
				log.Printf("account %s: imap needs imap_host and smtp_host — skipping", a.Name)
				continue
			}
			pw, err := a.IMAPPassword()
			if err != nil {
				log.Printf("%v", err)
				continue
			}
			if a.IMAPSecurity == "plain" || a.SMTPSecurity == "plain" {
				log.Printf("account %s: WARNING — plain (cleartext) connection; the mailbox password is sent unencrypted. Use ssl or starttls unless this is a trusted local network.", a.Name)
			}
			// no calendar for plain IMAP — the daemon nil-guards d.cals lookups
			d.providers[a.Name] = imapvendor.New(imapvendor.Config{
				Name:         a.Name,
				Email:        a.Email,
				Username:     a.Username,
				Password:     pw,
				IMAPHost:     a.IMAPHost,
				IMAPPort:     a.IMAPPort,
				IMAPSecurity: a.IMAPSecurity,
				SMTPHost:     a.SMTPHost,
				SMTPPort:     a.SMTPPort,
				SMTPSecurity: a.SMTPSecurity,
				Threading:    a.IMAPThreading,
			})
			log.Printf("account %s (%s, imap) ready", a.Name, a.Email)
		default:
			log.Printf("account %s: vendor %q not implemented yet", a.Name, a.Vendor)
		}
	}

	// notification default-action → deep-link the UI to the conversation
	d.notifier = notify.New(func(key, action string) {
		debuglog.Gen("notify action invoked (%s): %s", action, key)
		var k struct {
			A, ID, S, Cal, Link string
		}
		if err := json.Unmarshal([]byte(key), &k); err != nil {
			return
		}
		if k.Cal != "" {
			// Join only on an explicit click/join — "read" is the picker's
			// mark-read/dismiss key and must never launch the meeting.
			if action != "read" && k.Link != "" {
				exec.Command("xdg-open", k.Link).Start()
			}
			return
		}
		if action == "read" {
			if p := d.providers[k.A]; p != nil {
				go func() {
					rctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
					defer cancel()
					p.MarkRead(rctx, k.ID, true)
					if fs, err := p.ListFolders(rctx); err == nil {
						d.broadcast(map[string]any{"type": "folders", "account": k.A, "folders": fs})
					}
				}()
			}
			d.broadcast(map[string]any{"type": "readmarked", "account": k.A, "id": k.ID})
			return
		}
		d.broadcast(map[string]any{"type": "openconv", "account": k.A, "id": k.ID, "subject": k.S})
	})

	for name, p := range d.providers {
		go d.syncLoop(name, p)
		if cal := d.cals[name]; cal != nil {
			go d.calNotifyLoop(name, cal)
		}
		// contacts cold-start: seed from sent mail when the store is empty
		if len(d.db.QueryContacts(name, "", 1)) == 0 {
			go func(name string, p provider.Provider) {
				g, ok := p.(*gmail.Client)
				if !ok {
					return
				}
				sctx, cancel := context.WithTimeout(context.Background(), 3*time.Minute)
				defer cancel()
				addrs, err := g.HarvestAddresses(sctx, "from:me", 50)
				if err != nil {
					debuglog.Gen("contact seed %s: %v", name, err)
					return
				}
				now := time.Now().Unix()
				me := ""
				if a, err := d.cfg.Account(name); err == nil {
					me = strings.ToLower(a.Email)
				}
				for _, a := range addrs {
					if a.Email != "" && strings.ToLower(a.Email) != me {
						d.db.UpsertContact(name, a.Email, a.Name, now)
					}
				}
				debuglog.Gen("contact seed %s: %d addresses", name, len(addrs))
			}(name, p)
		}
	}

	// Update check: at start, every 3h, and on each client connect (see serve).
	if gitRev != "" {
		go func() {
			d.checkUpdate(context.Background())
			t := time.NewTicker(3 * time.Hour)
			defer t.Stop()
			for range t.C {
				d.checkUpdate(context.Background())
			}
		}()
	}

	// Heartbeat: lets the UI detect a dead socket (Quickshell's `connected`
	// reads the desired state, not reality) and re-dial within seconds.
	go func() {
		t := time.NewTicker(3 * time.Second)
		defer t.Stop()
		for range t.C {
			d.broadcast(map[string]any{"type": "ping"})
		}
	}()

	// Suspend/hibernate detection: monotonic pauses while wall time doesn't.
	// Sync loops slept through the gap — kick a refresh so mail isn't stale
	// until the next poll tick.
	go func() {
		mono, wall := time.Now(), time.Now().Round(0)
		for {
			time.Sleep(5 * time.Second)
			m, w := time.Now(), time.Now().Round(0)
			if w.Sub(wall)-m.Sub(mono) > time.Minute {
				log.Printf("wake from suspend — resync")
				time.Sleep(5 * time.Second) // let the network come back first
				d.broadcast(map[string]any{"type": "resync"})
			}
			mono, wall = m, w
		}
	}()

	sock := sockPath()
	os.Remove(sock)
	ln, err := net.Listen("unix", sock)
	if err != nil {
		log.Fatal(err)
	}
	defer ln.Close()
	log.Printf("mlqs listening on %s (%d accounts)", sock, len(cfg.Accounts))

	for {
		conn, err := ln.Accept()
		if err != nil {
			return
		}
		go d.serve(conn)
	}
}
