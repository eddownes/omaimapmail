#!/usr/bin/env python3
"""Multi-account IMAP IDLE watcher for OmaIMAPMail.

Originally derived from the single-account watcher in keithnyc/omafmail
(https://github.com/keithnyc/omafmail, MIT licensed); the IMAP/IDLE/MIME
plumbing below traces back to that project. This version adds multi-account
threading, the iCloud search-retry and ghost-UID handling, and per-account
notification/state tracking — see CHANGELOG.md for the full list.

Reads an accounts file (a JSON object with an "accounts" array — see
../README.md) and runs one independent watcher thread per account: connect,
select the configured mailbox read-only, loop issuing IMAP IDLE, waking on
server push, notifying only for mail that's new since that account's own
last-seen baseline, and persisting that baseline to its own state file.

Every event line on stdout is tagged with "accountId" so the single
Quickshell service that spawns this script can route it to the right
account. Restarting the whole process (which the service does whenever the
accounts file changes) is how added/edited/removed accounts take effect —
each thread reconnects independently after that with its own backoff, so one
account's outage never blocks the others.

Never touches message flags: SELECT is read-only and all fetches use
BODY.PEEK[], so watching mail here never marks it as read.
"""

from __future__ import annotations

import email
import email.header
import email.utils
import html
import imaplib
import json
import os
import re
import socket
import ssl
import subprocess
import sys
import threading
import time

IDLE_TIMEOUT_SECONDS = 25 * 60  # re-issue IDLE before the ~29 min server timeout
CONNECT_TIMEOUT_SECONDS = 15
DRAIN_TIMEOUT_SECONDS = 0.5  # short window to catch batched push lines (EXISTS + RECENT)
SNIPPET_CHARS = 220
UNSEEN_SEARCH_RETRIES = 5  # extra attempts beyond the first, only spent when the result is empty
UNSEEN_SEARCH_RETRY_DELAY = 0.5  # seconds between retries
BACKOFF_TIERS = [2, 5, 15, 30, 60]  # seconds, for network-error reconnects
AUTH_ERROR_RETRY_SECONDS = 300  # a bad password/mailbox won't fix itself; don't hammer the server

# --- Resource ceilings -------------------------------------------------
# Every one of these bounds a place where an untrusted input (a mail server,
# a message on it, a keyring helper's output, or a local config/state file
# that's been swapped out from under us) would otherwise be trusted to name
# its own size. None of this is about normal operation - normal accounts,
# messages, and files sit far under every ceiling below - it's about making
# sure a hostile or corrupted one can only ever cost a bounded amount of
# memory/CPU rather than an unbounded amount.
MAX_UNTAGGED_LINES = 1000  # untagged IMAP response lines drained/awaited per IDLE cycle
MAX_MESSAGE_FETCH_BYTES = 1 * 1024 * 1024  # bytes of a message fetched (headers + body prefix)
MAX_MIME_PARTS_SCANNED = 1000  # MIME parts walked per message when hunting for a text body
MAX_FIELD_CHARS = 300  # decoded header field (subject, sender name/address) kept per message
MAX_ERROR_MESSAGE_CHARS = 500  # exception/server text kept when emitting an error event
MAX_SECRET_BYTES = 8 * 1024  # secret-tool stdout (a password) accepted
MAX_HELPER_TIMEOUT_SECONDS = 10  # wall-clock budget for the secret-tool helper
MAX_CONFIG_FILE_BYTES = 2 * 1024 * 1024  # accounts.json read from disk
MAX_STATE_FILE_BYTES = 2 * 1024 * 1024  # per-account state.json read from disk
MAX_ACCOUNTS = 50  # watcher threads started, regardless of how many accounts.json lists
MAX_FETCH_LIMIT = 200  # clamp on a per-account "fetchLimit" from accounts.json
MAX_KNOWN_IDS = 5000  # seen-mail baseline entries kept per account

_emit_lock = threading.Lock()


def emit(event: dict) -> None:
    with _emit_lock:
        print(json.dumps(event, separators=(",", ":")), flush=True)


def fail(account_id: str, kind: str, message: str) -> None:
    # `message` can originate from a hostile server (exception text embedding
    # its own greeting/response) or a helper's stderr, so it's capped like any
    # other emitted field rather than passed through at whatever length it
    # happened to arrive in.
    emit({"type": "error", "accountId": account_id, "kind": kind, "message": message[:MAX_ERROR_MESSAGE_CHARS]})


