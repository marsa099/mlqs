package imap

import (
	"bytes"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/emersion/go-imap/v2"
	gomail "github.com/emersion/go-message/mail"

	"mlqs/internal/provider"
)

// buildMIME must not emit a Bcc header — plain SMTP transmits it verbatim and
// would leak blind recipients. recipients() still carries Bcc in the envelope.
func TestBuildMIMENoBccHeader(t *testing.T) {
	cl := &Client{cfg: Config{Email: "me@example.com"}}
	d := provider.Draft{
		To:       []provider.Address{{Email: "to@example.com"}},
		Cc:       []provider.Address{{Email: "cc@example.com"}},
		Bcc:      []provider.Address{{Email: "secret@example.com"}},
		Subject:  "hi",
		BodyText: "body",
	}
	raw, err := cl.buildMIME(d, "")
	if err != nil {
		t.Fatal(err)
	}
	headerBlock := string(raw)
	if i := strings.Index(headerBlock, "\r\n\r\n"); i >= 0 {
		headerBlock = headerBlock[:i]
	}
	if strings.Contains(strings.ToLower(headerBlock), "bcc:") {
		t.Fatalf("Bcc header leaked into message:\n%s", headerBlock)
	}
	if strings.Contains(headerBlock, "secret@example.com") {
		t.Fatalf("blind recipient present in headers:\n%s", headerBlock)
	}
	// but it must still be an envelope recipient
	got := recipients(d)
	if !contains(got, "secret@example.com") {
		t.Fatalf("bcc missing from SMTP envelope: %v", got)
	}
}

func TestBuildMIMEAttachmentContentType(t *testing.T) {
	payload := []byte("%PDF-1.4\nhello\n%%EOF\n")
	tests := []struct {
		name        string
		extension   string
		contentType string
	}{
		{name: "pdf", extension: ".pdf", contentType: "application/pdf"},
		{name: "uppercase pdf", extension: ".PDF", contentType: "application/pdf"},
		{name: "unknown", extension: ".mlqs-unknown", contentType: "application/octet-stream"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			filename := "attachment" + tt.extension
			path := filepath.Join(t.TempDir(), filename)
			if err := os.WriteFile(path, payload, 0o600); err != nil {
				t.Fatal(err)
			}

			cl := &Client{cfg: Config{Email: "me@example.com"}}
			raw, err := cl.buildMIME(provider.Draft{
				To:              []provider.Address{{Email: "to@example.com"}},
				Subject:         "attachment",
				BodyText:        "body",
				AttachmentPaths: []string{path},
			}, "")
			if err != nil {
				t.Fatal(err)
			}

			mr, err := gomail.CreateReader(bytes.NewReader(raw))
			if err != nil {
				t.Fatal(err)
			}
			for {
				part, err := mr.NextPart()
				if err != nil {
					t.Fatalf("attachment not found: %v", err)
				}
				ah, ok := part.Header.(*gomail.AttachmentHeader)
				if !ok {
					_, _ = io.Copy(io.Discard, part.Body)
					continue
				}
				contentType, _, err := ah.ContentType()
				if err != nil {
					t.Fatal(err)
				}
				if contentType != tt.contentType {
					t.Fatalf("Content-Type = %q, want %q", contentType, tt.contentType)
				}
				gotFilename, _ := ah.Filename()
				if gotFilename != filename {
					t.Fatalf("filename = %q, want %q", gotFilename, filename)
				}
				disposition, _, _ := ah.ContentDisposition()
				if disposition != "attachment" {
					t.Fatalf("disposition = %q, want attachment", disposition)
				}
				gotPayload, err := io.ReadAll(part.Body)
				if err != nil {
					t.Fatal(err)
				}
				if !bytes.Equal(gotPayload, payload) {
					t.Fatalf("decoded payload = %q, want %q", gotPayload, payload)
				}
				return
			}
		})
	}
}

