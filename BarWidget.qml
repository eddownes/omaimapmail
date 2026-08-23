import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui

BarWidget {
  id: root
  moduleName: "io.github.eddownes.omaimapmail"

  readonly property var mailService: bar && bar.shell
    ? bar.shell.serviceFor(root.moduleName)
    : null
  readonly property var accounts: mailService ? mailService.mergedAccounts : []

  readonly property int unreadCount: root.accounts.reduce(function(sum, a) {
    return sum + (a.unreadCount || 0)
  }, 0)
  readonly property bool hasError: root.accounts.some(function(a) { return a.connectionState === "error" })
  readonly property bool checking: mailService ? mailService.checking === true : false
  readonly property string icon: hasError ? "󰀦" : "󰇮"
  readonly property string labelText: root.unreadCount > 0 ? (root.icon + " " + root.unreadCount) : root.icon

  function forceReconnectAll() {
    if (root.mailService) root.mailService.forceReconnectAll()
  }

  readonly property bool opened: panelLoader.item
    ? panelLoader.item.opened === true
    : false
  readonly property bool popoutSwitchClosing: panelLoader.item
    ? panelLoader.item.popoutSwitchClosing === true
    : false

  function open() {
    if (panelLoader.item) panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item) panelLoader.item.close()
  }

  function toggle() {
    if (panelLoader.item) panelLoader.item.toggle()
  }

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  function injectPanel() {
    if (!panelLoader.item) return
    panelLoader.item.bar = root.bar
    panelLoader.item.anchorItem = button
    panelLoader.item.hostWidget = root
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  IpcHandler {
    target: root.moduleName

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function reconnect(): void { root.forceReconnectAll() }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.labelText
    active: root.unreadCount > 0 || root.hasError
    tooltipText: root.hasError
      ? "OmaIMAPMail: connection error"
      : (root.unreadCount > 0
        ? root.unreadCount + " unread message" + (root.unreadCount === 1 ? "" : "s") + " across " + root.accounts.length + " account" + (root.accounts.length === 1 ? "" : "s")
        : "OmaIMAPMail: inbox zero")
    onPressed: function(b) {
      if (b === Qt.RightButton) root.forceReconnectAll()
      else root.toggle()
    }
  }
}
