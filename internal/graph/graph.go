// Package graph implements provider.Provider and provider.CalendarProvider
// over the Microsoft Graph REST API — Outlook mail + calendar (Teams
// meetings), raw HTTP like the gmail/gcal packages.
//
// Graph has no thread API: messages carry a conversationId and everything
// conversation-shaped here is grouped client-side. Conversation-level
// actions (read/star/archive/trash) fan out over the member messages.
package graph

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"golang.org/x/oauth2"

	"mlqs/internal/debuglog"
	"mlqs/internal/httpx"
	"mlqs/internal/provider"
)

const apiBase = "https://graph.microsoft.com/v1.0"

type Client struct {
	hc *http.Client

	mu        sync.Mutex
	wellKnown map[string]string // wellKnownName -> folder id
}

func New(ctx context.Context, ts oauth2.TokenSource) *Client {
	return &Client{
		hc: &http.Client{
			Transport: &oauth2.Transport{Source: ts, Base: httpx.Transport()},
			Timeout:   90 * time.Second,
		},
		wellKnown: map[string]string{},
	}
}

// do calls a path under the API base; doAbs takes a full URL (nextLink pages).
func (c *Client) do(ctx context.Context, method, path string, q url.Values, body, out any) error {
	u := apiBase + path
	if len(q) > 0 {
		u += "?" + q.Encode()
	}
	return c.doAbs(ctx, method, u, body, out)
}

func (c *Client) doAbs(ctx context.Context, method, u string, body, out any) error {
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
	if resp.StatusCode == 410 {
		return errGone
	}
	if resp.StatusCode >= 300 {
		msg := string(rb)
		var e struct {
			Error struct {
				Message string `json:"message"`
			} `json:"error"`
		}
		if json.Unmarshal(rb, &e) == nil && e.Error.Message != "" {
			msg = e.Error.Message
		}
		return fmt.Errorf("graph: %d %s", resp.StatusCode, msg)
	}
	if out != nil && len(rb) > 0 {
		return json.Unmarshal(rb, out)
	}
	return nil
}

var errGone = fmt.Errorf("graph: 410 gone")

// ── folders ──

var roleByWellKnown = map[string]string{
	"inbox": "inbox", "sentitems": "sent", "drafts": "drafts",
	"junkemail": "spam", "deleteditems": "trash", "archive": "archive",
}

type apiFolder struct {
	ID            string `json:"id"`
	Name          string `json:"displayName"`
	Unread        int    `json:"unreadItemCount"`
	Total         int    `json:"totalItemCount"`
	WellKnownName string `json:"wellKnownName"`
}

func (c *Client) ListFolders(ctx context.Context) ([]provider.Folder, error) {
	q := url.Values{"$top": {"100"}, "includeHiddenFolders": {"false"}}
	var res struct {
		Items []apiFolder `json:"value"`
	}
	if err := c.do(ctx, "GET", "/me/mailFolders", q, nil, &res); err != nil {
		return nil, err
	}
	// v1.0 omits wellKnownName for many account types (it's a beta property;
	// org accounts typically drop it) — resolve the well-known folders by
	// direct addressing, which v1.0 supports for every account type.
	roleByID := map[string]string{}
	idByWK := map[string]string{}
	for wk, role := range roleByWellKnown {
		var f apiFolder
		if err := c.do(ctx, "GET", "/me/mailFolders/"+wk, url.Values{"$select": {"id"}}, nil, &f); err == nil && f.ID != "" {
			roleByID[f.ID] = role
			idByWK[wk] = f.ID
		}
	}
	var out []provider.Folder
	c.mu.Lock()
	for wk, id := range idByWK {
		c.wellKnown[wk] = id
	}
	for _, f := range res.Items {
		role := roleByWellKnown[strings.ToLower(f.WellKnownName)]
		if role == "" {
			role = roleByID[f.ID]
		}
		if f.WellKnownName != "" {
			c.wellKnown[strings.ToLower(f.WellKnownName)] = f.ID
		}
		if role == "" {
			switch strings.ToLower(f.Name) {
			case "conversation history", "outbox", "sync issues", "rss feeds":
				continue
			default:
				role = "label"
			}
		}
		out = append(out, provider.Folder{ID: f.ID, Name: f.Name, Role: role, Unread: f.Unread, Total: f.Total})
	}
	c.mu.Unlock()
	// stable order: inbox, sent, drafts, archive, spam, trash, then labels
	rank := map[string]int{"inbox": 0, "sent": 1, "drafts": 2, "archive": 3, "spam": 4, "trash": 5, "label": 6}
	sort.SliceStable(out, func(i, j int) bool { return rank[out[i].Role] < rank[out[j].Role] })
	return out, nil
}

