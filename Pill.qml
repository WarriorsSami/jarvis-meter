import QtQuick
import qs.Commons

// Small rounded button used by the confirm strips. `progress` (0..1) fills it,
// for press-and-hold actions.
Rectangle {
  id: pill
  property string label: ""
  property color fg: Color.foreground
  property color tint: fg
  property bool strong: false
  property real progress: 0
  property alias pressed: pillArea.pressed
  signal activated()

  width: pillText.implicitWidth + Style.spacing.lg * 2
  height: Style.space(20)
  radius: height / 2
  color: Util.alpha(tint, pillArea.containsMouse ? (strong ? 0.35 : 0.18) : (strong ? 0.22 : 0.1))
  border.width: 1
  border.color: Util.alpha(tint, 0.5)
  clip: true
  Behavior on color { ColorAnimation { duration: 120 } }

  Rectangle {
    width: parent.width * pill.progress
    height: parent.height
    color: Util.alpha(pill.tint, 0.55)
  }
  Text {
    id: pillText
    anchors.centerIn: parent
    text: pill.label
    color: pill.strong ? pill.tint : pill.fg
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
    font.bold: pill.strong
  }
  MouseArea {
    id: pillArea
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: pill.activated()
  }
}
