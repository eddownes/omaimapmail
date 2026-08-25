import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Owns the one long-lived multi-account IMAP watcher process (scripts/
// mail_watcher.py) and the accounts.json config it reads. BarWidget.qml and
// Panel.qml read everything through `mergedAccounts` — they never talk to
// IMAP or the filesystem directly.
Item {
  id: root

  property var shell: null
  property var manifest: null
  readonly property string home: Quickshell.env("HOME")
  readonly property string accountsDir: home + "/.config/omaimapmail"
  readonly property string accountsPath: root.accountsDir + "/accounts.json"
  readonly property string stateDir: home + "/.local/state/omaimapmail"
  readonly property string watcherScriptPath: manifest && manifest.__sourceDir
    ? manifest.__sourceDir + "/scripts/mail_watcher.py"
    : ""

  // Parsed accounts.json — array of {id, label, color, host, port, account,
  // mailbox, secretService, fetchLimit, inboxUrl, enabled}. Metadata only;
  // live IMAP state lives in accountStates, keyed the same way by id.
  property var accountDefs: []
  property string accountsError: ""
  property bool accountsReady: false
  property bool dirReady: false

  // accountId -> {unreadCount, messages, connectionState, lastError, configError, checking}
  property var accountStates: ({})
  property string fatalError: ""
  property bool manualReconnectRequested: false
  property int consecutiveFailures: 0

  // Ceilings enforced on accounts.json before it's parsed/retained. This file
  // is user-editable config, not remote-attacker input, but nothing stops it
  // from being huge or malformed (a bad hand-edit, a botched sync/restore,
  // disk corruption) — without a cap, loadAccounts() would happily JSON.parse
  // and hold onto however much text is there, and mergedAccounts would fan
  // that out across every widget with no limit on how many accounts or how
  // large any single field is. These bound the blast radius shell-side
  // rather than trusting the file to be well-formed.
  readonly property int maxAccountsFileBytes: 262144 // 256 KiB
  readonly property int maxAccountCount: 50
  readonly property int maxFieldChars: 500

  readonly property bool checking: root.consecutiveFailures === 0 && watcherProcess.running
    && Object.keys(root.accountStates).length < root.accountDefs.length

  // What BarWidget/Panel actually consume: account metadata joined with its
  // live state, in accounts.json order. An account with no state yet reads
  // as "connecting" so a brand new account shows up immediately instead of
  // being invisible until its first snapshot arrives.
  readonly property var mergedAccounts: root.accountDefs
    .filter(function(a) { return a.enabled !== false })
    .map(function(a) {
      var s = root.accountStates[a.id] || {
        unreadCount: 0, messages: [], connectionState: "connecting",
        lastError: null, configError: ""
      }
      return {
        id: a.id, label: a.label, color: a.color || "#8e6bb0",
        inboxUrl: a.inboxUrl || "", account: a.account,
        host: a.host || "", port: a.port || 993, mailbox: a.mailbox || "INBOX",
        secretService: a.secretService || ("omaimapmail-" + a.id), fetchLimit: a.fetchLimit || 20,
        unreadCount: s.unreadCount, messages: s.messages,
        connectionState: s.connectionState, lastError: s.lastError,
        configError: s.configError
      }
    })

  function defaultAccountsDoc() {
    return { version: 1, accounts: [] }
  }

  // Clamps every string field on an account entry to maxFieldChars so one
  // oversized value (a pasted URL gone wrong, a corrupted field) can't blow
  // up memory/layout for the whole panel. Applied after JSON.parse, before
  // the entry is retained in accountDefs.
  function clampAccountFields(account) {
    var clamped = {}
    for (var key in account) {
      var value = account[key]
      clamped[key] = (typeof value === "string" && value.length > root.maxFieldChars)
        ? value.slice(0, root.maxFieldChars)
        : value
    }
    return clamped
  }

  function loadAccounts(raw) {
    var text = String(raw || "")
    if (text.length > root.maxAccountsFileBytes) {
      // Bail out before JSON.parse ever sees it — an oversized file is
      // rejected wholesale rather than parsed and then truncated, since
      // parsing itself is the thing we don't want to do on unbounded input.
      root.accountDefs = []
      root.accountsError = "accounts.json is " + text.length + " bytes, over the "
        + root.maxAccountsFileBytes + " byte limit — refusing to load"
      console.warn("omaimapmail:", root.accountsError)
    } else {
      try {
        var parsed = JSON.parse(text)
        var list = Array.isArray(parsed.accounts) ? parsed.accounts : []
        if (list.length > root.maxAccountCount) {
          console.warn("omaimapmail: accounts.json has " + list.length + " accounts, keeping only the first "
            + root.maxAccountCount)
          list = list.slice(0, root.maxAccountCount)
        }
        root.accountDefs = list.map(root.clampAccountFields)
        root.accountsError = ""
      } catch (error) {
        root.accountDefs = []
        root.accountsError = String(error)
        console.warn("omaimapmail: accounts.json error:", root.accountsError)
      }
    }
    root.accountsReady = true
    // Prune state for accounts that no longer exist so a removed account's
    // stale unread badge/messages don't linger in mergedAccounts.
    var ids = {}
    for (var i = 0; i < root.accountDefs.length; i++) ids[root.accountDefs[i].id] = true
    var nextStates = ({})
    for (var key in root.accountStates) if (ids[key]) nextStates[key] = root.accountStates[key]
    root.accountStates = nextStates

    if (watcherProcess.running) {
      // accounts.json changed while already running (an edit from the
      // Settings view, or an external hand edit) — kill and let onExited's
      // restart pick up the new account list.
      root.manualReconnectRequested = true
      watcherProcess.running = false
    } else {
      root.maybeStart()
    }
  }

  function maybeStart() {
    if (!root.dirReady || !root.accountsReady || root.watcherScriptPath === "") return
    if (root.accountDefs.length === 0) return
    if (watcherProcess.running) return
    root.startWatcher()
  }

  function startWatcher() {
    root.manualReconnectRequested = false
    watcherProcess.command = ["python3", root.watcherScriptPath, root.accountsPath]
    watcherProcess.running = true
  }

  function forceReconnectAll() {
    root.manualReconnectRequested = true
    root.consecutiveFailures = 0
    restartTimer.stop()
    if (watcherProcess.running) watcherProcess.running = false
    else root.startWatcher()
  }

  function scheduleRestart() {
    var delaySeconds
    if (root.manualReconnectRequested) {
      delaySeconds = 0.2
      root.manualReconnectRequested = false
    } else {
      root.consecutiveFailures++
      var tiers = [2, 5, 15, 30, 60]
      delaySeconds = tiers[Math.min(root.consecutiveFailures - 1, tiers.length - 1)]
    }
    restartTimer.interval = Math.round(delaySeconds * 1000)
    restartTimer.restart()
  }

  function handleLine(line) {
    var event
    try {
      event = JSON.parse(line)
    } catch (error) {
      console.warn("omaimapmail: unreadable watcher output:", line)
      return
    }
    var id = event.accountId
    if (event.type === "fatal") {
      root.fatalError = String(event.message || "")
      console.warn("omaimapmail:", root.fatalError)
      return
    }
    if (!id) return
    root.fatalError = ""
    var next = ({})
    for (var k in root.accountStates) next[k] = root.accountStates[k]
    var current = next[id] || { unreadCount: 0, messages: [], connectionState: "connecting", lastError: null, configError: "" }

    if (event.type === "status" && event.state === "connected") {
      next[id] = { unreadCount: current.unreadCount, messages: current.messages, connectionState: "idle", lastError: null, configError: "" }
    } else if (event.type === "snapshot") {
      next[id] = {
        unreadCount: Number(event.unreadCount) || 0,
        messages: Array.isArray(event.messages) ? event.messages : [],
        connectionState: "idle", lastError: null, configError: ""
      }
    } else if (event.type === "error") {
      var kind = String(event.kind || "network")
      var message = String(event.message || "")
      if (kind === "config") {
        next[id] = { unreadCount: current.unreadCount, messages: current.messages, connectionState: "error", lastError: null, configError: message }
      } else {
        next[id] = { unreadCount: current.unreadCount, messages: current.messages, connectionState: "error", lastError: { kind: kind, message: message }, configError: "" }
      }
      console.warn("omaimapmail:", id, kind, message)
    } else {
      return
    }
    root.accountStates = next
  }

  // ---- accounts.json editing, used by the Settings view ----

  function saveAccounts(newAccountDefs) {
    var doc = { version: 1, accounts: newAccountDefs }
    var text = JSON.stringify(doc, null, 2) + "\n"
    accountsFile.setText(text)
    // Apply immediately rather than waiting for the watch-triggered reload
    // (FileView.onFileChanged) to come back around — writing and watching
    // the same file can race, and when it does, the UI is left showing
    // whatever was loaded before this save until something else forces a
    // reload (e.g. a shell restart). Parsing our own just-written text
    // here makes the update land synchronously and removes that race for
    // every write this plugin makes itself; external hand-edits still get
    // picked up reactively via the watcher as before.
    root.loadAccounts(text)
  }

  // Stores an account's app password in the system keyring. Never touches
  // argv or any file — the secret goes over the child process's stdin only,
  // exactly like OmaFMail's original single-account setup instructions.
  function storePassword(secretService, account, password, onDone) {
    console.warn("omaimapmail: storePassword() secretService=" + secretService + " account=" + account
      + " passwordStore.running(before)=" + passwordStore.running)
    passwordStore.secretService = secretService
    passwordStore.account = account
    passwordStore.secret = password
    passwordStore.onDoneCallback = onDone || null
    passwordStore.command = [
      "secret-tool", "store",
      "--label", "OmaIMAPMail: " + account,
      "service", secretService,
      "account", account
    ]
    if (passwordStore.running) {
      // A previous call never exited (stuck/hung) — force a fresh run
      // instead of silently no-op'ing on an unchanged `running: true`.
      console.warn("omaimapmail: storePassword() previous run still marked running — forcing restart")
      passwordStore.running = false
    }
    // Quickshell closes a Process's stdin channel by setting stdinEnabled
    // to false, and per its own docs that channel stays closed — even if
    // set back to true — for as long as this Process object lives. Since
    // passwordStore is reused across every Save click, each run has to
    // explicitly re-open it before starting, not just once at declaration.
    passwordStore.stdinEnabled = true
    passwordStore.running = true
  }

  Process {
    id: passwordStore
    property string secretService: ""
    property string account: ""
    property string secret: ""
    property var onDoneCallback: null
    stdinEnabled: true
    onStarted: {
      console.warn("omaimapmail: passwordStore process started")
      write(passwordStore.secret + "\n")
      passwordStore.secret = ""
      // secret-tool store reads stdin to EOF, not just to a newline —
      // without explicitly closing it here, it blocks forever waiting for
      // more input that never comes.
      passwordStore.stdinEnabled = false
    }
    stderr: SplitParser {
      onRead: function(line) { console.warn("omaimapmail: passwordStore(stderr):", line) }
    }
    onExited: function(exitCode) {
      console.warn("omaimapmail: passwordStore exited code=" + exitCode)
      if (passwordStore.onDoneCallback) passwordStore.onDoneCallback(exitCode === 0)
      passwordStore.onDoneCallback = null
    }
  }

  FileView {
    id: accountsFile
    path: root.accountsPath
    watchChanges: true
    printErrors: false
    onLoaded: root.loadAccounts(text())
    onLoadFailed: function(error) {
      // No accounts.json yet (fresh install) — seed an empty one so the
      // Settings view has something to write into.
      root.accountDefs = []
      root.accountsReady = true
      accountsFile.setText(JSON.stringify(root.defaultAccountsDoc(), null, 2) + "\n")
    }
    onFileChanged: reload()
  }

  Process {
    command: ["mkdir", "-p", root.accountsDir]
    running: true
    onExited: {
      root.dirReady = true
      accountsFile.reload()
    }
  }

  Timer {
    id: restartTimer
    repeat: false
    onTriggered: {
      if (!watcherProcess.running) root.startWatcher()
    }
  }

  Process {
    id: watcherProcess
    running: false
    command: []
    stdout: SplitParser {
      onRead: function(line) { root.handleLine(line) }
    }
    stderr: SplitParser {
      onRead: function(line) { console.warn("omaimapmail(stderr):", line) }
    }
    onExited: function(exitCode) {
      if (root.manualReconnectRequested) {
        // Deliberate kill-to-restart (accounts.json edit or a user-triggered
        // reconnect) — not a real error, so don't flash "connection lost".
        root.manualReconnectRequested = false
      } else if (exitCode !== 0) {
        root.fatalError = "watcher exited unexpectedly (code " + exitCode + ")"
      }
      root.scheduleRestart()
    }
  }
}