class IMAP4Idle(imaplib.IMAP4_SSL):
    def idle_start(self) -> bytes:
        tag = self._new_tag()
        self.send(b"%s IDLE\r\n" % tag)
        resp = self.readline()
        if not resp.startswith(b"+"):
            raise RuntimeError("server rejected IDLE: " + resp.decode(errors="replace"))
        return tag

    def idle_wait(self, timeout: float) -> list:
        # `readline()` itself already caps a single line's length (imaplib's
        # own _MAXLINE), but a server that just keeps pushing untagged lines
        # back-to-back inside the drain window could still make this loop
        # accumulate an unbounded number of them; cap the count too.
        self.sock.settimeout(timeout)
        lines = []
        try:
            line = self.readline()
            if not line:
                raise RuntimeError("connection closed during IDLE")
            lines.append(line)
        except socket.timeout:
            self.sock.settimeout(None)
            return lines
        self.sock.settimeout(DRAIN_TIMEOUT_SECONDS)
        try:
            while len(lines) < MAX_UNTAGGED_LINES:
                line = self.readline()
                if not line:
                    break
                lines.append(line)
        except socket.timeout:
            pass
        finally:
            self.sock.settimeout(None)
        return lines

    def idle_done(self, tag: bytes) -> None:
        self.send(b"DONE\r\n")
        for _ in range(MAX_UNTAGGED_LINES):
            line = self.readline()
            if not line or line.startswith(tag):
                return
        raise RuntimeError("server did not complete IDLE within %d lines" % MAX_UNTAGGED_LINES)


def _read_bounded(pipe, max_bytes: int, result: dict) -> None:
    chunks = []
    total = 0
    try:
        while True:
            chunk = pipe.read(65536)
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
            if total > max_bytes:
                break
    except (OSError, ValueError):
        pass
    result["data"] = b"".join(chunks)[:max_bytes]
    result["truncated"] = total > max_bytes


def run_bounded(cmd: list, timeout: float, max_bytes: int) -> tuple:
    """Run `cmd`, capturing stdout up to `max_bytes` within `timeout` seconds.

    A plain `subprocess.run(capture_output=True)` trusts the child to produce
    a reasonable amount of output before it decides to stop; a replaced or
    compromised helper binary doesn't have to honor that. Reading on a
    background thread lets us cut the child off — by byte count or by
    wall-clock — instead of buffering whatever it sends.
    """
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    result = {}
    reader = threading.Thread(target=_read_bounded, args=(proc.stdout, max_bytes, result), daemon=True)
    reader.start()
    reader.join(timeout)
    timed_out = reader.is_alive()
    truncated = result.get("truncated", False)
    if timed_out or truncated:
        proc.kill()
        reader.join(2)
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        pass
    if timed_out:
        raise subprocess.TimeoutExpired(cmd, timeout)
    if truncated:
        raise RuntimeError("helper %r output exceeded %d bytes" % (cmd[0], max_bytes))
    return proc.returncode, result.get("data", b"")


def load_password(service: str, account: str) -> str:
    returncode, stdout = run_bounded(
        ["secret-tool", "lookup", "service", service, "account", account],
        MAX_HELPER_TIMEOUT_SECONDS, MAX_SECRET_BYTES,
    )
    if returncode != 0 or not stdout:
        raise RuntimeError(
            "no secret found for service=%r account=%r; store one with: "
            "secret-tool store --label=\"OmaIMAPMail: %s\" service %s account %s"
            % (service, account, account, service, account)
        )
    return stdout.decode("utf-8", errors="replace").rstrip("\n")


def decode_header_value(raw: str) -> str:
    if not raw:
        return ""
    # `raw` is server-supplied and its decoded form is only ever used for a
    # subject line or a sender name/address, so cap it here at the single
    # choke point rather than trusting every caller to do it.
    raw = raw[: MAX_FIELD_CHARS * 4]  # decode_header() can expand encoded-words; cap the input too
    decoded = []
    for text, charset in email.header.decode_header(raw):
        if isinstance(text, bytes):
            decoded.append(text.decode(charset or "utf-8", errors="replace"))
        else:
            decoded.append(text)
    return "".join(decoded).strip()[:MAX_FIELD_CHARS]


