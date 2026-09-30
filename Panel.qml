import QtQuick
import qs.Commons
import qs.Ui

// Popup listing every Bluetooth adapter. The bar widget owns the data and the
// actions; this file is only the view, injected with `hostWidget`.
//
// Keys: Up/Down (or j/k) move, Enter selects, 1-9 pick an adapter directly,
// R refreshes, Esc closes.
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

  function open() {
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

  function deviceLine(a) {
    var connected = []
    for (var i = 0; i < a.devices.length; i++)
      if (a.devices[i].connected) connected.push(a.devices[i].name)
    if (connected.length > 0) return "Connected: " + connected.join(", ")
    if (a.devices.length === 0) return "No paired devices"
    return a.devices.length === 1 ? "1 paired device" : a.devices.length + " paired devices"
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
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
            anchors.fill: parent
            anchors.margins: Style.space(8)
            textFormat: Text.PlainText
            text: root.lastError
            color: root.foreground
            wrapMode: Text.Wrap
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }
        }

        Column {
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
            visible: root.adapters.length > 1
            width: parent.width
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            text: "Only one adapter is active at a time. Plugging a dongle in or out switches automatically."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            visible: root.adapters.length === 1
            width: parent.width
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            text: "Plug in a second adapter and it becomes the active one."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        Text {
          width: parent.width
          textFormat: Text.PlainText
          horizontalAlignment: Text.AlignHCenter
          text: root.adapters.length > 1
            ? "↵ select   1-9 pick   R refresh   Esc close"
            : "R refresh   Esc close"
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
    // What the switch shows. While a pick to a known adapter is in flight it
    // already shows the outcome: the picked one on, every other one off.
    readonly property bool shownOn: root.busy && root.pending.indexOf("hci") === 0
      ? root.pending === adapter.hci
      : isOn
    readonly property var dropped: !isOn && rowHot ? root.droppedDevices(adapter.hci) : []
    readonly property bool rowHot: hasCursor

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

      Text {
        id: mark
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: row.shownOn ? "󰂯" : "󰂲"
        color: row.shownOn ? root.foreground : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.heading
      }

      Column {
        width: parent.width - mark.width - stateSwitch.width - parent.spacing * 2
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(1)

        Text {
          width: parent.width
          textFormat: Text.PlainText
          elide: Text.ElideRight
          text: (row.rowIndex + 1) + "  " + (root.hostWidget ? root.hostWidget.nameFor(row.adapter) : row.adapter.hci)
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: row.isOn
        }
        Text {
          width: parent.width
          textFormat: Text.PlainText
          elide: Text.ElideRight
          text: (row.adapter.model !== "" ? row.adapter.model + " · " : "") + row.adapter.hci
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
        Text {
          width: parent.width
          textFormat: Text.PlainText
          elide: Text.ElideRight
          text: row.dropped.length > 0
            ? "Disconnects " + row.dropped.join(", ")
            : root.deviceLine(row.adapter)
          color: row.dropped.length > 0 ? Color.urgent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      // Radio-style switch: turning one adapter on turns the other off. The row
      // owns the click, so the switch only shows the state.
      ToggleSwitch {
        id: stateSwitch
        anchors.verticalCenter: parent.verticalCenter
        interactive: false
        cursorRing: false
        checked: row.shownOn
        busy: root.busy
        foreground: root.foreground
      }
    }
  }
}
