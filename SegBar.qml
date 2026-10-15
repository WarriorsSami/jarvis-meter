import QtQuick
import qs.Commons

// Segmented level meter; lit segments take the heat colour of their position.
Row {
  id: seg
  required property var mon
  property real value: 0
  property int count: 20
  property real segWidth: Style.space(6)
  property real segHeight: Style.space(8)
  spacing: Style.space(2)

  Repeater {
    model: seg.count
    Rectangle {
      required property int index
      readonly property bool lit: (index + 0.5) / seg.count <= seg.value
      width: seg.segWidth
      height: seg.segHeight
      radius: 1
      color: lit ? seg.mon.heat(Math.max(0.5, (index + 1) / seg.count)) : Util.alpha(seg.mon.fg, 0.08)
      Behavior on color { ColorAnimation { duration: 250 } }
    }
  }
}
