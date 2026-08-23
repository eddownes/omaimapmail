# Changelog

## 1.0.0 — first public release

OmaIMAPMail started as a private fork of [keithnyc/omafmail](https://github.com/keithnyc/omafmail)
(MIT licensed), built while adding a second account and iterating in daily
use. By this release the plugin had been substantially rewritten — this entry
covers everything that changed from the upstream single-account design.

### Rewritten: single account → unlimited accounts

Upstream OmaFMail is one plugin per account: each account is its own
Omarchy plugin folder, its own `manifest.json`, its own bar icon, and its own
`config.json`. Adding a second account meant cloning the whole plugin
directory and hand-editing IDs.

OmaIMAPMail is one plugin, period:

- A single `accounts.json` (an array of account entries) replaces one
  `config.json` per account.
- A single Python process (`scripts/mail_watcher.py`) runs one thread per
  account instead of one whole separate process (and Quickshell service
  instance) per account. Each thread has its own IMAP IDLE connection,
  its own seen-mail baseline, and its own reconnect/backoff — one account's
  outage never blocks another's.
- A single bar icon aggregates the unread count across every account, with
  a popup that lists every account's mail together, filterable to one
  account or all of them, each message tagged with a colored account badge.
- Editing `accounts.json` (by hand, or through the new settings UI) makes
  the running service pick up the change automatically — no new plugin
  folder, no manifest edits, no `omarchy plugin enable` ever required again.

### Added: in-shell settings UI

A gear icon in the popup opens an account manager: a list of configured
accounts (label, color, edit, remove) and an add/edit form (label, host,
port, mailbox, fetch limit, webmail URL, color, and a password field).
Saving an account writes `accounts.json` and stores its app password
directly in the system keyring via `secret-tool` — the password is piped
over the child process's stdin and never touches argv, a config file, or a
log line.

### Added: per-account color coding and filtering

Every account gets a color (from a fixed palette, chosen when the account is
added). Message rows show a colored account badge; filter buttons above the
message list narrow the view to one account or show everything combined.

### Fixed: iCloud (and any large-mailbox IMAP server) silently reporting zero unread

Upstream's single `UID SEARCH UNSEEN` call, issued immediately after
`SELECT`, can — at least against `imap.mail.me.com` with a very large
mailbox — non-deterministically return an empty result even when real
unread mail exists, because the server's search index hasn't caught up yet.
On top of that, the search response isn't reliably UID-ordered, and a
meaningful fraction of the UIDs it lists can be stale/ghost entries that
`FETCH` returns no data for.

`mail_watcher.py` now:
- retries an empty `UID SEARCH UNSEEN` up to 5 times with a short delay
  before trusting it,
- sorts the returned UIDs numerically descending and walks a bounded
  candidate pool (skipping ghosts) until it actually has `fetchLimit` real,
  fetchable messages, instead of blindly slicing the raw (and sometimes
  unordered) search response.

### Fixed: Save button hanging when adding an account with a password

Storing a password shells out to `secret-tool store`, which reads the
password from stdin **to EOF**, not just to a newline. The original
stdin-write code never closed the pipe, so `secret-tool` sat blocked forever
waiting for input that would never come — Save would appear to do nothing.
Fixed by explicitly closing the child process's stdin (`stdinEnabled =
false`) right after writing the password, and re-opening it before each
subsequent save (the process object is reused across every Save click).
A hard timeout and a visible "Saving…" state were also added so any future
hang like this fails loudly instead of silently.

### Fixed: settings UI showing stale data after Save

Writing `accounts.json` and watching it for external changes both use the
same file-watch mechanism; under load the app's own write could race the
watch-triggered reload, leaving the in-memory account list — and the
Settings view — stale until the shell was restarted, even though the write
itself had already succeeded on disk. `saveAccounts()` now updates the
in-memory state synchronously right after writing, instead of waiting on
the watcher to come back around. External edits to `accounts.json` are
still picked up reactively via the watcher as before.

### Unchanged from upstream

The core IMAP session handling — read-only `SELECT`, `BODY.PEEK[]` fetches
(so this plugin can never mark mail as read), the IMAP IDLE loop with
~25-minute re-issue, MIME part extraction and HTML-to-text snippet
generation, and the new-mail-vs-already-seen baseline/notification logic —
all trace directly back to keithnyc/omafmail.
