import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui

// Bar widget that shows which Bluetooth adapter is active and switches
// between them.
//
// Left click or scroll makes the next adapter the only powered one, right
// click turns every adapter back on, middle click refreshes. All the real work
// happens in bt-adapter.sh (rfkill + BlueZ over D-Bus, no privileges needed).
BarWidget {
  id: root
  moduleName: "io.github.cesarfilho.bluetooth-adapter-switch"

  // [{ hci, address, alias, powered, blocked }], in hciN order.
  property var adapters: []
  property bool busy: false
  property string lastError: ""

  readonly property string helper: decodeURIComponent(String(Qt.resolvedUrl("bt-adapter.sh")).replace(/^file:\/\//, ""))
  readonly property bool showLabel: !vertical && setting("showLabel", true) !== false
  readonly property int refreshMs: Math.max(2, Number(setting("refreshIntervalSec", 10))) * 1000

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

  readonly property string glyph: active ? "󰂯" : "󰂲"
  readonly property string labelText: !active ? "off" : (poweredCount > 1 ? "all" : active.hci)

  readonly property string barTooltip: {
    if (lastError !== "") return lastError
    if (adapters.length === 0) return "No Bluetooth adapter found"
    var lines = ["Bluetooth adapters"]
    for (var i = 0; i < adapters.length; i++) {
      var a = adapters[i]
      var state = a.blocked ? "blocked" : (a.powered ? "on" : "off")
      lines.push(a.hci + "  " + a.alias + "  " + a.address + "  [" + state + "]")
    }
    lines.push(switchable ? "Click: next adapter · Right-click: all on" : "Plug in a second adapter to switch")
    return lines.join("\n")
  }

  function parse(text) {
    var out = []
    var rows = String(text).split("\n")
    for (var i = 0; i < rows.length; i++) {
      var f = rows[i].split("|")
      if (f.length < 5 || f[0] === "") continue
      out.push({ hci: f[0], address: f[1], alias: f[2], powered: f[3] === "true", blocked: f[4] === "true" })
    }
    adapters = out
  }

  function refresh() {
    if (!statusProc.running) statusProc.running = true
  }

  function run(args) {
    if (busy) return
    busy = true
    lastError = ""
    actionProc.command = ["bash", helper].concat(args)
    actionProc.running = true
  }

  function next() { if (switchable) run(["next"]) }
  function allOn() { run(["all-on"]) }

  function triggerPress(mouseButton) {
    if (mouseButton === Qt.MiddleButton) refresh()
    else if (mouseButton === Qt.RightButton) allOn()
    else next()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Process {
    id: statusProc
    command: ["bash", root.helper, "status"]
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
      root.lastError = exitCode === 0 ? "" : ("Switch failed: " + String(actionErr.text).trim())
      root.refresh()
    }
  }

  Timer {
    interval: root.refreshMs
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
    dimmed: !root.switchable || root.busy
    tooltipText: root.barTooltip
    onPressed: function(b) { root.triggerPress(b) }
    onWheelMoved: function(delta) { root.next() }
  }
}
