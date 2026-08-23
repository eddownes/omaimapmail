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

_emit_lock = threading.Lock()


def emit(event: dict) -> None:
    with _emit_lock:
        print(json.dumps(event, separators=(",", ":")), flush=True)


def fail(account_id: str, kind: str, message: str) -> None:
    emit({"type": "error", "accountId": account_id, "kind": kind, "message": message})


class IMAP4Idle(imaplib.IMAP4_SSL):
    def idle_start(self) -> bytes:
        tag = self._new_tag()
        self.send(b"%s IDLE\r\n" % tag)
        resp = self.readline()
        if not resp.startswith(b"+"):
            raise RuntimeError("server rejected IDLE: " + resp.decode(errors="replace"))
        return tag

    def idle_wait(self, timeout: float) -> list:
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
            while True:
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
        while True:
            line = self.readline()
            if not line or line.startswith(tag):
                break


def load_password(service: str, account: str) -> str:
    result = subprocess.run(
        ["secret-tool", "lookup", "service", service, "account", account],
        capture_output=True, text=True, timeout=10,
    )
    if result.returncode != 0 or not result.stdout:
        raise RuntimeError(
            "no secret found for service=%r account=%r; store one with: "
            "secret-tool store --label=\"OmaIMAPMail: %s\" service %s account %s"
            % (service, account, account, service, account)
        )
    return result.stdout.rstrip("\n")


def decode_header_value(raw: str) -> str:
    if not raw:
        return ""
    decoded = []
    for text, charset in email.header.decode_header(raw):
        if isinstance(text, bytes):
            decoded.append(text.decode(charset or "utf-8", errors="replace"))
        else:
            decoded.append(text)
    return "".join(decoded).strip()


def decode_payload(payload: bytes, charset: str) -> str:
    try:
        return payload.decode(charset or "utf-8", errors="replace")
    except (LookupError, UnicodeDecodeError):
        return payload.decode("utf-8", errors="replace")


def extract_part(msg: email.message.Message, content_type: str) -> str | None:
    if msg.is_multipart():
        for part in msg.walk():
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
        status, data = imap.uid("fetch", uid, "(BODY.PEEK[])")
        if status != "OK" or not data or not data[0]:
            continue
        raw = data[0][1]
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


def load_known_ids(path: str):
    # Returns None (no baseline yet — e.g. first run for this account) so the
    # caller knows not to notify on whatever the very first snapshot finds.
    try:
        with open(path, "r", encoding="utf-8") as handle:
            data = json.load(handle)
        ids = data.get("knownIds")
        return ids if isinstance(ids, dict) else {}
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
    fetch_limit = int(account.get("fetchLimit", 20))
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
        except (OSError, ssl.SSLError, socket.timeout, imaplib.IMAP4.error) as error:
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
        with open(sys.argv[1], "r", encoding="utf-8") as handle:
            config = json.load(handle)
        accounts = config.get("accounts", [])
        if not isinstance(accounts, list):
            raise ValueError("'accounts' must be a list")
    except Exception as error:
        emit({"type": "fatal", "message": "invalid accounts file: %s" % error})
        return 2

    state_dir = str(config.get("stateDir") or (os.path.expanduser("~") + "/.local/state/omaimapmail"))

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
