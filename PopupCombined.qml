import QtQuick
import QtQuick.Shapes
import qs.Commons

// Style 4: total + per-core history in one view.
//   - ranking of the busiest cores (by average over the window)
//   - chart: all-cores line plus the selected core's line
//   - per-core columns (live) with a heat-map waterfall underneath, one strip
//     per core, newest sample on top. Hover a column/strip or a chip to select.
Column {
  id: view
  required property var mon
  property bool showHeader: true
  property bool showDisk: true
  spacing: Style.spacing.xl

  readonly property color fg: mon.fg
  readonly property color muted: Util.alpha(fg, 0.5)
  readonly property var hist: mon.coreHistory        // [sample][core], oldest first
  readonly property int n: mon.cores.length
  // History waterfall: each row averages `bucket` samples so cells can be big.
  readonly property int bucket: 2
  readonly property int rows: Math.ceil(mon.historySize / bucket)
  readonly property int cell: Style.space(10)
  readonly property int rowGap: Style.space(2)

  // Per-core average and peak over the history window.
  readonly property var stats: {
    var avg = [], peak = [], h = hist
    for (var c = 0; c < n; c++) {
      var s = 0, p = 0
      for (var t = 0; t < h.length; t++) {
        var v = h[t][c] || 0
        s += v
        if (v > p) p = v
      }
      avg.push(h.length ? s / h.length : 0)
      peak.push(p)
    }
    return { avg: avg, peak: peak }
  }
  readonly property var ranking: {
    var idx = []
    for (var c = 0; c < n; c++) idx.push(c)
    var a = stats.avg
    idx.sort(function(x, y) { return a[y] - a[x] })
    return idx
  }

  property int hovered: -1
  readonly property int selected: hovered >= 0 ? hovered : (ranking.length ? ranking[0] : 0)
  readonly property real selectedNow: mon.cores[selected] || 0
  readonly property color selColor: mon.heat(Math.max(selectedNow, 0.6))

  function pct(v) { return Math.round(v * 100) + "%" }
  function css(c, a) {
    return "rgba(" + Math.round(c.r * 255) + "," + Math.round(c.g * 255) + "," + Math.round(c.b * 255) + "," + a + ")"
  }

  // ── Header ──────────────────────────────────────────────────────────────
  Item {
    visible: view.showHeader
    width: parent.width
    height: Math.max(bigPct.implicitHeight, focusCol.implicitHeight)

    Row {
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.spacing.md
      Text {
        id: bigPct
        text: view.pct(view.mon.cpuShown)
        color: view.mon.heat(view.mon.cpuTotal)
        Behavior on color { ColorAnimation { duration: 500 } }
        font.family: Style.font.family
        font.pixelSize: Style.font.display
        font.bold: true
      }
      Text {
        anchors.baseline: bigPct.baseline
        text: "CPU · " + view.n + " cores"
        color: view.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
      }
    }

    Column {
      id: focusCol
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.spacing.xxs
      Text {
        anchors.right: parent.right
        text: view.hovered >= 0 ? "SELECTED" : "BUSIEST"
        color: view.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        font.letterSpacing: 1.5
      }
      Text {
        anchors.right: parent.right
        textFormat: Text.RichText
        text: "<b>Core " + view.selected + "</b>&nbsp;&nbsp;" + view.pct(view.selectedNow)
        color: view.selColor
        Behavior on color { ColorAnimation { duration: 300 } }
        font.family: Style.font.family
        font.pixelSize: Style.font.title
      }
      Text {
        anchors.right: parent.right
        text: "avg " + view.pct(view.stats.avg[view.selected] || 0) + " · peak " + view.pct(view.stats.peak[view.selected] || 0)
        color: view.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }
    }
  }

  // ── Top cores ───────────────────────────────────────────────────────────
  Row {
    spacing: Style.spacing.sm
    Text {
      anchors.verticalCenter: parent.verticalCenter
      text: "Top"
      color: view.muted
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      rightPadding: Style.spacing.xs
    }
    Repeater {
      model: Math.min(5, view.n)
      Rectangle {
        id: chip
        required property int index
        readonly property int core: view.ranking[index]
        readonly property real avg: view.stats.avg[core] || 0
        readonly property bool active: view.selected === core
        width: chipText.implicitWidth + Style.spacing.lg * 2
        height: chipText.implicitHeight + Style.spacing.xs * 2
        radius: height / 2
        color: active ? Util.alpha(view.mon.heat(Math.max(avg, 0.6)), 0.25) : Util.alpha(view.fg, 0.07)
        border.width: active ? 1 : 0
        border.color: view.mon.heat(Math.max(avg, 0.6))
        Behavior on color { ColorAnimation { duration: 200 } }
        Text {
          id: chipText
          anchors.centerIn: parent
          textFormat: Text.RichText
          text: "<b>#" + chip.core + "</b>&nbsp;" + view.pct(chip.avg)
          color: view.fg
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
        HoverHandler {
          onHoveredChanged: view.hovered = hovered ? chip.core : -1
        }
      }
    }
  }

  // ── Chart: all cores + selected core ────────────────────────────────────
  Column {
    width: parent.width
    spacing: Style.spacing.xs

    Item {
      id: chart
      width: parent.width
      height: Style.space(91)
      clip: true
      readonly property int size: view.mon.historySize
      readonly property real step: width / Math.max(1, size - 2)
      readonly property var total: view.mon.cpuHistory
      readonly property var core: view.hist.map(function(s) { return s[view.selected] || 0 })
      onTotalChanged: slide.restart()

      function pts(series, closed) {
        var out = [], n = series.length
        for (var i = 0; i < n; i++)
          out.push(Qt.point((size - n + i) * step, height - 1 - series[i] * (height - 2)))
        if (closed && n) {
          out.push(Qt.point(out[n - 1].x, height))
          out.push(Qt.point(out[0].x, height))
        }
        return out
      }

      Repeater {
        model: 3
        Rectangle {
          required property int index
          width: chart.width; height: 1
          y: Math.round(chart.height * (index + 1) / 4)
          color: Util.alpha(view.fg, 0.06)
        }
      }

      Item {
        width: chart.width + chart.step
        height: chart.height
        NumberAnimation on x { id: slide; from: chart.step; to: 0; duration: view.mon.interval }

        Shape {
          anchors.fill: parent
          preferredRendererType: Shape.CurveRenderer
          // All cores: soft filled area.
          ShapePath {
            strokeColor: "transparent"
            fillGradient: LinearGradient {
              x1: 0; y1: 0; x2: 0; y2: chart.height
              GradientStop { position: 0; color: Util.alpha(view.fg, 0.28) }
              GradientStop { position: 1; color: Util.alpha(view.fg, 0.0) }
            }
            PathPolyline { path: chart.pts(chart.total, true) }
          }
          ShapePath {
            fillColor: "transparent"
            strokeColor: Util.alpha(view.fg, 0.7)
            strokeWidth: Style.space(1.5)
            joinStyle: ShapePath.RoundJoin
            PathPolyline { path: chart.pts(chart.total, false) }
          }
          // Selected core: bold coloured line.
          ShapePath {
            fillColor: "transparent"
            strokeColor: view.selColor
            strokeWidth: Style.space(2)
            joinStyle: ShapePath.RoundJoin
            capStyle: ShapePath.RoundCap
            PathPolyline { path: chart.pts(chart.core, false) }
          }
        }
      }

      Rectangle {
        readonly property real v: chart.core.length ? chart.core[chart.core.length - 1] : 0
        width: Style.space(7); height: width; radius: width / 2
        x: chart.width - width / 2 - 1
        y: chart.height - 1 - v * (chart.height - 2) - height / 2
        color: view.selColor
        Behavior on y { NumberAnimation { duration: 400; easing.type: Easing.OutCubic } }
        SequentialAnimation on scale {
          loops: Animation.Infinite
          NumberAnimation { to: 1.5; duration: 700; easing.type: Easing.InOutSine }
          NumberAnimation { to: 1.0; duration: 700; easing.type: Easing.InOutSine }
        }
      }
    }

    // Legend.
    Row {
      spacing: Style.spacing.lg
      Row {
        spacing: Style.spacing.xs
        Rectangle { anchors.verticalCenter: parent.verticalCenter; width: Style.space(12); height: Style.space(2); radius: 1; color: Util.alpha(view.fg, 0.7) }
        Text { text: "all cores"; color: view.muted; font.family: Style.font.family; font.pixelSize: Style.font.caption }
      }
      Row {
        spacing: Style.spacing.xs
        Rectangle { anchors.verticalCenter: parent.verticalCenter; width: Style.space(12); height: Style.space(2); radius: 1; color: view.selColor }
        Text { text: "core " + view.selected; color: view.muted; font.family: Style.font.family; font.pixelSize: Style.font.caption }
      }
      Text {
        text: "last " + Math.round(view.mon.historySize * view.mon.interval / 1000) + "s"
        color: view.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }
    }
  }

  // ── Per-core columns + history waterfall (aligned per core) ─────────────
  Item {
    id: cores
    width: parent.width
    height: coreCol.implicitHeight
    readonly property real gap: Style.space(3)
    readonly property real colW: (width - gap * (view.n - 1)) / Math.max(1, view.n)

    Column {
      id: coreCol
      width: parent.width
      spacing: Style.spacing.sm

      // Live usage per core.
      Row {
        id: coreRow
        width: parent.width
        height: Style.space(52)
        spacing: cores.gap
        Repeater {
          model: view.n
          Rectangle {
            id: col
            required property int index
            readonly property real usage: view.mon.cores[index] || 0
            readonly property bool isSel: view.selected === index
            width: cores.colW
            height: coreRow.height
            radius: Math.min(width / 2, Style.space(3))
            color: Util.alpha(view.fg, isSel ? 0.2 : 0.08)
            opacity: view.hovered < 0 || isSel ? 1 : 0.45
            Behavior on opacity { NumberAnimation { duration: 200 } }
            Behavior on color { ColorAnimation { duration: 200 } }
            clip: true
            Rectangle {
              anchors.bottom: parent.bottom
              width: parent.width
              radius: parent.radius
              height: Math.max(2, parent.height * col.usage)
              color: view.mon.heat(col.usage)
              Behavior on height {
                SequentialAnimation {
                  PauseAnimation { duration: col.index * 12 }
                  NumberAnimation { duration: 450; easing.type: Easing.OutBack; easing.overshoot: 1.2 }
                }
              }
              Behavior on color { ColorAnimation { duration: 400 } }
            }
          }
        }
      }

      // Core number under each column.
      Row {
        width: parent.width
        spacing: cores.gap
        Repeater {
          model: view.n
          Text {
            required property int index
            readonly property bool isSel: view.selected === index
            width: cores.colW
            horizontalAlignment: Text.AlignHCenter
            text: index
            color: isSel ? view.selColor : (view.hovered < 0 ? view.muted : Util.alpha(view.fg, 0.3))
            Behavior on color { ColorAnimation { duration: 200 } }
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            font.bold: isSel
            scale: isSel ? 1.25 : 1
            Behavior on scale { NumberAnimation { duration: 200; easing.type: Easing.OutBack } }
          }
        }
      }

      // History: one strip per core under its column, newest row on top.
      Item {
        id: fall
        width: parent.width
        height: view.rows * view.cell - view.rowGap
        clip: true
        onWidthChanged: canvas.requestPaint()

        Canvas {
          id: canvas
          width: parent.width
          height: parent.height + view.cell
          y: 0
          onAvailableChanged: requestPaint()
          Connections {
            target: view
            function onHistChanged() {
              canvas.requestPaint()
              // Slide down only when a new row starts.
              if ((view.mon.sampleCount - 1) % view.bucket === 0) scroll.restart()
            }
            function onSelectedChanged() { canvas.requestPaint() }
          }
          NumberAnimation on y { id: scroll; from: -view.cell; to: 0; duration: 450; easing.type: Easing.OutCubic }

          onPaint: {
            var ctx = getContext("2d")
            ctx.reset()
            var h = view.hist, cw = cores.colW, gap = cores.gap
            var cell = view.cell, ch = cell - view.rowGap, rad = Math.min(Style.space(2.5), cw / 3)
            // Bucket samples by absolute index so rows don't jitter as history slides.
            var total = view.mon.sampleCount, first = total - h.length
            var newest = Math.floor((total - 1) / view.bucket)
            var sums = [], counts = []
            for (var i = 0; i < h.length; i++) {
              var r = newest - Math.floor((first + i) / view.bucket)
              if (r < 0 || r >= view.rows) continue
              if (!sums[r]) { sums[r] = []; counts[r] = 0 }
              counts[r]++
              for (var c = 0; c < view.n; c++) sums[r][c] = (sums[r][c] || 0) + (h[i][c] || 0)
            }
            for (r = 0; r < view.rows; r++) {
              if (!counts[r]) continue
              var y = r * cell
              for (c = 0; c < view.n; c++) {
                var v = sums[r][c] / counts[r]
                ctx.fillStyle = view.css(view.mon.heat(v), 0.07 + 0.93 * Math.pow(v, 0.8))
                ctx.beginPath()
                ctx.roundedRect(c * (cw + gap), y, cw, ch, rad, rad)
                ctx.fill()
              }
            }
            // Outline the selected core's strip.
            var filled = counts.length
            if (filled) {
              ctx.strokeStyle = view.css(view.selColor, 0.9)
              ctx.lineWidth = Style.space(1.5)
              ctx.beginPath()
              ctx.roundedRect(view.selected * (cw + gap) - 1.5, -1.5, cw + 3, filled * cell - view.rowGap + 3, rad + 1, rad + 1)
              ctx.stroke()
            }
          }
        }
      }

      Item {
        width: parent.width
        height: axisL.implicitHeight
        Text {
          id: axisL
          text: "↑ now"
          color: view.muted
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
        Text {
          anchors.horizontalCenter: parent.horizontalCenter
          text: "hover a core to follow it"
          color: Util.alpha(view.fg, 0.35)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
        Text {
          anchors.right: parent.right
          text: Math.round(view.mon.historySize * view.mon.interval / 1000) + "s ago ↓"
          color: view.muted
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }
    }

    HoverHandler {
      id: coreHover
      onHoveredChanged: if (!hovered) view.hovered = -1
      onPointChanged: {
        if (!hovered) return
        var c = Math.floor(point.position.x / (cores.colW + cores.gap))
        view.hovered = Math.max(0, Math.min(view.n - 1, c))
      }
    }
  }

  Rectangle { width: parent.width; height: 1; color: Util.alpha(view.fg, 0.1) }

  MemTree {
    width: parent.width
    mon: view.mon
  }
  DiskTree {
    visible: view.showDisk
    width: parent.width
    mon: view.mon
  }
}
