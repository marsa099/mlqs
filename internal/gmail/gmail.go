// Package gmail implements provider.Provider over the Gmail REST API.
// Raw HTTP (no Google SDK) — same approach as slqs takes with Slack.
package gmail

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"mime"
	"mime/multipart"
	"net/http"
	"net/mail"
	"net/textproto"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"golang.org/x/oauth2"

	"mlqs/internal/debuglog"
	"mlqs/internal/httpx"
	"mlqs/internal/provider"
)

const apiBase = "https://gmail.googleapis.com/gmail/v1/users/me"

type Client struct {
	hc *http.Client
}

func New(ctx context.Context, ts oauth2.TokenSource) *Client {
	return &Client{hc: &http.Client{
		Transport: &oauth2.Transport{Source: ts, Base: httpx.Transport()},
		Timeout:   90 * time.Second,
	}}
}

type apiError struct {
	status int
	msg    string
}

func (e *apiError) Error() string { return fmt.Sprintf("gmail: %d %s", e.status, e.msg) }

func (c *Client) do(ctx context.Context, method, path string, q url.Values, body, out any) error {
	u := apiBase + path
	if len(q) > 0 {
		u += "?" + q.Encode()
	}
	var rdr io.Reader
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			return err
		}
		rdr = bytes.NewReader(b)
	}
	req, err := http.NewRequestWithContext(ctx, method, u, rdr)
	if err != nil {
		return err
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := c.hc.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	rb, err := io.ReadAll(resp.Body)
	if err != nil {
		return err
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		var e struct {
			Error struct {
				Message string `json:"message"`
			} `json:"error"`
		}
		json.Unmarshal(rb, &e)
		debuglog.API("gmail %s %s -> %d %s", method, path, resp.StatusCode, e.Error.Message)
		return &apiError{status: resp.StatusCode, msg: e.Error.Message}
	}
	if out != nil && len(rb) > 0 {
		return json.Unmarshal(rb, out)
	}
	return nil
}

func (c *Client) get(ctx context.Context, path string, q url.Values, out any) error {
	return c.do(ctx, "GET", path, q, nil, out)
}

func (c *Client) post(ctx context.Context, path string, body, out any) error {
	return c.do(ctx, "POST", path, nil, body, out)
}

// Profile returns the account email and current historyId — the initial
// delta token for an account that has never synced.
func (c *Client) Profile(ctx context.Context) (email, historyID string, err error) {
	var p struct {
		EmailAddress string `json:"emailAddress"`
		HistoryID    string `json:"historyId"`
	}
	if err := c.get(ctx, "/profile", nil, &p); err != nil {
		return "", "", err
	}
	return p.EmailAddress, p.HistoryID, nil
}

// ---- folders (labels) ----

var systemRole = map[string]string{
	"INBOX": "inbox", "STARRED": "starred", "SENT": "sent",
	"DRAFT": "drafts", "SPAM": "spam", "TRASH": "trash",
}

var roleOrder = map[string]int{
	"inbox": 0, "starred": 1, "sent": 2, "drafts": 3, "spam": 4, "trash": 5, "label": 6,
}

func (c *Client) ListFolders(ctx context.Context) ([]provider.Folder, error) {
	var list struct {
		Labels []struct {
			ID   string `json:"id"`
			Name string `json:"name"`
			Type string `json:"type"`
		} `json:"labels"`
	}
	if err := c.get(ctx, "/labels", nil, &list); err != nil {
		return nil, err
	}
	var folders []provider.Folder
	for _, l := range list.Labels {
		role, isSystem := systemRole[l.ID]
		if !isSystem {
			// skip Gmail's synthetic buckets; user labels only
			if l.Type != "user" {
				continue
			}
			role = "label"
		}
		name := l.Name
		if role == "starred" {
			name = "Important"
		}
		folders = append(folders, provider.Folder{ID: l.ID, Name: name, Role: role})
	}

	// labels.list has no counts; fetch each label's unread/total concurrently
	var wg sync.WaitGroup
	sem := make(chan struct{}, 8)
	for i := range folders {
		wg.Add(1)
		go func(f *provider.Folder) {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()
			var lb struct {
				ThreadsUnread int `json:"threadsUnread"`
				ThreadsTotal  int `json:"threadsTotal"`
			}
			if err := c.get(ctx, "/labels/"+f.ID, nil, &lb); err == nil {
				f.Unread, f.Total = lb.ThreadsUnread, lb.ThreadsTotal
			}
		}(&folders[i])
	}
	wg.Wait()

	sort.SliceStable(folders, func(i, j int) bool {
		a, b := folders[i], folders[j]
		if roleOrder[a.Role] != roleOrder[b.Role] {
			return roleOrder[a.Role] < roleOrder[b.Role]
		}
		return a.Name < b.Name
	})
	return folders, nil
}