def decode_payload(payload: bytes, charset: str) -> str:
    try:
        return payload.decode(charset or "utf-8", errors="replace")
    except (LookupError, UnicodeDecodeError):
        return payload.decode("utf-8", errors="replace")


def extract_part(msg: email.message.Message, content_type: str) -> str | None:
    if msg.is_multipart():
        # A message could pack many trivial parts into the fetch-size budget
        # (MAX_MESSAGE_FETCH_BYTES already bounds total bytes, but not how
        # finely they're subdivided); stop hunting after a bounded number of
        # parts rather than walking however many the message contains.
        for count, part in enumerate(msg.walk()):
            if count >= MAX_MIME_PARTS_SCANNED:
                break
            if part.get_content_type() == content_type and not part.get_filename():
                payload = part.get_payload(decode=True)
                if payload is None:
                    continue
                return decode_payload(payload, part.get_content_charset())
        return None
    if msg.get_content_type() != content_type:
        return None
    payload = msg.get_payload(decode=True)
    if payload is None:
        return None
    return decode_payload(payload, msg.get_content_charset())


def html_to_text(raw_html: str) -> str:
    text = re.sub(r"(?is)<(script|style)[^>]*>.*?</\1>", " ", raw_html)
    text = re.sub(r"(?s)<[^>]+>", " ", text)
    return html.unescape(text)


def plain_text_snippet(msg: email.message.Message) -> str:
    body = extract_part(msg, "text/plain")
    if body is None:
        raw_html = extract_part(msg, "text/html")
        if raw_html is not None:
            body = html_to_text(raw_html)
    body = re.sub(r"\s+", " ", body or "").strip()
    return body[:SNIPPET_CHARS]


def connect(host: str, port: int, account: str, password: str) -> IMAP4Idle:
    imap = IMAP4Idle(host, port, timeout=CONNECT_TIMEOUT_SECONDS)
    imap.login(account, password)
    return imap


def search_unseen_uids(imap: IMAP4Idle) -> list:
    # Observed on iCloud (imap.mail.me.com) against a very large mailbox:
    # a UID SEARCH UNSEEN issued right after SELECT can non-deterministically
    # come back empty — sometimes the very first search on a fresh
    # connection is fine, sometimes it takes several attempts a fraction of
    # a second apart before the server's search index catches up. There is
    # no fixed number of retries or delay that is reliably enough on its
    # own, so retry a bounded number of times with a short sleep and accept
    # whatever the last attempt says rather than trusting an empty first
    # result outright. Cheap and harmless for well-behaved servers, since it
    # only spends extra round trips when the result is already empty.
    uids = []
    for attempt in range(1 + UNSEEN_SEARCH_RETRIES):
        status, data = imap.uid("search", None, "UNSEEN")
        if status != "OK":
            raise RuntimeError("UNSEEN search failed")
        uids = data[0].split()
        if uids:
            break
        if attempt < UNSEEN_SEARCH_RETRIES:
            time.sleep(UNSEEN_SEARCH_RETRY_DELAY)
    return uids


