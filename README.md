# mlqs

Native Linux mail client: Go daemon + Quickshell/QML UI. Gmail (and one day
Outlook) via the vendors' REST APIs — no IMAP. Vim bindings throughout.
Sibling of [slqs](https://github.com/daphen/slqs) (Slack) and dsqrd (Discord).

- Unread-first inbox, Threads view (conversations you participate in)
- Conversation view with quote-stripping (each reply shows only what it added)
- Inline reply (`i`), vimium-style link hints (`f`), keyboard triage
  (`e` archive · `dd` trash · `u` undo · `Shift+R` read-toggle · `x` star)
- Multi-account, desktop notifications with deep-link + mark-read actions
- Recipient autocomplete harvested from your own mail

## Requirements

- Linux + Wayland, [quickshell](https://quickshell.org)
- Nix (recommended) or Go 1.26+
- A Google account and ~10 minutes of OAuth console clicking (below)

## Google OAuth (bring your own client)

mlqs is an unverified personal app — you register your own OAuth client so
nobody pays Google's verification fees:

1. [console.cloud.google.com](https://console.cloud.google.com) → new project
2. APIs & Services → Library → enable **Gmail API**
3. OAuth consent screen: External. Then **publish to production**
   (unverified is fine — skipping this expires tokens weekly)
4. Credentials → Create → OAuth client ID → **Desktop app** → download the JSON
5. Save it as e.g. `~/.config/mlqs/google.json`

At consent time you'll see "Google hasn't verified this app" →
Advanced → continue. That's the deal with the BYO model.

## Configure

`~/.config/mlqs/accounts.json`:

```json
{
  "accounts": [
    { "name": "gmail", "vendor": "gmail", "email": "you@gmail.com",
      "credentials_file": "~/.config/mlqs/google.json" },
    { "name": "work",  "vendor": "gmail", "email": "you@company.com",
      "credentials_file": "~/.config/mlqs/google.json" }
  ]
}
```

Multiple accounts share one credentials file. Then authorize each:

```
mlqs auth gmail
mlqs auth work
```

Tokens land in `~/.local/share/mlqs/tokens/` and auto-refresh.

## Run

Nix:

```
nix run github:daphen/mlqs        # mlqs-client: starts daemon, opens UI
```

Manual:

```
go build -o mlqs . && ./mlqs &    # daemon (unix socket in $XDG_RUNTIME_DIR)
quickshell -p ui/shell.qml        # UI
```

## Keys (chin shows context-relevant ones)

| | |
|---|---|
| `j/k` `h/l` | move / spatial back-forward (sidebar ⇄ index ⇄ conversation) |
| `Enter` | open · `q` close conversation |
| `n` / `c` | compose · `i` reply inline · `R` pick reply target · `a` toggle reply-all |
| `f` | link/image/attachment hints · `o` original HTML in browser |
| `e` `dd` `u` | archive · trash · undo |
| `Shift+R` `x` | toggle read · star |
| `/` | search (Gmail syntax) · `Ctrl+S`/`Ctrl+Shift+L/H` switch account |
| `gg G Ctrl+D/U` | jump/scroll · `8j` counts work |

Notifications carry two actions: default = open the conversation,
"Mark read" = triage without opening (bind them in your notification center).

## Notes

- HTML mail is sanitized to Qt rich text; images are downloaded and rewritten
  to local files by the daemon (never fetched by the UI). `o` opens the
  original in a browser.
- `SLK_MEDIA_VIEWER` (optional): script handed image paths; falls back to
  xdg-open conventions.
- Caches live in `~/.cache/mlqs/`, mail state in `~/.local/share/mlqs/`.