// non-UTF-8 mail must decode (charset package registered). Without it,
// CreateReader fails and the raw bytes are dumped as the body.
func TestParseMessageLatin1(t *testing.T) {
	// "å" is 0xE5 in iso-8859-1
	raw := "From: a@b.se\r\n" +
		"Subject: hej\r\n" +
		"Content-Type: text/plain; charset=iso-8859-1\r\n" +
		"Content-Transfer-Encoding: 8bit\r\n\r\n" +
		"gr\xE5tt v\xE4der\r\n"
	pm := parseMessage("INBOX", 1, 1, 1, []byte(raw))
	if !strings.Contains(pm.BodyText, "grått väder") {
		t.Fatalf("latin-1 body not decoded to UTF-8: %q", pm.BodyText)
	}
}

// An inline cid image occupies an attachment slot, and parseMessage /
// FetchAttachment must number slots identically (both use isAttachmentSlot).
func TestInlineCidBecomesAttachment(t *testing.T) {
	raw := "From: a@b.se\r\n" +
		"Subject: pic\r\n" +
		"Content-Type: multipart/related; boundary=B\r\n\r\n" +
		"--B\r\n" +
		"Content-Type: text/html\r\n\r\n" +
		"<img src=\"cid:img1\">\r\n" +
		"--B\r\n" +
		"Content-Type: image/png\r\n" +
		"Content-Disposition: inline\r\n" +
		"Content-ID: <img1>\r\n" +
		"Content-Transfer-Encoding: base64\r\n\r\n" +
		"aGVsbG8=\r\n" +
		"--B--\r\n"
	pm := parseMessage("INBOX", 1, 1, 1, []byte(raw))
	if len(pm.Attachments) != 1 {
		t.Fatalf("expected 1 inline attachment, got %d", len(pm.Attachments))
	}
	a := pm.Attachments[0]
	if a.ContentID != "img1" || !a.Inline || a.ID != "0" {
		t.Fatalf("inline attachment wrong: %+v", a)
	}
}

func contains(ss []string, want string) bool {
	for _, s := range ss {
		if s == want {
			return true
		}
	}
	return false
}

// ---- conversation threading ----

// tm builds threadMeta the way parseThreadMeta would: own id, then referenced ids.
func tm(id string, refs ...string) threadMeta {
	m := threadMeta{messageID: id}
	for _, r := range refs {
		m.refs = append(m.refs, r)
	}
	return m
}

func groupsOf(ths []thread) [][]imap.UID {
	out := make([][]imap.UID, 0, len(ths))
	for _, t := range ths {
		out = append(out, t.uids)
	}
	return out
}

func sameGroups(got [][]imap.UID, want [][]imap.UID) bool {
	if len(got) != len(want) {
		return false
	}
	for i := range got {
		if len(got[i]) != len(want[i]) {
			return false
		}
		for j := range got[i] {
			if got[i][j] != want[i][j] {
				return false
			}
		}
	}
	return true
}

// RFC 5256's last step merges by subject, so unrelated mail sharing a subject
// arrives as one server thread. With no references between them, each message is
// its own conversation.
func TestSplitByReferencesSeparatesUnrelatedSameSubject(t *testing.T) {
	coarse := []thread{mkThread([]imap.UID{1, 2, 3})}
	meta := map[imap.UID]threadMeta{1: tm("a@x"), 2: tm("b@x"), 3: tm("c@x")}
	got := groupsOf(splitByReferences(coarse, meta))
	if want := [][]imap.UID{{1}, {2}, {3}}; !sameGroups(got, want) {
		t.Fatalf("got %v, want %v", got, want)
	}
}

// A real reply chain must survive the split, while an unrelated same-subject
// message in the same server thread is separated out.
func TestSplitByReferencesKeepsExplicitChain(t *testing.T) {
	coarse := []thread{mkThread([]imap.UID{10, 11, 12})}
	meta := map[imap.UID]threadMeta{
		10: tm("root@x"),
		11: tm("reply@x", "root@x"),
		12: tm("other@x"),
	}
	got := groupsOf(splitByReferences(coarse, meta))
	if want := [][]imap.UID{{10, 11}, {12}}; !sameGroups(got, want) {
		t.Fatalf("got %v, want %v", got, want)
	}
}

