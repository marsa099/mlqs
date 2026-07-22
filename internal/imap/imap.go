// Package imap implements provider.Provider over plain IMAP + SMTP, so mlqs
// can talk to any standards mailbox (Dovecot/Loopia, Fastmail, self-hosted…)
// alongside the Gmail and Graph vendors. There is no vendor REST API here:
// reads go over IMAP, sends over SMTP, and conversations are reconstructed
// from server-side THREAD=REFERENCES (with a one-message-per-conversation
// fallback when the server lacks THREAD).
//
// The client holds a single mutex-guarded IMAP connection — IMAP is stateful
// (one SELECT at a time), and a personal client has no need for a pool. Every
// call serializes on that lock and transparently redials a dropped connection
// once.
package imap

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/mail"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/emersion/go-imap/v2"
	"github.com/emersion/go-imap/v2/imapclient"
	// charset registers the non-UTF-8 decoders (iso-8859-1, windows-1252, …)
	// go-message needs to parse mail from providers that aren't UTF-8-only.
	_ "github.com/emersion/go-message/charset"
	gomail "github.com/emersion/go-message/mail"
	"github.com/emersion/go-sasl"
	"github.com/emersion/go-smtp"

	"mlqs/internal/provider"
)

// Config is the resolved connection info for one IMAP account. The daemon
// builds it from the config.Account entry plus the stored password.
type Config struct {
	Name         string
	Email        string
	Username     string // defaults to Email when empty
	Password     string
	IMAPHost     string
	IMAPPort     int
	IMAPSecurity string // "ssl" (implicit TLS) | "starttls" | "plain"
	SMTPHost     string
	SMTPPort     int
	SMTPSecurity string
	// Threading: "references" (default) uses server-side THREAD=REFERENCES;
	// "flat" forces one conversation per message.
	Threading string
}

func (c Config) user() string {
	if c.Username != "" {
		return c.Username
	}
	return c.Email
}

type Client struct {
	cfg Config

	mu      sync.Mutex // guards conn + the single in-flight IMAP command
	conn    *imapclient.Client
	special map[string]string // role ("sent"/"trash"/"archive"/…) -> mailbox name

	mmu     sync.Mutex          // guards members
	members map[string][]imap.UID // convID -> member UIDs, populated on list/get
}

func New(cfg Config) *Client {
	if cfg.IMAPPort == 0 {
		cfg.IMAPPort = 993
	}
	if cfg.IMAPSecurity == "" {
		cfg.IMAPSecurity = "ssl"
	}
	if cfg.SMTPPort == 0 {
		cfg.SMTPPort = 587
	}
	if cfg.SMTPSecurity == "" {
		cfg.SMTPSecurity = "starttls"
	}
	return &Client{cfg: cfg, members: map[string][]imap.UID{}}
}

var _ provider.Provider = (*Client)(nil)

// ---- connection management ----

func (cl *Client) dial() (*imapclient.Client, error) {
	addr := fmt.Sprintf("%s:%d", cl.cfg.IMAPHost, cl.cfg.IMAPPort)
	var (
		c   *imapclient.Client
		err error
	)
	switch cl.cfg.IMAPSecurity {
	case "starttls":
		c, err = imapclient.DialStartTLS(addr, nil)
	case "plain":
		c, err = imapclient.DialInsecure(addr, nil)
	default: // ssl / implicit TLS
		c, err = imapclient.DialTLS(addr, nil)
	}
	if err != nil {
		return nil, fmt.Errorf("imap dial %s: %w", addr, err)
	}
	if err := c.Login(cl.cfg.user(), cl.cfg.Password).Wait(); err != nil {
		c.Close()
		return nil, fmt.Errorf("imap login %s: %w", cl.cfg.user(), err)
	}
	// populate the capability set so hasThread() is reliable
	c.Capability().Wait()
	return c, nil
}

// ensure returns a live, authenticated connection, dialing if needed. Caller
// holds cl.mu.
func (cl *Client) ensure() (*imapclient.Client, error) {
	if cl.conn != nil && cl.conn.State() != imap.ConnStateLogout && cl.conn.State() != imap.ConnStateNone {
		return cl.conn, nil
	}
	cl.reset()
	c, err := cl.dial()
	if err != nil {
		return nil, err
	}
	cl.conn = c
	return c, nil
}

func (cl *Client) reset() {
	if cl.conn != nil {
		cl.conn.Close()
		cl.conn = nil
	}
	cl.special = nil
}

// do runs fn against a live connection under the lock, redialing once if the
// connection turns out to be dead (probed with NOOP so logical errors — e.g. a
// SELECT on a missing folder — are not mistaken for a dropped socket). ctx is
// honored at the boundaries (before running and before a retry) so a cancelled
// caller doesn't queue behind the lock or re-run after its budget expired.
func (cl *Client) do(ctx context.Context, fn func(c *imapclient.Client) error) error {
	return cl.run(ctx, true, fn)
}

// doOnce is do without the redial-and-retry — for non-idempotent operations
// (APPEND) where a retry after a mid-command socket drop could duplicate the
// server-side effect.
func (cl *Client) doOnce(ctx context.Context, fn func(c *imapclient.Client) error) error {
	return cl.run(ctx, false, fn)
}

func (cl *Client) run(ctx context.Context, retry bool, fn func(c *imapclient.Client) error) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	cl.mu.Lock()
	defer cl.mu.Unlock()
	c, err := cl.ensure()
	if err != nil {
		return err
	}
	err = fn(c)
	if err != nil && retry && ctx.Err() == nil {
		if pingErr := c.Noop().Wait(); pingErr != nil {
			cl.reset()
			c, e := cl.ensure()
			if e != nil {
				return e
			}
			return fn(c)
		}
	}
	return err
}

