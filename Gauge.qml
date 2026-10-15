import QtQuick
import QtQuick.Shapes
import qs.Commons

// Animated circular gauge used by the popup styles.
Item {
  id: gauge
  property real value: 0
  property color color: Color.foreground
  property color trackColor: Util.alpha(Color.foreground, 0.12)
  property real thickness: Math.max(2, width * 0.09)
  property real drawn: value
  property color drawnColor: color
  Behavior on drawn { NumberAnimation { duration: 900; easing.type: Easing.OutCubic } }
  Behavior on drawnColor { ColorAnimation { duration: 500 } }

  readonly property real r: (width - thickness) / 2
  implicitWidth: 80
  implicitHeight: width

  Shape {
    anchors.fill: parent
    preferredRendererType: Shape.CurveRenderer
    ShapePath {
      fillColor: "transparent"
      strokeColor: gauge.trackColor
      strokeWidth: gauge.thickness
      PathAngleArc {
        centerX: gauge.width / 2; centerY: gauge.height / 2
        radiusX: gauge.r; radiusY: gauge.r
        startAngle: 0; sweepAngle: 360
      }
    }
    ShapePath {
      fillColor: "transparent"
      strokeColor: gauge.drawnColor
      strokeWidth: gauge.thickness
      capStyle: ShapePath.RoundCap
      PathAngleArc {
        centerX: gauge.width / 2; centerY: gauge.height / 2
        radiusX: gauge.r; radiusY: gauge.r
        startAngle: -90; sweepAngle: Math.max(0.1, 360 * gauge.drawn)
      }
    }
  }
}
