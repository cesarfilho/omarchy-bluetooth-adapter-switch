import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui

// Bar widget for machines with more than one Bluetooth adapter.
//
// Left click opens a panel that lists every adapter with what it is (onboard
// chip or USB dongle), which one is active and what is paired to it, and lets
// you pick one. Scroll or middle click jumps straight to the next adapter and
// right click turns every adapter back on. All the real work happens in
// bt-adapter.sh (rfkill + BlueZ over D-Bus, no privileges needed).
BarWidget {
  id: root
  moduleName: "io.github.cesarfilho.bluetooth-adapter-switch"

  // [{ hci, kind, model, address, alias, powered, blocked, devices: [{ name, connected }] }]
  property var adapters: []
  property bool loaded: false
  property bool busy: false
  // What the running action is switching to: an hciN, "next" or "all".
  property string pending: ""
  property string lastError: ""
  property bool refreshQueued: false
  property bool announceNext: false

  readonly property string helper: decodeURIComponent(String(Qt.resolvedUrl("bt-adapter.sh")).replace(/^file:\/\//, ""))
  readonly property bool showLabel: !vertical && setting("showLabel", true) !== false
  readonly property string labelMode: String(setting("labelMode", "Type"))
  readonly property string clickAction: String(setting("clickAction", "Open panel"))
  readonly property bool notifyOnSwitch: setting("notify", true) !== false
  readonly property int refreshMs: Math.max(2, Number(setting("refreshIntervalSec", 10))) * 1000

  readonly property var panelItem: panelLoader.item
  readonly property bool panelOpen: panelItem ? panelItem.opened === true : false

  readonly property bool switchable: adapters.length > 1
  readonly property var active: {
    for (var i = 0; i < adapters.length; i++)
      if (adapters[i].powered && !adapters[i].blocked) return adapters[i]
    return null
  }
  readonly property int poweredCount: {
    var n = 0
    for (var i = 0; i < adapters.length; i++)
      if (adapters[i].powered && !adapters[i].blocked) n++
    return n
  }

  readonly property string glyph: busy ? "󰑐" : (active ? "󰂯" : "󰂲")
  readonly property string labelText: {
    if (busy) return "…"
    if (!active) return "off"
    if (poweredCount > 1) return "all"
    return labelFor(active)
  }

  readonly property string barTooltip: {
    if (lastError !== "") return lastError
    if (!loaded) return "Bluetooth adapters"
    if (adapters.length === 0) return "No Bluetooth adapter found"
    var lines = ["Bluetooth adapters"]
    for (var i = 0; i < adapters.length; i++) {
      var a = adapters[i]
      lines.push(rowMark(a) + " " + nameFor(a) + "  " + a.hci + "  [" + stateOf(a) + "]")
    }
    lines.push(switchable
      ? "Click: choose · Scroll: next · Right-click: all on"
      : "Plug in a second adapter to switch")
    return lines.join("\n")
  }

  // ---- naming -------------------------------------------------------------

  function kindName(kind) {
    return kind === "usb" ? "USB dongle" : (kind === "onboard" ? "Onboard" : "Adapter")
  }

  function sameKindCount(a) {
    var n = 0
    for (var i = 0; i < adapters.length; i++) if (adapters[i].kind === a.kind) n++
    return n
  }

  // "Onboard" / "USB dongle", with the hciN appended when two adapters would
  // otherwise read the same.
  function nameFor(a) {
    var base = kindName(a.kind)
    return sameKindCount(a) > 1 ? base + " " + a.hci : base
  }

  // Short text for the bar: "USB", "Onboard", or the raw hciN.
  function labelFor(a) {
    if (labelMode === "Adapter id" || a.kind === "other" || sameKindCount(a) > 1) return a.hci
    return a.kind === "usb" ? "USB" : "Onboard"
  }

  function stateOf(a) { return a.blocked || !a.powered ? "off" : "on" }
  function rowMark(a) { return a.blocked || !a.powered ? "○" : "●" }

  // ---- data ---------------------------------------------------------------

  function parse(text) {
    try {
      var data = JSON.parse(String(text))
      if (Array.isArray(data)) adapters = data
    } catch (e) {
      lastError = "Could not read adapter state"
    }
    loaded = true
    if (announceNext) { announceNext = false; announce() }
    if (refreshQueued) { refreshQueued = false; refresh() }
  }

  function refresh() {
    if (statusProc.running) { refreshQueued = true; return }
    statusProc.running = true
  }

  // ---- actions ------------------------------------------------------------

  function run(args, target) {
    if (busy) return
    busy = true
    pending = target
    lastError = ""
    actionProc.command = ["bash", helper].concat(args)
    actionProc.running = true
  }

  function use(hci) {
    // Already the only active adapter: nothing to do.
    if (active && active.hci === hci && poweredCount === 1) return
    run(["use", hci], hci)
  }
  function next() { if (switchable) run(["next"], "next") }
  function allOn() { run(["all-on"], "all") }

  function announce() {
    if (!notifyOnSwitch) return
    var title = "Bluetooth adapter"
    var body
    if (poweredCount > 1) body = "All adapters are on"
    else if (active) body = "Using " + nameFor(active) + (active.model ? " · " + active.model : "")
    else body = "No adapter is active"
    notifyProc.command = ["notify-send", "-a", "Bluetooth Adapter Switch", "-i", "bluetooth",
                          "-h", "string:x-canonical-private-synchronous:bt-adapter-switch", title, body]
    notifyProc.running = true
  }

  // Popup contract: the shell finds a widget's panel through open/close/opened
  // on the bar-widget root (Bar.findPanelWidget), which is how `shell toggle`,
  // hotkeys and panel switching reach it.
  readonly property bool opened: panelOpen

  function open() {
    if (panelLoader.item && panelLoader.item.open) panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item && panelLoader.item.close) panelLoader.item.close()
  }

  function togglePanel() {
    if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle()
  }

  readonly property bool popoutSwitchClosing: panelItem ? panelItem.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelItem && panelItem.closeForPopoutSwitch) panelItem.closeForPopoutSwitch()
  }

  function triggerPress(mouseButton) {
    if (mouseButton === Qt.MiddleButton) next()
    else if (mouseButton === Qt.RightButton) allOn()
    else if (clickAction === "Switch to next") next()
    else togglePanel()
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: root.injectPanel()
  }

  Process {
    id: statusProc
    command: ["bash", root.helper, "json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.parse(text)
    }
  }

  Process {
    id: actionProc
    command: []
    stderr: StdioCollector { id: actionErr; waitForEnd: true }
    onExited: function(exitCode) {
      root.busy = false
      root.pending = ""
      if (exitCode === 0) {
        root.announceNext = true
      } else {
        var why = String(actionErr.text).trim()
        root.lastError = "Could not switch: " + (why !== "" ? why : "exit code " + exitCode)
        if (root.notifyOnSwitch) {
          notifyProc.command = ["notify-send", "-u", "critical", "-a", "Bluetooth Adapter Switch",
                                "-i", "dialog-error", "Bluetooth adapter", root.lastError]
          notifyProc.running = true
        }
      }
      root.refresh()
    }
  }

  Process { id: notifyProc; command: [] }

  // Poll faster while the panel is open so it feels live.
  Timer {
    interval: root.panelOpen ? 2000 : root.refreshMs
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.showLabel ? root.glyph + " " + root.labelText : root.glyph
    fontSize: root.vertical ? Style.bar.iconFont : Style.font.body
    hasVisualContent: true
    active: root.panelOpen
    useActiveColor: false
    dimmed: root.adapters.length < 2 || root.busy
    tooltipText: root.barTooltip
    onPressed: function(b) { root.triggerPress(b) }
    onWheelMoved: function(delta) { root.next() }
  }
}
