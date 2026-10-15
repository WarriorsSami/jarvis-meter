import QtQuick
import QtQuick.Shapes
import qs.Commons

// Style 3: scrolling CPU history chart, then RAM/Disk meters.
Column {
  id: view
  property var mon
  spacing: Style.spacing.xxl
  readonly property color muted: Util.alpha(mon.fg, 0.5)

  Row {
    spacing: Style.spacing.md
    Text {
      id: bigPct
      text: Math.round(view.mon.cpuShown * 100) + "%"
      color: view.mon.heat(view.mon.cpuTotal)
      Behavior on color { ColorAnimation { duration: 500 } }
      font.family: Style.font.family
      font.pixelSize: Style.font.display
      font.bold: true
    }
    Text {
      id: label
      anchors.baseline: bigPct.baseline
      text: "CPU  ·  last " + Math.round(view.mon.historySize * view.mon.interval / 1000) + "s"
      color: view.muted
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
    }
  }

  Item {
    id: chart
    width: parent.width
    height: Style.space(72)
    clip: true
    readonly property var hist: view.mon.cpuHistory
    readonly property real step: width / Math.max(1, view.mon.historySize - 2)
    readonly property color line: view.mon.heat(view.mon.cpuTotal)
    onHistChanged: slide.restart()

    // Faint gridlines at 25/50/75%.
    Repeater {
      model: 3
      Rectangle {
        required property int index
        width: chart.width; height: 1
        y: Math.round(chart.height * (index + 1) / 4)
        color: Util.alpha(view.mon.fg, 0.06)
      }
    }

    function pts(closed) {
      var out = []
      var h = chart.hist, n = h.length, size = view.mon.historySize
      for (var i = 0; i < n; i++) {
        var x = (size - n + i) * chart.step
        out.push(Qt.point(x, chart.height - 1 - h[i] * (chart.height - 2)))
      }
      if (closed && n) {
        out.push(Qt.point(out[n - 1].x, chart.height))
        out.push(Qt.point(out[0].x, chart.height))
      }
      return out
    }

    // New samples slide in from the right.
    Item {
      id: strip
      width: chart.width + chart.step
      height: chart.height
      NumberAnimation on x { id: slide; from: chart.step; to: 0; duration: view.mon.interval; easing.type: Easing.Linear }

      Shape {
        anchors.fill: parent
        preferredRendererType: Shape.CurveRenderer
        ShapePath {
          strokeColor: "transparent"
          fillGradient: LinearGradient {
            x1: 0; y1: 0; x2: 0; y2: chart.height
            GradientStop { position: 0; color: Util.alpha(chart.line, 0.45) }
            GradientStop { position: 1; color: Util.alpha(chart.line, 0.0) }
          }
          PathPolyline { path: chart.pts(true) }
        }
        ShapePath {
          fillColor: "transparent"
          strokeColor: chart.line
          strokeWidth: Style.space(2)
          joinStyle: ShapePath.RoundJoin
          capStyle: ShapePath.RoundCap
          PathPolyline { path: chart.pts(false) }
        }
      }
    }

    // Glowing dot on the newest sample.
    Rectangle {
      readonly property real v: chart.hist.length ? chart.hist[chart.hist.length - 1] : 0
      width: Style.space(7); height: width; radius: width / 2
      x: chart.width - width / 2 - 1
      y: chart.height - 1 - v * (chart.height - 2) - height / 2
      color: chart.line
      Behavior on y { NumberAnimation { duration: 400; easing.type: Easing.OutCubic } }
      SequentialAnimation on scale {
        loops: Animation.Infinite
        NumberAnimation { to: 1.5; duration: 700; easing.type: Easing.InOutSine }
        NumberAnimation { to: 1.0; duration: 700; easing.type: Easing.InOutSine }
      }
    }
  }

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
