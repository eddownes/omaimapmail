import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "io.github.eddownes.omaimapmail"
  ipcTarget: "io.github.eddownes.omaimapmail"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null

  readonly property var mailService: bar && bar.shell
    ? bar.shell.serviceFor("io.github.eddownes.omaimapmail")
    : null
  readonly property var accounts: mailService ? mailService.mergedAccounts : []
  readonly property string fatalError: mailService ? mailService.fatalError : ""

  // "all" or one of accounts[].id — which account's messages the popup shows.
  property string filterAccountId: "all"

  readonly property var rows: {
    var merged = []
    for (var i = 0; i < root.accounts.length; i++) {
      var a = root.accounts[i]
      var msgs = a.messages || []
      for (var j = 0; j < msgs.length; j++) {
        var tagged = {}
        for (var k in msgs[j]) tagged[k] = msgs[j][k]
        tagged.account = a.label
        tagged.accountId = a.id
        tagged.accountColor = a.color
        merged.push(tagged)
      }
    }
    merged.sort(function(x, y) { return (y.receivedAt || 0) - (x.receivedAt || 0) })
    return merged
  }

  readonly property var filteredRows: root.filterAccountId === "all"
    ? root.rows
    : root.rows.filter(function(m) { return m.accountId === root.filterAccountId })

  readonly property int unreadCount: root.accounts.reduce(function(sum, a) { return sum + (a.unreadCount || 0) }, 0)

  readonly property string connectionState: root.accounts.some(function(a) { return a.connectionState === "error" })
    ? "error"
    : (root.accounts.some(function(a) { return a.connectionState === "connecting" }) ? "connecting" : "idle")

  // One line per account currently in a config or connection error state, e.g. "iCloud: Sign-in failed — check the stored app password".
  readonly property var errorLines: {
    var lines = []
    if (root.fatalError) lines.push(root.fatalError)
    for (var i = 0; i < root.accounts.length; i++) {
      var a = root.accounts[i]
      if (a.configError) lines.push(a.label + ": " + a.configError)
      else if (a.connectionState === "error" && a.lastError) lines.push(a.label + ": " + Model.errorSummary(a.lastError))
    }
    return lines
  }

  property double now: Date.now()

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.hostWidget || root, direction)
    return false
  }

  function accountById(id) {
    for (var i = 0; i < root.accounts.length; i++) if (root.accounts[i].id === id) return root.accounts[i]
    return null
  }

  function openInboxFor(accountId) {
    var a = root.accountById(accountId)
    if (a && a.inboxUrl) Quickshell.execDetached(["xdg-open", a.inboxUrl])
  }

  function forceReconnectAll() {
    if (root.mailService) root.mailService.forceReconnectAll()
  }

  // ---------------------------------------------------------------- settings

  property bool settingsOpen: false
  property string editingAccountId: "" // "" = add-new form is closed; "new" = adding; else editing that id
  readonly property var colorPalette: ["#3f7fd1", "#d64545", "#4caf7d", "#c9963c", "#8e6bb0", "#4f9da6", "#c1547a", "#6b9e3f"]

  function nextDefaultColor() {
    return root.colorPalette[root.accounts.length % root.colorPalette.length]
  }

  function slugify(label, keepId) {
    var base = String(label || "").toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "")
    if (!base) base = "account"
    var existing = {}
    for (var i = 0; i < root.accounts.length; i++) existing[root.accounts[i].id] = true
    if (keepId) delete existing[keepId]
    var candidate = base
    var n = 2
    while (existing[candidate]) {
      candidate = base + "-" + n
      n++
    }
    return candidate
  }

  function openAddForm() {
    root.editingAccountId = "new"
    formLabel.text = ""
    formAccount.text = ""
    formHost.text = ""
    formPort.field.value = 993
    formMailbox.text = "INBOX"
    formFetchLimit.field.value = 20
    formInboxUrl.text = ""
    formPassword.text = ""
    formColor = root.nextDefaultColor()
    formError = ""
  }

  function openEditForm(id) {
    var a = root.accountById(id)
    if (!a) return
    root.editingAccountId = id
    formLabel.text = a.label
    formAccount.text = a.account
    formHost.text = a.host
    formPort.field.value = a.port
    formMailbox.text = a.mailbox
    formFetchLimit.field.value = a.fetchLimit
    formInboxUrl.text = a.inboxUrl
    formPassword.text = ""
    formColor = a.color
    formError = ""
  }

  function closeForm() {
    root.editingAccountId = ""
  }

  property string formColor: root.colorPalette[0]
  property string formError: ""

  function rawAccountDefsList() {
    // accounts[] already carries every field the form needs; strip the
    // live-state fields back off so this can round-trip into accounts.json.
    return root.accounts.map(function(a) {
      return {
        id: a.id, label: a.label, color: a.color, host: a.host, port: a.port,
        account: a.account, mailbox: a.mailbox, secretService: a.secretService,
        fetchLimit: a.fetchLimit, inboxUrl: a.inboxUrl, enabled: true
      }
    })
  }

  function saveForm() {
    console.warn("omaimapmail: saveForm() called, editingAccountId=" + root.editingAccountId)
    var label = formLabel.text.trim()
    var account = formAccount.text.trim()
    var host = formHost.text.trim()
    if (!label || !account || !host) {
      root.formError = "Label, account email, and host are required."
      console.warn("omaimapmail: saveForm() validation failed:", root.formError)
      return
    }
    var isNew = root.editingAccountId === "new"
    var id = isNew ? root.slugify(label, "") : root.editingAccountId
    var existing = isNew ? null : root.accountById(id)
    var secretService = existing ? existing.secretService : ("omaimapmail-" + id)
    var mailbox = formMailbox.text.trim() || "INBOX"
    var inboxUrl = formInboxUrl.text.trim()
    var port = formPort.field.value || 993
    var fetchLimit = formFetchLimit.field.value || 20
    var color = root.formColor

    var list = root.rawAccountDefsList()
    var entry = {
      id: id, label: label, color: color, host: host, port: port,
      account: account, mailbox: mailbox, secretService: secretService,
      fetchLimit: fetchLimit, inboxUrl: inboxUrl, enabled: true
    }

    function applyAndSave() {
      var next = []
      var replaced = false
      for (var i = 0; i < list.length; i++) {
        if (list[i].id === id) { next.push(entry); replaced = true }
        else next.push(list[i])
      }
      if (!replaced) next.push(entry)
      console.warn("omaimapmail: saveForm() writing accounts.json, id=" + id + " replaced=" + replaced + " total=" + next.length)
      if (root.mailService) root.mailService.saveAccounts(next)
      else console.warn("omaimapmail: saveForm() has no mailService — cannot save")
      root.closeForm()
    }

    var password = formPassword.text
    if (password.length > 0 && root.mailService) {
      console.warn("omaimapmail: saveForm() storing password for secretService=" + secretService)
      root.formSaving = true
      passwordStoreTimeout.restart()
      root.mailService.storePassword(secretService, account, password, function(ok) {
        passwordStoreTimeout.stop()
        root.formSaving = false
        console.warn("omaimapmail: storePassword callback ok=" + ok)
        if (ok) applyAndSave()
        else root.formError = "Could not store the password in the system keyring — check that a Secret Service provider (e.g. gnome-keyring-daemon) is running."
      })
    } else {
      if (!root.mailService) console.warn("omaimapmail: saveForm() has no mailService")
      applyAndSave()
    }
  }

  property bool formSaving: false

  property string pendingRemoveId: ""

  function requestRemove(id) {
    root.pendingRemoveId = id
    removeConfirm.opened = true
  }

  function confirmRemove() {
    var list = root.rawAccountDefsList().filter(function(a) { return a.id !== root.pendingRemoveId })
    if (root.mailService) root.mailService.saveAccounts(list)
    if (root.filterAccountId === root.pendingRemoveId) root.filterAccountId = "all"
    root.pendingRemoveId = ""
    removeConfirm.opened = false
  }

  // ---------------------------------------------------------------- components

  component AccountBadge: BorderSurface {
    id: badge
    required property string label
    required property color badgeColor
    implicitWidth: badgeText.implicitWidth + Style.space(12)
    implicitHeight: badgeText.implicitHeight + Style.space(4)
    radius: implicitHeight / 2
    color: badge.badgeColor

    Text {
      id: badgeText
      anchors.centerIn: parent
      text: badge.label
      color: "#ffffff"
      font.pixelSize: Style.font.caption
      font.bold: true
    }
  }

  component ColorSwatch: BorderSurface {
    id: swatch
    required property string modelData // the color hex string, from the palette Repeater's model
    property bool swatchSelected: false
    signal picked()
    implicitWidth: Style.space(22)
    implicitHeight: Style.space(22)
    radius: implicitHeight / 2
    color: swatch.modelData
    borderSpec: swatch.swatchSelected ? Border.flat("#ffffff", 2) : Border.none()

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: swatch.picked()
    }
  }

  component MessageRow: CursorSurface {
    id: card
    required property var modelData // auto-populated per item by Repeater on an array model
    required property var bar
    required property double now

    readonly property color rowForeground: bar ? bar.foreground : Color.foreground
    readonly property string rowFontFamily: bar ? bar.fontFamily : Style.font.family

    // modelData can be evaluated once before the Repeater assigns it; every
    // binding below reads through this fallback so it stays reactive instead
    // of freezing on the first (undefined) evaluation.
    readonly property var msg: card.modelData || {}
    readonly property string fromName: card.msg.fromName || "(unknown sender)"
    readonly property string avatarKey: card.msg.fromAddress || card.msg.fromName || ""
    readonly property string subjectText: card.msg.subject || ""
    readonly property string snippetText: card.msg.snippet || ""
    readonly property double receivedAt: card.msg.receivedAt || 0
    readonly property string accountLabel: card.msg.account || ""
    readonly property string accountId: card.msg.accountId || ""
    readonly property color accountBadgeColor: card.msg.accountColor || Model.avatarColor(card.accountLabel)

    signal activated()

    hasCursor: rowMouse.containsMouse
    foreground: card.rowForeground
    implicitHeight: rowLayout.implicitHeight + Style.space(20)

    MouseArea {
      id: rowMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: card.activated()
    }

    RowLayout {
      id: rowLayout
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(12)

      BorderSurface {
        Layout.preferredWidth: Style.space(34)
        Layout.preferredHeight: Style.space(34)
        Layout.alignment: Qt.AlignTop
        radius: width / 2
        color: Model.avatarColor(card.avatarKey)

        Text {
          anchors.centerIn: parent
          text: Model.initials(card.fromName)
          color: "#ffffff"
          font.family: card.rowFontFamily
          font.pixelSize: Style.font.bodySmall
          font.bold: true
        }
      }

      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(3)

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(8)

          Text {
            Layout.fillWidth: true
            text: card.fromName
            elide: Text.ElideRight
            color: card.rowForeground
            font.family: card.rowFontFamily
            font.pixelSize: Style.font.body
            font.bold: true
          }

          Text {
            text: Model.relativeTime(card.receivedAt, card.now)
            color: Qt.darker(card.rowForeground, 1.35)
            font.family: card.rowFontFamily
            font.pixelSize: Style.font.caption
          }
        }

        Text {
          Layout.fillWidth: true
          text: card.subjectText
          elide: Text.ElideRight
          color: card.rowForeground
          font.family: card.rowFontFamily
          font.pixelSize: Style.font.bodySmall
        }

        Text {
          Layout.fillWidth: true
          text: card.snippetText
          wrapMode: Text.Wrap
          maximumLineCount: 2
          elide: Text.ElideRight
          color: Qt.darker(card.rowForeground, 1.35)
          font.family: card.rowFontFamily
          font.pixelSize: Style.font.caption
        }

        AccountBadge {
          Layout.alignment: Qt.AlignLeft
          Layout.topMargin: Style.space(2)
          label: card.accountLabel
          badgeColor: card.accountBadgeColor
        }
      }
    }
  }

  component AccountListRow: RowLayout {
    id: arow
    required property var modelData
    // modelData can be evaluated once before the Repeater assigns it (see
    // MessageRow above); read through this fallback so bindings stay
    // reactive instead of freezing on the first (undefined) evaluation.
    readonly property var entry: arow.modelData || { id: "", label: "", account: "", host: "", color: "#808080" }
    property color rowForeground: root.bar ? root.bar.foreground : Color.foreground
    spacing: Style.space(8)

    BorderSurface {
      Layout.preferredWidth: Style.space(14)
      Layout.preferredHeight: Style.space(14)
      Layout.alignment: Qt.AlignVCenter
      radius: width / 2
      color: arow.entry.color
    }

    ColumnLayout {
      Layout.fillWidth: true
      spacing: 0

      Text {
        text: arow.entry.label
        color: arow.rowForeground
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.bodySmall
        font.bold: true
      }
      Text {
        text: arow.entry.account + " · " + arow.entry.host
        color: Qt.darker(arow.rowForeground, 1.35)
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
        Layout.fillWidth: true
      }
    }

    Button {
      iconText: "󰏫"
      tooltipText: "Edit " + arow.entry.label
      foreground: arow.rowForeground
      onClicked: root.openEditForm(arow.entry.id)
    }

    Button {
      iconText: "󰆴"
      tooltipText: "Remove " + arow.entry.label
      foreground: Color.urgent
      onClicked: root.requestRemove(arow.entry.id)
    }
  }

  Timer {
    interval: 1000
    running: root.opened
    repeat: true
    onTriggered: root.now = Date.now()
  }

  // Guards against a hung secret-tool/keyring call leaving Save looking
  // like it silently did nothing.
  Timer {
    id: passwordStoreTimeout
    interval: 8000
    repeat: false
    onTriggered: {
      console.warn("omaimapmail: storePassword timed out")
      root.formSaving = false
      root.formError = "Timed out storing the password — check that a Secret Service provider (e.g. gnome-keyring-daemon) is running."
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.hostWidget || root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(440))
    contentHeight: panel.fittedContentHeight(content.implicitHeight, Style.space(560))

    ConfirmDialog {
      id: removeConfirm
      anchors.fill: parent
      z: 10
      message: "Remove " + (root.accountById(root.pendingRemoveId) ? root.accountById(root.pendingRemoveId).label : "this account")
        + "? This stops watching it and deletes it from accounts.json. Its stored password and local state are left in place."
      confirmText: "Remove"
      cancelText: "Cancel"
      background: root.bar ? root.bar.background : Color.background
      foreground: root.bar ? root.bar.foreground : Color.foreground

      onOpenedChanged: {
        if (opened) forceActiveFocus()
        else Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
      }

      Keys.onPressed: function(event) {
        if (removeConfirm.handleKey(event)) event.accepted = true
      }

      onCanceled: { removeConfirm.opened = false; root.pendingRemoveId = "" }
      onConfirmed: root.confirmRemove()
    }

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Flickable {
        anchors.fill: parent
        contentWidth: width
        contentHeight: content.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Column {
          id: content
          width: parent.width
          spacing: Style.space(12)

          Row {
            width: parent.width
            spacing: Style.space(8)

            Text {
              width: parent.width - refreshButton.width - settingsButton.width - parent.spacing * 2
              text: root.settingsOpen
                ? "Accounts"
                : (root.filteredRows.length > 0
                  ? root.filteredRows.length + " unread message" + (root.filteredRows.length === 1 ? "" : "s")
                  : "Inbox zero")
              color: root.bar ? root.bar.foreground : Color.foreground
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.subtitle
              font.bold: true
              anchors.verticalCenter: parent.verticalCenter
            }

            Button {
              id: refreshButton
              iconText: "󰑐"
              tooltipText: "Reconnect all accounts now"
              foreground: root.bar ? root.bar.foreground : Color.foreground
              iconSpinning: root.connectionState === "connecting"
              onClicked: root.forceReconnectAll()
            }

            Button {
              id: settingsButton
              iconText: "󰒓"
              tooltipText: root.settingsOpen ? "Back to inbox" : "Manage accounts"
              foreground: root.bar ? root.bar.foreground : Color.foreground
              selected: root.settingsOpen
              onClicked: {
                root.settingsOpen = !root.settingsOpen
                root.closeForm()
              }
            }
          }

          // ---------------------------------------------------- inbox view

          Row {
            width: parent.width
            spacing: Style.space(6)
            visible: !root.settingsOpen

            Button {
              text: "All"
              bordered: true
              selected: root.filterAccountId === "all"
              foreground: root.bar ? root.bar.foreground : Color.foreground
              accent: Color.accent
              onClicked: root.filterAccountId = "all"
            }

            Repeater {
              model: root.accounts

              Button {
                required property var modelData
                text: modelData.label
                bordered: true
                selected: root.filterAccountId === modelData.id
                foreground: root.bar ? root.bar.foreground : Color.foreground
                accent: modelData.color
                onClicked: root.filterAccountId = modelData.id
              }
            }
          }

          Column {
            width: parent.width
            spacing: Style.space(2)
            visible: !root.settingsOpen && root.errorLines.length > 0

            Repeater {
              model: root.errorLines
              Text {
                width: content.width
                wrapMode: Text.Wrap
                text: modelData
                color: Color.urgent
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.bodySmall
              }
            }
          }

          PanelSeparator {
            visible: !root.settingsOpen && root.filteredRows.length > 0
            foreground: root.bar ? root.bar.foreground : Color.foreground
          }

          Column {
            width: parent.width
            spacing: Style.space(4)
            visible: !root.settingsOpen

            Repeater {
              model: root.filteredRows

              MessageRow {
                width: content.width
                bar: root.bar
                now: root.now
                onActivated: root.openInboxFor(accountId)
              }
            }
          }

          Text {
            visible: !root.settingsOpen && root.filteredRows.length === 0 && root.errorLines.length === 0
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: root.connectionState === "connecting" ? "Connecting…" : "No unread messages"
            color: root.bar ? root.bar.foreground : Color.foreground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.body
          }

          Text {
            visible: !root.settingsOpen
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            text: "Click a message to open its inbox · right-click the bar icon to reconnect all"
            color: Qt.darker(root.bar ? root.bar.foreground : Color.foreground, 1.45)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
          }

          // -------------------------------------------------- settings view

          Column {
            width: parent.width
            spacing: Style.space(10)
            visible: root.settingsOpen

            Column {
              width: parent.width
              spacing: Style.space(8)
              visible: root.editingAccountId === ""

              Repeater {
                model: root.accounts
                AccountListRow {
                  width: content.width
                }
              }

              Text {
                visible: root.accounts.length === 0
                width: parent.width
                text: "No accounts configured yet."
                color: Qt.darker(root.bar ? root.bar.foreground : Color.foreground, 1.35)
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.bodySmall
              }

              Button {
                text: "+ Add account"
                bordered: true
                foreground: root.bar ? root.bar.foreground : Color.foreground
                onClicked: root.openAddForm()
              }
            }

            PanelSeparator {
              visible: root.editingAccountId !== ""
              foreground: root.bar ? root.bar.foreground : Color.foreground
            }

            Column {
              width: parent.width
              spacing: Style.space(8)
              visible: root.editingAccountId !== ""

              Text {
                text: root.editingAccountId === "new" ? "Add IMAP account" : "Edit " + root.editingAccountId
                color: root.bar ? root.bar.foreground : Color.foreground
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.body
                font.bold: true
              }

              TextField { id: formLabel; width: parent.width; placeholderText: "Label (e.g. Work Gmail)" }
              TextField { id: formAccount; width: parent.width; placeholderText: "Account email (also the IMAP username)" }
              TextField { id: formHost; width: parent.width; placeholderText: "IMAP host (e.g. imap.gmail.com)" }

              Row {
                width: parent.width
                spacing: Style.space(12)
                NumberField { id: formPort; label: "Port"; from: 1; to: 65535; value: 993 }
                NumberField { id: formFetchLimit; label: "Fetch limit"; from: 1; to: 200; value: 20 }
              }

              TextField { id: formMailbox; width: parent.width; placeholderText: "Mailbox (default INBOX)" }
              TextField { id: formInboxUrl; width: parent.width; placeholderText: "Webmail URL to open on click (optional)" }
              TextField {
                id: formPassword
                width: parent.width
                password: true
                placeholderText: root.editingAccountId === "new"
                  ? "App password (stored in system keyring)"
                  : "Leave blank to keep current password"
              }

              Row {
                spacing: Style.space(8)
                Text {
                  text: "Color"
                  anchors.verticalCenter: parent.verticalCenter
                  color: root.bar ? root.bar.foreground : Color.foreground
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.bodySmall
                }
                Repeater {
                  model: root.colorPalette
                  ColorSwatch {
                    swatchSelected: root.formColor === modelData
                    onPicked: root.formColor = modelData
                  }
                }
              }

              Text {
                visible: root.formError !== ""
                width: parent.width
                wrapMode: Text.Wrap
                text: root.formError
                color: Color.urgent
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.bodySmall
              }

              Row {
                spacing: Style.space(8)
                Button {
                  text: root.formSaving ? "Saving…" : "Save"
                  bordered: true
                  foreground: root.bar ? root.bar.foreground : Color.foreground
                  accent: root.formColor
                  onClicked: if (!root.formSaving) root.saveForm()
                }
                Button {
                  text: "Cancel"
                  bordered: true
                  foreground: root.bar ? root.bar.foreground : Color.foreground
                  onClicked: root.closeForm()
                }
              }
            }
          }
        }
      }
    }
  }
}