// folderID resolves a well-known name, listing folders once when unknown.
func (c *Client) folderID(ctx context.Context, wk string) string {
	c.mu.Lock()
	id := c.wellKnown[wk]
	c.mu.Unlock()
	if id != "" {
		return id
	}
	c.ListFolders(ctx)
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.wellKnown[wk]
}

// ── messages / conversations ──

type apiRecipient struct {
	EmailAddress struct {
		Name    string `json:"name"`
		Address string `json:"address"`
	} `json:"emailAddress"`
}

func (r apiRecipient) addr() provider.Address {
	return provider.Address{Name: r.EmailAddress.Name, Email: r.EmailAddress.Address}
}

type apiMessage struct {
	ID             string         `json:"id"`
	ConversationID string         `json:"conversationId"`
	Subject        string         `json:"subject"`
	BodyPreview    string         `json:"bodyPreview"`
	From           *apiRecipient  `json:"from"`
	ReplyTo        []apiRecipient `json:"replyTo"`
	To             []apiRecipient `json:"toRecipients"`
	Cc             []apiRecipient `json:"ccRecipients"`
	Received       time.Time      `json:"receivedDateTime"`
	IsRead         bool           `json:"isRead"`
	HasAttachments bool           `json:"hasAttachments"`
	ParentFolderID string         `json:"parentFolderId"`
	Flag           *struct {
		FlagStatus string `json:"flagStatus"`
	} `json:"flag"`
	Body *struct {
		ContentType string `json:"contentType"`
		Content     string `json:"content"`
	} `json:"body"`
}

// snippet flattens Graph's bodyPreview: unlike gmail's snippet it keeps raw
// newlines and runs ~255 chars — multi-line snippets overflow the index rows.
func snippet(s string) string {
	s = strings.Join(strings.Fields(s), " ")
	if len(s) > 180 {
		s = s[:180]
	}
	return s
}

const listSelect = "id,conversationId,subject,bodyPreview,from,receivedDateTime,isRead,hasAttachments,flag,parentFolderId"

func (m apiMessage) starred() bool { return m.Flag != nil && m.Flag.FlagStatus == "flagged" }

// group folds a message page into conversation rows, newest-first.
func group(msgs []apiMessage) []provider.Conversation {
	byConv := map[string]*provider.Conversation{}
	var order []string
	for _, m := range msgs {
		cv := byConv[m.ConversationID]
		if cv == nil {
			cv = &provider.Conversation{ID: m.ConversationID, Subject: m.Subject, Snippet: snippet(m.BodyPreview), Date: m.Received}
			byConv[m.ConversationID] = cv
			order = append(order, m.ConversationID)
		}
		cv.MsgCount++
		if m.Received.After(cv.Date) {
			cv.Date = m.Received
			cv.Snippet = snippet(m.BodyPreview)
		}
		if !m.IsRead {
			cv.Unread = true
		}
		if m.starred() {
			cv.Starred = true
		}
		if m.HasAttachments {
			cv.HasAttach = true
		}
		if m.From != nil {
			a := m.From.addr()
			dup := false
			for _, s := range cv.Senders {
				if strings.EqualFold(s.Email, a.Email) {
					dup = true
				}
			}
			if !dup {
				cv.Senders = append(cv.Senders, a)
			}
		}
		seen := false
		for _, f := range cv.FolderIDs {
			if f == m.ParentFolderID {
				seen = true
			}
		}
		if !seen {
			cv.FolderIDs = append(cv.FolderIDs, m.ParentFolderID)
		}
	}
	out := make([]provider.Conversation, 0, len(order))
	for _, id := range order {
		out = append(out, *byConv[id])
	}
	return out
}