// ---- conversation listing ----

type apiHeader struct {
	Name  string `json:"name"`
	Value string `json:"value"`
}

func headerVal(hs []apiHeader, name string) string {
	for _, h := range hs {
		if strings.EqualFold(h.Name, name) {
			return h.Value
		}
	}
	return ""
}

type apiThreadStub struct {
	ID      string `json:"id"`
	Snippet string `json:"snippet"`
}

type apiPart struct {
	PartID   string `json:"partId"`
	MimeType string `json:"mimeType"`
	Filename string `json:"filename"`
	Headers  []apiHeader
	Body     struct {
		AttachmentID string `json:"attachmentId"`
		Size         int64  `json:"size"`
		Data         string `json:"data"`
	} `json:"body"`
	Parts []apiPart `json:"parts"`
}

type apiMessage struct {
	ID           string   `json:"id"`
	ThreadID     string   `json:"threadId"`
	LabelIDs     []string `json:"labelIds"`
	Snippet      string   `json:"snippet"`
	InternalDate string   `json:"internalDate"`
	Payload      apiPart  `json:"payload"`
}

type apiThread struct {
	ID       string       `json:"id"`
	Messages []apiMessage `json:"messages"`
}

func parseAddr(s string) provider.Address {
	if a, err := mail.ParseAddress(s); err == nil {
		return provider.Address{Name: a.Name, Email: a.Address}
	}
	return provider.Address{Name: s}
}

func parseAddrList(s string) []provider.Address {
	if s == "" {
		return nil
	}
	list, err := mail.ParseAddressList(s)
	if err != nil {
		return []provider.Address{{Name: s}}
	}
	out := make([]provider.Address, 0, len(list))
	for _, a := range list {
		out = append(out, provider.Address{Name: a.Name, Email: a.Address})
	}
	return out
}

func msDate(internal string) time.Time {
	ms, _ := strconv.ParseInt(internal, 10, 64)
	return time.UnixMilli(ms)
}

func hasLabel(ids []string, l string) bool {
	for _, id := range ids {
		if id == l {
			return true
		}
	}
	return false
}

func (c *Client) threadPage(ctx context.Context, q url.Values, limit int) (provider.Page, error) {
	if limit <= 0 {
		limit = 50
	}
	q.Set("maxResults", strconv.Itoa(limit))
	var list struct {
		Threads       []apiThreadStub `json:"threads"`
		NextPageToken string          `json:"nextPageToken"`
	}
	if err := c.get(ctx, "/threads", q, &list); err != nil {
		return provider.Page{}, err
	}

	convs := make([]provider.Conversation, len(list.Threads))
	var wg sync.WaitGroup
	sem := make(chan struct{}, 8)
	for i, stub := range list.Threads {
		wg.Add(1)
		go func(i int, stub apiThreadStub) {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()
			conv, err := c.threadMeta(ctx, stub.ID)
			if err != nil {
				debuglog.API("threadMeta %s: %v", stub.ID, err)
				conv = provider.Conversation{ID: stub.ID, Subject: "(unavailable)"}
			}
			conv.Snippet = stub.Snippet
			convs[i] = conv
		}(i, stub)
	}
	wg.Wait()
	return provider.Page{Conversations: convs, NextCursor: list.NextPageToken}, nil
}

