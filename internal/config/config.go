package config

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
)

type Account struct {
	Name   string `json:"name"`   // rail label, unique across accounts
	Vendor string `json:"vendor"` // "gmail" | "outlook"
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

func expand(p string) string {
	if len(p) > 1 && p[:2] == "~/" {
		return filepath.Join(os.Getenv("HOME"), p[2:])
	}
	return p
}