func (c *Client) ListConversations(ctx context.Context, folderID, cursor string, limit int, unreadOnly bool) (provider.Page, error) {
	var res struct {
		Items []apiMessage `json:"value"`
		Next  string       `json:"@odata.nextLink"`
	}
	if cursor != "" {
		if err := c.doAbs(ctx, "GET", cursor, nil, &res); err != nil {
			return provider.Page{}, err
		}
	} else {
		q := url.Values{"$top": {fmt.Sprint(limit * 2)}, "$select": {listSelect}}
		if unreadOnly {
			// $orderby with $filter trips Graph's InefficientFilter — sort client-side
			q.Set("$filter", "isRead eq false")
		} else {
			q.Set("$orderby", "receivedDateTime desc")
		}
		if err := c.do(ctx, "GET", "/me/mailFolders/"+url.PathEscape(folderID)+"/messages", q, nil, &res); err != nil {
			return provider.Page{}, err
		}
	}
	sort.SliceStable(res.Items, func(i, j int) bool { return res.Items[i].Received.After(res.Items[j].Received) })
	return provider.Page{Conversations: group(res.Items), NextCursor: res.Next}, nil
}

// convMessages lists every message of a conversation (full body optional).
func (c *Client) convMessages(ctx context.Context, convID string, withBody bool) ([]apiMessage, error) {
	sel := listSelect
	if withBody {
		sel += ",body,replyTo,toRecipients,ccRecipients"
	}
	q := url.Values{
		"$filter": {"conversationId eq '" + strings.ReplaceAll(convID, "'", "''") + "'"},
		"$top":    {"100"},
		"$select": {sel},
	}
	var res struct {
		Items []apiMessage `json:"value"`
	}
	if err := c.do(ctx, "GET", "/me/messages", q, nil, &res); err != nil {
		return nil, err
	}
	sort.SliceStable(res.Items, func(i, j int) bool { return res.Items[i].Received.Before(res.Items[j].Received) })
	return res.Items, nil
}

type apiAttachment struct {
	ID           string `json:"id"`
	Name         string `json:"name"`
	ContentType  string `json:"contentType"`
	Size         int64  `json:"size"`
	IsInline     bool   `json:"isInline"`
	ContentID    string `json:"contentId"`
	ContentBytes string `json:"contentBytes"`
}

func (c *Client) GetConversation(ctx context.Context, id string) ([]provider.Message, error) {
	msgs, err := c.convMessages(ctx, id, true)
	if err != nil {
		return nil, err
	}
	out := make([]provider.Message, 0, len(msgs))
	for _, m := range msgs {
		pm := provider.Message{
			ID: m.ID, ConvID: m.ConversationID, Subject: m.Subject, Snippet: snippet(m.BodyPreview),
			Date: m.Received, Unread: !m.IsRead, Starred: m.starred(),
		}
		if m.From != nil {
			pm.From = m.From.addr()
		}
		for _, r := range m.ReplyTo {
			pm.ReplyTo = append(pm.ReplyTo, r.addr())
		}
		for _, r := range m.To {
			pm.To = append(pm.To, r.addr())
		}
		for _, r := range m.Cc {
			pm.Cc = append(pm.Cc, r.addr())
		}
		if m.Body != nil {
			if strings.EqualFold(m.Body.ContentType, "html") {
				pm.BodyHTML = m.Body.Content
			} else {
				pm.BodyText = m.Body.Content
			}
		}
		if m.HasAttachments {
			var ares struct {
				Items []apiAttachment `json:"value"`
			}
			q := url.Values{"$select": {"id,name,contentType,size,isInline,contentId"}}
			if err := c.do(ctx, "GET", "/me/messages/"+url.PathEscape(m.ID)+"/attachments", q, nil, &ares); err != nil {
				debuglog.API("graph attachments %s: %v", m.ID, err)
			}
			for _, a := range ares.Items {
				pm.Attachments = append(pm.Attachments, provider.Attachment{
					ID: a.ID, Name: a.Name, MIME: a.ContentType, Size: a.Size,
					Inline: a.IsInline, ContentID: a.ContentID,
				})
			}
		}
		out = append(out, pm)
	}
	return out, nil
}

func (c *Client) GetConversationMeta(ctx context.Context, id string) (provider.Conversation, error) {
	msgs, err := c.convMessages(ctx, id, false)
	if err != nil {
		return provider.Conversation{}, err
	}
	if len(msgs) == 0 {
		return provider.Conversation{}, fmt.Errorf("conversation not found")
	}
	cvs := group(msgs)
	cv := cvs[0]
	// the sync layer's inbox test is name-based ("Inbox"); Graph folder ids
	// are opaque, so mark membership explicitly
	if inbox := c.folderID(ctx, "inbox"); inbox != "" {
		for _, f := range cv.FolderIDs {
			if f == inbox {
				cv.FolderIDs = append(cv.FolderIDs, "Inbox")
				break
			}
		}
	}
	return cv, nil
}

