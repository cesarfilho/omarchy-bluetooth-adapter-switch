import QtQuick
import qs.Commons
import qs.Ui

// Popup listing every Bluetooth adapter. The bar widget owns the data and the
// actions; this file is only the view, injected with `hostWidget`.
//
// Keys: Up/Down (or j/k) move, Enter selects, 1-9 pick an adapter directly,
// S scans for new devices, R refreshes, Esc closes.
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

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color dim: Qt.darker(foreground, 1.5)

  // Keyboard cursor over the adapter rows.
  property bool cursorActive: false
  property int cursorIndex: 0
  readonly property int rowCount: adapters.length

  readonly property string heroMeta: {
    if (busy) return pending === "auto" ? "Choosing automatically…" : "Switching adapter…"
    if (!hostWidget || !hostWidget.loaded) return "Reading adapters…"
    if (adapters.length === 0) return "No adapter found"
    if (active) return "Using " + hostWidget.nameFor(active)
    return "No adapter active"
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
    cursorIndex = 0
    root.controller.show()
    if (hostWidget) hostWidget.refresh()
  }
  function close() { root.controller.hide() }
  function toggle() { root.opened ? root.close() : root.open() }

  function moveCursor(delta) {
    if (rowCount === 0) return
    if (!cursorActive) {
      cursorActive = true
      // Start on the active adapter so Enter/arrows feel anchored.
      var start = 0
      for (var i = 0; i < adapters.length; i++)
        if (active && adapters[i].hci === active.hci) start = i
      cursorIndex = start
      return
    }
    cursorIndex = Math.max(0, Math.min(rowCount - 1, cursorIndex + delta))
  }

  function activateCursor() {
    if (!hostWidget || !cursorActive) return
    if (cursorIndex < adapters.length) hostWidget.use(adapters[cursorIndex].hci)
  }

  function pickNumber(n) {
    if (hostWidget && n >= 1 && n <= adapters.length) hostWidget.use(adapters[n - 1].hci)
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

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) { if (dy !== 0) root.moveCursor(dy) }
      onActivateRequested: root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        var k = t.toLowerCase()
        if (k === "j") root.moveCursor(1)
        else if (k === "k") root.moveCursor(-1)
        else if (k === "r" && root.hostWidget) root.hostWidget.refresh()
        else if (k === "s" && root.hostWidget && root.active) root.hostWidget.toggleScan(root.active.hci)
        else if (k >= "1" && k <= "9") root.pickNumber(parseInt(k, 10))
      }

      Column {
        id: column
        anchors.fill: parent
        spacing: Style.space(14)

        PanelHero {
          foreground: root.foreground
          fontFamily: root.fontFamily
          title: "Bluetooth adapters"
          meta: root.heroMeta
          iconComponent: Component {
            Text {
              textFormat: Text.PlainText
              text: root.active ? "󰂯" : "󰂲"
              color: root.foreground
              opacity: root.active ? 1.0 : 0.5
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
            }
          }
        }

        PanelSeparator { foreground: root.foreground }

        // Inline error, so a failed switch is visible where you clicked.
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

        // Scrolls once the list (devices, scan results) outgrows the popup.
        Flickable {
          width: parent.width
          height: Math.min(listColumn.implicitHeight, Style.space(400))
          contentWidth: width
          contentHeight: listColumn.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          interactive: contentHeight > height

          Column {
            id: listColumn
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: "ADAPTERS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.adapters
              AdapterRow {
                required property var modelData
                required property int index
                width: parent.width
                adapter: modelData
                rowIndex: index
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
          text: root.adapters.length > 1
            ? "↵ select   S scan   R refresh   Esc close"
            : "S scan   R refresh   Esc close"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }

  component AdapterRow: CursorSurface {
    id: row
    required property var adapter
    required property int rowIndex

    readonly property bool isOn: adapter && adapter.powered && !adapter.blocked
    readonly property bool isSole: isOn && root.poweredCount === 1
    readonly property bool isPending: root.busy && root.pending === adapter.hci
    readonly property var dropped: !isOn && rowHot ? root.droppedDevices(adapter.hci) : []
    readonly property bool rowHot: hasCursor
    readonly property bool scanningHere: root.hostWidget ? root.hostWidget.scanning === adapter.hci : false
    // Nearby devices that announce a real name; unnamed ones are just a MAC
    // address and not worth a row.
    readonly property var nearbyNamed: {
      var out = []
      var list = adapter && adapter.nearby ? adapter.nearby : []
      for (var i = 0; i < list.length && out.length < 6; i++)
        if (!/^([0-9a-f]{2}[:-]){5}[0-9a-f]{2}$/i.test(list[i].name)) out.push(list[i])
      return out
    }

    foreground: root.foreground
    hasCursor: root.cursorActive && root.cursorIndex === rowIndex
    current: isSole
    opacity: root.busy && !isPending ? 0.6 : 1.0
    implicitHeight: content.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onContainsMouseChanged: if (containsMouse) {
        root.cursorActive = true
        root.cursorIndex = row.rowIndex
      }
      onClicked: if (root.hostWidget) root.hostWidget.use(row.adapter.hci)
    }

    Row {
      id: content
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(10)

      Column {
        width: parent.width - adapterSwitch.width - (scanBtn.visible ? scanBtn.width + parent.spacing : 0) - parent.spacing * 2
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(1)

        Text {
          width: parent.width
          textFormat: Text.PlainText
          elide: Text.ElideRight
          text: (row.rowIndex + 1) + "  " + (root.hostWidget ? root.hostWidget.nameFor(row.adapter) : row.adapter.hci)
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.subtitle
          font.bold: row.isOn
        }
        Text {
          width: parent.width
          textFormat: Text.PlainText
          elide: Text.ElideRight
          text: (row.adapter.model !== "" ? row.adapter.model + " · " : "") + row.adapter.hci
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
        Text {
          visible: row.dropped.length > 0
          width: parent.width
          textFormat: Text.PlainText
          elide: Text.ElideRight
          text: "Disconnects " + row.dropped.join(", ")
          color: Color.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }

        Text {
          visible: row.adapter.devices.length === 0 && row.dropped.length === 0
          width: parent.width
          textFormat: Text.PlainText
          text: "No paired devices"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }

        // Paired devices. Click a line (or the link button) to connect or
        // disconnect; the trash button forgets it. Every button acts on this
        // adapter specifically, which is what makes it work for a device
        // paired to the adapter that is not the default one.
        Repeater {
          model: row.adapter.devices

          Item {
            id: dev
            required property var modelData
            readonly property bool confirming: root.confirmForget === modelData.address
            readonly property bool working: root.pending === "dev:" + modelData.address
            readonly property bool canConnect: row.isOn && !root.busy
            readonly property bool hasBattery: modelData.battery !== null && modelData.battery !== undefined
            readonly property int battery: hasBattery ? Number(modelData.battery) : 0
            readonly property bool lowBattery: hasBattery && battery <= 20
            // The destructive action stays out of sight until you point at the line.
            readonly property bool showForget: hover.hovered || confirming

            width: parent.width
            height: Math.max(devText.implicitHeight, forgetBtn.implicitHeight)

            HoverHandler { id: hover }

            MouseArea {
              anchors.fill: parent
              enabled: dev.canConnect
              cursorShape: dev.canConnect ? Qt.PointingHandCursor : Qt.ArrowCursor
              onClicked: root.toggleConnection(row.adapter, dev.modelData)
            }

            Text {
              id: devText
              anchors.left: parent.left
              anchors.right: batteryText.visible ? batteryText.left : connSwitch.left
              anchors.rightMargin: Style.space(6)
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              elide: Text.ElideRight
              text: dev.confirming
                ? "Click again to forget " + dev.modelData.name
                : dev.working
                  ? dev.modelData.name + " · working…"
                  : (dev.modelData.connected ? "● " : "") + dev.modelData.name
                    + (dev.modelData.hasProfile === false ? " · BLE only" : "")
              color: dev.confirming ? Color.urgent : (dev.modelData.connected ? root.foreground : root.dim)
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }

            // Battery level, when the device reports one (BlueZ Battery1).
            Text {
              id: batteryText
              visible: dev.hasBattery && !dev.confirming
              anchors.right: connSwitch.left
              anchors.rightMargin: Style.space(6)
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: root.batteryGlyph(dev.battery) + " " + dev.battery + "%"
              color: dev.lowBattery ? Color.urgent : root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              font.bold: dev.lowBattery
            }

            ToggleSwitch {
              id: connSwitch
              anchors.right: parent.right
              anchors.rightMargin: dev.showForget ? forgetBtn.width + Style.space(6) : 0
              anchors.verticalCenter: parent.verticalCenter
              checked: dev.modelData.connected
              busy: dev.working
              interactive: dev.canConnect && dev.modelData.hasProfile !== false
              opacity: interactive || dev.working ? 1.0 : 0.45
              cursorRing: false
              trackHeight: Style.space(16)
              foreground: dev.modelData.connected ? root.foreground : root.dim
              onToggled: root.toggleConnection(row.adapter, dev.modelData)

              PanelToolTip {
                visible: connSwitch.containsMouse
                text: !row.isOn ? "Switch to this adapter to connect"
                  : (dev.modelData.hasProfile === false ? "Low Energy entry: it cannot carry audio. Forget it and pair the audio device"
                    : (dev.modelData.connected ? "Disconnect" : "Connect"))
                fontFamily: root.fontFamily
              }
            }

            PanelActionButton {
              id: forgetBtn
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              iconText: "󰅙"
              visible: dev.showForget
              tooltipText: dev.confirming ? "Click again to confirm" : "Forget this device"
              foreground: dev.confirming ? Color.urgent : root.dim
              hoverColor: Color.urgent
              fontFamily: root.fontFamily
              fontSize: Style.font.title
              enabled: !root.busy
              onClicked: root.requestForget(row.adapter, dev.modelData)
            }
          }
        }

        // Devices found by the scan, ready to pair.
        Text {
          visible: row.scanningHere
          width: parent.width
          textFormat: Text.PlainText
          text: row.nearbyNamed.length > 0 ? "NEARBY" : "Looking for devices…"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: true
          topPadding: Style.space(4)
        }

        Repeater {
          model: row.scanningHere ? row.nearbyNamed : []

          Item {
            id: near
            required property var modelData
            readonly property bool working: root.pending === "dev:" + modelData.address

            width: parent.width
            height: Math.max(nearText.implicitHeight, pairBtn.implicitHeight)

            Text {
              id: nearText
              anchors.left: parent.left
              anchors.right: pairBtn.left
              anchors.rightMargin: Style.space(6)
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              elide: Text.ElideRight
              text: near.modelData.name + (near.modelData.hasProfile ? "" : " · BLE") + (near.working ? " · pairing…" : "")
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }

            PanelActionButton {
              id: pairBtn
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              iconText: "󰐕"
              tooltipText: near.modelData.hasProfile ? "Pair and connect" : "Pair (Low Energy: no audio)"
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.title
              enabled: !root.busy
              onClicked: if (root.hostWidget) root.hostWidget.pairDevice(row.adapter.hci, near.modelData)
            }
          }
        }
      }

      PanelActionButton {
        id: scanBtn
        visible: row.isOn
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

      // On = this is the adapter in use. Turning another one on switches to it
      // (the rest go off); turning the active one off hands over to the other.
      ToggleSwitch {
        id: adapterSwitch
        anchors.verticalCenter: parent.verticalCenter
        checked: row.isOn
        busy: row.isPending
        interactive: root.adapters.length > 1 && !root.busy
        opacity: interactive || row.isPending ? 1.0 : 0.5
        cursorRing: false
        trackHeight: Style.space(20)
        foreground: root.foreground
        onToggled: root.toggleAdapter(row.adapter)

        PanelToolTip {
          visible: adapterSwitch.containsMouse
          text: root.adapters.length < 2 ? "Only one adapter"
            : (row.isOn ? "Switch to the other adapter" : "Use this adapter (turns the other off)")
          fontFamily: root.fontFamily
        }
      }
    }
  }
}
