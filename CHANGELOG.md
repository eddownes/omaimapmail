# Changelog

## 1.0.3 — closed the accounts.json check/open race

Follow-up fix required by the
[HANCORE-linux/omarchy-plugin-marketplace](https://github.com/HANCORE-linux/omarchy-plugin-marketplace/issues/1811)
security review: at the previously submitted HEAD
(`b43b2d62309f1e307c6a5a6ef1a3657a0b16cb9b`), the TLS and `PlainText` fixes
held up, but `Service.qml`'s `accounts.json` guard still resolved the path
twice — once in an out-of-band `stat` process, once when `FileView.reload()`
later opened it — leaving a window in between where the path could be
repointed at a FIFO (whose open+read would then block, or hand back
attacker-controlled bytes) or an oversized regular file (which `FileView`
would then load in full, since it has no byte cap of its own). This release:

- Replaces the `stat`-then-`FileView.reload()` pair with a single helper
  process that opens `accounts.json` exactly once and then checks and reads
  that same file descriptor — never the path again — rejecting anything
  that isn't a plain regular file within the existing 2 MiB ceiling before a
  single byte of it reaches this shell process. `FileView` is now used only
  to write `accounts.json` and to notice external changes to it, never to
  read its content.

No behavior changes for well-formed accounts files.

## 1.0.2 — verified TLS and shell-side ceilings

Fixes required by the [omarchyplugins.com](https://omarchyplugins.com) review
of this plugin, reported by reviewer **ryanrhughes**: at the previously
submitted HEAD (`ab4bbb28345ab1035b3a3f87a40db59be3518c90`), the IMAP
connection didn't verify the server's TLS certificate or hostname, the QML
service still loaded and retained the complete `accounts.json` with no
shell-side byte/account/field ceilings (the prior 1.0.1 fix only bounded the
Python watcher's own copy of that data), and attacker-controlled sender/
subject/snippet text reached `Text` elements at their default rich-text
setting, permitting remote-image loads. This release:

- `scripts/mail_watcher.py`'s `connect()` now opens `IMAP4_SSL` with an
  explicit `ssl.create_default_context()` instead of relying on its
  unverified default, so a network attacker can no longer impersonate an
  IMAP server to capture an account's password and mail.
- `Service.qml` stats `accounts.json` out-of-band before ever letting
  `FileView` load it, refusing to load (and reporting an error) past a 2 MiB
  ceiling instead of pulling an arbitrarily large file into the shell
  process; parsed account entries are now also capped at 50 and each
  string field truncated to 300 characters, mirroring the ceilings
  `mail_watcher.py` already applies to its own copy of the same file.
- `Panel.qml`'s sender-name, subject, and snippet `Text` elements now set
  `textFormat: Text.PlainText` explicitly, so a crafted HTML-looking
  message can no longer get rendered as rich text and trigger a remote
  image fetch.

No behavior changes for well-formed accounts/messages/servers.

Thanks to ryanrhughes for the review.

## 1.0.1 — resource-ceiling hardening

Fixes required by the [omarchyplugins.com](https://omarchyplugins.com) review
of this plugin, reported by reviewer **HANCORE-linux**: at the submitted
HEAD (`77fd4e946f267cfd64a9341c197b9422635c2e09`), the long-lived watcher in
`scripts/mail_watcher.py` accepted unbounded IMAP readline/fetch bodies,
parsed and decoded each complete message, captured `secret-tool` output
completely, and read config/state JSON without byte or account-count
ceilings — so a hostile mail server, message, keyring value, or replaced
local file could exhaust the helper's and shell's memory. This release caps
protocol lines/bodies and child-process/file reads, bounds threads/records/
fields, and emits only bounded event lines:

- IMAP message fetches use partial-fetch syntax (`BODY.PEEK[]<0.N>`) instead
  of an unbounded `BODY.PEEK[]`, capping bytes pulled per message regardless
  of what size the message or server claims.
- IDLE's untagged-response draining loops are capped by line count, not just
  by time.
- `secret-tool`'s output is read on a bounded reader instead of
  `subprocess.run(capture_output=True)`, capped by both bytes and wall-clock.
- MIME parts scanned per message, and decoded header fields (subject,
  sender name/address) kept in emitted events, are both capped.
- `accounts.json` and each account's `state.json` are read with a byte
  ceiling before parsing; the seen-mail baseline loaded from state is capped
  in entry count; the number of accounts/threads started from a config file
  is capped; a per-account `fetchLimit` is clamped to a sane maximum.
- Emitted error-event text is truncated, so a hostile server can't inflate
  an exception message into an unbounded event line.
- Also fixed while in there: the watcher's exception handler didn't catch
  the IDLE-protocol `RuntimeError`s (pre-existing, and one newly added
  above) — a triggering server would have silently killed that account's
  thread forever instead of backing off and reconnecting like every other
  network failure.

No behavior changes for well-formed accounts/messages — every ceiling above
sits far above normal usage.

Thanks to HANCORE-linux for the review.

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