func (c *Client) FetchAttachment(ctx context.Context, messageID, attachmentID string) ([]byte, error) {
	var a apiAttachment
	if err := c.do(ctx, "GET", "/me/messages/"+url.PathEscape(messageID)+"/attachments/"+url.PathEscape(attachmentID), nil, nil, &a); err != nil {
		return nil, err
	}
	return base64.StdEncoding.DecodeString(a.ContentBytes)
}

// ── delta sync (inbox) ──

func (c *Client) Delta(ctx context.Context, sinceToken string) (provider.Delta, error) {
	inbox := c.folderID(ctx, "inbox")
	if inbox == "" {
		return provider.Delta{}, fmt.Errorf("no inbox folder resolved")
	}
	link := sinceToken
	if link == "" {
		link = apiBase + "/me/mailFolders/" + url.PathEscape(inbox) + "/messages/delta?$select=id,conversationId,isRead"
	}
	changedConvs := map[string]bool{}
	for {
		var res struct {
			Items []apiMessage `json:"value"`
			Next  string       `json:"@odata.nextLink"`
			Delta string       `json:"@odata.deltaLink"`
		}
		if err := c.doAbs(ctx, "GET", link, nil, &res); err != nil {
			if err == errGone {
				// expired token: restart from scratch next tick
				return provider.Delta{FullResync: true, NextToken: ""}, nil
			}
			return provider.Delta{}, err
		}
		for _, m := range res.Items {
			if m.ConversationID != "" {
				changedConvs[m.ConversationID] = true
			}
		}
		if res.Delta != "" {
			d := provider.Delta{NextToken: res.Delta}
			if sinceToken == "" {
				// first run is the baseline dump, not real changes
				return provider.Delta{FullResync: true, NextToken: res.Delta}, nil
			}
			for id := range changedConvs {
				d.Changed = append(d.Changed, id)
			}
			return d, nil
		}
		if res.Next == "" {
			return provider.Delta{NextToken: sinceToken}, nil
		}
		link = res.Next
	}
}

// ── actions (fan out over the conversation's messages) ──

func (c *Client) forEachMsg(ctx context.Context, convID string, f func(m apiMessage) error) error {
	msgs, err := c.convMessages(ctx, convID, false)
	if err != nil {
		return err
	}
	for _, m := range msgs {
		if err := f(m); err != nil {
			return err
		}
	}
	return nil
}

func (c *Client) MarkRead(ctx context.Context, convID string, read bool) error {
	return c.forEachMsg(ctx, convID, func(m apiMessage) error {
		if m.IsRead == read {
			return nil
		}
		return c.do(ctx, "PATCH", "/me/messages/"+url.PathEscape(m.ID), nil,
			map[string]any{"isRead": read}, nil)
	})
}

func (c *Client) Star(ctx context.Context, convID string, starred bool) error {
	status := "notFlagged"
	if starred {
		status = "flagged"
	}
	return c.forEachMsg(ctx, convID, func(m apiMessage) error {
		return c.do(ctx, "PATCH", "/me/messages/"+url.PathEscape(m.ID), nil,
			map[string]any{"flag": map[string]string{"flagStatus": status}}, nil)
	})
}

func (c *Client) moveConv(ctx context.Context, convID, destWellKnown string) error {
	dest := c.folderID(ctx, destWellKnown)
	if dest == "" {
		dest = destWellKnown
	}
	return c.forEachMsg(ctx, convID, func(m apiMessage) error {
		return c.do(ctx, "POST", "/me/messages/"+url.PathEscape(m.ID)+"/move", nil,
			map[string]string{"destinationId": dest}, nil)
	})
}

func (c *Client) Archive(ctx context.Context, convID string) error {
	return c.moveConv(ctx, convID, "archive")
}
func (c *Client) Unarchive(ctx context.Context, convID string) error {
	return c.moveConv(ctx, convID, "inbox")
}
func (c *Client) Trash(ctx context.Context, convID string) error {
	return c.moveConv(ctx, convID, "deleteditems")
}
func (c *Client) Untrash(ctx context.Context, convID string) error {
	return c.moveConv(ctx, convID, "inbox")
}

