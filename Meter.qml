import QtQuick
import qs.Commons

// Labelled horizontal progress meter: "icon  Label ........ detail" over a bar.
Column {
  id: meter
  property var mon
  property string icon: ""
  property string label: ""
  property string detail: ""
  property real value: 0
  property real threshold: 0.9
  property int barHeight: Style.space(6)
  spacing: Style.spacing.sm

  property real shown: value
  Behavior on shown { NumberAnimation { duration: 900; easing.type: Easing.OutCubic } }

  Item {
    width: parent.width
    height: Math.max(name.implicitHeight, pct.implicitHeight)
    Text {
      id: name
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      text: meter.icon + "  " + meter.label
      color: meter.mon.fg
      font.family: Style.font.family
      font.pixelSize: Style.font.body
    }
    Text {
      id: pct
      anchors.right: parent.right
      anchors.baseline: name.baseline
      textFormat: Text.RichText
      text: "<span style='color:" + Util.alpha(meter.mon.fg, 0.5) + "'>" + meter.detail + "</span>&nbsp;&nbsp;<b>" + Math.round(meter.shown * 100) + "%</b>"
      color: meter.mon.heat(meter.value)
      font.family: Style.font.family
      font.pixelSize: Style.font.body
    }
  }

  Rectangle {
    width: parent.width
    height: meter.barHeight
    radius: height / 2
    color: Util.alpha(meter.mon.fg, 0.1)
    Rectangle {
      height: parent.height
      radius: height / 2
      width: Math.max(height, parent.width * meter.shown)
      color: meter.mon.heat(meter.value)
      Behavior on color { ColorAnimation { duration: 500 } }
      SequentialAnimation on opacity {
        running: meter.value > meter.threshold
        loops: Animation.Infinite
        onRunningChanged: if (!running) parent.opacity = 1
        NumberAnimation { to: 0.5; duration: 600; easing.type: Easing.InOutSine }
        NumberAnimation { to: 1; duration: 600; easing.type: Easing.InOutSine }
      }
    }
  }
}
