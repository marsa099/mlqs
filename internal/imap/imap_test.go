package imap

import (
	"strings"
	"testing"

	"github.com/emersion/go-imap/v2"

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

func TestSmartThreadSplitsUnrelatedSameSubjectMail(t *testing.T) {
	coarse := []thread{mkThread([]imap.UID{1, 2, 3})}
	meta := map[imap.UID]threadMeta{
		1: {uid: 1, subject: "Din faktura från Apple"},
		2: {uid: 2, subject: "Din faktura från Apple"},
		3: {uid: 3, subject: "Din faktura från Apple"},
	}
	got := splitServerThreads(coarse, meta, true)
	if len(got) != 3 {
		t.Fatalf("independent recurring mail collapsed into %d threads: %+v", len(got), got)
	}
}

func TestSmartThreadKeepsExplicitReferences(t *testing.T) {
	coarse := []thread{mkThread([]imap.UID{10, 11, 12})}
	meta := map[imap.UID]threadMeta{
		10: {uid: 10, messageID: "root@example", subject: "Question"},
		11: {uid: 11, messageID: "reply@example", inReplyTo: []string{"root@example"}, subject: "Sv: Question"},
		12: {uid: 12, messageID: "other@example", subject: "Question"},
	}
	got := splitServerThreads(coarse, meta, true)
	if len(got) != 2 || len(got[0].uids) != 2 || got[0].uids[0] != 10 || got[0].uids[1] != 11 {
		t.Fatalf("explicit thread was not preserved while subject merge was split: %+v", got)
	}
}

func TestSmartThreadLocalizedSubjectFallback(t *testing.T) {
	participants := func(xs ...string) map[string]bool {
		m := map[string]bool{}
		for _, x := range xs {
			m[x] = true
		}
		return m
	}
	coarse := []thread{mkThread([]imap.UID{20, 21})}
	meta := map[imap.UID]threadMeta{
		20: {uid: 20, subject: "Möte", sender: "a@example", recipients: participants("b@example"), participants: participants("a@example", "b@example")},
		21: {uid: 21, subject: "SV: Möte", sender: "b@example", recipients: participants("a@example"), participants: participants("a@example", "b@example")},
	}
	if got := splitServerThreads(coarse, meta, true); len(got) != 1 || len(got[0].uids) != 2 {
		t.Fatalf("localized reply fallback failed: %+v", got)
	}
	meta[21] = threadMeta{uid: 21, subject: "Fwd: Möte", sender: "b@example", recipients: participants("a@example"), participants: participants("a@example", "b@example")}
	if got := splitServerThreads(coarse, meta, true); len(got) != 2 {
		t.Fatalf("forward incorrectly joined to original: %+v", got)
	}
}

func TestUnreadFilterKeepsStableRootAndAllMembers(t *testing.T) {
	all := []thread{mkThread([]imap.UID{5, 8, 13}), mkThread([]imap.UID{21})}
	got := filterThreadsByUID(all, map[imap.UID]bool{13: true})
	if len(got) != 1 || got[0].root != 5 || len(got[0].uids) != 3 {
		t.Fatalf("unread filter changed thread identity or discarded seen ancestors: %+v", got)
	}
}

func TestSubjectKind(t *testing.T) {
	cases := []struct{ in, kind, base string }{
		{" SV: Re:  Quarterly  report ", "reply", "quarterly report"},
		{"Re[2]: Hello", "reply", "hello"},
		{"Fwd: Re: Hello", "forward", "hello"},
		{"Din faktura från Apple", "", "din faktura från apple"},
	}
	for _, tc := range cases {
		kind, base := subjectKind(tc.in)
		if kind != tc.kind || base != tc.base {
			t.Errorf("subjectKind(%q) = (%q, %q), want (%q, %q)", tc.in, kind, base, tc.kind, tc.base)
		}
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
