package main

import (
	"context"
	"fmt"
	"log"
	"os"
	"sort"

	"mlqs/internal/auth"
	"mlqs/internal/config"
	"mlqs/internal/gmail"
	"mlqs/internal/provider"
)

func main() {
	cfg, err := config.Load()
	if err != nil {
		log.Fatal(err)
	}
	a, err := cfg.Account("gmail")
	if err != nil {
		log.Fatal(err)
	}
	ts, err := auth.Source(context.Background(), a)
	if err != nil {
		log.Fatal(err)
	}
	c := gmail.New(context.Background(), ts)
	ctx := context.Background()

	if len(os.Args) > 1 && os.Args[1] == "stats" {
		queries := [][2]string{
			{"inbox total", "in:inbox"},
			{"inbox unread", "in:inbox is:unread"},
			{"promotions", "in:inbox category:promotions"},
			{"social", "in:inbox category:social"},
			{"updates", "in:inbox category:updates"},
			{"forums", "in:inbox category:forums"},
			{"primary", "in:inbox category:primary"},
			{"older than 2y", "in:inbox older_than:2y"},
			{"older than 1y", "in:inbox older_than:1y"},
			{"older than 6m", "in:inbox older_than:6m"},
			{"older than 1m", "in:inbox older_than:1m"},
			{"has unsubscribe", "in:inbox unsubscribe"},
			{"primary, last month", "in:inbox category:primary newer_than:1m"},
			{"primary unread", "in:inbox category:primary is:unread"},
			{"starred in inbox", "in:inbox is:starred"},
		}
		for _, q := range queries {
			n, err := c.EstimateThreads(ctx, q[1])
			if err != nil {
				fmt.Printf("%-22s ERR %v\n", q[0], err)
				continue
			}
			fmt.Printf("%-22s %6d   (%s)\n", q[0], n, q[1])
		}
		return
	}
	if len(os.Args) > 2 && os.Args[1] == "scan" {
		query := os.Args[2]
		var all []provider.Conversation
		cursor := ""
		for len(all) < 1500 {
			pg, err := c.SearchPage(ctx, query, cursor, 100)
			if err != nil {
				log.Fatal(err)
			}
			all = append(all, pg.Conversations...)
			if pg.NextCursor == "" {
				break
			}
			cursor = pg.NextCursor
		}
		fmt.Printf("TOTAL %d threads for %q\n\n", len(all), query)
		bySender := map[string]int{}
		name := map[string]string{}
		for _, cv := range all {
			for _, s := range cv.Senders {
				bySender[s.Email]++
				if s.Name != "" {
					name[s.Email] = s.Name
				}
			}
		}
		type kv struct {
			k string
			n int
		}
		var top []kv
		for k, n := range bySender {
			top = append(top, kv{k, n})
		}
		sort.Slice(top, func(i, j int) bool { return top[i].n > top[j].n })
		fmt.Println("== top senders ==")
		for i, t := range top {
			if i >= 40 {
				break
			}
			fmt.Printf("%4d  %-40s %s\n", t.n, t.k, name[t.k])
		}
		fmt.Println("\n== 50 most recent ==")
		sort.Slice(all, func(i, j int) bool { return all[i].Date.After(all[j].Date) })
		for i, cv := range all {
			if i >= 50 {
				break
			}
			who := "?"
			if len(cv.Senders) > 0 {
				who = cv.Senders[0].Name
				if who == "" {
					who = cv.Senders[0].Email
				}
			}
			subj := cv.Subject
			if len(subj) > 60 {
				subj = subj[:60]
			}
			fmt.Printf("%s  %-28.28s  %s\n", cv.Date.Format("2006-01-02"), who, subj)
		}
		return
	}
	if len(os.Args) > 1 && os.Args[1] == "markread" {
		ids, err := c.ListMessageIDs(ctx, "in:inbox is:unread", 100000)
		if err != nil {
			log.Fatalf("listing: %v (got %d ids)", err, len(ids))
		}
		fmt.Printf("marking %d messages read...\n", len(ids))
		if err := c.BatchModify(ctx, ids, nil, []string{"UNREAD"}); err != nil {
			log.Fatal(err)
		}
		fmt.Println("done")
		return
	}
	if len(os.Args) > 1 && os.Args[1] == "check" {
		fs, err := c.ListFolders(ctx)
		if err != nil {
			log.Fatal(err)
		}
		for _, f := range fs {
			if f.Role == "inbox" {
				fmt.Printf("INBOX: %d unread / %d total\n", f.Unread, f.Total)
			}
		}
		return
	}
	log.Fatal("usage: triage stats | scan <query> | markread | check")
}