func (cl *Client) hasThread(c *imapclient.Client) bool {
	return c.Caps().Has(imap.Cap("THREAD=REFERENCES"))
}

// ---- convID codec: folder \x1f uidvalidity \x1f rootUID ----

func encodeConvID(folder string, uidvalidity uint32, root imap.UID) string {
	raw := fmt.Sprintf("%s\x1f%d\x1f%d", folder, uidvalidity, uint32(root))
	return base64.RawURLEncoding.EncodeToString([]byte(raw))
}

func decodeConvID(id string) (folder string, uidvalidity uint32, root imap.UID, err error) {
	b, err := base64.RawURLEncoding.DecodeString(id)
	if err != nil {
		return "", 0, 0, fmt.Errorf("bad convID %q: %w", id, err)
	}
	parts := strings.SplitN(string(b), "\x1f", 3)
	if len(parts) != 3 {
		return "", 0, 0, fmt.Errorf("bad convID %q", id)
	}
	uv, _ := strconv.ParseUint(parts[1], 10, 32)
	ru, _ := strconv.ParseUint(parts[2], 10, 32)
	return parts[0], uint32(uv), imap.UID(ru), nil
}

// messageID codec: folder \x1f uidvalidity \x1f uid — identifies a single
// message for attachment fetches, carrying UIDVALIDITY so a stale id can be
// rejected after the mailbox is renumbered.
func encodeMsgID(folder string, uidvalidity uint32, uid imap.UID) string {
	return base64.RawURLEncoding.EncodeToString([]byte(fmt.Sprintf("%s\x1f%d\x1f%d", folder, uidvalidity, uint32(uid))))
}

func decodeMsgID(id string) (folder string, uidvalidity uint32, uid imap.UID, err error) {
	b, err := base64.RawURLEncoding.DecodeString(id)
	if err != nil {
		return "", 0, 0, err
	}
	parts := strings.SplitN(string(b), "\x1f", 3)
	if len(parts) != 3 {
		return "", 0, 0, fmt.Errorf("bad messageID %q", id)
	}
	uv, _ := strconv.ParseUint(parts[1], 10, 32)
	u, _ := strconv.ParseUint(parts[2], 10, 32)
	return parts[0], uint32(uv), imap.UID(u), nil
}

// ---- folders ----

func roleForAttrs(name string, attrs []imap.MailboxAttr) string {
	if strings.EqualFold(name, "INBOX") {
		return "inbox"
	}
	for _, a := range attrs {
		switch a {
		case imap.MailboxAttrSent:
			return "sent"
		case imap.MailboxAttrDrafts:
			return "drafts"
		case imap.MailboxAttrTrash:
			return "trash"
		case imap.MailboxAttrJunk:
			return "spam"
		case imap.MailboxAttrArchive:
			return "archive"
		case imap.MailboxAttrFlagged:
			return "starred"
		case imap.MailboxAttrAll:
			return "archive"
		}
	}
	return "label"
}

func (cl *Client) ListFolders(ctx context.Context) ([]provider.Folder, error) {
	var out []provider.Folder
	err := cl.do(ctx, func(c *imapclient.Client) error {
		datas, err := c.List("", "*", &imap.ListOptions{
			ReturnSpecialUse: true,
			ReturnStatus:     &imap.StatusOptions{NumMessages: true, NumUnseen: true},
		}).Collect()
		if err != nil {
			return err
		}
		special := map[string]string{}
		out = out[:0]
		for _, d := range datas {
			if hasAttr(d.Attrs, imap.MailboxAttrNonExistent) {
				continue
			}
			role := roleForAttrs(d.Mailbox, d.Attrs)
			if role != "label" && special[role] == "" {
				special[role] = d.Mailbox
			}
			f := provider.Folder{ID: d.Mailbox, Name: displayName(d.Mailbox, d.Delim), Role: role}
			if d.Status != nil {
				if d.Status.NumMessages != nil {
					f.Total = int(*d.Status.NumMessages)
				}
				if d.Status.NumUnseen != nil {
					f.Unread = int(*d.Status.NumUnseen)
				}
			}
			out = append(out, f)
		}
		cl.special = special // caller holds cl.mu via do()
		return nil
	})
	if err != nil {
		return nil, err
	}
	sortFolders(out)
	return out, nil
}

func hasAttr(attrs []imap.MailboxAttr, want imap.MailboxAttr) bool {
	for _, a := range attrs {
		if a == want {
			return true
		}
	}
	return false
}

// displayName strips the hierarchy prefix so "INBOX.Sent" shows as "Sent".
func displayName(mailbox string, delim rune) string {
	name := mailbox
	if delim != 0 {
		if i := strings.LastIndexByte(name, byte(delim)); i >= 0 {
			name = name[i+1:]
		}
	}
	if strings.EqualFold(mailbox, "INBOX") {
		return "Inbox"
	}
	return name
}

var roleOrder = map[string]int{
	"inbox": 0, "starred": 1, "sent": 2, "drafts": 3,
	"archive": 4, "spam": 5, "trash": 6, "label": 7,
}

func sortFolders(fs []provider.Folder) {
	sort.SliceStable(fs, func(i, j int) bool {
		ri, rj := roleOrder[fs[i].Role], roleOrder[fs[j].Role]
		if ri != rj {
			return ri < rj
		}
		return fs[i].Name < fs[j].Name
	})
}

