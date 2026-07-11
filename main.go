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
	"log"
	"net"
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
	"mlqs/internal/imgcache"
	"mlqs/internal/notify"
	"mlqs/internal/provider"
	"mlqs/internal/sanitize"
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
	providers map[string]provider.Provider // keyed by account name
	cals      map[string]*gcal.Client      // keyed by account name

	calMu       sync.Mutex
	calNotified map[string]bool // event occurrence keys already reminded

	mu    sync.Mutex
	conns map[net.Conn]struct{}

	notifMu  sync.Mutex
	notified map[string]string
	notifier *notify.Notifier
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
		fs, err := p.ListFolders(ctx)
		if err != nil {
			fail(err)
			return
		}
		d.sendTo(conn, map[string]any{"type": "folders", "account": cmd.Account, "folders": fs})
	case "conversations":
		if cmd.Cursor != "" {
			pg, err := p.ListConversations(ctx, cmd.Folder, cmd.Cursor, 50, false)
			if err != nil {
				fail(err)
				return
			}
			d.sendTo(conn, map[string]any{"type": "conversations", "account": cmd.Account,
				"folder": cmd.Folder, "items": pg.Conversations, "next": pg.NextCursor})
			return
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
				"id": m.ID, "convId": m.ConvID, "from": m.From, "to": m.To, "cc": m.Cc,
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
		path := filepath.Join(dir, imgcache.Key(cmd.ID+cmd.Text)[:12]+"-"+filepath.Base(name))
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
func (d *daemon) agenda(ctx context.Context, cal *gcal.Client, days int) ([]gcal.Event, error) {
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
	var out []gcal.Event
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
	var uniq []gcal.Event
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

func sortEvents(evs []gcal.Event) {
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

// calNotifyLoop reminds 5 minutes before events start, with a Join action
// when the event carries a meet link. Watches every visible calendar
// (shared ones included); declined and all-day events stay silent.
func (d *daemon) calNotifyLoop(account string, cal *gcal.Client) {
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
		var evs []gcal.Event
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
			if lead > 5*time.Minute || lead < -time.Minute {
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
			path := filepath.Join(dir, imgcache.Key(m.ID+a.ID)[:12]+"-"+filepath.Base(a.Name))
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
	tok, err := auth.Authorize(context.Background(), acct)
	if err != nil {
		log.Fatal(err)
	}
	if err := auth.SaveToken(acct.Name, tok); err != nil {
		log.Fatal(err)
	}
	fmt.Printf("authorized %s (%s)\n", acct.Name, acct.Email)
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
		cals:        map[string]*gcal.Client{},
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
			if k.Link != "" {
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
