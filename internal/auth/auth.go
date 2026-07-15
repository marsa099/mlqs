// Package auth implements the loopback-PKCE OAuth flow and the on-disk
// token store. Tokens live at ~/.local/share/mlqs/tokens/<account>.json.
package auth

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"time"

	"golang.org/x/oauth2"
	"golang.org/x/oauth2/endpoints"

	"mlqs/internal/config"
	"mlqs/internal/httpx"
)

// Optional embedded public client (PKCE, no secret). Empty means BYO:
// each outlook account carries its own client_id — see README.
const defaultMSClientID = ""

func oauthConfig(a config.Account, redirect string) (*oauth2.Config, error) {
	switch a.Vendor {
	case "gmail":
		id, secret, err := a.GoogleCreds()
		if err != nil {
			return nil, err
		}
		return &oauth2.Config{
			ClientID: id, ClientSecret: secret,
			Endpoint:    endpoints.Google,
			RedirectURL: redirect,
			Scopes: []string{
				"https://www.googleapis.com/auth/gmail.modify",
				"https://www.googleapis.com/auth/gmail.send",
				"https://www.googleapis.com/auth/calendar",
			},
		}, nil
	case "outlook":
		id := a.ClientID
		if id == "" {
			id = defaultMSClientID
		}
		if id == "" {
			return nil, fmt.Errorf("account %q: outlook needs client_id (embedded default not registered yet)", a.Name)
		}
		return &oauth2.Config{
			ClientID: id,
			// endpoints.Microsoft is the consumer-only LiveConnect endpoint
			// (login.live.com), which rejects work/school (Microsoft 365)
			// accounts with "we couldn't find a Microsoft account". AzureAD
			// routes both work and personal accounts and issues Graph tokens.
			// Empty tenant defaults to "common".
			Endpoint:    endpoints.AzureAD(a.Tenant),
			RedirectURL: redirect,
			Scopes: []string{
				"offline_access",
				"https://graph.microsoft.com/Mail.ReadWrite",
				"https://graph.microsoft.com/Mail.Send",
				"https://graph.microsoft.com/Calendars.ReadWrite",
				"https://graph.microsoft.com/User.Read",
			},
		}, nil
	}
	return nil, fmt.Errorf("account %q: unknown vendor %q", a.Name, a.Vendor)
}

// Authorize runs the interactive consent flow: local loopback listener,
// browser handoff, PKCE code exchange. Blocks until consent or timeout.
func Authorize(ctx context.Context, a config.Account) (*oauth2.Token, error) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return nil, err
	}
	defer ln.Close()
	redirect := fmt.Sprintf("http://localhost:%d/cb", ln.Addr().(*net.TCPAddr).Port)
	conf, err := oauthConfig(a, redirect)
	if err != nil {
		return nil, err
	}

	verifier := oauth2.GenerateVerifier()
	sb := make([]byte, 16)
	rand.Read(sb)
	state := hex.EncodeToString(sb)
	// login_hint pins the consent screen to the account being authorized —
	// without it Google silently uses the browser's last-active session
	url := conf.AuthCodeURL(state, oauth2.AccessTypeOffline, oauth2.S256ChallengeOption(verifier),
		oauth2.SetAuthURLParam("login_hint", a.Email))

	type result struct {
		code string
		err  error
	}
	ch := make(chan result, 1)
	srv := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/cb" {
			http.NotFound(w, r)
			return
		}
		q := r.URL.Query()
		if q.Get("state") != state {
			ch <- result{err: fmt.Errorf("state mismatch")}
		} else if e := q.Get("error"); e != "" {
			ch <- result{err: fmt.Errorf("consent denied: %s", e)}
		} else {
			ch <- result{code: q.Get("code")}
		}
		fmt.Fprintln(w, "mlqs: authorized — you can close this tab.")
	})}
	go srv.Serve(ln)
	defer srv.Close()

	fmt.Println("opening browser for consent; if nothing happens, open:")
	fmt.Println("  " + url)
	exec.Command("xdg-open", url).Start()

	select {
	case r := <-ch:
		if r.err != nil {
			return nil, r.err
		}
		return conf.Exchange(ctx, r.code, oauth2.VerifierOption(verifier))
	case <-time.After(5 * time.Minute):
		return nil, fmt.Errorf("timed out waiting for consent")
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}

func tokenPath(account string) string {
	base := os.Getenv("XDG_DATA_HOME")
	if base == "" {
		base = filepath.Join(os.Getenv("HOME"), ".local", "share")
	}
	return filepath.Join(base, "mlqs", "tokens", account+".json")
}

func SaveToken(account string, t *oauth2.Token) error {
	p := tokenPath(account)
	if err := os.MkdirAll(filepath.Dir(p), 0o700); err != nil {
		return err
	}
	b, err := json.Marshal(t)
	if err != nil {
		return err
	}
	return os.WriteFile(p, b, 0o600)
}

func LoadToken(account string) (*oauth2.Token, error) {
	b, err := os.ReadFile(tokenPath(account))
	if err != nil {
		return nil, err
	}
	var t oauth2.Token
	if err := json.Unmarshal(b, &t); err != nil {
		return nil, err
	}
	return &t, nil
}

// Source returns a token source that auto-refreshes and persists refreshed
// tokens back to disk, so a daemon restart never re-prompts for consent.
// Refreshes go through the hardened client so they can't wedge either.
func Source(ctx context.Context, a config.Account) (oauth2.TokenSource, error) {
	ctx = context.WithValue(ctx, oauth2.HTTPClient, httpx.Client(60*time.Second))
	tok, err := LoadToken(a.Name)
	if err != nil {
		return nil, fmt.Errorf("account %q not authorized yet — run: mlqs auth %s (%w)", a.Name, a.Name, err)
	}
	conf, err := oauthConfig(a, "http://localhost/cb")
	if err != nil {
		return nil, err
	}
	return &persisting{account: a.Name, src: conf.TokenSource(ctx, tok), last: tok.AccessToken}, nil
}

type persisting struct {
	account string
	src     oauth2.TokenSource
	last    string
}

func (p *persisting) Token() (*oauth2.Token, error) {
	t, err := p.src.Token()
	if err != nil {
		return nil, err
	}
	if t.AccessToken != p.last {
		p.last = t.AccessToken
		if err := SaveToken(p.account, t); err != nil {
			return nil, fmt.Errorf("persisting refreshed token: %w", err)
		}
	}
	return t, nil
}
