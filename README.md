# mlqs

Native Linux mail client: Go daemon + Quickshell/QML UI. Gmail and
Outlook/Microsoft 365 (mail + calendar, Teams/Meet links) via the vendors'
REST APIs — no IMAP. Vim bindings throughout. Wayland only (quickshell).
Sibling of [slqs](https://github.com/daphen/slqs) (Slack) and dsqrd (Discord).

- Unread-first inbox, Threads view (conversations you participate in)
- Conversation view with quote-stripping (each reply shows only what it added)
- Inline reply (`i`), vimium-style link hints (`f`), keyboard triage
  (`e` archive · `dd` trash · `u` undo · `Shift+R` read-toggle · `x` star)
- Multi-account, desktop notifications with deep-link + mark-read actions
- Recipient autocomplete harvested from your own mail

## Requirements

Everything ships in the nix flake: the Go daemon, quickshell, and a
vendored copy of the QsLib UI kit (components, icons, and a default
theme) under `ui/vendor/`. There are no other runtime dependencies —
`nix profile install github:daphen/mlqs` (or the flake-input route
below) is the whole install.

If you keep your own QsLib at `~/.local/share/qml/QsLib` it takes
precedence over the vendored copy — that's how the author's live
design system plugs in.

## Two accounts, two vendors (typical setup)

Personal Gmail + work Microsoft 365 in one client:

```json
{
  "accounts": [
    { "name": "personal", "vendor": "gmail",
      "email": "you@gmail.com",
      "credentials_file": "~/.config/mlqs/google.json" },
    { "name": "work", "vendor": "outlook",
      "email": "you@company.com",
      "client_id": "<azure-application-client-id>" }
  ]
}
```

Set up the Google OAuth client (section below), register the Azure app
(Outlook section below), then authorize each account in turn:

```
mlqs auth personal
mlqs auth work
```

Each opens a browser consent pinned to that account. Both mailboxes,
both calendars, and cross-account agenda/reminders then work out of
the box; tabs at the top-left switch accounts (ctrl+s cycles).

## Details

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

## Outlook / Microsoft 365

Outlook accounts work through Microsoft Graph — mail and calendar,
including Teams meetings (the agenda's join key and the reminder's Join
button open Teams in the browser).

Bring your own Azure app registration (free, ~10 minutes, no admin
consent needed for your own mailbox):

1. Go to [portal.azure.com](https://portal.azure.com) → **Microsoft Entra
   ID → App registrations → New registration**.
2. Name it (e.g. `mlqs`). Under **Supported account types** pick
   *"Accounts in any organizational directory and personal Microsoft
   accounts"* — that covers both work M365 and personal outlook.com.
3. Under **Redirect URI** choose platform **"Mobile and desktop
   applications"** and enter `http://localhost`.
4. After creating, open **Authentication** and set **"Allow public client
   flows"** to **Yes**. No client secret — mlqs uses PKCE.
5. Copy the **Application (client) ID** into your account entry:

```json
{
  "name": "work",
  "vendor": "outlook",
  "email": "you@company.com",
  "client_id": "<application-client-id>"
}
```

Then authorize as usual: `mlqs auth work`. Scopes requested:
`Mail.ReadWrite`, `Mail.Send`, `Calendars.ReadWrite`, `User.Read`,
`offline_access`.

Notes:

- Some organizations gate third-party apps; if consent fails with an
  admin-approval screen, your IT needs to allow the app (or you register
  it inside the org tenant instead of multitenant).
- Replies thread through Graph's native reply flow, so recipients in
  Outlook see the usual quoted history.

## Calendar

The daemon also speaks Google Calendar: a merged agenda across accounts
(sidebar → Calendar), RSVP (`y`/`m`/`x`), event creation (`n` in the
calendar pane, with optional Google Meet), invite RSVP straight from
invitation emails, and a desktop notification 5 minutes before events
with a Join action.

Setup on top of the mail scopes:

1. In the same Google Cloud project, enable the **Google Calendar API**
   (APIs & Services → Library → Google Calendar API → Enable).
2. Re-run consent for every account so the token gains the calendar
   scope: `mlqs auth <name>`.

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
QML2_IMPORT_PATH=$PWD/ui/vendor quickshell -p ui/shell.qml   # UI
# (the nix wrapper sets this for you; vendored QsLib lives in ui/vendor)
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