def fetch_unseen(imap: IMAP4Idle, limit: int) -> list:
    uids = search_unseen_uids(imap)

    # Also observed on iCloud alongside the empty-search race: the UNSEEN
    # search response for a very large mailbox is not reliably UID-ordered,
    # and a meaningful fraction of the UIDs it lists can be stale/ghost
    # entries — FETCH returns OK with no data for them, as if they no longer
    # exist in the selected mailbox. Sorting numerically descending and
    # walking until `limit` messages actually fetch (skipping ghosts,
    # bounded by a generous candidate cap) reliably surfaces the real,
    # current unread mail instead of `uids[-limit:]`, which can land
    # entirely on ghosts.
    try:
        uids = sorted(uids, key=int, reverse=True)
    except ValueError:
        uids = list(reversed(uids))
    candidates = uids[: max(limit * 10, 100)] if limit else uids

    messages = []
    for uid in candidates:
        if limit and len(messages) >= limit:
            break
        # `<0.N>` is IMAP's partial-fetch syntax: the server sends at most N
        # octets of the body starting at 0, so a message's own declared size
        # can no longer dictate how much this reads off the wire (headers -
        # which is all a hostile literal-length claim could otherwise inflate
        # - come first, well within the cap). Plain BODY.PEEK[] would trust
        # the server/message to name its own size, which is exactly what
        # let a hostile message or server exhaust memory here.
        status, data = imap.uid("fetch", uid, "(BODY.PEEK[]<0.%d>)" % MAX_MESSAGE_FETCH_BYTES)
        if status != "OK" or not data or not data[0]:
            continue
        raw = data[0][1][:MAX_MESSAGE_FETCH_BYTES]
        msg = email.message_from_bytes(raw)

        name, addr = email.utils.parseaddr(decode_header_value(msg.get("From", "")))
        try:
            received_at = int(email.utils.parsedate_to_datetime(msg.get("Date", "")).timestamp() * 1000)
        except (TypeError, ValueError):
            received_at = 0

        messages.append({
            "id": uid.decode(),
            "fromName": name or addr or "(unknown sender)",
            "fromAddress": addr,
            "subject": decode_header_value(msg.get("Subject", "")) or "(no subject)",
            "receivedAt": received_at,
            "snippet": plain_text_snippet(msg),
        })

    messages.sort(key=lambda m: (m["receivedAt"], int(m["id"])), reverse=True)
    return messages


def state_path_for(account_id: str, state_dir: str) -> str:
    return os.path.join(state_dir, account_id, "state.json")


def read_json_capped(path: str, max_bytes: int):
    # Local files are normally trusted, but this one can be swapped out from
    # under us (a stale/replaced state.json, or an accounts.json edited by
    # something other than the settings UI) - so don't hand json.load()
    # however many bytes it wants to. Reading max_bytes+1 lets us tell
    # "exactly at the cap" apart from "over it" without buffering more than
    # one byte past the limit.
    with open(path, "rb") as handle:
        raw = handle.read(max_bytes + 1)
    if len(raw) > max_bytes:
        raise ValueError("%s exceeds %d bytes" % (path, max_bytes))
    return json.loads(raw.decode("utf-8"))


def load_known_ids(path: str):
    # Returns None (no baseline yet — e.g. first run for this account) so the
    # caller knows not to notify on whatever the very first snapshot finds.
    try:
        data = read_json_capped(path, MAX_STATE_FILE_BYTES)
        ids = data.get("knownIds")
        if not isinstance(ids, dict):
            return {}
        # Cap how many baseline entries we carry forward: this is only ever
        # used for "have we seen this id" membership checks, so an
        # oversized/corrupted state file degrades to a smaller baseline
        # rather than an unbounded in-memory dict.
        if len(ids) > MAX_KNOWN_IDS:
            ids = dict(list(ids.items())[:MAX_KNOWN_IDS])
        return ids
    except FileNotFoundError:
        return None
    except Exception:
        return None


def save_known_ids(path: str, known_ids: dict) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as handle:
        json.dump({"version": 1, "knownIds": known_ids}, handle, indent=2)
        handle.write("\n")
    os.replace(tmp, path)


def send_notification(account_id: str, title: str, body: str, urgency: str = "normal", glyph: str = "\U000f01ee") -> None:
    subprocess.run(
        ["omarchy-notification-send", "--app-name", "omaimapmail-" + account_id,
         "--urgency", urgency, "--glyph", glyph, title, body],
        check=False,
    )


def notify_new(account_id: str, new_messages: list) -> None:
    if len(new_messages) == 1:
        m = new_messages[0]
        body = (m["subject"] + " — " + m["snippet"]) if m.get("snippet") else m["subject"]
        send_notification(account_id, m["fromName"], body)
    else:
        shown = new_messages[:5]
        lines = [m["fromName"] + ": " + m["subject"] for m in shown]
        if len(new_messages) > len(shown):
            lines.append("+%d more" % (len(new_messages) - len(shown)))
        send_notification(account_id, "%d new messages" % len(new_messages), "\n".join(lines))


