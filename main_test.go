package main

import (
	"context"
	"encoding/json"
	"errors"
	"net"
	"slices"
	"sync"
	"testing"
	"time"

	"mlqs/internal/cache"
	"mlqs/internal/config"
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

type delayedUnreadProvider struct {
	provider.Provider
	unreadStarted chan struct{}
	releaseUnread chan struct{}
}

type pacedReadProvider struct {
	provider.Provider
	mu          sync.Mutex
	active      int
	maxActive   int
	markCalls   int
	folderCalls int
	failFirst   int
	callTimes   []time.Time
	successful  []string
	state       map[string]bool
	marked      chan struct{}
	refreshed   chan struct{}
}

func (p *pacedReadProvider) MarkRead(_ context.Context, id string, read bool) error {
	p.mu.Lock()
	p.active++
	p.markCalls++
	call := p.markCalls
	p.callTimes = append(p.callTimes, time.Now())
	if p.active > p.maxActive {
		p.maxActive = p.active
	}
	p.mu.Unlock()
	defer func() {
		p.mu.Lock()
		p.active--
		p.mu.Unlock()
	}()
	time.Sleep(3 * time.Millisecond)
	if call <= p.failFirst {
		return errors.New("gmail: 429 rateLimitExceeded")
	}
	p.mu.Lock()
	p.state[id] = read
	if read {
		p.successful = append(p.successful, id+":read")
	} else {
		p.successful = append(p.successful, id+":unread")
	}
	p.mu.Unlock()
	p.marked <- struct{}{}
	return nil
}

func (p *pacedReadProvider) ListFolders(context.Context) ([]provider.Folder, error) {
	p.mu.Lock()
	p.folderCalls++
	p.mu.Unlock()
	select {
	case p.refreshed <- struct{}{}:
	default:
	}
	return []provider.Folder{{ID: "INBOX", Role: "inbox"}}, nil
}

func (p delayedUnreadProvider) ListConversations(_ context.Context, folder, _ string, _ int, unreadOnly bool) (provider.Page, error) {
	if unreadOnly {
		close(p.unreadStarted)
		<-p.releaseUnread
		return provider.Page{Conversations: []provider.Conversation{{
			ID: "older-unread", Subject: "Older unread", Unread: true, FolderIDs: []string{folder},
		}}}, nil
	}
	return provider.Page{Conversations: []provider.Conversation{{
		ID: "newest", Subject: "Newest", FolderIDs: []string{folder},
	}}, NextCursor: "next"}, nil
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

func TestConversationListDoesNotWaitForFullUnreadRefresh(t *testing.T) {
	t.Setenv("XDG_DATA_HOME", t.TempDir())
	db, err := cache.Open()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	p := delayedUnreadProvider{
		unreadStarted: make(chan struct{}),
		releaseUnread: make(chan struct{}),
	}
	client, server := net.Pipe()
	defer client.Close()
	defer server.Close()
	client.SetReadDeadline(time.Now().Add(500 * time.Millisecond))

	d := &daemon{db: db, providers: map[string]provider.Provider{"work": p}}
	done := make(chan struct{})
	go func() {
		d.handle(server, command{Type: "conversations", Account: "work", Folder: "INBOX"})
		close(done)
	}()

	var event struct {
		Type  string                  `json:"type"`
		Items []provider.Conversation `json:"items"`
		Next  string                  `json:"next"`
	}
	if err := json.NewDecoder(client).Decode(&event); err != nil {
		close(p.releaseUnread)
		t.Fatalf("foreground conversation page did not arrive: %v", err)
	}
	if event.Type != "conversations" || event.Next != "next" || len(event.Items) != 1 || event.Items[0].ID != "newest" {
		close(p.releaseUnread)
		t.Fatalf("foreground event = %#v", event)
	}
	select {
	case <-p.unreadStarted:
	case <-time.After(time.Second):
		close(p.releaseUnread)
		t.Fatal("full unread refresh did not start after foreground response")
	}

	close(p.releaseUnread)
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("background unread refresh did not finish")
	}
	cached := db.CachedConversations("work", "INBOX", 10)
	if len(cached) != 2 || cached[0].ID != "older-unread" || !cached[0].Unread {
		t.Fatalf("refreshed cache = %#v", cached)
	}
}

func TestBulkReadIsPacedRetriedAndRefreshesFoldersOnce(t *testing.T) {
	t.Setenv("XDG_DATA_HOME", t.TempDir())
	db, err := cache.Open()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	p := &pacedReadProvider{
		failFirst: 2,
		state:     map[string]bool{},
		marked:    make(chan struct{}, 8),
		refreshed: make(chan struct{}, 1),
	}
	d := &daemon{
		cfg:                &config.Config{Accounts: []config.Account{{Name: "work"}}},
		db:                 db,
		providers:          map[string]provider.Provider{"work": p},
		conns:              map[net.Conn]struct{}{},
		readPace:           15 * time.Millisecond,
		readRetryBase:      time.Millisecond,
		folderRefreshDelay: 30 * time.Millisecond,
	}
	client, server := net.Pipe()
	defer client.Close()
	go d.serve(server)

	dec := json.NewDecoder(client)
	for i := 0; i < 2; i++ {
		var bootstrap map[string]any
		if err := dec.Decode(&bootstrap); err != nil {
			t.Fatal(err)
		}
	}
	enc := json.NewEncoder(client)
	for _, read := range []bool{true, false} {
		for i := 0; i < 4; i++ {
			if err := enc.Encode(command{Type: "markread", Account: "work", ID: string(rune('a' + i)), Text: map[bool]string{true: "true", false: "false"}[read]}); err != nil {
				t.Fatal(err)
			}
		}
	}
	for i := 0; i < 8; i++ {
		select {
		case <-p.marked:
		case <-time.After(2 * time.Second):
			t.Fatal("timed out waiting for paced read mutations")
		}
	}
	select {
	case <-p.refreshed:
	case <-time.After(time.Second):
		t.Fatal("timed out waiting for coalesced folder refresh")
	}
	time.Sleep(50 * time.Millisecond)

	p.mu.Lock()
	defer p.mu.Unlock()
	if p.markCalls != 10 {
		t.Fatalf("mark calls = %d, want 10 including two retries", p.markCalls)
	}
	if p.maxActive != 1 {
		t.Fatalf("concurrent mark calls = %d, want 1", p.maxActive)
	}
	if p.folderCalls != 1 {
		t.Fatalf("folder refreshes = %d, want 1", p.folderCalls)
	}
	if elapsed := p.callTimes[len(p.callTimes)-1].Sub(p.callTimes[0]); elapsed < 120*time.Millisecond {
		t.Fatalf("mutations were not paced: %v", elapsed)
	}
	want := []string{"a:read", "b:read", "c:read", "d:read", "a:unread", "b:unread", "c:unread", "d:unread"}
	if !slices.Equal(p.successful, want) {
		t.Fatalf("successful operations = %#v, want %#v", p.successful, want)
	}
	for id, read := range p.state {
		if read {
			t.Fatalf("%s ended read after ordered undo", id)
		}
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
