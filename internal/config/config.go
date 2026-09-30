package config

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

type Account struct {
	Name   string `json:"name"`   // rail label, unique across accounts
	Vendor string `json:"vendor"` // "gmail" | "outlook" | "imap"
	Email  string `json:"email"`
	// Gmail is BYO-credentials (OSS model): either inline id/secret or a
	// pointer to the console-downloaded client JSON. Outlook falls back to
	// the embedded public client when unset.
	ClientID        string `json:"client_id,omitempty"`
	ClientSecret    string `json:"client_secret,omitempty"`
	CredentialsFile string `json:"credentials_file,omitempty"`
	// Outlook only: Azure AD authority tenant. Empty → "common" (accepts
	// work/school and personal accounts). Set to a tenant ID or
	// "organizations" to pin sign-in to one org and skip consumer routing.
	Tenant string `json:"tenant,omitempty"`
	// Outlook only: shared mailboxes this user has been delegated access to
	// (e.g. "support@company.com"). Each one shows up as a read-only-ish
	// folder under this account (triage works, sending/replying does not),
	// never counts toward badges, and never notifies. Needs the
	// Mail.ReadWrite.Shared scope — re-run `mlqs auth <name>` after adding.
	SharedMailboxes []string `json:"shared_mailboxes,omitempty"`
	// IMAP vendor: plain IMAP + SMTP. Security is "ssl" (implicit TLS),
	// "starttls" or "plain". Ports default to 993 (imap) / 587 (smtp).
	// Username defaults to Email. The password is never stored inline here —
	// it comes from PasswordCmd, the MLQS_IMAP_PASSWORD env, or the cred file
	// ~/.local/share/mlqs/tokens/<name>.imap (see IMAPPassword).
	IMAPHost     string `json:"imap_host,omitempty"`
	IMAPPort     int    `json:"imap_port,omitempty"`
	IMAPSecurity string `json:"imap_security,omitempty"`
	SMTPHost     string `json:"smtp_host,omitempty"`
	SMTPPort     int    `json:"smtp_port,omitempty"`
	SMTPSecurity string `json:"smtp_security,omitempty"`
	Username     string `json:"username,omitempty"`
	PasswordCmd  string `json:"password_cmd,omitempty"`
	// IMAPThreading: "" (default) groups reply chains via the server's
	// THREAD=REFERENCES, then splits apart RFC-5256's subject-only merges using
	// explicit Message-ID references; "server" (alias "references") keeps the
	// server's grouping verbatim; "flat" gives one conversation per message.
	IMAPThreading string `json:"imap_threading,omitempty"`
}

type Config struct {
	Accounts  []Account        `json:"accounts"`
	Summarize *SummarizeConfig `json:"summarize,omitempty"`
	Rules     []Rule           `json:"rules,omitempty"`
}

// Rule hides matching mail from the list AND from notifications. The fields are
// ANDed: an empty field is "don't care", so {SenderEmail: "notifications@github.com",
// SenderName: "lovable-ci-bot[bot]"} hides that bot without hiding the rest of
// GitHub — which a single-field rule cannot express.
//
// Matching is deliberately limited to sender + subject: mail headers (List-Id,
// Precedence) never reach a Conversation, and Snippet is not portable (a body
// preview on Gmail/Graph, literally the subject on IMAP).
type Rule struct {
	ID          string `json:"id"`                    // stable handle for delete
	SenderEmail string `json:"senderEmail,omitempty"` // substring, case-insensitive
	SenderName  string `json:"senderName,omitempty"`
	Subject     string `json:"subject,omitempty"`
	Exact       bool   `json:"exact,omitempty"` // whole-field equality instead of substring
	Created     string `json:"created,omitempty"`
}

