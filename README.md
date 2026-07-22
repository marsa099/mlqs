# mlqs

Native Linux mail client: Go daemon + Quickshell/QML UI. Gmail and
Outlook/Microsoft 365 (mail + calendar, Teams/Meet links) via the vendors'
REST APIs, plus plain **IMAP/SMTP** for any standards mailbox. Vim bindings
throughout. Wayland only (quickshell).
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

## Setting up with an agent

The fastest path is handing this README to a coding agent (Claude Code
or similar) and letting it drive. Paste something like:

> Install and set up mlqs from github:daphen/mlqs by reading its README.
> I use Gmail personally (me@gmail.com) and Microsoft 365 at work
> (me@company.com). Do everything scriptable yourself; hand me the
> browser steps (Google Cloud console, Azure portal, OAuth consents)
> one at a time and verify each stage before moving on.

Notes for the agent:

- **Install**: `nix profile install github:daphen/mlqs` — the default
  package is `mlqs-client` (bundles daemon, quickshell, vendored UI kit).
  Wayland session required.
- **Config**: `~/.config/mlqs/accounts.json` (examples below). Tokens
  land in `~/.local/share/mlqs/tokens/`, auto-refresh after first consent.
- **Human-only steps** — surface these, don't attempt them:
  1. Google Cloud console: create project, enable **Gmail API** and
     **Google Calendar API**, create an OAuth *desktop app* client,
     download the JSON to `~/.config/mlqs/google.json`.
  2. Azure portal: the app registration in the Outlook section below.
  3. Each `mlqs auth <name>`: a consent tab opens (URL is also printed —
     relay it if no browser appears; the loopback listener waits 5 min).
- **Verify between stages** over the daemon socket
  (`$XDG_RUNTIME_DIR/mlqs.sock`, newline-JSON):
  - `{"type":"ping"}` → `{"type":"pong"}` — daemon up
  - `{"type":"folders","account":"<name>"}` → folder list — auth works
  - `{"type":"agenda","account":"<name>","text":"7"}` → events — calendar works
  - Errors arrive as `{"type":"toast","text":...}`: `403 insufficient
    authentication scopes` → re-run auth; `has not been used in project`
    → API enablement missing; `not a desktop-app client JSON` → wrong
    Google download type; Azure admin-approval screen → org tenant
    policy blocks unverified apps.
- **Launch**: `mlqs-client`. Window title is `mail-client` (WM rules
  key off it). The daemon keeps running when the window closes —
  notifications and deep-links stay live.

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

> **You do not need to register anything in your employer's tenant.**
> Register the app with *any* Microsoft account — a free personal one is
> fine (App Registrations costs nothing, no subscription needed). Because
> the registration is multitenant, your work account signs in to it at
> consent time. Registration and consent are separate: the app's identity
> lives wherever you create it; your employer's tenant only sees a consent
> request. (One registration can also be shared — the client ID is a
> public PKCE identifier, not a secret.)

1. Go to [portal.azure.com](https://portal.azure.com) → **Microsoft Entra
   ID → App registrations → New registration** — signed in with any
   Microsoft account, personal is fine.
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

## IMAP / SMTP (any standards mailbox)

For a plain mailbox — Fastmail, Loopia, mailbox.org, a self-hosted
Dovecot, anything that speaks IMAP — there is no vendor REST API and no
OAuth console: reads go over IMAP, sends over SMTP, and the password is
the credential. Conversations are reconstructed from the server's
`THREAD=REFERENCES` (a per-message fallback kicks in when the server
lacks THREAD). No calendar.

Account entry (`~/.config/mlqs/accounts.json`):

```json
{
  "name": "personal", "vendor": "imap", "email": "you@example.com",
  "imap_host": "imap.example.com", "imap_port": 993, "imap_security": "ssl",
  "smtp_host": "smtp.example.com", "smtp_port": 587, "smtp_security": "starttls"
}
```

- `imap_security` / `smtp_security`: `ssl` (implicit TLS), `starttls`, or
  `plain`. Ports default to 993 (imap) / 587 (smtp); `username` defaults
  to `email`.
- `imap_threading`: `references` (default) groups reply chains via the
  server's THREAD; `flat` gives one conversation per message — set it to
  `flat` if the subject-merge below bothers you.
- Store the password: `mlqs auth personal` prompts for it (no echo) and
  writes `~/.local/share/mlqs/tokens/personal.imap` (0600). Alternatives:
  a `"password_cmd": "pass show mail/personal"` field, or the
  `MLQS_IMAP_PASSWORD` env at auth time.

Triage maps to IMAP moves: archive → the `\Archive` special-use folder,
trash → `\Trash`, star → the `\Flagged` keyword, read → `\Seen`. Sends
are `APPEND`ed to the `\Sent` folder. Reply threading is set via
`In-Reply-To`/`References`.

Known trade-off: `THREAD=REFERENCES` is RFC-5256, which merges by subject
when messages carry no `References` — so a run of identically-subjected
bulk mail (receipts, notifications) collapses into one conversation. Set
`"imap_threading": "flat"` to opt out and get one conversation per message.

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
