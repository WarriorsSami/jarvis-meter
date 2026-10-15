import QtQuick
import qs.Commons

// Style 1: big CPU number, a column per core, then RAM/Disk meters.
Column {
  id: view
  property var mon
  spacing: Style.spacing.xxl
  readonly property color muted: Util.alpha(mon.fg, 0.5)

  Item {
    width: parent.width
    height: big.implicitHeight
    Column {
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.spacing.xxs
      Text {
        text: "PROCESSOR"
        color: view.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        font.letterSpacing: 1.5
      }
      Text {
        text: view.mon.cores.length + " cores"
        color: view.mon.fg
        font.family: Style.font.family
        font.pixelSize: Style.font.body
      }
    }
    Text {
      id: big
      anchors.right: parent.right
      text: Math.round(view.mon.cpuShown * 100) + "%"
      color: view.mon.heat(view.mon.cpuTotal)
      Behavior on color { ColorAnimation { duration: 500 } }
      font.family: Style.font.family
      font.pixelSize: Style.font.displayLarge
      font.bold: true
    }
  }

  Row {
    id: coreRow
    width: parent.width
    height: Style.space(56)
    spacing: Style.space(3)
    readonly property int n: Math.max(1, view.mon.cores.length)
    Repeater {
      model: view.mon.cores.length
      Rectangle {
        id: col
        required property int index
        readonly property real usage: view.mon.cores[index] || 0
        width: (coreRow.width - coreRow.spacing * (coreRow.n - 1)) / coreRow.n
        height: coreRow.height
        radius: Math.min(width / 2, Style.space(3))
        color: Util.alpha(view.mon.fg, 0.08)
        clip: true
        Rectangle {
          anchors.bottom: parent.bottom
          width: parent.width
          radius: parent.radius
          height: Math.max(2, parent.height * col.usage)
          color: view.mon.heat(col.usage)
          Behavior on height {
            SequentialAnimation {
              PauseAnimation { duration: col.index * 15 }
              NumberAnimation { duration: 500; easing.type: Easing.OutBack; easing.overshoot: 1.2 }
            }
          }
          Behavior on color { ColorAnimation { duration: 400 } }
        }
      }
    }
  }

  Rectangle { width: parent.width; height: 1; color: Util.alpha(view.mon.fg, 0.1) }

  Meter {
    width: parent.width
    mon: view.mon
    icon: "\u{f035b}"
    label: "Memory"
    detail: view.mon.gib(view.mon.memUsedBytes) + " / " + view.mon.gib(view.mon.memTotalBytes)
    value: view.mon.memUsage
  }
  Meter {
    width: parent.width
    mon: view.mon
    icon: "\u{f02ca}"
    label: "Disk " + view.mon.diskPath
    detail: view.mon.gib(view.mon.diskUsedBytes) + " / " + view.mon.gib(view.mon.diskTotalBytes)
    value: view.mon.diskUsage
  }
}