// Match reports whether the rule hides this conversation. Every non-empty field
// must match (AND). Senders are checked across the WHOLE thread, not just the
// latest, so a noisy participant can't slip through by replying last.
func (r Rule) Match(senders []Address, subject string) bool {
	if r.SenderEmail == "" && r.SenderName == "" && r.Subject == "" {
		return false // an empty rule must never hide everything
	}
	if r.Subject != "" && !fieldMatch(r.Subject, subject, r.Exact) {
		return false
	}
	if r.SenderEmail == "" && r.SenderName == "" {
		return true
	}
	for _, a := range senders {
		okEmail := r.SenderEmail == "" || fieldMatch(r.SenderEmail, a.Email, r.Exact)
		okName := r.SenderName == "" || fieldMatch(r.SenderName, a.Name, r.Exact)
		if okEmail && okName {
			return true
		}
	}
	return false
}

func fieldMatch(want, got string, exact bool) bool {
	w, g := strings.ToLower(strings.TrimSpace(want)), strings.ToLower(got)
	if w == "" {
		return true
	}
	if exact {
		return g == w
	}
	return strings.Contains(g, w)
}

// MatchAny is the daemon's hot-path check.
func MatchAny(rules []Rule, senders []Address, subject string) bool {
	for _, r := range rules {
		if r.Match(senders, subject) {
			return true
		}
	}
	return false
}

// Address mirrors provider.Address without importing it — internal/provider
// imports nothing from config, and adding the reverse edge would be an import
// cycle. Kept minimal on purpose.
type Address struct {
	Name  string
	Email string
}

// SummarizeConfig is the optional "summarize" block in accounts.json: a keyless
// CLI ({provider, model}) or an OpenAI-compatible endpoint ({base_url, model,
// api_key}). Mirrors dsqrd's profiles.json summarize block.
type SummarizeConfig struct {
	Provider string `json:"provider,omitempty"`
	Model    string `json:"model,omitempty"`
	BaseURL  string `json:"base_url,omitempty"`
	APIKey   string `json:"api_key,omitempty"`
}

func Path() string {
	if d := os.Getenv("XDG_CONFIG_HOME"); d != "" {
		return filepath.Join(d, "mlqs", "accounts.json")
	}
	return filepath.Join(os.Getenv("HOME"), ".config", "mlqs", "accounts.json")
}

// Load returns an empty config when the file doesn't exist yet — the daemon
// still starts and the UI shows no accounts rather than failing.
func Load() (*Config, error) {
	b, err := os.ReadFile(Path())
	if os.IsNotExist(err) {
		return &Config{}, nil
	}
	if err != nil {
		return nil, err
	}
	var c Config
	if err := json.Unmarshal(b, &c); err != nil {
		return nil, fmt.Errorf("parsing %s: %w", Path(), err)
	}
	return &c, nil
}

// WriteRules replaces the "rules" block, preserving every other key byte-for-byte.
//
// Unlike WriteSummarize this REFUSES to write when an existing config won't parse.
// That writer tolerates a bad read (`_ = json.Unmarshal`), which means a corrupt
// accounts.json would be replaced by a file containing only the written block —
// silently destroying the account list. Rules are written far more often, so the
// risk is not acceptable here.
func WriteRules(rules []Rule) error {
	p := Path()
	m := map[string]json.RawMessage{}
	if b, err := os.ReadFile(p); err == nil {
		if err := json.Unmarshal(b, &m); err != nil {
			return fmt.Errorf("refusing to write rules: %s is not valid JSON (%w)", p, err)
		}
	} else if !os.IsNotExist(err) {
		return err
	}
	if rules == nil {
		rules = []Rule{}
	}
	bb, err := json.Marshal(rules)
	if err != nil {
		return err
	}
	m["rules"] = bb
	out, err := json.MarshalIndent(m, "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(p), 0755); err != nil {
		return err
	}
	tmp := p + ".tmp"
	if err := os.WriteFile(tmp, out, 0600); err != nil {
		return err
	}
	return os.Rename(tmp, p)
}

