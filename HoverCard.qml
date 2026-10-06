import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// The card shown while the pointer rests on the bar icon: what is on right now
// (the active adapter and the devices connected to it) and anything that went
// wrong. Everything else lives in the click panel.
//
// It is its own small popup rather than a PopupCard: PopupCard registers with
// the bar's popout coordinator, so a hover would close whatever panel is open
// and releasing it would drop the click panel's registration.
PopupWindow {
  id: root

  property Item anchorItem: null
  property var bar: null
  property var host: null
  property bool open: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color dim: Qt.darker(foreground, 1.6)
  readonly property int margin: Style.gapsOut
  readonly property int padding: Style.spacing.popupPadding
  readonly property var borderSpec: Border.localOrSurfaceSpec("popups", "border", Color.popups.border, Color.popups.border, Math.max(1, Style.space(2)))

  readonly property var adapters: host ? host.adapters : []
  readonly property var live: {
    var out = []
    for (var i = 0; i < adapters.length; i++)
      if (adapters[i].powered && !adapters[i].blocked) out.push(adapters[i])
    return out
  }
  // Adapters that are off: worth a line each so it is clear what a switch would
  // leave behind (and what is paired there).
  readonly property var standby: {
    var out = []
    for (var i = 0; i < adapters.length; i++)
      if (!(adapters[i].powered && !adapters[i].blocked)) out.push(adapters[i])
    return out
  }
  readonly property string errorLine: host && host.lastError !== "" ? host.lastError.split("\n")[0] : ""
  readonly property string note: {
    if (!host) return ""
    if (host.busy) return "Working…"
    if (host.scanning !== "") return "Scanning for devices…"
    return ""
  }
  readonly property string emptyText: {
    if (!host || !host.loaded) return "Reading adapters…"
    if (adapters.length === 0) return "No Bluetooth adapter found"
    if (live.length === 0) return "Bluetooth is off"
    return ""
  }

  function connected(a) {
    var out = []
    var list = a.devices || []
    for (var i = 0; i < list.length; i++) if (list[i].connected) out.push(list[i])
    return out
  }
  function pairedCount(a) { return (a.devices || []).length }
  function standbyText(a) {
    var n = pairedCount(a)
    return (host ? host.nameFor(a) : a.hci) + " is off" + (n > 0 ? ", " + n + (n === 1 ? " device" : " devices") + " paired" : "")
  }
  function hasBattery(d) { return d.battery !== null && d.battery !== undefined }

  color: "transparent"
  visible: open || card.opacity > 0
  implicitWidth: Style.space(250)
  implicitHeight: column.implicitHeight + card.contentTopInset + card.contentBottomInset
  // Purely informational: let the pointer reach what is underneath.
  mask: Region {}

  anchor {
    id: popupAnchor
    window: anchorItem ? anchorItem.QsWindow.window : null
    adjustment: PopupAdjustment.Slide
    edges: Edges.Top | Edges.Left
    gravity: Edges.Bottom | Edges.Right
    rect.width: 1
    rect.height: 1

    onAnchoring: {
      var window = root.anchorItem ? root.anchorItem.QsWindow.window : null
      if (!window || !root.bar) return
      var t = root.anchorItem
      var w = root.implicitWidth
      var h = root.implicitHeight
      var x = t.width / 2 - w / 2
      var y = t.height + root.margin
      if (root.bar.position === "bottom") y = -h - root.margin
      else if (root.bar.position === "left") { x = t.width + root.margin; y = t.height / 2 - h / 2 }
      else if (root.bar.position === "right") { x = -w - root.margin; y = t.height / 2 - h / 2 }
      var p = window.contentItem.mapFromItem(t, x, y)
      if (root.bar.position === "top" || root.bar.position === "bottom")
        p.x = Math.max(root.margin, Math.min(p.x, window.width - w - root.margin))
      else
        p.y = Math.max(root.margin, Math.min(p.y, window.height - h - root.margin))
      popupAnchor.rect.x = Math.round(p.x)
      popupAnchor.rect.y = Math.round(p.y)
    }
  }

  BorderSurface {
    id: card
    anchors.fill: parent
    color: Color.popups.background
    borderSpec: root.borderSpec
    padding: root.padding
    radius: Style.cornerRadius
    opacity: root.open ? 1.0 : 0

    Behavior on opacity {
      NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
    }

    Column {
      id: column
      anchors.fill: parent
      anchors.topMargin: card.contentTopInset
      anchors.rightMargin: card.contentRightInset
      anchors.bottomMargin: card.contentBottomInset
      anchors.leftMargin: card.contentLeftInset
      spacing: Style.space(10)

      // A failure, where it cannot be missed.
      Rectangle {
        visible: root.errorLine !== ""
        width: parent.width
        height: visible ? errorText.implicitHeight + Style.space(12) : 0
        radius: Style.cornerRadius
        color: Qt.rgba(Color.urgent.r, Color.urgent.g, Color.urgent.b, 0.16)
        border.width: 1
        border.color: Qt.rgba(Color.urgent.r, Color.urgent.g, Color.urgent.b, 0.5)

        Text {
          id: errorText
          anchors.fill: parent
          anchors.margins: Style.space(6)
          textFormat: Text.PlainText
          wrapMode: Text.Wrap
          text: root.errorLine
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
      }

      Text {
        visible: root.emptyText !== ""
        width: parent.width
        textFormat: Text.PlainText
        wrapMode: Text.Wrap
        text: root.emptyText
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }

      Text {
        visible: root.live.length > 1
        width: parent.width
        textFormat: Text.PlainText
        wrapMode: Text.Wrap
        text: root.live.length + " adapters are on; settling on one"
        color: Color.urgent
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }

      Repeater {
        model: root.live

        Column {
          id: block
          required property var modelData
          readonly property var devices: root.connected(modelData)
          readonly property int paired: root.pairedCount(modelData)
          readonly property int idle: paired - devices.length
          width: column.width
          spacing: Style.space(6)

          Row {
            spacing: Style.space(8)

            Rectangle {
              width: Style.space(8)
              height: width
              radius: width / 2
              anchors.verticalCenter: title.verticalCenter
              color: root.foreground
            }

            Column {
              id: title
              spacing: Style.space(1)

              Text {
                textFormat: Text.PlainText
                text: root.host ? root.host.nameFor(block.modelData) : block.modelData.hci
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.subtitle
                font.bold: true
              }
              Text {
                visible: block.modelData.model !== ""
                textFormat: Text.PlainText
                text: block.modelData.model
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
            }
          }

          Text {
            visible: block.devices.length === 0
            leftPadding: Style.space(16)
            textFormat: Text.PlainText
            text: block.paired === 0 ? "No paired devices"
              : "Nothing connected, " + block.paired + (block.paired === 1 ? " device" : " devices") + " paired"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }

          Repeater {
            model: block.devices

            Item {
              id: line
              required property var modelData
              readonly property bool hasBat: root.hasBattery(modelData)
              readonly property int level: hasBat ? Math.max(0, Math.min(100, Number(modelData.battery))) : 0
              readonly property bool low: hasBat && level <= (host ? host.lowBatteryLevel : 20)

              width: block.width
              height: Math.max(name.implicitHeight, gauge.height)

              Text {
                id: name
                anchors.left: parent.left
                anchors.leftMargin: Style.space(16)
                anchors.right: gauge.visible ? gauge.left : parent.right
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                elide: Text.ElideRight
                text: line.modelData.name
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }

              // Battery: a short gauge and the number, urgent when low.
              Row {
                id: gauge
                visible: line.hasBat
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(6)

                Rectangle {
                  width: Style.space(34)
                  height: Style.space(4)
                  radius: height / 2
                  anchors.verticalCenter: parent.verticalCenter
                  color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.18)

                  Rectangle {
                    width: parent.width * line.level / 100
                    height: parent.height
                    radius: parent.radius
                    color: line.low ? Color.urgent : root.foreground
                  }
                }
                Text {
                  width: Style.space(30)
                  horizontalAlignment: Text.AlignRight
                  textFormat: Text.PlainText
                  text: line.level + "%"
                  color: line.low ? Color.urgent : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.bold: line.low
                }
              }
            }
          }

          Text {
            visible: block.devices.length > 0 && block.idle > 0
            leftPadding: Style.space(16)
            textFormat: Text.PlainText
            text: "+" + block.idle + " paired, not connected"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }
      }

      Text {
        visible: root.standby.length > 0 && root.adapters.length > 1
        width: parent.width
        textFormat: Text.PlainText
        wrapMode: Text.Wrap
        text: {
          var out = []
          for (var i = 0; i < root.standby.length; i++) out.push(root.standbyText(root.standby[i]))
          return out.join("\n")
        }
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }

      Text {
        visible: root.note !== ""
        width: parent.width
        textFormat: Text.PlainText
        text: root.note
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }
    }
  }
}
