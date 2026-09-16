package main

import (
	"context"
	"encoding/json"
	"errors"
	"net"
	"testing"

	"mlqs/internal/cache"
	"mlqs/internal/provider"

	"golang.org/x/oauth2"
)

type expiredProvider struct {
	provider.Provider
}

type sendProvider struct {
	provider.Provider
	err error
}

func (p sendProvider) Send(context.Context, provider.Draft) error {
	return p.err
}

func (expiredProvider) GetConversation(context.Context, string) ([]provider.Message, error) {
	return nil, &oauth2.RetrieveError{ErrorCode: "invalid_grant"}
}

func TestSendLearnsContactsOnlyAfterSuccess(t *testing.T) {
	t.Setenv("XDG_DATA_HOME", t.TempDir())
	db, err := cache.Open()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	db.UpsertContact("work", "known@example.com", "Known Name", 1)
	cmd := command{
		Type: "send", Account: "work",
		To:  "to@example.com, known@example.com",
		Cc:  "cc@example.com",
		Bcc: "bcc@example.com",
	}

	run := func(p provider.Provider) map[string]any {
		client, server := net.Pipe()
		defer client.Close()
		defer server.Close()
		d := &daemon{db: db, providers: map[string]provider.Provider{"work": p}}
		go d.handle(server, cmd)
		var event map[string]any
		if err := json.NewDecoder(client).Decode(&event); err != nil {
			t.Fatal(err)
		}
		return event
	}

	if event := run(sendProvider{}); event["type"] != "sent" {
		t.Fatalf("successful send event = %#v", event)
	}
	for _, want := range []struct {
		prefix string
		email  string
		name   string
	}{
		{prefix: "to@", email: "to@example.com"},
		{prefix: "cc@", email: "cc@example.com"},
		{prefix: "bcc@", email: "bcc@example.com"},
		{prefix: "known@", email: "known@example.com", name: "Known Name"},
	} {
		contacts := db.QueryContacts("work", want.prefix, 8)
		if len(contacts) != 1 || contacts[0].Email != want.email || contacts[0].Name != want.name {
			t.Fatalf("contacts for %q = %#v, want %s <%s>", want.prefix, contacts, want.name, want.email)
		}
		if contacts := db.QueryContacts("personal", want.prefix, 8); len(contacts) != 0 {
			t.Fatalf("contact leaked to another account: %#v", contacts)
		}
	}

	cmd.To = "failed@example.com"
	cmd.Cc = ""
	cmd.Bcc = ""
	if event := run(sendProvider{err: errors.New("send rejected")}); event["type"] != "toast" {
		t.Fatalf("failed send event = %#v", event)
	}
	if contacts := db.QueryContacts("work", "failed@", 8); len(contacts) != 0 {
		t.Fatalf("failed send learned contacts: %#v", contacts)
	}
}

func TestConversationExpiredSessionRequestsAuthentication(t *testing.T) {
	client, server := net.Pipe()
	defer client.Close()
	defer server.Close()

	d := &daemon{providers: map[string]provider.Provider{"work": expiredProvider{}}}
	go d.handle(server, command{Type: "conversation", Account: "work", ID: "thread-1"})

	var event map[string]any
	if err := json.NewDecoder(client).Decode(&event); err != nil {
		t.Fatal(err)
	}
	if event["type"] != "authRequired" || event["account"] != "work" ||
		event["operation"] != "conversation" || event["id"] != "thread-1" {
		t.Fatalf("unexpected event: %#v", event)
	}
}