// specialMailbox resolves a role to a mailbox, running a LIST if the cache is
// cold. Caller holds cl.mu (via do). Returns "" when the server exposes none.
func (cl *Client) specialMailbox(c *imapclient.Client, role string) string {
	if cl.special == nil {
		datas, err := c.List("", "*", &imap.ListOptions{ReturnSpecialUse: true}).Collect()
		if err != nil {
			// leave cl.special nil so the next call retries — caching an empty
			// map here would disable special folders (Archive, Sent filing) for
			// the life of the connection after a single transient LIST failure.
			return ""
		}
		m := map[string]string{}
		for _, d := range datas {
			r := roleForAttrs(d.Mailbox, d.Attrs)
			if r != "label" && m[r] == "" {
				m[r] = d.Mailbox
			}
		}
		cl.special = m
	}
	return cl.special[role]
}

// ---- threading ----

type thread struct {
	root   imap.UID
	uids   []imap.UID
	maxUID imap.UID
}

func flattenThread(td imapclient.ThreadData, into *[]imap.UID) {
	for _, n := range td.Chain {
		*into = append(*into, imap.UID(n))
	}
	for _, sub := range td.SubThreads {
		flattenThread(sub, into)
	}
}

// threads returns the folder's conversations newest-first (by highest member
// UID, a cheap proxy for most-recent arrival). When the server lacks THREAD,
// every message becomes its own conversation.
func (cl *Client) threads(c *imapclient.Client, unreadOnly bool) ([]thread, error) {
	crit := &imap.SearchCriteria{}
	if unreadOnly {
		crit.NotFlag = []imap.Flag{imap.FlagSeen}
	}
	var out []thread
	if cl.cfg.Threading != "flat" && cl.hasThread(c) {
		tds, err := c.UIDThread(&imapclient.ThreadOptions{
			Algorithm:      imap.ThreadReferences,
			SearchCriteria: crit,
		}).Wait()
		if err != nil {
			return nil, err
		}
		for _, td := range tds {
			var uids []imap.UID
			flattenThread(td, &uids)
			if len(uids) == 0 {
				continue
			}
			out = append(out, mkThread(uids))
		}
	} else {
		data, err := c.UIDSearch(crit, nil).Wait()
		if err != nil {
			return nil, err
		}
		for _, u := range data.AllUIDs() {
			out = append(out, thread{root: u, uids: []imap.UID{u}, maxUID: u})
		}
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].maxUID > out[j].maxUID })
	return out, nil
}

func mkThread(uids []imap.UID) thread {
	root, max := uids[0], uids[0]
	for _, u := range uids {
		if u > max {
			max = u
		}
	}
	return thread{root: root, uids: uids, maxUID: max}
}

// ---- listing conversations ----

func (cl *Client) ListConversations(ctx context.Context, folderID, cursor string, limit int, unreadOnly bool) (provider.Page, error) {
	if folderID == "" {
		folderID = "INBOX"
	}
	if limit <= 0 {
		limit = 50
	}
	after := parseCursor(cursor)
	var page provider.Page
	err := cl.do(ctx, func(c *imapclient.Client) error {
		sel, err := c.Select(folderID, nil).Wait()
		if err != nil {
			return err
		}
		ths, err := cl.threads(c, unreadOnly)
		if err != nil {
			return err
		}
		page = provider.Page{}
		// Anchor the cursor to the last thread's max-UID rather than a numeric
		// offset: threads are strictly ordered by max-UID (unique per message),
		// so a page boundary stays put even as mail arrives (would shift an
		// offset down, duplicating rows) or is expunged (shifting it up, skipping).
		var pageThreads []thread
		for _, t := range ths {
			if after != 0 && t.maxUID >= after {
				continue
			}
			pageThreads = append(pageThreads, t)
			if len(pageThreads) >= limit {
				break
			}
		}
		if len(pageThreads) == 0 {
			return nil
		}

		// one UID FETCH for every member across the page
		var all imap.UIDSet
		for _, t := range pageThreads {
			all.AddNum(t.uids...)
		}
		bufs, err := cl.fetchMeta(c, all)
		if err != nil {
			return err
		}
		for _, t := range pageThreads {
			conv := buildConversation(folderID, sel.UIDValidity, t, bufs)
			cl.remember(conv.ID, t.uids)
			page.Conversations = append(page.Conversations, conv)
		}
		last := pageThreads[len(pageThreads)-1]
		if last.maxUID > 1 { // more may remain below this anchor
			page.NextCursor = "uid:" + strconv.FormatUint(uint64(last.maxUID), 10)
		}
		return nil
	})
	if err != nil {
		return provider.Page{}, err
	}
	return page, nil
}

// parseCursor reads a "uid:<n>" anchor — the max-UID of the last row of the
// previous page; the next page returns threads strictly below it.
func parseCursor(cursor string) imap.UID {
	if strings.HasPrefix(cursor, "uid:") {
		n, _ := strconv.ParseUint(cursor[4:], 10, 32)
		return imap.UID(n)
	}
	return 0
}

func (cl *Client) fetchMeta(c *imapclient.Client, uids imap.UIDSet) (map[imap.UID]*imapclient.FetchMessageBuffer, error) {
	out := map[imap.UID]*imapclient.FetchMessageBuffer{}
	if nums, ok := uids.Nums(); ok && len(nums) == 0 {
		return out, nil
	}
	bufs, err := c.Fetch(uids, &imap.FetchOptions{
		UID:           true,
		Envelope:      true,
		Flags:         true,
		InternalDate:  true,
		BodyStructure: &imap.FetchItemBodyStructure{Extended: true},
	}).Collect()
	if err != nil {
		return nil, err
	}
	for _, b := range bufs {
		out[b.UID] = b
	}
	return out, nil
}

