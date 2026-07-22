package imap

import (
	"strings"
	"testing"

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
