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
	"log"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"

	"mlqs/internal/auth"
	"mlqs/internal/cache"
	"mlqs/internal/config"
	"mlqs/internal/debuglog"
	"mlqs/internal/gmail"
	"mlqs/internal/imgcache"
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

	mu    sync.Mutex
	conns map[net.Conn]struct{}

	notifMu  sync.Mutex
	notified map[string]string
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
		case "folders", "conversations", "conversation", "openhtml", "openatt", "search", "threads", "markread", "star", "archive", "trash", "send":
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
			out = append(out, map[string]any{
				"id": m.ID, "convId": m.ConvID, "from": m.From, "to": m.To, "cc": m.Cc,
				"subject": m.Subject, "snippet": m.Snippet, "date": m.Date,
				"unread": m.Unread, "starred": m.Starred, "attachments": atts,
				"bodyRich": rich,
				"hasHtml":  strings.TrimSpace(m.BodyHTML) != "",
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
		go func() { defer wg.Done(); minePg, merr = p.Search(ctx, "from:me", 50) }()
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
		seen := map[string]bool{}
		var items []provider.Conversation
		for _, c := range unreadPg.Conversations {
			if c.Unread && hasMe(c) {
				seen[c.ID] = true
				items = append(items, c)
			}
		}
		for _, c := range minePg.Conversations {
			if !seen[c.ID] {
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
		if err := p.Send(ctx, draft); err != nil {
			fail(err)
			return
		}
		d.sendTo(conn, map[string]any{"type": "sent", "account": cmd.Account, "conv": cmd.Conv})
	}
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
		cfg:       cfg,
		db:        db,
		providers: map[string]provider.Provider{},
		conns:     map[net.Conn]struct{}{},
		notified:  map[string]string{},
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
			log.Printf("account %s (%s) ready", a.Name, a.Email)
		default:
			log.Printf("account %s: vendor %q not implemented yet", a.Name, a.Vendor)
		}
	}

	for name, p := range d.providers {
		go d.syncLoop(name, p)
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
