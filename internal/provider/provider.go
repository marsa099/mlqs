// Package provider defines the vendor-blind mail interface. Gmail and
// Microsoft Graph each implement it; everything above is vendor-agnostic.
// Types carry json tags because they flow to the UI as-is over IPC.
package provider

import (
	"context"
	"time"
)

type Address struct {
	Name  string `json:"name"`
	Email string `json:"email"`
}

// Role classifies well-known folders so the UI can order and glyph them
// without vendor knowledge: inbox|starred|sent|drafts|archive|spam|trash|label.
type Folder struct {
	ID     string `json:"id"`
	Name   string `json:"name"`
	Role   string `json:"role"`
	Unread int    `json:"unread"`
	Total  int    `json:"total"`
}

type Attachment struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	MIME      string `json:"mime"`
	Size      int64  `json:"size"`
	Inline    bool   `json:"inline"`
	ContentID string `json:"contentId"`
	// set by the daemon when the image renders in the sanitized body —
	// the UI hides its chip (no double listing)
	ShownInline bool `json:"shownInline"`
}

type Message struct {
	ID     string  `json:"id"`
	ConvID string  `json:"convId"`
	From   Address `json:"from"`
	// Reply-To when the sender set one (RFC 5322 §3.6.2) — replies must
	// target this over From; list servers (GitHub's reply+token@) depend on it
	// and the bare From is often a no-reply that bounces.
	ReplyTo     []Address    `json:"replyTo"`
	To          []Address    `json:"to"`
	Cc          []Address    `json:"cc"`
	Bcc         []Address    `json:"bcc"`
	Subject     string       `json:"subject"`
	Snippet     string       `json:"snippet"`
	BodyHTML    string       `json:"bodyHtml"`
	BodyText    string       `json:"bodyText"`
	Date        time.Time    `json:"date"`
	Unread      bool         `json:"unread"`
	Starred     bool         `json:"starred"`
	Attachments []Attachment `json:"attachments"`
}

type Conversation struct {
	ID        string    `json:"id"`
	Subject   string    `json:"subject"`
	Snippet   string    `json:"snippet"`
	Senders   []Address `json:"senders"`
	Date      time.Time `json:"date"`
	Unread    bool      `json:"unread"`
	Starred   bool      `json:"starred"`
	HasAttach bool      `json:"hasAttach"`
	MsgCount  int       `json:"msgCount"`
	FolderIDs []string  `json:"folderIds"`
}

type Page struct {
	Conversations []Conversation `json:"conversations"`
	NextCursor    string         `json:"nextCursor"`
}

// Delta reports what changed since a sync token. FullResync signals the
// token expired (Gmail history too old, Graph token invalidated) and the
// caller must re-list from scratch.
type Delta struct {
	Changed    []string
	Removed    []string
	NextToken  string
	FullResync bool
}

type Draft struct {
	To, Cc, Bcc     []Address
	Subject         string
	BodyText        string
	InReplyTo       string // message ID being replied to; threads on the vendor side
	ConvID          string
	AttachmentPaths []string
}

type Provider interface {
	ListFolders(ctx context.Context) ([]Folder, error)
	ListConversations(ctx context.Context, folderID, cursor string, limit int, unreadOnly bool) (Page, error)
	GetConversation(ctx context.Context, id string) ([]Message, error)
	GetConversationMeta(ctx context.Context, id string) (Conversation, error)
	FetchAttachment(ctx context.Context, messageID, attachmentID string) ([]byte, error)
	Delta(ctx context.Context, sinceToken string) (Delta, error)
	Send(ctx context.Context, d Draft) error
	MarkRead(ctx context.Context, convID string, read bool) error
	Star(ctx context.Context, convID string, starred bool) error
	Archive(ctx context.Context, convID string) error
	Unarchive(ctx context.Context, convID string) error
	Trash(ctx context.Context, convID string) error
	Untrash(ctx context.Context, convID string) error
	Search(ctx context.Context, q string, limit int) (Page, error)
}