// threadMeta fetches header-level metadata for one thread and folds it into
// the index-row shape: latest date, unique senders, unread/starred anywhere.
func (c *Client) threadMeta(ctx context.Context, id string) (provider.Conversation, error) {
	q := url.Values{"format": {"metadata"}}
	q["metadataHeaders"] = []string{"Subject", "From"}
	var t apiThread
	if err := c.get(ctx, "/threads/"+id, q, &t); err != nil {
		return provider.Conversation{}, err
	}
	conv := provider.Conversation{ID: t.ID, MsgCount: len(t.Messages)}
	seen := map[string]bool{}
	folderSeen := map[string]bool{}
	for i, m := range t.Messages {
		if i == 0 {
			conv.Subject = headerVal(m.Payload.Headers, "Subject")
		}
		if from := headerVal(m.Payload.Headers, "From"); from != "" {
			a := parseAddr(from)
			if !seen[a.Email] {
				seen[a.Email] = true
				conv.Senders = append(conv.Senders, a)
			}
		}
		if d := msDate(m.InternalDate); d.After(conv.Date) {
			conv.Date = d
		}
		conv.Snippet = m.Snippet
		conv.Unread = conv.Unread || hasLabel(m.LabelIDs, "UNREAD")
		conv.Starred = conv.Starred || hasLabel(m.LabelIDs, "STARRED")
		for _, l := range m.LabelIDs {
			if !folderSeen[l] {
				folderSeen[l] = true
				conv.FolderIDs = append(conv.FolderIDs, l)
			}
		}
	}
	return conv, nil
}

func (c *Client) GetConversationMeta(ctx context.Context, id string) (provider.Conversation, error) {
	return c.threadMeta(ctx, id)
}

func (c *Client) ListConversations(ctx context.Context, folderID, cursor string, limit int, unreadOnly bool) (provider.Page, error) {
	q := url.Values{"labelIds": {folderID}}
	if cursor != "" {
		q.Set("pageToken", cursor)
	}
	if unreadOnly {
		q.Set("q", "is:unread")
	}
	return c.threadPage(ctx, q, limit)
}

func (c *Client) Search(ctx context.Context, query string, limit int) (provider.Page, error) {
	return c.threadPage(ctx, url.Values{"q": {query}}, limit)
}

// ---- full conversation ----

func decodeB64url(s string) []byte {
	if b, err := base64.URLEncoding.DecodeString(s); err == nil {
		return b
	}
	b, _ := base64.RawURLEncoding.DecodeString(s)
	return b
}

func walkParts(p apiPart, msg *provider.Message) {
	if len(p.Parts) > 0 {
		for _, ch := range p.Parts {
			walkParts(ch, msg)
		}
		return
	}
	if p.Body.AttachmentID != "" {
		cid := strings.Trim(headerVal(p.Headers, "Content-ID"), "<>")
		disp := headerVal(p.Headers, "Content-Disposition")
		msg.Attachments = append(msg.Attachments, provider.Attachment{
			ID: p.Body.AttachmentID, Name: p.Filename, MIME: p.MimeType,
			Size: p.Body.Size, ContentID: cid,
			Inline: cid != "" || strings.HasPrefix(disp, "inline"),
		})
		return
	}
	switch {
	case p.MimeType == "text/html" && msg.BodyHTML == "":
		msg.BodyHTML = string(decodeB64url(p.Body.Data))
	case p.MimeType == "text/plain" && msg.BodyText == "":
		msg.BodyText = string(decodeB64url(p.Body.Data))
	}
}

func (c *Client) GetConversation(ctx context.Context, id string) ([]provider.Message, error) {
	var t apiThread
	if err := c.get(ctx, "/threads/"+id, url.Values{"format": {"full"}}, &t); err != nil {
		return nil, err
	}
	msgs := make([]provider.Message, 0, len(t.Messages))
	for _, m := range t.Messages {
		pm := provider.Message{
			ID: m.ID, ConvID: m.ThreadID, Snippet: m.Snippet,
			Date:    msDate(m.InternalDate),
			Unread:  hasLabel(m.LabelIDs, "UNREAD"),
			Starred: hasLabel(m.LabelIDs, "STARRED"),
			Subject: headerVal(m.Payload.Headers, "Subject"),
			From:    parseAddr(headerVal(m.Payload.Headers, "From")),
			ReplyTo: parseAddrList(headerVal(m.Payload.Headers, "Reply-To")),
			To:      parseAddrList(headerVal(m.Payload.Headers, "To")),
			Cc:      parseAddrList(headerVal(m.Payload.Headers, "Cc")),
		}
		walkParts(m.Payload, &pm)
		msgs = append(msgs, pm)
	}
	return msgs, nil
}

