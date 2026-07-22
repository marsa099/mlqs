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
	// IMAPThreading: "references" (default) groups reply chains via the
	// server's THREAD=REFERENCES; "flat" gives one conversation per message
	// (avoids RFC-5256 subject-merge collapsing unrelated same-subject mail).
	IMAPThreading string `json:"imap_threading,omitempty"`
}

type Config struct {
	Accounts []Account `json:"accounts"`
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