func (c *Client) Search(ctx context.Context, qs string, limit int) (provider.Page, error) {
	q := url.Values{
		"$search": {`"` + strings.ReplaceAll(qs, `"`, ``) + `"`},
		"$top":    {fmt.Sprint(limit)},
		"$select": {listSelect},
	}
	var res struct {
		Items []apiMessage `json:"value"`
		Next  string       `json:"@odata.nextLink"`
	}
	if err := c.do(ctx, "GET", "/me/messages", q, nil, &res); err != nil {
		return provider.Page{}, err
	}
	sort.SliceStable(res.Items, func(i, j int) bool { return res.Items[i].Received.After(res.Items[j].Received) })
	return provider.Page{Conversations: group(res.Items), NextCursor: res.Next}, nil
}

// ── send ──

func recipients(as []provider.Address) []map[string]any {
	out := make([]map[string]any, 0, len(as))
	for _, a := range as {
		out = append(out, map[string]any{"emailAddress": map[string]string{"address": a.Email, "name": a.Name}})
	}
	return out
}

func fileAttachments(paths []string) ([]map[string]any, error) {
	var out []map[string]any
	for _, p := range paths {
		b, err := os.ReadFile(p)
		if err != nil {
			return nil, err
		}
		out = append(out, map[string]any{
			"@odata.type":  "#microsoft.graph.fileAttachment",
			"name":         filepath.Base(p),
			"contentBytes": base64.StdEncoding.EncodeToString(b),
		})
	}
	return out, nil
}

func (c *Client) Send(ctx context.Context, d provider.Draft) error {
	if d.InReplyTo != "" {
		return c.sendReply(ctx, d)
	}
	msg := map[string]any{
		"subject":      d.Subject,
		"body":         map[string]string{"contentType": "Text", "content": d.BodyText},
		"toRecipients": recipients(d.To),
	}
	if len(d.Cc) > 0 {
		msg["ccRecipients"] = recipients(d.Cc)
	}
	if len(d.Bcc) > 0 {
		msg["bccRecipients"] = recipients(d.Bcc)
	}
	if len(d.AttachmentPaths) > 0 {
		atts, err := fileAttachments(d.AttachmentPaths)
		if err != nil {
			return err
		}
		msg["attachments"] = atts
	}
	return c.do(ctx, "POST", "/me/sendMail", nil, map[string]any{"message": msg, "saveToSentItems": true}, nil)
}

// sendReply threads via createReply → patch → send, which keeps Graph's
// reply headers and lets Outlook render the quoted history natively.
func (c *Client) sendReply(ctx context.Context, d provider.Draft) error {
	var draft struct {
		ID   string `json:"id"`
		Body *struct {
			ContentType string `json:"contentType"`
			Content     string `json:"content"`
		} `json:"body"`
	}
	if err := c.do(ctx, "POST", "/me/messages/"+url.PathEscape(d.InReplyTo)+"/createReply", nil,
		map[string]any{}, &draft); err != nil {
		return err
	}
	patch := map[string]any{}
	if draft.Body != nil && strings.EqualFold(draft.Body.ContentType, "html") {
		esc := strings.ReplaceAll(strings.ReplaceAll(stdEscape(d.BodyText), "\n", "<br>"), "\r", "")
		patch["body"] = map[string]string{"contentType": "HTML",
			"content": `<div style="font-family:inherit">` + esc + "</div>" + draft.Body.Content}
	} else {
		prev := ""
		if draft.Body != nil {
			prev = draft.Body.Content
		}
		patch["body"] = map[string]string{"contentType": "Text", "content": d.BodyText + "\n\n" + prev}
	}
	if len(d.To) > 0 {
		patch["toRecipients"] = recipients(d.To)
	}
	if len(d.Cc) > 0 {
		patch["ccRecipients"] = recipients(d.Cc)
	}
	if err := c.do(ctx, "PATCH", "/me/messages/"+url.PathEscape(draft.ID), nil, patch, nil); err != nil {
		return err
	}
	for _, att := range d.AttachmentPaths {
		atts, err := fileAttachments([]string{att})
		if err != nil {
			return err
		}
		if err := c.do(ctx, "POST", "/me/messages/"+url.PathEscape(draft.ID)+"/attachments", nil, atts[0], nil); err != nil {
			return err
		}
	}
	return c.do(ctx, "POST", "/me/messages/"+url.PathEscape(draft.ID)+"/send", nil, map[string]any{}, nil)
}