// FetchAttachment downloads one attachment body.
func (c *Client) FetchAttachment(ctx context.Context, messageID, attachmentID string) ([]byte, error) {
	var out struct {
		Data string `json:"data"`
	}
	if err := c.get(ctx, "/messages/"+messageID+"/attachments/"+attachmentID, nil, &out); err != nil {
		return nil, err
	}
	return decodeB64url(out.Data), nil
}

// ---- delta sync ----

func (c *Client) Delta(ctx context.Context, sinceToken string) (provider.Delta, error) {
	if sinceToken == "" {
		_, hid, err := c.Profile(ctx)
		if err != nil {
			return provider.Delta{}, err
		}
		return provider.Delta{NextToken: hid, FullResync: true}, nil
	}

	changed := map[string]bool{}
	nextToken := sinceToken
	pageToken := ""
	for {
		q := url.Values{"startHistoryId": {sinceToken}}
		if pageToken != "" {
			q.Set("pageToken", pageToken)
		}
		var resp struct {
			History []struct {
				MessagesAdded []struct {
					Message struct {
						ThreadID string `json:"threadId"`
					} `json:"message"`
				} `json:"messagesAdded"`
				MessagesDeleted []struct {
					Message struct {
						ThreadID string `json:"threadId"`
					} `json:"message"`
				} `json:"messagesDeleted"`
				LabelsAdded []struct {
					Message struct {
						ThreadID string `json:"threadId"`
					} `json:"message"`
				} `json:"labelsAdded"`
				LabelsRemoved []struct {
					Message struct {
						ThreadID string `json:"threadId"`
					} `json:"message"`
				} `json:"labelsRemoved"`
			} `json:"history"`
			HistoryID     string `json:"historyId"`
			NextPageToken string `json:"nextPageToken"`
		}
		err := c.get(ctx, "/history", q, &resp)
		if err != nil {
			// expired history token → caller re-lists from scratch
			var ae *apiError
			if isStatus(err, 404, &ae) {
				_, hid, perr := c.Profile(ctx)
				if perr != nil {
					return provider.Delta{}, perr
				}
				return provider.Delta{NextToken: hid, FullResync: true}, nil
			}
			return provider.Delta{}, err
		}
		for _, h := range resp.History {
			for _, x := range h.MessagesAdded {
				changed[x.Message.ThreadID] = true
			}
			for _, x := range h.MessagesDeleted {
				changed[x.Message.ThreadID] = true
			}
			for _, x := range h.LabelsAdded {
				changed[x.Message.ThreadID] = true
			}
			for _, x := range h.LabelsRemoved {
				changed[x.Message.ThreadID] = true
			}
		}
		if resp.HistoryID != "" {
			nextToken = resp.HistoryID
		}
		if resp.NextPageToken == "" {
			break
		}
		pageToken = resp.NextPageToken
	}

	d := provider.Delta{NextToken: nextToken}
	for id := range changed {
		d.Changed = append(d.Changed, id)
	}
	return d, nil
}

func isStatus(err error, code int, out **apiError) bool {
	ae, ok := err.(*apiError)
	if ok && ae.status == code {
		*out = ae
		return true
	}
	return false
}

// ---- actions ----

func (c *Client) modify(ctx context.Context, convID string, add, remove []string) error {
	body := map[string]any{}
	if len(add) > 0 {
		body["addLabelIds"] = add
	}
	if len(remove) > 0 {
		body["removeLabelIds"] = remove
	}
	return c.post(ctx, "/threads/"+convID+"/modify", body, nil)
}

func (c *Client) MarkRead(ctx context.Context, convID string, read bool) error {
	if read {
		return c.modify(ctx, convID, nil, []string{"UNREAD"})
	}
	return c.modify(ctx, convID, []string{"UNREAD"}, nil)
}

func (c *Client) Star(ctx context.Context, convID string, starred bool) error {
	if starred {
		return c.modify(ctx, convID, []string{"STARRED"}, nil)
	}
	return c.modify(ctx, convID, nil, []string{"STARRED"})
}