func buildConversation(folderID string, uidvalidity uint32, t thread, bufs map[imap.UID]*imapclient.FetchMessageBuffer) provider.Conversation {
	conv := provider.Conversation{
		ID:        encodeConvID(folderID, uidvalidity, t.root),
		FolderIDs: []string{folderID},
		MsgCount:  len(t.uids),
	}
	type dated struct {
		addr provider.Address
		when time.Time
	}
	var senders []dated
	seen := map[string]bool{}
	for _, u := range t.uids {
		b := bufs[u]
		if b == nil {
			continue
		}
		when := b.InternalDate
		if b.Envelope != nil && !b.Envelope.Date.IsZero() {
			when = b.Envelope.Date
		}
		if when.After(conv.Date) {
			conv.Date = when
			if b.Envelope != nil {
				conv.Subject = cleanSubject(b.Envelope.Subject)
				conv.Snippet = b.Envelope.Subject
			}
		}
		if !hasFlag(b.Flags, imap.FlagSeen) {
			conv.Unread = true
		}
		if hasFlag(b.Flags, imap.FlagFlagged) {
			conv.Starred = true
		}
		if b.BodyStructure != nil && structureHasAttachment(b.BodyStructure) {
			conv.HasAttach = true
		}
		if b.Envelope != nil && len(b.Envelope.From) > 0 {
			a := toAddress(b.Envelope.From[0])
			if !seen[a.Email] {
				seen[a.Email] = true
				senders = append(senders, dated{a, when})
			}
		}
	}
	sort.SliceStable(senders, func(i, j int) bool { return senders[i].when.Before(senders[j].when) })
	for _, s := range senders {
		conv.Senders = append(conv.Senders, s.addr)
	}
	return conv
}

func structureHasAttachment(bs imap.BodyStructure) bool {
	found := false
	bs.Walk(func(path []int, part imap.BodyStructure) bool {
		sp, ok := part.(*imap.BodyStructureSinglePart)
		if !ok {
			return true
		}
		if d := sp.Disposition(); d != nil && strings.EqualFold(d.Value, "attachment") {
			found = true
			return false
		}
		if sp.Filename() != "" {
			found = true
			return false
		}
		return true
	})
	return found
}

var rePrefix = []string{"re:", "sv:", "fwd:", "fw:", "vb:", "aw:"}

func cleanSubject(s string) string {
	for {
		trimmed := strings.TrimSpace(s)
		lower := strings.ToLower(trimmed)
		cut := false
		for _, p := range rePrefix {
			if strings.HasPrefix(lower, p) {
				trimmed = strings.TrimSpace(trimmed[len(p):])
				cut = true
				break
			}
		}
		s = trimmed
		if !cut {
			return s
		}
	}
}

func (cl *Client) GetConversationMeta(ctx context.Context, id string) (provider.Conversation, error) {
	folder, uidvalidity, root, err := decodeConvID(id)
	if err != nil {
		return provider.Conversation{}, err
	}
	var conv provider.Conversation
	err = cl.do(ctx, func(c *imapclient.Client) error {
		sel, err := c.Select(folder, nil).Wait()
		if err != nil {
			return err
		}
		if sel.UIDValidity != uidvalidity {
			return fmt.Errorf("uidvalidity changed for %s", folder)
		}
		uids, err := cl.membersFor(c, id, folder, root)
		if err != nil {
			return err
		}
		var set imap.UIDSet
		set.AddNum(uids...)
		bufs, err := cl.fetchMeta(c, set)
		if err != nil {
			return err
		}
		conv = buildConversation(folder, uidvalidity, mkThread(uids), bufs)
		return nil
	})
	if err != nil {
		return provider.Conversation{}, err
	}
	return conv, nil
}

// membersFor returns the UIDs of the conversation rooted at root, preferring
// the cache populated during listing and re-threading the folder on a miss.
func (cl *Client) membersFor(c *imapclient.Client, convID, folder string, root imap.UID) ([]imap.UID, error) {
	cl.mmu.Lock()
	cached := cl.members[convID]
	cl.mmu.Unlock()
	if len(cached) > 0 {
		return cached, nil
	}
	ths, err := cl.threads(c, false)
	if err != nil {
		return nil, err
	}
	for _, t := range ths {
		for _, u := range t.uids {
			if u == root {
				cl.remember(convID, t.uids)
				return t.uids, nil
			}
		}
	}
	// thread collapsed to just the root (or the root is all that's left)
	return []imap.UID{root}, nil
}

func (cl *Client) remember(convID string, uids []imap.UID) {
	cp := append([]imap.UID(nil), uids...)
	cl.mmu.Lock()
	cl.members[convID] = cp
	cl.mmu.Unlock()
}

// ---- full conversation bodies ----