def watch_account(account: dict, state_dir: str) -> None:
    account_id = str(account["id"])
    host = str(account["host"])
    port = int(account.get("port", 993))
    mailbox = str(account.get("mailbox", "INBOX"))
    acct_email = str(account["account"])
    secret_service = str(account.get("secretService", "omaimapmail-" + account_id))
    fetch_limit = max(1, min(int(account.get("fetchLimit", 20)), MAX_FETCH_LIMIT))
    state_file = state_path_for(account_id, state_dir)

    known_ids = load_known_ids(state_file)
    has_baseline = known_ids is not None
    if known_ids is None:
        known_ids = {}

    consecutive_failures = 0

    while True:
        try:
            password = load_password(secret_service, acct_email)
        except Exception as error:
            fail(account_id, "auth", str(error))
            time.sleep(AUTH_ERROR_RETRY_SECONDS)
            continue

        imap = None
        try:
            try:
                imap = connect(host, port, acct_email, password)
            except imaplib.IMAP4.error as error:
                fail(account_id, "auth", "login failed: %s" % error)
                time.sleep(AUTH_ERROR_RETRY_SECONDS)
                continue
            except (OSError, ssl.SSLError, socket.timeout) as error:
                raise  # handled by the outer except below, with normal backoff

            status, _ = imap.select(mailbox, readonly=True)
            if status != "OK":
                fail(account_id, "config", "cannot select mailbox %r" % mailbox)
                time.sleep(AUTH_ERROR_RETRY_SECONDS)
                continue

            emit({"type": "status", "accountId": account_id, "state": "connected"})
            consecutive_failures = 0

            while True:
                messages = fetch_unseen(imap, fetch_limit)

                id_set = {}
                new_messages = []
                for m in messages:
                    id_set[m["id"]] = True
                    if has_baseline and m["id"] not in known_ids:
                        new_messages.append(m)

                emit({"type": "snapshot", "accountId": account_id, "unreadCount": len(messages), "messages": messages})
                if new_messages:
                    notify_new(account_id, new_messages)
                known_ids = id_set
                has_baseline = True
                save_known_ids(state_file, known_ids)

                tag = imap.idle_start()
                imap.idle_wait(IDLE_TIMEOUT_SECONDS)
                imap.idle_done(tag)
                # Loop regardless of whether IDLE reported a change: a plain
                # keepalive cycle just re-fetches the same (cheap) snapshot,
                # which also self-heals any push notification the server
                # dropped.
        except (OSError, ssl.SSLError, socket.timeout, imaplib.IMAP4.error, RuntimeError) as error:
            # RuntimeError covers IMAP4Idle's own IDLE-protocol failures
            # (rejected IDLE, connection dropped mid-IDLE, a server that never
            # completes DONE within MAX_UNTAGGED_LINES) - without it here, a
            # server that triggers one of those would silently kill this
            # thread instead of backing off and reconnecting like every other
            # network failure does.
            fail(account_id, "network", str(error))
        finally:
            if imap is not None:
                try:
                    imap.logout()
                except Exception:
                    pass

        delay = BACKOFF_TIERS[min(consecutive_failures, len(BACKOFF_TIERS) - 1)]
        consecutive_failures += 1
        time.sleep(delay)


def main() -> int:
    if len(sys.argv) != 2:
        emit({"type": "fatal", "message": "usage: mail_watcher.py <accounts-json-path>"})
        return 2

    try:
        config = read_json_capped(sys.argv[1], MAX_CONFIG_FILE_BYTES)
        accounts = config.get("accounts", [])
        if not isinstance(accounts, list):
            raise ValueError("'accounts' must be a list")
    except Exception as error:
        emit({"type": "fatal", "message": "invalid accounts file: %s" % error})
        return 2

    state_dir = str(config.get("stateDir") or (os.path.expanduser("~") + "/.local/state/omaimapmail"))

    if len(accounts) > MAX_ACCOUNTS:
        emit({"type": "error", "accountId": "*", "kind": "config",
              "message": "accounts file lists %d accounts; only the first %d will be watched"
              % (len(accounts), MAX_ACCOUNTS)})
        accounts = accounts[:MAX_ACCOUNTS]

    threads = []
    for account in accounts:
        if not isinstance(account, dict):
            continue
        if not account.get("id") or not account.get("host") or not account.get("account"):
            continue
        if account.get("enabled") is False:
            continue
        t = threading.Thread(target=watch_account, args=(account, state_dir), daemon=True)
        t.start()
        threads.append(t)

    if not threads:
        emit({"type": "fatal", "message": "no accounts configured"})
        return 0

    for t in threads:
        t.join()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
