package graph

import (
	"reflect"
	"testing"

	"mlqs/internal/provider"
)

func TestMailboxSplitsSharedIDs(t *testing.T) {
	cases := []struct{ id, addr, raw string }{
		{"AAMkAGI2=", "", "AAMkAGI2="},
		{"shared:support@example.com:AAMkAGI2=", "support@example.com", "AAMkAGI2="},
		{"shared:broken-no-second-colon", "", "shared:broken-no-second-colon"},
		{"", "", ""},
	}
	for _, c := range cases {
		addr, raw := mailbox(c.id)
		if addr != c.addr || raw != c.raw {
			t.Errorf("mailbox(%q) = (%q, %q), want (%q, %q)", c.id, addr, raw, c.addr, c.raw)
		}
	}
}

func TestWrapIDRoundTrips(t *testing.T) {
	if got := wrapID("", "x"); got != "x" {
		t.Errorf("own mailbox ids must stay untouched, got %q", got)
	}
	if got := wrapID("a@b.c", ""); got != "" {
		t.Errorf("empty id must stay empty, got %q", got)
	}
	w := wrapID("a@b.c", "id1")
	if addr, raw := mailbox(w); addr != "a@b.c" || raw != "id1" {
		t.Errorf("round trip failed: %q -> (%q, %q)", w, addr, raw)
	}
	if userBase("") != "/me" || userBase("a@b.c") != "/users/a@b.c" {
		t.Errorf("userBase mapping wrong: %q %q", userBase(""), userBase("a@b.c"))
	}
}

func TestWrapConvsNamespacesConversationAndFolderIDs(t *testing.T) {
	in := []provider.Conversation{{ID: "c1", FolderIDs: []string{"f1", "f2"}}}
	got := wrapConvs("s@x.y", in)
	want := []provider.Conversation{{ID: "shared:s@x.y:c1", FolderIDs: []string{"shared:s@x.y:f1", "shared:s@x.y:f2"}}}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("got %+v want %+v", got, want)
	}
	plain := wrapConvs("", []provider.Conversation{{ID: "c1"}})
	if plain[0].ID != "c1" {
		t.Errorf("own mailbox rows must not be prefixed, got %q", plain[0].ID)
	}
}
