import QtQuick
import qs.Commons

// Style 2: three big ring gauges plus a heat-map tile per core.
Column {
  id: view
  property var mon
  spacing: Style.spacing.xxl
  readonly property color muted: Util.alpha(mon.fg, 0.5)

  component Dial: Column {
    id: dial
    property real value: 0
    property real shown: 0
    property string label: ""
    property string detail: ""
    spacing: Style.spacing.sm
    width: (view.width - Style.spacing.xxl * 2) / 3

    Item {
      width: parent.width
      height: width
      Gauge {
        anchors.fill: parent
        anchors.margins: Style.space(4)
        value: dial.value
        color: view.mon.heat(dial.value)
        trackColor: Util.alpha(view.mon.fg, 0.1)
        thickness: Style.space(7)
      }
      Text {
        anchors.centerIn: parent
        text: Math.round(dial.shown * 100) + "%"
        color: view.mon.fg
        font.family: Style.font.family
        font.pixelSize: Style.font.heading
        font.bold: true
      }
    }
    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      text: dial.label
      color: view.muted
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      font.letterSpacing: 1.5
    }
    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      text: dial.detail
      color: view.mon.fg
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
    }
  }

  Row {
    spacing: Style.spacing.xxl
    Dial { value: view.mon.cpuTotal; shown: view.mon.cpuShown; label: "CPU"; detail: view.mon.cores.length + " cores" }
    Dial { value: view.mon.memUsage; shown: view.mon.memShown; label: "MEMORY"; detail: view.mon.gib(view.mon.memUsedBytes) + " / " + view.mon.gib(view.mon.memTotalBytes) }
    Dial { value: view.mon.diskUsage; shown: view.mon.diskShown; label: "DISK"; detail: view.mon.gib(view.mon.diskUsedBytes) + " / " + view.mon.gib(view.mon.diskTotalBytes) }
  }

  Flow {
    id: tiles
    width: parent.width
    spacing: Style.space(4)
    readonly property int perRow: Math.min(16, Math.max(1, view.mon.cores.length))
    readonly property real tile: (width - spacing * (perRow - 1)) / perRow
    Repeater {
      model: view.mon.cores.length
      Rectangle {
        required property int index
        readonly property real usage: view.mon.cores[index] || 0
        width: tiles.tile
        height: Style.space(10)
        radius: Style.space(3)
        color: view.mon.heat(usage)
        opacity: 0.15 + 0.85 * usage
        Behavior on opacity { NumberAnimation { duration: 600; easing.type: Easing.OutCubic } }
        Behavior on color { ColorAnimation { duration: 400 } }
      }
    }
  }
}
