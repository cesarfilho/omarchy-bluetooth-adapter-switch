import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui

// Bar widget for machines with more than one Bluetooth adapter.
//
// Exactly one adapter is active at a time. Plugging a dongle in makes it the
// active adapter and unplugging it brings the onboard one back (or the reverse
// if the preference is "Onboard"); a manual pick in between is kept until the
// adapters change again.
//
// Left click opens a panel that lists every adapter with what it is (onboard
// chip or USB dongle), which one is active and what is paired to it, and lets
// you pick one. Scroll or middle click jumps straight to the next adapter and
// right click goes back to the automatic choice. All the real work happens in
// bt-adapter.sh (rfkill + BlueZ over D-Bus, no privileges needed).
BarWidget {
  id: root
  moduleName: "io.github.cesarfilho.bluetooth-adapter-switch"

  // [{ hci, kind, model, address, alias, powered, blocked, devices: [{ name, connected }] }]
  property var adapters: []
  property bool loaded: false
  property bool busy: false
  // What the running action is switching to: an hciN, "next" or "auto".
  property string pending: ""
  property string lastError: ""
  property bool refreshQueued: false
  property bool announceNext: false
  // Adapters seen on the previous read ("hciN:ADDRESS,..."), to notice plug and
  // unplug; empty until the first read so starting the shell never switches.
  property string knownSet: ""
  // Notification for the running action when it succeeds: headline, body and
  // glyph. An empty doneTitle means the action announces the adapter instead.
  property string doneTitle: ""
  property string doneMessage: ""
  property string doneGlyph: "󰂯"
  // Id of the last toast, so the next one replaces it instead of stacking.
  property int lastNotifId: 0
  // Start of the error text if the running action fails, e.g. "Could not connect to X".
  property string failPrefix: ""
  // The hciN currently looking for devices ("" when not scanning).
  property string scanning: ""
  // When the last automatic "ensure" failed (ms since epoch), 0 if it has not.
  property double ensureFailedAt: 0
  readonly property int ensureRetryMs: 60000
  // True while the running action is settle()'s "ensure" (only that one backs off).
  property bool ensureRun: false
  // Address of the adapter in use on the previous read, and whether the devices
  // that were connected before a change of adapter still have to be reconnected.
  property string activeAddr: ""
  property bool reconnectWanted: false
  // Every adapter was off on a read since activeAddr was set (Bluetooth switched off and back on).
  property bool wasOff: false
  // Addresses already warned about a low battery (until it recovers).
  property var batteryWarned: ({})

  readonly property string helper: decodeURIComponent(String(Qt.resolvedUrl("bt-adapter.sh")).replace(/^file:\/\//, ""))
  readonly property bool showLabel: !vertical && setting("showLabel", false) === true
  readonly property string labelMode: String(setting("labelMode", "Type"))
  readonly property string preferKind: {
    var v = String(setting("preferred", "USB dongle"))
    return v === "Onboard" ? "onboard" : (v === "Last used" ? "last" : "usb")
  }
  readonly property string clickAction: String(setting("clickAction", "Open panel"))
  readonly property string scanTransport: {
    var v = String(setting("scanTransport", "Classic (headsets, speakers)"))
    return v.indexOf("Low Energy") === 0 ? "le" : (v.indexOf("Both") === 0 ? "auto" : "bredr")
  }
  readonly property bool keepOneOn: setting("keepOneOn", true) !== false
  readonly property bool notifyOnSwitch: setting("notify", true) !== false
  readonly property bool autoReconnect: setting("autoReconnect", true) !== false
  // Battery percentage at or below which a device is flagged; 0 turns the alert off.
  readonly property int batteryAlertPct: Math.max(0, Math.min(50, Number(setting("batteryAlert", 20))))
  readonly property int lowBatteryLevel: batteryAlertPct > 0 ? batteryAlertPct : 20
  readonly property int connectTimeoutSec: Math.max(5, Math.min(60, Number(setting("connectTimeoutSec", 15))))
  readonly property int errorDismissMs: Math.max(3, Number(setting("errorDismissSec", 12))) * 1000
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
    return labelFor(active)
  }

  // Hover card (HoverCard.qml): shown after the pointer rests on the icon for a
  // moment, hidden while the click panel is open since the panel shows the same.
  readonly property bool hovering: button.tooltipHovered
  property bool hoverReady: false
  readonly property bool hoverOpen: hoverReady && hovering && !panelOpen

  onHoveringChanged: {
    hoverReady = false
    if (hovering) hoverTimer.restart()
    else hoverTimer.stop()
  }
  onPanelOpenChanged: {
    hoverReady = false
    if (!panelOpen && hovering) hoverTimer.restart()
  }

  Timer { id: hoverTimer; interval: 350; onTriggered: root.hoverReady = true }

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
    settle()
    trackActive()
    checkBattery()
  }

  // A different adapter became the active one (a switch, a dongle unplugged, or
  // Bluetooth switched back on): bring back the devices that were connected.
  // The very first read only records the adapter, so starting the shell never
  // reconnects anything by itself.
  function trackActive() {
    var addr = active ? active.address : ""
    if (addr === "") {
      if (activeAddr !== "") wasOff = true
    } else {
      if (activeAddr !== "" && (addr !== activeAddr || wasOff) && autoReconnect) reconnectWanted = true
      activeAddr = addr
      wasOff = false
    }
    if (reconnectWanted && !busy && active && !reconnectProc.running) {
      reconnectWanted = false
      reconnectProc.command = ["env", "BT_CONNECT_TIMEOUT=" + connectTimeoutSec, "bash", helper, "reconnect", active.hci]
      reconnectProc.running = true
    }
  }

  // One notification per device when its battery drops to the threshold, and
  // again only after it has recovered (a few points of hysteresis).
  function checkBattery() {
    if (batteryAlertPct === 0) return
    var warned = batteryWarned
    var changed = false
    for (var i = 0; i < adapters.length; i++) {
      var list = adapters[i].devices
      for (var j = 0; j < list.length; j++) {
        var d = list[j]
        var known = warned[d.address] === true
        var level = d.battery === null || d.battery === undefined ? -1 : Number(d.battery)
        if (d.connected && level >= 0 && level <= batteryAlertPct && !known) {
          warned[d.address] = true
          changed = true
          notify("Battery low", d.name + " is at " + level + "%", "󰂃", "normal", true)
        } else if (known && (!d.connected || level > batteryAlertPct + 5)) {
          delete warned[d.address]
          changed = true
        }
      }
    }
    if (changed) batteryWarned = warned
  }

  // Keep exactly one adapter active. A change in the set of adapters (dongle
  // plugged or unplugged) re-applies the preference; anything else only steps
  // in when several adapters are on (or none, if "Turn one back on" is set).
  // After a failed attempt it waits ensureRetryMs before trying again, so a
  // blocked or missing adapter does not turn into a retry loop.
  function settle() {
    var ready = []
    for (var i = 0; i < adapters.length; i++)
      if (adapters[i].address !== "") ready.push(adapters[i].hci + ":" + adapters[i].address)
    // An adapter BlueZ has not registered yet has no address: wait for it.
    if (ready.length !== adapters.length) return
    // Mid-switch: leave knownSet alone so the change is still seen afterwards.
    if (busy) return
    // An empty read (rfkill hiccup, last adapter unplugged) must not wipe
    // knownSet, or the adapters coming back would not count as a change.
    if (ready.length === 0) return
    var set = ready.join(",")
    var changed = knownSet !== "" && set !== knownSet
    if (changed) {
      // Everything off on purpose and "turn one back on" disabled: respect it.
      // Otherwise remember the new set only once the switch really started, so
      // a change that could not be applied is seen again on the next read.
      if ((poweredCount === 0 && !keepOneOn) || automatic()) knownSet = set
      return
    }
    knownSet = set
    if ((poweredCount > 1 || (poweredCount === 0 && keepOneOn)) &&
        Date.now() - ensureFailedAt > ensureRetryMs) {
      ensureRun = true
      run(["ensure", preferKind], "auto", "Could not switch")
    }
  }

  function refresh() {
    if (statusProc.running) { refreshQueued = true; return }
    statusProc.running = true
  }

  // ---- actions ------------------------------------------------------------

  // Returns true when the action was started, false when it was ignored.
  function run(args, target, failText) {
    if (busy) {
      ensureRun = false
      console.log("[bt-adapter-switch] ignored " + args.join(" ") + ": another action is running")
      return false
    }
    console.log("[bt-adapter-switch] run " + args.join(" "))
    busy = true
    pending = target
    lastError = ""
    if (failText !== undefined) { setDone("", "", "󰂯"); failPrefix = failText }
    actionProc.command = ["env", "BT_CONNECT_TIMEOUT=" + connectTimeoutSec, "bash", helper].concat(args)
    actionProc.running = true
    return true
  }

  // Every action checks `busy` before it touches doneMessage, failPrefix or the
  // scan: those belong to the action that is already running, and a stray
  // scroll or click must not rewrite its notification or error text.
  function use(hci) {
    if (busy) return
    // Already the only active adapter: nothing to do.
    if (active && active.hci === hci && poweredCount === 1) return
    stopScan()
    setDone("", "", "󰂯")
    failPrefix = "Could not switch"
    run(["use", hci], hci)
  }
  function next() {
    if (busy || !switchable) return
    stopScan()
    setDone("", "", "󰂯")
    failPrefix = "Could not switch"
    run(["next"], "next")
  }
  function automatic() {
    if (busy) return false
    stopScan()
    return run(["auto", preferKind], "auto", "Could not switch")
  }
  function forget(hci, address, name) {
    if (busy) return
    setDone("Forgot device", name, "󰅙")
    failPrefix = "Could not forget " + name
    run(["forget", hci, address], "dev:" + address)
  }
  // Connecting a device that belongs to an adapter that is off switches to that
  // adapter first (the other one goes off, as always).
  function connectDevice(hci, d) {
    if (busy) return
    var owner = null
    for (var i = 0; i < adapters.length; i++) if (adapters[i].hci === hci) owner = adapters[i]
    var needsSwitch = owner !== null && (!owner.powered || owner.blocked || poweredCount !== 1)
    stopScan()
    setDone("Connected", d.name, "󰂱")
    failPrefix = "Could not connect to " + d.name
    run([needsSwitch ? "switch-connect" : "connect", hci, d.address], "dev:" + d.address)
  }
  // Music (A2DP) <-> call mode with a microphone (HFP).
  function toggleProfile(d) {
    if (busy) return
    var toCall = d.profile === "a2dp"
    setDone(toCall ? "Call mode" : "Music mode", d.name + (toCall ? ": microphone on, lower sound quality" : ": high quality sound"), toCall ? "󰋎" : "󰋋")
    failPrefix = "Could not change the audio profile of " + d.name
    run(["profile", d.address, toCall ? "hfp" : "a2dp"], "dev:" + d.address)
  }
  // Anonymised report on the clipboard, for pasting into a bug report.
  function copyDiagnostics() {
    if (busy) return
    setDone("Diagnostics copied", "Paste it into your issue (device names and addresses are masked)", "󰆏")
    failPrefix = "Could not copy the diagnostics"
    run(["diagnostics", "--copy"], "diag")
  }
  function disconnectDevice(hci, d) {
    if (busy) return
    setDone("Disconnected", d.name, "󰂲")
    failPrefix = "Could not disconnect " + d.name
    run(["disconnect", hci, d.address], "dev:" + d.address)
  }
  function pairDevice(hci, d) {
    if (busy) return
    setDone("Paired", d.name, "󰂱")
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

  function setDone(title, message, glyph) {
    doneTitle = title
    doneMessage = message
    doneGlyph = glyph
  }

  // One toast per event, built by Omarchy's own notifier: a glyph instead of a
  // generic icon, the previous toast replaced rather than stacked, and a click
  // that opens this panel. Argument words stay separate, never one shell string.
  function notify(headline, body, glyph, urgency, always) {
    if (!notifyOnSwitch && always !== true) return
    notifyProc.command = ["omarchy-notification-send", "--app-name", "Bluetooth", "-g", glyph, "-u", urgency,
                          "-r", String(lastNotifId), "-p", headline, body,
                          "--exec", "omarchy-shell", "io.github.cesarfilho.bluetooth-adapter-switch", "open"]
    notifyProc.running = true
  }

  // After a switch: which adapter is in use, and what is connected to it.
  function announce() {
    if (!active) { notify("No Bluetooth adapter active", "Open the panel to pick one", "󰂲", "normal"); return }
    var linked = []
    for (var i = 0; i < active.devices.length; i++)
      if (active.devices[i].connected) linked.push(active.devices[i].name)
    var body = active.model ? active.model + " · " + active.hci : active.hci
    if (linked.length > 0) body += "\n" + linked.join(", ") + " connected"
    notify("Using " + nameFor(active), body, "󰂯", "low")
  }

  function notifyDone() {
    notify(doneTitle, doneMessage, doneGlyph, "low")
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
    else if (mouseButton === Qt.RightButton) automatic()
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

  function injectHover() {
    var target = hoverLoader.item
    if (!target) return
    target.bar = root.bar
    target.anchorItem = button
    target.host = root
  }

  Binding { target: hoverLoader.item; property: "open"; value: root.hoverOpen; when: hoverLoader.item !== null }

  onBarChanged: { injectPanel(); injectHover() }
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

  Loader {
    id: hoverLoader
    active: true
    source: Qt.resolvedUrl("HoverCard.qml")
    onLoaded: root.injectHover()
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
      // Remember a failed automatic attempt so settle() backs off.
      if (root.ensureRun) root.ensureFailedAt = exitCode === 0 ? 0 : Date.now()
      root.ensureRun = false
      root.busy = false
      root.pending = ""
      if (exitCode === 0 && root.doneTitle !== "") {
        root.notifyDone()
      } else if (exitCode === 0) {
        root.announceNext = true
      } else {
        var why = String(actionErr.text).trim()
        // Exit 4 from "pair": paired fine, only the connect failed. The helper's
        // message already says so, so the "Could not pair" prefix would mislead.
        var pairedOnly = exitCode === 4 && why !== "" && root.failPrefix.indexOf("Could not pair") === 0
        var head = pairedOnly ? "" : (root.failPrefix !== "" ? root.failPrefix : "Action failed") + ": "
        root.lastError = head + (why !== "" ? why : "exit code " + exitCode) + "\nDetails: ~/.local/state/omarchy-bluetooth-adapter-switch/plugin.log"
        root.notify(pairedOnly ? "Paired, but not connected" : (root.failPrefix !== "" ? root.failPrefix : "Bluetooth action failed"),
                    why !== "" ? why : "exit code " + exitCode, "󰂲", "critical")
      }
      root.setDone("", "", "󰂯")
      root.failPrefix = ""
      root.refresh()
    }
  }

  // Reconnects the devices that were connected before the adapter changed. It
  // runs beside the user's actions rather than as one of them, so the panel
  // stays usable while a headset that is switched off times out.
  Process {
    id: reconnectProc
    command: []
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var names = String(text).trim().split("\n").filter(function(n) { return n !== "" })
        if (names.length > 0)
          root.notify("Reconnected", names.join(", "), "󰂱", "low")
        root.refresh()
      }
    }
  }

  // Plug and unplug: one line per Bluetooth adapter event, then re-read after
  // things have settled (BlueZ registers a new adapter a moment after rfkill).
  Process {
    id: watchProc
    command: ["bash", root.helper, "watch"]
    running: true
    stdout: SplitParser { onRead: settleTimer.restart() }
    onExited: watchRestart.start()
  }

  Timer { id: watchRestart; interval: 3000; onTriggered: watchProc.running = true }
  Timer { id: settleTimer; interval: 1200; onTriggered: root.refresh() }

  // A failure message is news for a few seconds, not a permanent banner.
  Timer {
    id: errorTimer
    interval: root.errorDismissMs
    onTriggered: root.lastError = ""
  }
  onLastErrorChanged: if (lastError !== "") errorTimer.restart()

  Process {
    id: notifyProc
    command: []
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.lastNotifId = parseInt(String(text).trim(), 10) || 0
    }
  }

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
    // The shell's own tooltip only draws plain text; HoverCard replaces it.
    tooltipText: ""
    onPressed: function(b) { root.triggerPress(b) }
    onWheelMoved: function(delta) { root.next() }
  }
}
