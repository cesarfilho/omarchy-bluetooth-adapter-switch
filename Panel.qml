import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui

// Popup listing every Bluetooth adapter with its paired devices and, while a
// scan runs, the devices found nearby. The bar widget owns the data and the
// actions; this file is only the view, injected with `hostWidget`.
//
// One flat list of rows (adapter, its devices, its scan results) so the
// keyboard cursor, the mouse hover and the scroll position all share a model.
//
// Keys: Up/Down (or j/k) move, Enter acts on the row (use adapter, connect or
// disconnect, pair), X/Delete forgets a device, 1-9 pick an adapter directly,
// S scans, R refreshes, Esc closes.
Panel {
  id: root
  moduleName: "io.github.cesarfilho.bluetooth-adapter-switch"
  ipcTarget: "io.github.cesarfilho.bluetooth-adapter-switch"

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  readonly property var adapters: hostWidget ? hostWidget.adapters : []
  readonly property bool busy: hostWidget ? hostWidget.busy : false
  readonly property string pending: hostWidget ? hostWidget.pending : ""
  readonly property string lastError: hostWidget ? hostWidget.lastError : ""
  readonly property var active: hostWidget ? hostWidget.active : null
  readonly property int poweredCount: hostWidget ? hostWidget.poweredCount : 0
  readonly property string scanning: hostWidget ? hostWidget.scanning : ""

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color dim: Qt.darker(foreground, 1.5)

  readonly property string heroMeta: {
    if (busy) return pending === "auto" ? "Choosing automatically…" : "Working…"
    if (!hostWidget || !hostWidget.loaded) return "Reading adapters…"
    if (adapters.length === 0) return "No adapter found"
    if (active) return "Using " + hostWidget.nameFor(active)
    return "No adapter active"
  }

  // ---------- Rows ----------

  // Nearby devices that announce a real name; unnamed ones are just a MAC
  // address and not worth a row.
  function namedNearby(a) {
    var out = []
    var list = a && a.nearby ? a.nearby : []
    for (var i = 0; i < list.length && out.length < 6; i++)
      if (!/^([0-9a-f]{2}[:-]){5}[0-9a-f]{2}$/i.test(list[i].name)) out.push(list[i])
    return out
  }

  readonly property var rows: {
    var out = []
    for (var i = 0; i < adapters.length; i++) {
      var a = adapters[i]
      out.push({ type: "adapter", key: "a:" + a.hci, adapter: a, number: i + 1 })
      for (var j = 0; j < a.devices.length; j++)
        out.push({ type: "device", key: "d:" + a.hci + ":" + a.devices[j].address, adapter: a, dev: a.devices[j] })
      if (a.devices.length === 0)
        out.push({ type: "note", key: "z:" + a.hci, text: "No paired devices" })
      if (scanning === a.hci) {
        var near = namedNearby(a)
        out.push({ type: "label", key: "l:" + a.hci, text: near.length > 0 ? "NEARBY" : "Looking for devices…" })
        for (var k = 0; k < near.length; k++)
          out.push({ type: "nearby", key: "n:" + a.hci + ":" + near[k].address, adapter: a, dev: near[k] })
      }
    }
    return out
  }

  function selectable(r) { return r.type === "adapter" || r.type === "device" || r.type === "nearby" }

  // Keyboard cursor, tracked by key so it survives the list being rebuilt on
  // every refresh and scan result.
  property bool cursorActive: false
  property string cursorKey: ""
  readonly property int cursorIndex: {
    if (!cursorActive) return -1
    for (var i = 0; i < rows.length; i++) if (rows[i].key === cursorKey) return i
    return -1
  }
  readonly property var cursorRow: cursorIndex >= 0 ? rows[cursorIndex] : null

  function moveCursor(delta) {
    if (rows.length === 0) return
    if (cursorIndex < 0) {
      cursorActive = true
      // Start on the active adapter so Enter/arrows feel anchored.
      var start = 0
      for (var s = 0; s < rows.length; s++)
        if (rows[s].type === "adapter" && active && rows[s].adapter.hci === active.hci) { start = s; break }
      cursorKey = rows[start].key
      return
    }
    for (var i = cursorIndex + delta; i >= 0 && i < rows.length; i += delta)
      if (selectable(rows[i])) { cursorKey = rows[i].key; return }
  }

  function activate(r) {
    if (!hostWidget || !r || busy) return
    if (r.type === "adapter") hostWidget.use(r.adapter.hci)
    else if (r.type === "device") toggleConnection(r.adapter, r.dev)
    else if (r.type === "nearby") hostWidget.pairDevice(r.adapter.hci, r.dev)
  }

  function pickNumber(n) {
    if (hostWidget && !busy && n >= 1 && n <= adapters.length) hostWidget.use(adapters[n - 1].hci)
  }

  // Address of the device whose "forget" button was clicked once; a second click
  // within a few seconds confirms it. Unpairing means pairing again from
  // scratch, so one stray click should not do it.
  property string confirmForget: ""

  function requestForget(a, d) {
    if (!hostWidget || busy) return
    if (confirmForget === d.address) {
      confirmForget = ""
      hostWidget.forget(a.hci, d.address, d.name)
    } else {
      confirmForget = d.address
      confirmTimer.restart()
    }
  }

  // Battery icon for a 0-100 level (Material Design Icons battery-10 ... battery).
  function batteryGlyph(level) {
    var step = Math.min(10, Math.max(1, Math.round(level / 10)))
    return String.fromCodePoint(step === 10 ? 0xF0079 : 0xF0079 + step)
  }

  // Adapter switch: on -> use it; off (it is the one in use) -> use the other one.
  function toggleAdapter(a) {
    if (!hostWidget || busy || adapters.length < 2) return
    var isOn = a.powered && !a.blocked
    if (!isOn) { hostWidget.use(a.hci); return }
    for (var i = 0; i < adapters.length; i++)
      if (adapters[i].hci !== a.hci) { hostWidget.use(adapters[i].hci); return }
  }

  function toggleConnection(a, d) {
    if (!hostWidget || busy) return
    if (d.connected) hostWidget.disconnectDevice(a.hci, d)
    else hostWidget.connectDevice(a.hci, d)
  }

  // Paired devices that are connected right now on adapters that switching to
  // `target` would turn off.
  function droppedDevices(target) {
    var names = []
    for (var i = 0; i < adapters.length; i++) {
      var a = adapters[i]
      if (a.hci === target || a.blocked || !a.powered) continue
      for (var j = 0; j < a.devices.length; j++)
        if (a.devices[j].connected) names.push(a.devices[j].name)
    }
    return names
  }

  // Scroll the list just enough to show the row the cursor is on.
  function keepCursorVisible() {
    var item = cursorIndex >= 0 ? repeater.itemAt(cursorIndex) : null
    if (!item) return
    var pad = Style.space(4)
    if (item.y < flick.contentY) flick.contentY = Math.max(0, item.y - pad)
    else if (item.y + item.height > flick.contentY + flick.height)
      flick.contentY = Math.min(flick.contentHeight - flick.height, item.y + item.height - flick.height + pad)
  }
  onCursorKeyChanged: Qt.callLater(keepCursorVisible)

  // Stop scanning as soon as the panel goes away.
  onOpenedChanged: if (!opened && hostWidget) hostWidget.stopScan()

  Timer {
    id: confirmTimer
    interval: 4000
    onTriggered: root.confirmForget = ""
  }

  function open() {
    confirmForget = ""
    cursorActive = false
    cursorKey = ""
    root.controller.show()
    if (hostWidget) hostWidget.refresh()
  }
  function close() { root.controller.hide() }
  function toggle() { root.opened ? root.close() : root.open() }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) { if (dy !== 0) root.moveCursor(dy) }
      onActivateRequested: root.activate(root.cursorRow)
      onDeleteRequested: if (root.cursorRow && root.cursorRow.type === "device") root.requestForget(root.cursorRow.adapter, root.cursorRow.dev)
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        var k = t.toLowerCase()
        if (k === "j") root.moveCursor(1)
        else if (k === "k") root.moveCursor(-1)
        else if (k === "x" && root.cursorRow && root.cursorRow.type === "device") root.requestForget(root.cursorRow.adapter, root.cursorRow.dev)
        else if (k === "r" && root.hostWidget) root.hostWidget.refresh()
        else if (k === "s" && root.hostWidget && root.active) root.hostWidget.toggleScan(root.active.hci)
        else if (k >= "1" && k <= "9") root.pickNumber(parseInt(k, 10))
      }

      Column {
        id: column
        anchors.fill: parent
        spacing: Style.space(14)

        // ---------- Hero: icon · title · status ----------
        PanelHero {
          foreground: root.foreground
          fontFamily: root.fontFamily
          title: "Bluetooth adapters"
          meta: root.heroMeta
          detail: root.scanning !== "" ? "SCANNING" : ""
          iconComponent: Component {
            Text {
              textFormat: Text.PlainText
              text: root.busy ? "󰑐" : (root.active ? "󰂯" : "󰂲")
              color: root.foreground
              opacity: root.active ? 1.0 : 0.5
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
            }
          }
        }

        PanelSeparator { foreground: root.foreground }

        // Inline error, so a failed action is visible where you clicked.
        Rectangle {
          visible: root.lastError !== ""
          width: parent.width
          height: visible ? errorText.implicitHeight + Style.space(16) : 0
          radius: Style.cornerRadius
          color: Qt.rgba(Color.urgent.r, Color.urgent.g, Color.urgent.b, 0.16)
          border.width: 1
          border.color: Qt.rgba(Color.urgent.r, Color.urgent.g, Color.urgent.b, 0.5)

          Text {
            id: errorText
            anchors.left: parent.left
            anchors.right: dismissBtn.left
            anchors.top: parent.top
            anchors.margins: Style.space(8)
            textFormat: Text.PlainText
            text: root.lastError
            color: root.foreground
            wrapMode: Text.Wrap
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }

          PanelActionButton {
            id: dismissBtn
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: Style.space(4)
            iconText: "󰅖"
            tooltipText: "Dismiss"
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: if (root.hostWidget) root.hostWidget.lastError = ""
          }
        }

        // Scrolls once the list outgrows the popup.
        Flickable {
          id: flick
          width: parent.width
          height: Math.min(listColumn.implicitHeight, Style.space(400))
          contentWidth: width
          contentHeight: listColumn.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          interactive: contentHeight > height

          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          Column {
            id: listColumn
            width: parent.width
            spacing: Style.space(2)

            Repeater {
              id: repeater
              model: root.rows
              delegate: Item {
                id: slot
                required property var modelData
                required property int index
                readonly property bool isRow: root.selectable(modelData)

                width: listColumn.width
                // Each adapter after the first gets a divider and room above it.
                readonly property bool startsGroup: modelData.type === "adapter" && modelData.number > 1
                height: (startsGroup ? Style.space(14) : 0) + (isRow ? entryRow.implicitHeight : textEntry.implicitHeight)

                PanelSeparator {
                  visible: slot.startsGroup
                  foreground: root.foreground
                  y: Style.space(6)
                }

                Text {
                  id: textEntry
                  visible: !slot.isRow
                  y: slot.startsGroup ? Style.space(14) : 0
                  width: parent.width
                  leftPadding: Style.space(10) + Style.space(22)
                  topPadding: modelData.type === "label" ? Style.space(6) : 0
                  textFormat: Text.PlainText
                  wrapMode: Text.Wrap
                  text: modelData.text || ""
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: modelData.type === "label"
                  font.letterSpacing: modelData.type === "label" ? 1.2 : 0
                }

                DeviceRow {
                  id: entryRow
                  visible: slot.isRow
                  y: slot.startsGroup ? Style.space(14) : 0
                  width: parent.width
                  entry: slot.modelData
                }
              }
            }

            Text {
              visible: root.hostWidget && root.hostWidget.loaded && root.adapters.length === 0
              width: parent.width
              textFormat: Text.PlainText
              wrapMode: Text.Wrap
              text: "No Bluetooth adapter found. Plug one in and it will show up here."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }

            Text {
              visible: root.adapters.length === 1
              width: parent.width
              topPadding: Style.space(8)
              textFormat: Text.PlainText
              wrapMode: Text.Wrap
              text: "Plug in a second adapter to switch between them."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }

        PanelSeparator { foreground: root.foreground }

        Text {
          width: parent.width
          textFormat: Text.PlainText
          horizontalAlignment: Text.AlignHCenter
          text: {
            var parts = ["↵ select"]
            if (root.cursorRow && root.cursorRow.type === "device") parts.push("X forget")
            parts.push("S scan", "R refresh", "Esc close")
            return parts.join("   ")
          }
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }

  // One row for an adapter, a paired device or a scan result. Devices and scan
  // results are indented under their adapter; the destructive "forget" action
  // only shows on the row the cursor or pointer is on.
  component DeviceRow: CursorSurface {
    id: row
    required property var entry

    readonly property string kind: entry.type
    readonly property var adapter: entry.adapter
    readonly property var dev: entry.dev
    readonly property bool isAdapter: kind === "adapter"
    readonly property bool isDevice: kind === "device"
    readonly property bool isNearby: kind === "nearby"

    readonly property bool adapterOn: adapter && adapter.powered && !adapter.blocked
    readonly property bool isSole: isAdapter && adapterOn && root.poweredCount === 1
    readonly property bool scanningHere: root.scanning === adapter.hci
    readonly property bool working: !isAdapter && root.pending === "dev:" + dev.address
    readonly property bool adapterPending: isAdapter && root.busy && root.pending === adapter.hci
    readonly property bool confirming: isDevice && root.confirmForget === dev.address
    readonly property bool connected: isDevice && dev.connected
    readonly property bool bleOnly: !isAdapter && dev.hasProfile === false
    readonly property bool canConnect: isDevice && adapterOn && !root.busy && !bleOnly

    readonly property bool hasBattery: isDevice && dev.battery !== null && dev.battery !== undefined
    readonly property int battery: hasBattery ? Number(dev.battery) : 0
    readonly property bool lowBattery: hasBattery && battery <= 20

    readonly property var dropped: isAdapter && !adapterOn && rowHot ? root.droppedDevices(adapter.hci) : []
    readonly property bool rowHot: hasCursor || hover.hovered
    readonly property bool showForget: isDevice && (rowHot || confirming)

    readonly property real inset: isAdapter ? 0 : Style.space(22)

    foreground: root.foreground
    hasCursor: root.cursorActive && root.cursorKey === entry.key
    current: isSole || connected
    opacity: root.busy && !adapterPending && !working ? 0.6 : 1.0
    implicitHeight: Math.max(info.implicitHeight, Style.space(24)) + Style.spacing.rowPaddingX

    readonly property string caption: {
      if (isAdapter) {
        if (dropped.length > 0) return "Disconnects " + dropped.join(", ")
        return (adapter.model !== "" ? adapter.model + " · " : "") + adapter.hci
      }
      if (confirming) return "Click again to forget"
      if (working) return isNearby ? "Pairing…" : "Working…"
      if (isNearby) return bleOnly ? "Low Energy · no audio" : "Ready to pair"
      if (bleOnly) return "Low Energy only · no audio"
      if (connected) return "Connected"
      if (!adapterOn) return "Paired · adapter off"
      return "Paired"
    }
    readonly property color captionColor: (dropped.length > 0 || confirming) ? Color.urgent : (connected || working ? root.foreground : root.dim)

    HoverHandler { id: hover }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onContainsMouseChanged: if (containsMouse) {
        root.cursorActive = true
        root.cursorKey = row.entry.key
      }
      onClicked: root.activate(row.entry)
    }

    // Leading icon: adapter radio, or the device's link state.
    Text {
      id: icon
      anchors.left: parent.left
      anchors.leftMargin: Style.space(10) + row.inset
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: row.isAdapter ? (row.adapterOn ? "󰂯" : "󰂲") : (row.connected ? "󰂱" : "󰂯")
      color: row.isAdapter ? (row.adapterOn ? root.foreground : root.dim) : (row.connected ? root.foreground : root.dim)
      font.family: root.fontFamily
      font.pixelSize: Style.font.heading
    }

    Column {
      id: info
      anchors.left: icon.right
      anchors.leftMargin: Style.space(10)
      anchors.right: trailing.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(1)

      Text {
        width: parent.width
        textFormat: Text.PlainText
        elide: Text.ElideRight
        text: row.isAdapter
          ? (root.adapters.length > 1 ? row.entry.number + "  " : "") + (root.hostWidget ? root.hostWidget.nameFor(row.adapter) : row.adapter.hci)
          : row.dev.name
        color: row.isAdapter || row.connected || row.isNearby ? root.foreground : root.dim
        font.family: root.fontFamily
        font.pixelSize: row.isAdapter ? Style.font.subtitle : Style.font.body
        font.bold: row.isAdapter && row.adapterOn
      }

      Text {
        width: parent.width
        textFormat: Text.PlainText
        elide: Text.ElideRight
        text: row.caption
        color: row.captionColor
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }

    // Trailing controls, right to left.
    Row {
      id: trailing
      anchors.right: parent.right
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(8)
      layoutDirection: Qt.LeftToRight

      // Battery level, when the device reports one (BlueZ Battery1).
      Text {
        visible: row.hasBattery && !row.confirming
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: root.batteryGlyph(row.battery) + " " + row.battery + "%"
        color: row.lowBattery ? Color.urgent : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: row.lowBattery
      }

      PanelActionButton {
        visible: row.isAdapter && row.adapterOn
        anchors.verticalCenter: parent.verticalCenter
        iconText: "󰍉"
        tooltipText: row.scanningHere ? "Stop scanning" : "Scan for new devices"
        foreground: row.scanningHere ? root.foreground : root.dim
        bordered: true
        fontFamily: root.fontFamily
        fontSize: Style.font.title
        enabled: !root.busy
        onClicked: if (root.hostWidget) root.hostWidget.toggleScan(row.adapter.hci)
      }

      PanelActionButton {
        visible: row.isNearby
        anchors.verticalCenter: parent.verticalCenter
        iconText: "󰐕"
        tooltipText: row.bleOnly ? "Pair (Low Energy: no audio)" : "Pair and connect"
        foreground: root.foreground
        fontFamily: root.fontFamily
        fontSize: Style.font.title
        enabled: !root.busy
        onClicked: root.activate(row.entry)
      }

      // On = this is the adapter in use. Turning another one on switches to it
      // (the rest go off); turning the active one off hands over to the other.
      ToggleSwitch {
        id: adapterSwitch
        visible: row.isAdapter
        anchors.verticalCenter: parent.verticalCenter
        checked: row.adapterOn
        busy: row.adapterPending
        interactive: root.adapters.length > 1 && !root.busy
        opacity: interactive || row.adapterPending ? 1.0 : 0.5
        cursorRing: false
        trackHeight: Style.space(20)
        foreground: root.foreground
        onToggled: root.toggleAdapter(row.adapter)

        PanelToolTip {
          visible: adapterSwitch.containsMouse
          text: root.adapters.length < 2 ? "Only one adapter"
            : (row.adapterOn ? "Switch to the other adapter" : "Use this adapter (turns the other off)")
          fontFamily: root.fontFamily
        }
      }

      // The destructive action stays out of sight until you point at the line.
      PanelActionButton {
        visible: row.showForget
        anchors.verticalCenter: parent.verticalCenter
        iconText: "󰅙"
        tooltipText: row.confirming ? "Click again to confirm" : "Forget this device"
        foreground: row.confirming ? Color.urgent : root.dim
        hoverColor: Color.urgent
        fontFamily: root.fontFamily
        fontSize: Style.font.title
        enabled: !root.busy
        onClicked: root.requestForget(row.adapter, row.dev)
      }
    }
  }
}
