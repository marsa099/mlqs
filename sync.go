package main

import (
	"context"
	"encoding/json"
	"sync"
	"time"

	"mlqs/internal/debuglog"
	"mlqs/internal/provider"
)

const pollInterval = 45 * time.Second

// syncLoop polls the vendor delta API and pushes changes to connected UIs.
// Neither Gmail nor Graph offers desktop push (Pub/Sub / public webhook), so
// a cheap "what changed since token X" poll is the live channel.
func (d *daemon) syncLoop(account string, p provider.Provider) {
	for {
		d.syncOnce(account, p)
		time.Sleep(pollInterval)
	}
}

func (d *daemon) syncOnce(account string, p provider.Provider) {
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()

	tok := d.db.DeltaToken(account)
	delta, err := p.Delta(ctx, tok)
	if err != nil {
		debuglog.Sync("%s: delta: %v", account, err)
		return
	}
	if delta.FullResync {
		// fresh baseline: changes before this token are unknowable; the UI's
		// on-demand fetches cover the gap
		d.db.SetDeltaToken(account, delta.NextToken, time.Now().Unix())
		debuglog.Sync("%s: full resync baseline %s", account, delta.NextToken)
		// seed the per-account tab badges at startup
		if fs, err := p.ListFolders(ctx); err == nil {
			d.db.UpsertFolders(account, fs)
			d.broadcast(map[string]any{"type": "folders", "account": account, "folders": fs})
		}
		return
	}
	if len(delta.Changed) == 0 {
		if delta.NextToken != tok {
			d.db.SetDeltaToken(account, delta.NextToken, time.Now().Unix())
		}
		return
	}
	debuglog.Sync("%s: %d changed threads", account, len(delta.Changed))

	changed := delta.Changed
	if len(changed) > 100 {
		changed = changed[:100]
	}
	var wg sync.WaitGroup
	sem := make(chan struct{}, 6)
	for _, id := range changed {
		wg.Add(1)
		go func(id string) {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()
			conv, err := p.GetConversationMeta(ctx, id)
			if err != nil {
				// thread gone (permanent delete) → drop it from any open view
				d.db.RemoveConversation(account, id)
				d.broadcast(map[string]any{"type": "convRemoved", "account": account, "id": id})
				return
			}
			d.db.UpsertConversations(account, []provider.Conversation{conv})
			d.broadcast(map[string]any{"type": "convUpdated", "account": account, "conv": conv})
			d.maybeNotify(account, conv)
		}(id)
	}
	wg.Wait()

	d.db.SetDeltaToken(account, delta.NextToken, time.Now().Unix())

	// badges: recount folders after any change batch
	if fs, err := p.ListFolders(ctx); err == nil {
		d.db.UpsertFolders(account, fs)
		d.broadcast(map[string]any{"type": "folders", "account": account, "folders": fs})
	}
}

// maybeNotify fires a desktop notification for fresh unread inbox mail.
// Keyed on the conv's latest date so label-only changes don't re-notify.
func (d *daemon) maybeNotify(account string, c provider.Conversation) {
	if !c.Unread || time.Since(c.Date) > 15*time.Minute {
		debuglog.Sync("notify skip %s/%s: unread=%v age=%s", account, c.ID, c.Unread, time.Since(c.Date))
		return
	}
	inbox := false
	for _, f := range c.FolderIDs {
		if f == "INBOX" || f == "Inbox" {
			inbox = true
			break
		}
	}
	if !inbox {
		debuglog.Sync("notify skip %s/%s: not in inbox %v", account, c.ID, c.FolderIDs)
		return
	}
	key := account + ":" + c.ID
	stamp := c.Date.Format(time.RFC3339)
	d.notifMu.Lock()
	prev := d.notified[key]
	d.notified[key] = stamp
	d.notifMu.Unlock()
	if prev == stamp {
		debuglog.Sync("notify skip %s/%s: already notified", account, c.ID)
		return
	}
	who := "mail"
	if len(c.Senders) > 0 {
		if c.Senders[len(c.Senders)-1].Name != "" {
			who = c.Senders[len(c.Senders)-1].Name
		} else {
			who = c.Senders[len(c.Senders)-1].Email
		}
	}
	subj := c.Subject
	if subj == "" {
		subj = "(no subject)"
	}
	k, _ := json.Marshal(map[string]string{"A": account, "ID": c.ID, "S": subj})
	debuglog.Sync("notify FIRE %s/%s: %s — %s", account, c.ID, who, subj)
	body := subj
	if c.Snippet != "" {
		body += "\n" + c.Snippet
	}
	d.notifier.Notify(string(k), who+"  ·  "+account, body)
}