func stdEscape(s string) string {
	r := strings.NewReplacer("&", "&amp;", "<", "&lt;", ">", "&gt;")
	return r.Replace(s)
}

// ── calendar (provider.CalendarProvider) ──

type apiCalTime struct {
	DateTime string `json:"dateTime"`
	TimeZone string `json:"timeZone"`
}

func (t apiCalTime) parse() time.Time {
	loc := time.UTC
	if t.TimeZone != "" && t.TimeZone != "UTC" {
		if l, err := time.LoadLocation(t.TimeZone); err == nil {
			loc = l
		}
	}
	// Graph pads sub-second digits; trim to the second
	s := t.DateTime
	if i := strings.IndexByte(s, '.'); i > 0 {
		s = s[:i]
	}
	ts, err := time.ParseInLocation("2006-01-02T15:04:05", s, loc)
	if err != nil {
		return time.Time{}
	}
	return ts.Local()
}

type apiEvent struct {
	ID            string     `json:"id"`
	Subject       string     `json:"subject"`
	Start         apiCalTime `json:"start"`
	End           apiCalTime `json:"end"`
	IsAllDay      bool       `json:"isAllDay"`
	IsCancelled   bool       `json:"isCancelled"`
	WebLink       string     `json:"webLink"`
	ICalUID       string     `json:"iCalUId"`
	OnlineMeeting *struct {
		JoinURL string `json:"joinUrl"`
	} `json:"onlineMeeting"`
	OnlineMeetingURL string `json:"onlineMeetingUrl"`
	Location         *struct {
		DisplayName string `json:"displayName"`
	} `json:"location"`
	Organizer *apiRecipient `json:"organizer"`
	Attendees []struct {
		EmailAddress struct {
			Name    string `json:"name"`
			Address string `json:"address"`
		} `json:"emailAddress"`
		Status struct {
			Response string `json:"response"`
		} `json:"status"`
	} `json:"attendees"`
	ResponseStatus *struct {
		Response string `json:"response"`
	} `json:"responseStatus"`
}

func mapResponse(r string) string {
	switch r {
	case "accepted", "organizer":
		return "accepted"
	case "tentativelyAccepted":
		return "tentative"
	case "declined":
		return "declined"
	case "notResponded":
		return "needsAction"
	}
	return ""
}

func flattenEvent(calID string, e apiEvent) provider.CalEvent {
	ev := provider.CalEvent{
		ID: e.ID, CalID: calID, Title: e.Subject,
		Start: e.Start.parse(), End: e.End.parse(), AllDay: e.IsAllDay,
		HTMLLink: e.WebLink, ICalUID: e.ICalUID,
	}
	if ev.Title == "" {
		ev.Title = "(untitled)"
	}
	if e.OnlineMeeting != nil && e.OnlineMeeting.JoinURL != "" {
		ev.MeetLink = e.OnlineMeeting.JoinURL
	} else if e.OnlineMeetingURL != "" {
		ev.MeetLink = e.OnlineMeetingURL
	}
	if e.Location != nil {
		ev.Location = e.Location.DisplayName
	}
	if e.Organizer != nil {
		ev.Organizer = e.Organizer.EmailAddress.Name
		if ev.Organizer == "" {
			ev.Organizer = e.Organizer.EmailAddress.Address
		}
	}
	for _, a := range e.Attendees {
		ev.Attendees = append(ev.Attendees, provider.CalAttendee{
			Email: a.EmailAddress.Address, Name: a.EmailAddress.Name,
			Status: mapResponse(a.Status.Response),
		})
	}
	if e.ResponseStatus != nil {
		ev.MyStatus = mapResponse(e.ResponseStatus.Response)
	}
	return ev
}