func (c *Client) Archive(ctx context.Context, convID string) error {
	return c.modify(ctx, convID, nil, []string{"INBOX"})
}

func (c *Client) Unarchive(ctx context.Context, convID string) error {
	return c.modify(ctx, convID, []string{"INBOX"}, nil)
}

func (c *Client) Trash(ctx context.Context, convID string) error {
	return c.post(ctx, "/threads/"+convID+"/trash", nil, nil)
}

func (c *Client) Untrash(ctx context.Context, convID string) error {
	return c.post(ctx, "/threads/"+convID+"/untrash", nil, nil)
}

// ---- send ----

// Send builds an RFC822 MIME message and posts it. Gmail's send endpoint
// takes raw MIME (unlike Graph's JSON) — threading needs both threadId and
// the RFC In-Reply-To/References headers, fetched from the replied-to message.
func (c *Client) Send(ctx context.Context, d provider.Draft) error {
	var replyMsgID string
	if d.InReplyTo != "" {
		q := url.Values{"format": {"metadata"}, "metadataHeaders": {"Message-ID"}}
		var m struct {
			Payload struct {
				Headers []apiHeader `json:"headers"`
			} `json:"payload"`
		}
		if err := c.get(ctx, "/messages/"+d.InReplyTo, q, &m); err == nil {
			replyMsgID = headerVal(m.Payload.Headers, "Message-ID")
		}
	}

	raw, err := buildMIME(d, replyMsgID)
	if err != nil {
		return err
	}
	body := map[string]any{"raw": base64.RawURLEncoding.EncodeToString(raw)}
	if d.ConvID != "" {
		body["threadId"] = d.ConvID
	}
	return c.post(ctx, "/messages/send", body, nil)
}

func addrLine(as []provider.Address) string {
	parts := make([]string, 0, len(as))
	for _, a := range as {
		parts = append(parts, (&mail.Address{Name: a.Name, Address: a.Email}).String())
	}
	return strings.Join(parts, ", ")
}

func b64wrap(b []byte) string {
	s := base64.StdEncoding.EncodeToString(b)
	var out strings.Builder
	for len(s) > 76 {
		out.WriteString(s[:76] + "\r\n")
		s = s[76:]
	}
	out.WriteString(s + "\r\n")
	return out.String()
}

