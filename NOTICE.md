# Third-party notices

OmaIMAPMail bundles no third-party code or libraries. At runtime it shells
out to the following external tools, which are **not** distributed with
this plugin and are covered by their own respective licenses:

| Tool | Used for | License |
|---|---|---|
| [Python 3](https://www.python.org/) standard library (`imaplib`, `email`, `ssl`, `json`, `threading`, etc.) | IMAP IDLE watching — no `pip` packages required | PSF License |
| [`secret-tool`](https://gitlab.gnome.org/GNOME/libsecret) (part of `libsecret`) | Stores/retrieves IMAP app passwords via the system Secret Service | LGPL-2.1-or-later |
| `omarchy-notification-send` (ships with [Omarchy](https://omarchy.org/)) | Desktop notifications | MIT (Omarchy) |
| `xdg-open` (part of `xdg-utils`) | Opens an account's webmail URL on click | MIT |

No third-party Python packages are required or installed — all IMAP
communication uses only Python's standard library.

## Upstream attribution

OmaIMAPMail is a fork of [keithnyc/omafmail](https://github.com/keithnyc/omafmail)
(MIT licensed). The read-only IMAP session handling, IDLE loop, and MIME
parsing in `scripts/mail_watcher.py` trace directly back to that project.
See [`LICENSE`](LICENSE) for the full dual copyright notice and
[`CHANGELOG.md`](CHANGELOG.md) for what has changed since the fork.