func (c *Client) Calendars(ctx context.Context) ([]provider.Calendar, error) {
	q := url.Values{"$select": {"id,name,isDefaultCalendar,canEdit,hexColor"}}
	var res struct {
		Items []struct {
			ID        string `json:"id"`
			Name      string `json:"name"`
			IsDefault bool   `json:"isDefaultCalendar"`
			CanEdit   bool   `json:"canEdit"`
			HexColor  string `json:"hexColor"`
		} `json:"value"`
	}
	if err := c.do(ctx, "GET", "/me/calendars", q, nil, &res); err != nil {
		return nil, err
	}
	var out []provider.Calendar
	for _, it := range res.Items {
		role := "reader"
		if it.CanEdit {
			role = "writer"
		}
		out = append(out, provider.Calendar{ID: it.ID, Name: it.Name, Primary: it.IsDefault, Color: it.HexColor, Role: role})
	}
	return out, nil
}

const eventSelect = "id,subject,start,end,isAllDay,isCancelled,webLink,iCalUId,onlineMeeting,onlineMeetingUrl,location,organizer,attendees,responseStatus"

func (c *Client) Events(ctx context.Context, calID string, from, to time.Time) ([]provider.CalEvent, error) {
	path := "/me/calendars/" + url.PathEscape(calID) + "/calendarView"
	if calID == "primary" {
		path = "/me/calendarView"
	}
	q := url.Values{
		"startDateTime": {from.UTC().Format(time.RFC3339)},
		"endDateTime":   {to.UTC().Format(time.RFC3339)},
		"$top":          {"250"},
		"$select":       {eventSelect},
		"$orderby":      {"start/dateTime"},
	}
	var res struct {
		Items []apiEvent `json:"value"`
	}
	if err := c.do(ctx, "GET", path, q, nil, &res); err != nil {
		return nil, err
	}
	var out []provider.CalEvent
	for _, e := range res.Items {
		if e.IsCancelled {
			continue
		}
		out = append(out, flattenEvent(calID, e))
	}
	return out, nil
}

func (c *Client) RSVP(ctx context.Context, calID, eventID, status string) error {
	verb := map[string]string{
		"accepted": "accept", "tentative": "tentativelyAccept", "declined": "decline",
	}[status]
	if verb == "" {
		return fmt.Errorf("unknown rsvp status %q", status)
	}
	return c.do(ctx, "POST", "/me/events/"+url.PathEscape(eventID)+"/"+verb, nil,
		map[string]any{"sendResponse": true}, nil)
}

func (c *Client) FindByICalUID(ctx context.Context, calID, uid string) (*provider.CalEvent, error) {
	q := url.Values{
		"$filter": {"iCalUId eq '" + strings.ReplaceAll(uid, "'", "''") + "'"},
		"$select": {eventSelect},
	}
	var res struct {
		Items []apiEvent `json:"value"`
	}
	if err := c.do(ctx, "GET", "/me/events", q, nil, &res); err != nil {
		return nil, err
	}
	for _, e := range res.Items {
		if !e.IsCancelled {
			ev := flattenEvent(calID, e)
			return &ev, nil
		}
	}
	return nil, fmt.Errorf("no event for invite (uid %s)", uid)
}

func (c *Client) Create(ctx context.Context, calID string, ne provider.NewEvent) (*provider.CalEvent, error) {
	tz := time.Local.String()
	body := map[string]any{
		"subject": ne.Title,
		"body":    map[string]string{"contentType": "Text", "content": ne.Notes},
		"start":   map[string]string{"dateTime": ne.Start.Format("2006-01-02T15:04:05"), "timeZone": tz},
		"end":     map[string]string{"dateTime": ne.End.Format("2006-01-02T15:04:05"), "timeZone": tz},
	}
	if ne.Location != "" {
		body["location"] = map[string]string{"displayName": ne.Location}
	}
	if len(ne.Attendees) > 0 {
		var atts []map[string]any
		for _, a := range ne.Attendees {
			atts = append(atts, map[string]any{
				"emailAddress": map[string]string{"address": a}, "type": "required",
			})
		}
		body["attendees"] = atts
	}
	if ne.Meet {
		body["isOnlineMeeting"] = true
		body["onlineMeetingProvider"] = "teamsForBusiness"
	}
	path := "/me/calendars/" + url.PathEscape(calID) + "/events"
	if calID == "primary" {
		path = "/me/events"
	}
	var created apiEvent
	if err := c.do(ctx, "POST", path, nil, body, &created); err != nil {
		return nil, err
	}
	ev := flattenEvent(calID, created)
	return &ev, nil
}