func buildMIME(d provider.Draft, replyMsgID string) ([]byte, error) {
	var buf bytes.Buffer
	w := func(k, v string) {
		if v != "" {
			fmt.Fprintf(&buf, "%s: %s\r\n", k, v)
		}
	}
	w("To", addrLine(d.To))
	w("Cc", addrLine(d.Cc))
	w("Bcc", addrLine(d.Bcc))
	w("Subject", mime.QEncoding.Encode("utf-8", d.Subject))
	if replyMsgID != "" {
		w("In-Reply-To", replyMsgID)
		w("References", replyMsgID)
	}
	w("MIME-Version", "1.0")

	if len(d.AttachmentPaths) == 0 {
		w("Content-Type", `text/plain; charset="UTF-8"`)
		w("Content-Transfer-Encoding", "base64")
		buf.WriteString("\r\n" + b64wrap([]byte(d.BodyText)))
		return buf.Bytes(), nil
	}

	mp := multipart.NewWriter(&buf)
	w("Content-Type", `multipart/mixed; boundary="`+mp.Boundary()+`"`)
	buf.WriteString("\r\n")

	th := textproto.MIMEHeader{}
	th.Set("Content-Type", `text/plain; charset="UTF-8"`)
	th.Set("Content-Transfer-Encoding", "base64")
	tw, err := mp.CreatePart(th)
	if err != nil {
		return nil, err
	}
	tw.Write([]byte(b64wrap([]byte(d.BodyText))))

	for _, path := range d.AttachmentPaths {
		data, err := os.ReadFile(path)
		if err != nil {
			return nil, fmt.Errorf("attachment %s: %w", path, err)
		}
		name := filepath.Base(path)
		ct := mime.TypeByExtension(filepath.Ext(path))
		if ct == "" {
			ct = "application/octet-stream"
		}
		ah := textproto.MIMEHeader{}
		ah.Set("Content-Type", ct)
		ah.Set("Content-Transfer-Encoding", "base64")
		ah.Set("Content-Disposition", fmt.Sprintf(`attachment; filename="%s"`, name))
		aw, err := mp.CreatePart(ah)
		if err != nil {
			return nil, err
		}
		aw.Write([]byte(b64wrap(data)))
	}
	if err := mp.Close(); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

var _ provider.Provider = (*Client)(nil)

// ---- triage helpers ----

// EstimateThreads sizes a search without fetching it (Gmail's estimate —
// rough above ~1000 but fine for bucket planning).
func (c *Client) EstimateThreads(ctx context.Context, query string) (int, error) {
	q := url.Values{"q": {query}, "maxResults": {"1"}, "fields": {"resultSizeEstimate"}}
	var out struct {
		ResultSizeEstimate int `json:"resultSizeEstimate"`
	}
	if err := c.get(ctx, "/threads", q, &out); err != nil {
		return 0, err
	}
	return out.ResultSizeEstimate, nil
}

// ListMessageIDs pages through message ids matching a query, up to max.
func (c *Client) ListMessageIDs(ctx context.Context, query string, max int) ([]string, error) {
	var ids []string
	pageToken := ""
	for len(ids) < max {
		q := url.Values{"q": {query}, "maxResults": {"500"}, "fields": {"messages/id,nextPageToken"}}
		if pageToken != "" {
			q.Set("pageToken", pageToken)
		}
		var out struct {
			Messages []struct {
				ID string `json:"id"`
			} `json:"messages"`
			NextPageToken string `json:"nextPageToken"`
		}
		if err := c.get(ctx, "/messages", q, &out); err != nil {
			return ids, err
		}
		for _, m := range out.Messages {
			ids = append(ids, m.ID)
		}
		if out.NextPageToken == "" {
			break
		}
		pageToken = out.NextPageToken
	}
	if len(ids) > max {
		ids = ids[:max]
	}
	return ids, nil
}

// BatchModify applies label changes to up to 1000 message ids per call.
func (c *Client) BatchModify(ctx context.Context, ids, add, remove []string) error {
	for start := 0; start < len(ids); start += 1000 {
		end := min(start+1000, len(ids))
		body := map[string]any{"ids": ids[start:end]}
		if len(add) > 0 {
			body["addLabelIds"] = add
		}
		if len(remove) > 0 {
			body["removeLabelIds"] = remove
		}
		if err := c.post(ctx, "/messages/batchModify", body, nil); err != nil {
			return err
		}
	}
	return nil
}

// SearchPage is Search with an explicit cursor, for paging a triage scan.
func (c *Client) SearchPage(ctx context.Context, query, cursor string, limit int) (provider.Page, error) {
	q := url.Values{"q": {query}}
	if cursor != "" {
		q.Set("pageToken", cursor)
	}
	return c.threadPage(ctx, q, limit)
}

// HarvestAddresses collects every From/To/Cc address across the threads
// matching a query — the contacts cold-start seed (people I write to).
func (c *Client) HarvestAddresses(ctx context.Context, query string, limit int) ([]provider.Address, error) {
	q := url.Values{"q": {query}, "maxResults": {strconv.Itoa(limit)}}
	var list struct {
		Threads []apiThreadStub `json:"threads"`
	}
	if err := c.get(ctx, "/threads", q, &list); err != nil {
		return nil, err
	}
	var mu sync.Mutex
	var out []provider.Address
	var wg sync.WaitGroup
	sem := make(chan struct{}, 8)
	for _, st := range list.Threads {
		wg.Add(1)
		go func(id string) {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()
			qq := url.Values{"format": {"metadata"}}
			qq["metadataHeaders"] = []string{"From", "To", "Cc"}
			var t apiThread
			if err := c.get(ctx, "/threads/"+id, qq, &t); err != nil {
				return
			}
			var got []provider.Address
			for _, m := range t.Messages {
				got = append(got, parseAddr(headerVal(m.Payload.Headers, "From")))
				got = append(got, parseAddrList(headerVal(m.Payload.Headers, "To"))...)
				got = append(got, parseAddrList(headerVal(m.Payload.Headers, "Cc"))...)
			}
			mu.Lock()
			out = append(out, got...)
			mu.Unlock()
		}(st.ID)
	}
	wg.Wait()
	return out, nil
}
