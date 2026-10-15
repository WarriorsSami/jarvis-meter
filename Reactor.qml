import QtQuick
import QtQuick.Shapes
import QtQuick.Effects
import qs.Commons

// Arc-reactor style CPU gauge: lit tick ring, glowing load arc, and
// counter-rotating segment rings around a breathing core.
Item {
  id: rx
  required property var mon
  property real value: 0
  property real shown: value
  property string label: "CPU"
  readonly property color glow: mon.accent
  readonly property color tint: mon.heat(value)
  readonly property real s: width
  implicitWidth: Style.space(160)
  implicitHeight: width

  layer.enabled: true
  layer.effect: MultiEffect {
    shadowEnabled: true
    shadowColor: rx.glow
    shadowBlur: 0.7
    shadowOpacity: 0.8
    shadowHorizontalOffset: 0
    shadowVerticalOffset: 0
    blurMax: 24
  }

  // Tick ring: 60 ticks, lit up to the current load.
  Repeater {
    model: 60
    Item {
      required property int index
      width: rx.s; height: rx.s
      rotation: index * 6
      readonly property bool lit: index / 60 < rx.shown
      Rectangle {
        x: (rx.s - width) / 2
        y: 0
        width: Style.space(2)
        height: index % 5 === 0 ? rx.s * 0.075 : rx.s * 0.045
        radius: 1
        color: parent.lit ? rx.mon.heat(Math.max(0.5, index / 60)) : Util.alpha(rx.glow, 0.15)
        Behavior on color { ColorAnimation { duration: 200 } }
      }
    }
  }

  // Slow dashed outer ring.
  Shape {
    anchors.fill: parent
    preferredRendererType: Shape.CurveRenderer
    RotationAnimation on rotation { from: 0; to: 360; duration: 40000; loops: Animation.Infinite }
    ShapePath {
      fillColor: "transparent"
      strokeColor: Util.alpha(rx.glow, 0.45)
      strokeWidth: Style.space(1.5)
      strokeStyle: ShapePath.DashLine
      dashPattern: [2, 4]
      PathAngleArc { centerX: rx.s / 2; centerY: rx.s / 2; radiusX: rx.s * 0.40; radiusY: rx.s * 0.40; startAngle: 0; sweepAngle: 360 }
    }
  }

  // Load arc.
  Gauge {
    anchors.centerIn: parent
    width: rx.s * 0.70
    value: rx.value
    color: rx.tint
    trackColor: Util.alpha(rx.glow, 0.10)
    thickness: Style.space(7)
  }

  // Counter-rotating segments.
  Shape {
    anchors.fill: parent
    preferredRendererType: Shape.CurveRenderer
    RotationAnimation on rotation { from: 360; to: 0; duration: 9000 - 6000 * rx.value; loops: Animation.Infinite }
    ShapePath {
      fillColor: "transparent"
      strokeColor: Util.alpha(rx.glow, 0.7)
      strokeWidth: Style.space(2)
      capStyle: ShapePath.FlatCap
      PathAngleArc { centerX: rx.s / 2; centerY: rx.s / 2; radiusX: rx.s * 0.27; radiusY: rx.s * 0.27; startAngle: 0; sweepAngle: 70 }
      PathMove { x: rx.s / 2 + rx.s * 0.27 * Math.cos(Math.PI * 120 / 180); y: rx.s / 2 + rx.s * 0.27 * Math.sin(Math.PI * 120 / 180) }
      PathAngleArc { centerX: rx.s / 2; centerY: rx.s / 2; radiusX: rx.s * 0.27; radiusY: rx.s * 0.27; startAngle: 120; sweepAngle: 70 }
      PathMove { x: rx.s / 2 + rx.s * 0.27 * Math.cos(Math.PI * 240 / 180); y: rx.s / 2 + rx.s * 0.27 * Math.sin(Math.PI * 240 / 180) }
      PathAngleArc { centerX: rx.s / 2; centerY: rx.s / 2; radiusX: rx.s * 0.27; radiusY: rx.s * 0.27; startAngle: 240; sweepAngle: 70 }
    }
  }

  // Breathing core (faster under load).
  Rectangle {
    id: core
    anchors.centerIn: parent
    width: rx.s * 0.40
    height: width
    radius: width / 2
    color: Util.alpha(rx.glow, 0.06)
    border.width: 1
    border.color: Util.alpha(rx.glow, 0.35)
    SequentialAnimation on scale {
      loops: Animation.Infinite
      NumberAnimation { to: 1.06; duration: 1800 - 1300 * rx.value; easing.type: Easing.InOutSine }
      NumberAnimation { to: 1.0; duration: 1800 - 1300 * rx.value; easing.type: Easing.InOutSine }
    }
  }

  Column {
    anchors.centerIn: parent
    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      text: Math.round(rx.shown * 100) + "%"
      color: rx.mon.fg
      font.family: Style.font.family
      font.pixelSize: Style.font.display
      font.bold: true
    }
    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      text: rx.label
      color: Util.alpha(rx.glow, 0.8)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      font.letterSpacing: 3
    }
  }
}