func (cl *Client) GetConversation(ctx context.Context, id string) ([]provider.Message, error) {
	folder, uidvalidity, root, err := decodeConvID(id)
	if err != nil {
		return nil, err
	}
	var msgs []provider.Message
	err = cl.do(ctx, func(c *imapclient.Client) error {
		sel, err := c.Select(folder, nil).Wait()
		if err != nil {
			return err
		}
		if sel.UIDValidity != uidvalidity {
			// the mailbox was renumbered — this convID's root UID may now point
			// at a different, reused message. Refuse rather than show the wrong thread.
			return fmt.Errorf("uidvalidity changed for %s", folder)
		}
		uids, err := cl.membersFor(c, id, folder, root)
		if err != nil {
			return err
		}
		var set imap.UIDSet
		set.AddNum(uids...)
		bufs, err := c.Fetch(set, &imap.FetchOptions{
			UID:          true,
			Flags:        true,
			InternalDate: true,
			BodySection:  []*imap.FetchItemBodySection{{}},
		}).Collect()
		if err != nil {
			return err
		}
		byUID := map[imap.UID]*imapclient.FetchMessageBuffer{}
		for _, b := range bufs {
			byUID[b.UID] = b
		}
		msgs = msgs[:0]
		for _, u := range uids {
			b := byUID[u]
			if b == nil {
				continue
			}
			raw := b.FindBodySection(&imap.FetchItemBodySection{})
			pm := parseMessage(folder, uidvalidity, root, u, raw)
			pm.Unread = !hasFlag(b.Flags, imap.FlagSeen)
			pm.Starred = hasFlag(b.Flags, imap.FlagFlagged)
			if pm.Date.IsZero() {
				pm.Date = b.InternalDate
			}
			msgs = append(msgs, pm)
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	sort.SliceStable(msgs, func(i, j int) bool { return msgs[i].Date.Before(msgs[j].Date) })
	return msgs, nil
}

// parseMessage turns a raw RFC822 message into a provider.Message, extracting
// the text/html and text/plain bodies and attachment metadata. Attachment IDs
// are the ordinal index; FetchAttachment re-parses to return the bytes.
func parseMessage(folder string, uidvalidity uint32, root, uid imap.UID, raw []byte) provider.Message {
	pm := provider.Message{
		ID:     encodeMsgID(folder, uidvalidity, uid),
		ConvID: encodeConvID(folder, uidvalidity, root),
	}
	mr, err := gomail.CreateReader(bytes.NewReader(raw))
	if err != nil {
		// not a MIME message we can parse — fall back to raw as plain text
		pm.BodyText = string(raw)
		return pm
	}
	h := mr.Header
	if d, err := h.Date(); err == nil {
		pm.Date = d
	}
	pm.Subject, _ = h.Subject()
	if from, err := h.AddressList("From"); err == nil && len(from) > 0 {
		pm.From = provider.Address{Name: from[0].Name, Email: from[0].Address}
	}
	pm.To = mailAddrs(h, "To")
	pm.Cc = mailAddrs(h, "Cc")

	idx := 0
	for {
		part, err := mr.NextPart()
		if err == io.EOF {
			break
		}
		if err != nil {
			break
		}
		if isAttachmentSlot(part.Header) {
			// real attachment, or an inline cid image — both occupy a slot so
			// the daemon's cid rewriter and FetchAttachment can reach them.
			n, _ := io.Copy(io.Discard, part.Body)
			pm.Attachments = append(pm.Attachments, slotAttachment(part.Header, idx, n))
			idx++
			continue
		}
		if ih, ok := part.Header.(*gomail.InlineHeader); ok {
			ct, _, _ := ih.ContentType()
			body, _ := io.ReadAll(part.Body)
			switch {
			case ct == "text/html" && pm.BodyHTML == "":
				pm.BodyHTML = string(body)
			case ct == "text/plain" && pm.BodyText == "":
				pm.BodyText = string(body)
			}
		}
	}
	if pm.Snippet == "" {
		pm.Snippet = snippet(pm.BodyText)
	}
	return pm
}

// isAttachmentSlot classifies a MIME part statelessly — a real attachment, or
// an inline non-text part (a cid-referenced image). Inline text bodies are not
// slots. parseMessage and FetchAttachment both use it so their attachment
// indices line up.
func isAttachmentSlot(ph gomail.PartHeader) bool {
	switch h := ph.(type) {
	case *gomail.AttachmentHeader:
		return true
	case *gomail.InlineHeader:
		ct, _, _ := h.ContentType()
		return ct != "text/plain" && ct != "text/html"
	}
	return false
}

func slotAttachment(ph gomail.PartHeader, idx int, size int64) provider.Attachment {
	att := provider.Attachment{
		ID:        strconv.Itoa(idx),
		Size:      size,
		ContentID: strings.Trim(ph.Get("Content-ID"), "<>"),
	}
	switch h := ph.(type) {
	case *gomail.AttachmentHeader:
		att.Name, _ = h.Filename()
		att.MIME, _, _ = h.ContentType()
		att.Inline = att.ContentID != ""
	case *gomail.InlineHeader:
		att.MIME, _, _ = h.ContentType()
		att.Inline = true // inline non-text ⇒ a cid image
	}
	return att
}

func mailAddrs(h gomail.Header, key string) []provider.Address {
	as, err := h.AddressList(key)
	if err != nil {
		return nil
	}
	out := make([]provider.Address, 0, len(as))
	for _, a := range as {
		out = append(out, provider.Address{Name: a.Name, Email: a.Address})
	}
	return out
}

func snippet(text string) string {
	s := strings.Join(strings.Fields(text), " ")
	if len(s) > 200 {
		s = s[:200]
	}
	return s
}

func (cl *Client) FetchAttachment(ctx context.Context, messageID, attachmentID string) ([]byte, error) {
	folder, uidvalidity, uid, err := decodeMsgID(messageID)
	if err != nil {
		return nil, err
	}
	want, err := strconv.Atoi(attachmentID)
	if err != nil {
		return nil, fmt.Errorf("bad attachment id %q", attachmentID)
	}
	var data []byte
	err = cl.do(ctx, func(c *imapclient.Client) error {
		sel, err := c.Select(folder, nil).Wait()
		if err != nil {
			return err
		}
		if sel.UIDValidity != uidvalidity {
			return fmt.Errorf("uidvalidity changed for %s", folder)
		}
		var set imap.UIDSet
		set.AddNum(uid)
		bufs, err := c.Fetch(set, &imap.FetchOptions{
			UID:         true,
			BodySection: []*imap.FetchItemBodySection{{}},
		}).Collect()
		if err != nil {
			return err
		}
		if len(bufs) == 0 {
			return fmt.Errorf("message %s gone", messageID)
		}
		raw := bufs[0].FindBodySection(&imap.FetchItemBodySection{})
		mr, err := gomail.CreateReader(bytes.NewReader(raw))
		if err != nil {
			return err
		}
		idx := 0
		for {
			part, err := mr.NextPart()
			if err == io.EOF {
				break
			}
			if err != nil {
				return err
			}
			if !isAttachmentSlot(part.Header) {
				continue
			}
			if idx == want {
				data, err = io.ReadAll(part.Body)
				return err
			}
			idx++
		}
		return fmt.Errorf("attachment %s not found in %s", attachmentID, messageID)
	})
	return data, err
}

// ---- delta ----

// Delta tracks new arrivals per folder via UIDVALIDITY/UIDNEXT snapshots. The
// token is a compact "folder:uidvalidity:uidnext,..." string. Flag-only changes
// (read/star toggled elsewhere) are picked up by the UI's on-demand refetch;
// CONDSTORE MODSEQ deltas are a possible later refinement.
func (cl *Client) Delta(ctx context.Context, sinceToken string) (provider.Delta, error) {
	prev := parseDeltaToken(sinceToken)
	var (
		changed []string
		next    = map[string]folderState{}
		resync  bool
	)
	err := cl.do(ctx, func(c *imapclient.Client) error {
		datas, err := c.List("", "*", &imap.ListOptions{
			ReturnSpecialUse: true,
			ReturnStatus:     &imap.StatusOptions{UIDNext: true, UIDValidity: true, NumMessages: true, NumUnseen: true},
		}).Collect()
		if err != nil {
			return err
		}
		for _, d := range datas {
			if hasAttr(d.Attrs, imap.MailboxAttrNonExistent) || d.Status == nil {
				continue
			}
			cur := folderState{
				UIDValidity: d.Status.UIDValidity,
				UIDNext:     uint32(d.Status.UIDNext),
				NumMessages: derefU32(d.Status.NumMessages),
				NumUnseen:   derefU32(d.Status.NumUnseen),
			}
			next[d.Mailbox] = cur
			old, ok := prev[d.Mailbox]
			if !ok {
				continue // new folder since last poll; baseline it silently
			}
			if old.UIDValidity != cur.UIDValidity {
				resync = true
				continue
			}
			if cur == old {
				continue // nothing moved in this folder
			}
			// New mail (UIDNEXT advanced), an expunge (NumMessages dropped), or a
			// read/star toggle from another client (NumUnseen moved) — thread the
			// folder ONCE and emit the touched conversations.
			ids, err := cl.changedConvIDs(c, d.Mailbox, old, cur)
			if err != nil {
				return err
			}
			changed = append(changed, ids...)
		}
		return nil
	})
	if err != nil {
		return provider.Delta{}, err
	}
	if sinceToken == "" || resync {
		return provider.Delta{NextToken: formatDeltaToken(next), FullResync: true}, nil
	}
	return provider.Delta{Changed: dedup(changed), NextToken: formatDeltaToken(next)}, nil
}

// deltaWindow bounds how many recent conversations a state change (expunge or
// read/star toggle) re-emits — flag changes deep in a large mailbox need
// CONDSTORE/QRESYNC to catch precisely; this covers the recent, visible ones.
const deltaWindow = 200

// changedConvIDs threads the folder once and returns the conversation ids that
// moved since `old`: any thread carrying a new UID (arrivals), plus — when the
// folder's message/unseen counts shifted — the recent window (so a read or
// delete on another client refreshes here). It caches members for exactly the
// emitted conversations so the sync loop's GetConversationMeta hits the cache
// instead of re-threading the whole mailbox per changed id.
func (cl *Client) changedConvIDs(c *imapclient.Client, folder string, old, cur folderState) ([]string, error) {
	if _, err := c.Select(folder, nil).Wait(); err != nil {
		return nil, err
	}
	ths, err := cl.threads(c, false)
	if err != nil {
		return nil, err
	}
	// Re-emit the recent window only for changes new UIDs can't explain: an
	// expunge (message count dropped), or a read/star toggle from another
	// client with no new mail (unseen moved while UIDNEXT held). New mail alone
	// is covered by the per-thread hasNew check below, so it doesn't churn the
	// whole window.
	expunged := cur.NumMessages < old.NumMessages
	flagOnly := cur.UIDNext == old.UIDNext && cur.NumUnseen != old.NumUnseen
	stateMoved := expunged || flagOnly
	var ids []string
	for i, t := range ths { // ths is newest-first
		hasNew := false
		for _, u := range t.uids {
			if u >= imap.UID(old.UIDNext) {
				hasNew = true
				break
			}
		}
		if hasNew || (stateMoved && i < deltaWindow) {
			id := encodeConvID(folder, cur.UIDValidity, t.root)
			cl.remember(id, t.uids)
			ids = append(ids, id)
		}
	}
	return ids, nil
}

func derefU32(p *uint32) uint32 {
	if p == nil {
		return 0
	}
	return *p
}

type folderState struct {
	UIDValidity uint32 `json:"v"`
	UIDNext     uint32 `json:"n"`
	NumMessages uint32 `json:"m"`
	NumUnseen   uint32 `json:"u"`
}

// The token is JSON — robust against mailbox names containing ':' or ',' that
// a delimited format would mangle.
func parseDeltaToken(s string) map[string]folderState {
	out := map[string]folderState{}
	if s == "" {
		return out
	}
	json.Unmarshal([]byte(s), &out)
	return out
}

func formatDeltaToken(m map[string]folderState) string {
	b, err := json.Marshal(m)
	if err != nil {
		return ""
	}
	return string(b)
}

func dedup(in []string) []string {
	seen := map[string]bool{}
	var out []string
	for _, s := range in {
		if !seen[s] {
			seen[s] = true
			out = append(out, s)
		}
	}
	return out
}

// ---- flag / move operations ----

func (cl *Client) storeFlag(ctx context.Context, convID string, flag imap.Flag, set bool) error {
	folder, uidvalidity, root, err := decodeConvID(convID)
	if err != nil {
		return err
	}
	op := imap.StoreFlagsAdd
	if !set {
		op = imap.StoreFlagsDel
	}
	return cl.do(ctx, func(c *imapclient.Client) error {
		sel, err := c.Select(folder, nil).Wait()
		if err != nil {
			return err
		}
		if sel.UIDValidity != uidvalidity {
			return fmt.Errorf("uidvalidity changed for %s", folder)
		}
		uids, err := cl.membersFor(c, convID, folder, root)
		if err != nil {
			return err
		}
		var s imap.UIDSet
		s.AddNum(uids...)
		cmd := c.Store(s, &imap.StoreFlags{Op: op, Silent: true, Flags: []imap.Flag{flag}}, nil)
		return cmd.Close()
	})
}

func (cl *Client) MarkRead(ctx context.Context, convID string, read bool) error {
	return cl.storeFlag(ctx, convID, imap.FlagSeen, read)
}

func (cl *Client) Star(ctx context.Context, convID string, starred bool) error {
	return cl.storeFlag(ctx, convID, imap.FlagFlagged, starred)
}

// move relocates every member of the conversation to dstRole's mailbox. destFor
// resolves the target; an empty target (no such special folder) is a no-op
// error surfaced to the user.
func (cl *Client) move(ctx context.Context, convID, dstRole, dstFallback string) error {
	folder, uidvalidity, root, err := decodeConvID(convID)
	if err != nil {
		return err
	}
	return cl.do(ctx, func(c *imapclient.Client) error {
		dst := cl.specialMailbox(c, dstRole)
		if dst == "" {
			dst = dstFallback
		}
		if dst == "" || strings.EqualFold(dst, folder) {
			return fmt.Errorf("no %s folder to move to", dstRole)
		}
		sel, err := c.Select(folder, nil).Wait()
		if err != nil {
			return err
		}
		if sel.UIDValidity != uidvalidity {
			return fmt.Errorf("uidvalidity changed for %s", folder)
		}
		uids, err := cl.membersFor(c, convID, folder, root)
		if err != nil {
			return err
		}
		var s imap.UIDSet
		s.AddNum(uids...)
		if _, err := c.Move(s, dst).Wait(); err != nil {
			return err
		}
		cl.mmu.Lock()
		delete(cl.members, convID)
		cl.mmu.Unlock()
		return nil
	})
}

func (cl *Client) Archive(ctx context.Context, convID string) error {
	return cl.move(ctx, convID, "archive", "Archive")
}

func (cl *Client) Unarchive(ctx context.Context, convID string) error {
	return cl.moveToInbox(ctx, convID)
}

func (cl *Client) Trash(ctx context.Context, convID string) error {
	return cl.move(ctx, convID, "trash", "Trash")
}

func (cl *Client) Untrash(ctx context.Context, convID string) error {
	return cl.moveToInbox(ctx, convID)
}

func (cl *Client) moveToInbox(ctx context.Context, convID string) error {
	folder, uidvalidity, root, err := decodeConvID(convID)
	if err != nil {
		return err
	}
	return cl.do(ctx, func(c *imapclient.Client) error {
		if strings.EqualFold(folder, "INBOX") {
			return nil
		}
		sel, err := c.Select(folder, nil).Wait()
		if err != nil {
			return err
		}
		if sel.UIDValidity != uidvalidity {
			return fmt.Errorf("uidvalidity changed for %s", folder)
		}
		uids, err := cl.membersFor(c, convID, folder, root)
		if err != nil {
			return err
		}
		var s imap.UIDSet
		s.AddNum(uids...)
		if _, err := c.Move(s, "INBOX").Wait(); err != nil {
			return err
		}
		cl.mmu.Lock()
		delete(cl.members, convID)
		cl.mmu.Unlock()
		return nil
	})
}

// ---- search ----

func (cl *Client) Search(ctx context.Context, q string, limit int) (provider.Page, error) {
	if limit <= 0 {
		limit = 50
	}
	var page provider.Page
	err := cl.do(ctx, func(c *imapclient.Client) error {
		sel, err := c.Select("INBOX", nil).Wait()
		if err != nil {
			return err
		}
		data, err := c.UIDSearch(&imap.SearchCriteria{Text: []string{q}}, nil).Wait()
		if err != nil {
			return err
		}
		uids := data.AllUIDs()
		sort.Slice(uids, func(i, j int) bool { return uids[i] > uids[j] })
		if len(uids) > limit {
			uids = uids[:limit]
		}
		var set imap.UIDSet
		set.AddNum(uids...)
		bufs, err := cl.fetchMeta(c, set)
		if err != nil {
			return err
		}
		for _, u := range uids {
			conv := buildConversation("INBOX", sel.UIDValidity, thread{root: u, uids: []imap.UID{u}, maxUID: u}, bufs)
			page.Conversations = append(page.Conversations, conv)
		}
		return nil
	})
	if err != nil {
		return provider.Page{}, err
	}
	return page, nil
}

// ---- send ----

func (cl *Client) Send(ctx context.Context, d provider.Draft) error {
	var inReplyTo string
	if d.InReplyTo != "" {
		if folder, _, uid, err := decodeMsgID(d.InReplyTo); err == nil {
			cl.do(ctx, func(c *imapclient.Client) error {
				if _, err := c.Select(folder, nil).Wait(); err != nil {
					return err
				}
				var s imap.UIDSet
				s.AddNum(uid)
				bufs, err := c.Fetch(s, &imap.FetchOptions{UID: true, Envelope: true}).Collect()
				if err == nil && len(bufs) > 0 && bufs[0].Envelope != nil {
					inReplyTo = bufs[0].Envelope.MessageID
				}
				return nil
			})
		}
	}

	raw, err := cl.buildMIME(d, inReplyTo)
	if err != nil {
		return err
	}

	rcpts := recipients(d)
	if err := cl.sendSMTP(cl.cfg.Email, rcpts, raw); err != nil {
		return err
	}
	// best-effort: file a copy in Sent (server may already, e.g. Gmail — but a
	// plain IMAP host does not, so we APPEND). Failure here must not fail the send.
	cl.appendSent(ctx, raw)
	return nil
}

func recipients(d provider.Draft) []string {
	var out []string
	for _, group := range [][]provider.Address{d.To, d.Cc, d.Bcc} {
		for _, a := range group {
			if a.Email != "" {
				out = append(out, a.Email)
			}
		}
	}
	return out
}

func (cl *Client) sendSMTP(from string, to []string, raw []byte) error {
	if len(to) == 0 {
		return fmt.Errorf("no recipients")
	}
	addr := fmt.Sprintf("%s:%d", cl.cfg.SMTPHost, cl.cfg.SMTPPort)
	var (
		c   *smtp.Client
		err error
	)
	switch cl.cfg.SMTPSecurity {
	case "ssl":
		c, err = smtp.DialTLS(addr, nil)
	case "plain":
		c, err = smtp.Dial(addr)
	default: // starttls
		c, err = smtp.DialStartTLS(addr, nil)
	}
	if err != nil {
		return fmt.Errorf("smtp dial %s: %w", addr, err)
	}
	defer c.Close()

	host, _ := os.Hostname()
	if host == "" {
		host = "localhost"
	}
	if err := c.Hello(host); err != nil {
		return err
	}
	if ok, _ := c.Extension("AUTH"); ok {
		if err := c.Auth(sasl.NewPlainClient("", cl.cfg.user(), cl.cfg.Password)); err != nil {
			return fmt.Errorf("smtp auth: %w", err)
		}
	}
	return c.SendMail(from, to, bytes.NewReader(raw))
}

func (cl *Client) appendSent(ctx context.Context, raw []byte) {
	// doOnce, not do: a redial-and-retry after the server has committed the
	// APPEND but before we read its response would file a second Sent copy.
	cl.doOnce(ctx, func(c *imapclient.Client) error {
		sent := cl.specialMailbox(c, "sent")
		if sent == "" {
			return nil
		}
		cmd := c.Append(sent, int64(len(raw)), &imap.AppendOptions{Flags: []imap.Flag{imap.FlagSeen}})
		if _, err := cmd.Write(raw); err != nil {
			cmd.Close()
			return err
		}
		if err := cmd.Close(); err != nil {
			return err
		}
		_, err := cmd.Wait()
		return err
	})
}

func (cl *Client) buildMIME(d provider.Draft, inReplyTo string) ([]byte, error) {
	var buf bytes.Buffer
	var h gomail.Header
	h.SetAddressList("From", []*mail.Address{{Name: "", Address: cl.cfg.Email}})
	h.SetAddressList("To", toMailAddrs(d.To))
	if len(d.Cc) > 0 {
		h.SetAddressList("Cc", toMailAddrs(d.Cc))
	}
	// Deliberately no Bcc header: plain SMTP submission transmits the message
	// bytes verbatim, so a Bcc: line would expose blind recipients to everyone
	// (and file into Sent that way too). recipients() already carries Bcc in the
	// SMTP envelope, which is all that's needed for delivery.
	h.SetSubject(d.Subject)
	h.SetDate(time.Now())
	if inReplyTo != "" {
		ref := inReplyTo
		if !strings.HasPrefix(ref, "<") {
			ref = "<" + ref + ">"
		}
		h.Set("In-Reply-To", ref)
		h.Set("References", ref)
	}

	mw, err := gomail.CreateWriter(&buf, h)
	if err != nil {
		return nil, err
	}
	tw, err := mw.CreateInline()
	if err != nil {
		return nil, err
	}
	var th gomail.InlineHeader
	th.Set("Content-Type", "text/plain; charset=utf-8")
	pw, err := tw.CreatePart(th)
	if err != nil {
		return nil, err
	}
	io.WriteString(pw, d.BodyText)
	pw.Close()
	tw.Close()

	for _, path := range d.AttachmentPaths {
		data, err := os.ReadFile(path)
		if err != nil {
			return nil, fmt.Errorf("attachment %s: %w", path, err)
		}
		var ah gomail.AttachmentHeader
		ah.SetFilename(baseName(path))
		aw, err := mw.CreateAttachment(ah)
		if err != nil {
			return nil, err
		}
		aw.Write(data)
		aw.Close()
	}
	if err := mw.Close(); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

func toMailAddrs(as []provider.Address) []*mail.Address {
	out := make([]*mail.Address, 0, len(as))
	for _, a := range as {
		out = append(out, &mail.Address{Name: a.Name, Address: a.Email})
	}
	return out
}

func baseName(path string) string {
	if i := strings.LastIndexByte(path, '/'); i >= 0 {
		return path[i+1:]
	}
	return path
}

// ---- small helpers ----

func toAddress(a imap.Address) provider.Address {
	return provider.Address{Name: a.Name, Email: a.Addr()}
}

func hasFlag(flags []imap.Flag, want imap.Flag) bool {
	for _, f := range flags {
		if f == want {
			return true
		}
	}
	return false
}
