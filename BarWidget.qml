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
  // Text for the notification when the running action succeeds.
  property string doneMessage: ""
  // Start of the error text if the running action fails, e.g. "Could not connect to X".
  property string failPrefix: ""
  // The hciN currently looking for devices ("" when not scanning).
  property string scanning: ""

  readonly property string helper: decodeURIComponent(String(Qt.resolvedUrl("bt-adapter.sh")).replace(/^file:\/\//, ""))
  readonly property bool showLabel: !vertical && setting("showLabel", true) !== false
  readonly property string labelMode: String(setting("labelMode", "Type"))
  readonly property string clickAction: String(setting("clickAction", "Open panel"))
  readonly property string scanTransport: {
    var v = String(setting("scanTransport", "Classic (headsets, speakers)"))
    return v.indexOf("Low Energy") === 0 ? "le" : (v.indexOf("Both") === 0 ? "auto" : "bredr")
  }
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
    // Battery of connected devices, so it is visible without opening the panel.
    for (var j = 0; j < adapters.length; j++) {
      var devs = adapters[j].devices || []
      for (var k = 0; k < devs.length; k++)
        if (devs[k].connected && devs[k].battery !== null && devs[k].battery !== undefined)
          lines.push(devs[k].name + "  " + devs[k].battery + "%")
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
      console.warn("[bt-adapter-switch] could not parse adapter state: " + e)
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
    if (busy) {
      console.log("[bt-adapter-switch] ignored " + args.join(" ") + ": another action is running")
      return
    }
    console.log("[bt-adapter-switch] run " + args.join(" "))
    busy = true
    pending = target
    lastError = ""
    actionProc.command = ["bash", helper].concat(args)
    actionProc.running = true
  }

  function use(hci) {
    // Already the only active adapter: nothing to do.
    if (active && active.hci === hci && poweredCount === 1) return
    stopScan()
    doneMessage = ""
    failPrefix = "Could not switch"
    run(["use", hci], hci)
  }
  function next() { if (switchable) { stopScan(); doneMessage = ""; failPrefix = "Could not switch"; run(["next"], "next") } }
  function allOn() { doneMessage = ""; failPrefix = "Could not turn the adapters on"; run(["all-on"], "all") }
  function forget(hci, address, name) {
    doneMessage = "Forgot " + name
    failPrefix = "Could not forget " + name
    run(["forget", hci, address], "dev:" + address)
  }
  function connectDevice(hci, d) {
    doneMessage = "Connected to " + d.name
    failPrefix = "Could not connect to " + d.name
    run(["connect", hci, d.address], "dev:" + d.address)
  }
  function disconnectDevice(hci, d) {
    doneMessage = "Disconnected " + d.name
    failPrefix = "Could not disconnect " + d.name
    run(["disconnect", hci, d.address], "dev:" + d.address)
  }
  function pairDevice(hci, d) {
    doneMessage = "Paired with " + d.name
    failPrefix = "Could not pair with " + d.name
    run(["pair", hci, d.address], "dev:" + d.address)
  }

  // Device discovery is tied to a running process, so scanning is a Process we
  // start and stop. It also stops by itself after 45 s.
  function startScan(hci) {
    if (scanProc.running) scanProc.running = false
    scanning = hci
    scanProc.command = ["bash", helper, "scan", hci, "45", scanTransport]
    scanProc.running = true
  }
  function stopScan() {
    scanning = ""
    if (scanProc.running) scanProc.running = false
  }
  function toggleScan(hci) { scanning === hci ? stopScan() : startScan(hci) }

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

  function notifyDone() {
    if (!notifyOnSwitch) return
    notifyProc.command = ["notify-send", "-a", "Bluetooth Adapter Switch", "-i", "bluetooth",
                          "-h", "string:x-canonical-private-synchronous:bt-adapter-switch",
                          "Bluetooth adapter", doneMessage]
    notifyProc.running = true
  }

  // The bar and the popup host drive the panel through its owner: an outside
  // click calls owner.close(), and opening another bar popup calls
  // closeForPopoutSwitch(). Without these forwarders the popup falls back to
  // assigning its own `open`, which silently breaks the binding to the panel's
  // state and the panel never opens again until the shell restarts.
  readonly property bool opened: panelOpen
  readonly property bool popoutSwitchClosing: panelItem ? panelItem.popoutSwitchClosing === true : false
  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }

  function togglePanel() {
    if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle()
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
      console.log("[bt-adapter-switch] exit " + exitCode + (exitCode === 0 ? "" : ": " + String(actionErr.text).trim()))
      root.busy = false
      root.pending = ""
      if (exitCode === 0 && root.doneMessage !== "") {
        root.notifyDone()
      } else if (exitCode === 0) {
        root.announceNext = true
      } else {
        var why = String(actionErr.text).trim()
        root.lastError = (root.failPrefix !== "" ? root.failPrefix : "Action failed") + ": " + (why !== "" ? why : "exit code " + exitCode) + "\nDetails: ~/.local/state/omarchy-bluetooth-adapter-switch/plugin.log"
        if (root.notifyOnSwitch) {
          notifyProc.command = ["notify-send", "-u", "critical", "-a", "Bluetooth Adapter Switch",
                                "-i", "dialog-error", "Bluetooth adapter", root.lastError]
          notifyProc.running = true
        }
      }
      root.doneMessage = ""
      root.failPrefix = ""
      root.refresh()
    }
  }

  // A failure message is news for a few seconds, not a permanent banner.
  Timer {
    id: errorTimer
    interval: 12000
    onTriggered: root.lastError = ""
  }
  onLastErrorChanged: if (lastError !== "") errorTimer.restart()

  Process { id: notifyProc; command: [] }

  Process {
    id: scanProc
    command: []
    onExited: root.scanning = ""
  }

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