// Two deliveries of the same message (a Bcc'd copy, a list echo) share a
// Message-ID. They must union, not let the last writer win — that split a thread
// the server had grouped correctly and showed a phantom duplicate row.
func TestSplitByReferencesUnionsDuplicateMessageID(t *testing.T) {
	coarse := []thread{mkThread([]imap.UID{5, 9, 12})}
	meta := map[imap.UID]threadMeta{
		5:  tm("m@x"),
		9:  tm("m@x"),
		12: tm("child@x", "m@x"),
	}
	got := groupsOf(splitByReferences(coarse, meta))
	if want := [][]imap.UID{{5, 9, 12}}; !sameGroups(got, want) {
		t.Fatalf("got %v, want %v", got, want)
	}
}

// Siblings replying to a parent that isn't in this folder still belong together.
func TestSplitByReferencesGroupsSiblingsOfAbsentParent(t *testing.T) {
	coarse := []thread{mkThread([]imap.UID{4, 7})}
	meta := map[imap.UID]threadMeta{
		4: tm("one@x", "gone@x"),
		7: tm("two@x", "gone@x"),
	}
	got := groupsOf(splitByReferences(coarse, meta))
	if want := [][]imap.UID{{4, 7}}; !sameGroups(got, want) {
		t.Fatalf("got %v, want %v", got, want)
	}
}

// A metadata fetch that returned nothing for a thread must leave the server's
// grouping alone rather than exploding it into singletons.
func TestSplitByReferencesKeepsThreadWhenMetaMissing(t *testing.T) {
	coarse := []thread{mkThread([]imap.UID{1, 2, 3})}
	got := groupsOf(splitByReferences(coarse, map[imap.UID]threadMeta{}))
	if want := [][]imap.UID{{1, 2, 3}}; !sameGroups(got, want) {
		t.Fatalf("got %v, want %v", got, want)
	}
}

// Splitting never merges across server threads: the result is always a
// refinement of what the server returned.
func TestSplitByReferencesNeverMergesAcrossThreads(t *testing.T) {
	coarse := []thread{mkThread([]imap.UID{1}), mkThread([]imap.UID{2})}
	meta := map[imap.UID]threadMeta{1: tm("a@x", "shared@x"), 2: tm("b@x", "shared@x")}
	got := groupsOf(splitByReferences(coarse, meta))
	if want := [][]imap.UID{{1}, {2}}; !sameGroups(got, want) {
		t.Fatalf("got %v, want %v", got, want)
	}
}

// The unread view keeps whole conversations — including already-read ancestors —
// so a thread's root, and therefore its convID, matches the all-mail view.
func TestFilterThreadsKeepsRootAndAllMembers(t *testing.T) {
	ths := []thread{mkThread([]imap.UID{5, 9, 13}), mkThread([]imap.UID{2})}
	got := filterThreads(ths, map[imap.UID]bool{13: true})
	if len(got) != 1 {
		t.Fatalf("got %d threads, want 1", len(got))
	}
	if got[0].root != 5 {
		t.Fatalf("root = %d, want 5 (must match the all-mail view)", got[0].root)
	}
	if want := [][]imap.UID{{5, 9, 13}}; !sameGroups(groupsOf(got), want) {
		t.Fatalf("members = %v, want %v", groupsOf(got), want)
	}
}

func TestMessageIDsAndNormalize(t *testing.T) {
	got := messageIDs("<A@x>\r\nReferences: <b@y> <A@x>\r\n")
	if want := []string{"a@x", "b@y"}; len(got) != 2 || got[0] != want[0] || got[1] != want[1] {
		t.Fatalf("messageIDs = %v, want %v (lowercased, deduped, in order)", got, want)
	}
	if s := normalizeMessageID("  <Foo@Bar>  "); s != "foo@bar" {
		t.Fatalf("normalizeMessageID = %q, want %q", s, "foo@bar")
	}
}