// WriteSummarize merges a summarize block into accounts.json, preserving every
// other key (accounts, etc.); atomic tmp+rename. Mirrors dsqrd's
// _write_summarize_cfg — the one-click-setup writer. 0600 since it may hold a key.
func WriteSummarize(block SummarizeConfig) error {
	p := Path()
	m := map[string]json.RawMessage{}
	if b, err := os.ReadFile(p); err == nil {
		_ = json.Unmarshal(b, &m) // tolerate an absent/empty file
	}
	bb, err := json.Marshal(block)
	if err != nil {
		return err
	}
	m["summarize"] = bb
	out, err := json.MarshalIndent(m, "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(p), 0755); err != nil {
		return err
	}
	tmp := p + ".tmp"
	if err := os.WriteFile(tmp, out, 0600); err != nil {
		return err
	}
	return os.Rename(tmp, p)
}

func (c *Config) Account(name string) (Account, error) {
	for _, a := range c.Accounts {
		if a.Name == name {
			return a, nil
		}
	}
	return Account{}, fmt.Errorf("no account %q in %s", name, Path())
}

// GoogleCreds resolves the OAuth client for a gmail account from either the
// inline fields or the downloaded client JSON ({"installed":{...}}).
func (a Account) GoogleCreds() (id, secret string, err error) {
	if a.ClientID != "" {
		return a.ClientID, a.ClientSecret, nil
	}
	if a.CredentialsFile == "" {
		return "", "", fmt.Errorf("account %q: set client_id/client_secret or credentials_file", a.Name)
	}
	b, err := os.ReadFile(expand(a.CredentialsFile))
	if err != nil {
		return "", "", err
	}
	var f struct {
		Installed struct {
			ClientID     string `json:"client_id"`
			ClientSecret string `json:"client_secret"`
		} `json:"installed"`
	}
	if err := json.Unmarshal(b, &f); err != nil {
		return "", "", fmt.Errorf("parsing %s: %w", a.CredentialsFile, err)
	}
	if f.Installed.ClientID == "" {
		return "", "", fmt.Errorf("%s: not a desktop-app client JSON (no \"installed\" key)", a.CredentialsFile)
	}
	return f.Installed.ClientID, f.Installed.ClientSecret, nil
}

// IMAPCredPath is where the IMAP password lands after `mlqs auth <name>`, next
// to the OAuth token store.
func IMAPCredPath(account string) string {
	base := os.Getenv("XDG_DATA_HOME")
	if base == "" {
		base = filepath.Join(os.Getenv("HOME"), ".local", "share")
	}
	return filepath.Join(base, "mlqs", "tokens", account+".imap")
}

// IMAPPassword resolves the account's password in order: PasswordCmd output,
// then the cred file written by `mlqs auth`, then the MLQS_IMAP_PASSWORD env.
func (a Account) IMAPPassword() (string, error) {
	if a.PasswordCmd != "" {
		out, err := exec.Command("sh", "-c", a.PasswordCmd).Output()
		if err != nil {
			return "", fmt.Errorf("account %q: password_cmd: %w", a.Name, err)
		}
		return strings.TrimRight(string(out), "\r\n"), nil
	}
	if b, err := os.ReadFile(IMAPCredPath(a.Name)); err == nil {
		var f struct {
			Password string `json:"password"`
		}
		if err := json.Unmarshal(b, &f); err != nil {
			return "", fmt.Errorf("parsing %s: %w", IMAPCredPath(a.Name), err)
		}
		if f.Password != "" {
			return f.Password, nil
		}
	}
	if p := os.Getenv("MLQS_IMAP_PASSWORD"); p != "" {
		return p, nil
	}
	return "", fmt.Errorf("account %q not authorized yet — run: mlqs auth %s", a.Name, a.Name)
}

func expand(p string) string {
	if len(p) > 1 && p[:2] == "~/" {
		return filepath.Join(os.Getenv("HOME"), p[2:])
	}
	return p
}
