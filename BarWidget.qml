import QtQuick
import QtQuick.Shapes
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import qs.Commons
import qs.Ui

// Per-core CPU bars, RAM and disk usage. Settings (shell.json layout entry):
//   interval      - sample period in ms (default 2000)
//   disk          - mount point to report (default "/")
//   coreBarWidth  - width of each core bar in px (default 2)
//   popupStyle    - hover popup look: "hud", "combined", "dashboard", "rings" or "graph" (default "hud")
BarWidget {
  id: root
  moduleName: "io.github.warriorssami.jarvis-meter"

  readonly property int interval: setting("interval", 2000)
  readonly property string diskPath: setting("disk", "/")
  readonly property int coreBarWidth: setting("coreBarWidth", 2)
  property string styleOverride: ""   // set by the preview file
  property var previewExpand: []      // disk paths to auto-expand while previewing
  readonly property string popupStyle: styleOverride || setting("popupStyle", "hud")

  readonly property int historySize: 40
  property var cpuHistory: []
  property var coreHistory: []    // [sample][core], oldest first
  property int sampleCount: 0     // total samples taken, for stable bucketing

  property var cores: []          // per-core usage, 0..1
  property real cpuTotal: 0       // aggregate usage, 0..1
  property real memUsage: 0
  property real memUsedBytes: 0
  property real memTotalBytes: 0
  property real diskUsage: 0
  property real diskUsedBytes: 0
  property real diskTotalBytes: 0
  property var prevTimes: ({})    // "cpuN" -> { idle, total }
  // Network throughput (bytes/s), summed over physical interfaces.
  property real rxRate: 0
  property real txRate: 0
  property var rxHistory: []
  property var txHistory: []
  property var prevNet: null      // { rx, tx, t }
  property var peaks: []          // per-core peak-hold, decays each sample

  // "hud" style swaps the theme colours for a holographic cyan → amber → red.
  readonly property bool hud: popupStyle === "hud"
  readonly property color fg: hud ? "#a6ecff" : (bar ? bar.barForeground : Color.foreground)
  readonly property color hot: hud ? "#ff4b3a" : (bar ? bar.urgent : Color.urgent)
  readonly property color amber: "#ffb547"
  readonly property color accent: hud ? "#38d6ff" : fg

  function pct(v) { return Math.round(v * 100) + "%" }

  function gib(bytes) { return (bytes / 1073741824).toFixed(1) + "G" }

  function parse(output) {
    var lines = String(output || "").split("\n")
    var nextPrev = {}
    var perCore = []
    var mem = {}
    var dfLine = ""
    var netRx = 0, netTx = 0

    for (var i = 0; i < lines.length; i++) {
      var line = lines[i]
      if (line.indexOf("cpu") === 0) {
        var f = line.trim().split(/\s+/)
        var name = f[0]
        var nums = f.slice(1).map(Number)
        var idle = nums[3] + (nums[4] || 0)
        var total = 0
        // Exclude guest/guest_nice: already counted in user/nice.
        for (var j = 0; j < Math.min(nums.length, 8); j++) total += nums[j]
        var prev = prevTimes[name]
        var usage = 0
        if (prev && total > prev.total)
          usage = 1 - (idle - prev.idle) / (total - prev.total)
        usage = Math.max(0, Math.min(1, usage))
        nextPrev[name] = { idle: idle, total: total }
        if (name === "cpu") cpuTotal = usage
        else perCore[Number(name.slice(3))] = usage
      } else if (line.indexOf("Mem") === 0) {
        var m = line.match(/^(\w+):\s+(\d+)/)
        if (m) mem[m[1]] = Number(m[2]) * 1024
      } else if (line.indexOf("DF ") === 0) {
        dfLine = line
      } else if (line.indexOf("NET ") === 0) {
        // NET iface: rx_bytes 7 fields tx_bytes ...  (skip loopback and virtual bridges)
        var n = line.slice(4).match(/^\s*([^:\s]+):\s*(\d+)(?:\s+\d+){7}\s+(\d+)/)
        if (n && !/^(lo|docker|veth|br-|virbr|tailscale|wg)/.test(n[1])) {
          netRx += Number(n[2])
          netTx += Number(n[3])
        }
      }
    }

    prevTimes = nextPrev
    var now = Date.now()
    if (prevNet && now > prevNet.t) {
      var dt = (now - prevNet.t) / 1000
      rxRate = Math.max(0, (netRx - prevNet.rx) / dt)
      txRate = Math.max(0, (netTx - prevNet.tx) / dt)
      var rh = rxHistory.slice(-(historySize - 1)); rh.push(rxRate); rxHistory = rh
      var th = txHistory.slice(-(historySize - 1)); th.push(txRate); txHistory = th
    }
    prevNet = { rx: netRx, tx: netTx, t: now }
    var hist = cpuHistory.slice(-(historySize - 1))
    hist.push(cpuTotal)
    cpuHistory = hist
    var ch = coreHistory.slice(-(historySize - 1))
    ch.push(perCore)
    sampleCount++
    coreHistory = ch
    var nextPeaks = []
    for (var k = 0; k < perCore.length; k++)
      nextPeaks[k] = Math.max(perCore[k] || 0, (peaks[k] || 0) - 0.06)
    peaks = nextPeaks
    cores = perCore

    if (mem.MemTotal > 0) {
      memTotalBytes = mem.MemTotal
      memUsedBytes = mem.MemTotal - (mem.MemAvailable || 0)
      memUsage = memUsedBytes / memTotalBytes
    }

    // df -P: DF <fs> <blocks> <used> <avail> <cap> <mount>
    var d = dfLine.trim().split(/\s+/)
    if (d.length >= 5) {
      var used = Number(d[3]), avail = Number(d[4])
      if (used + avail > 0) {
        diskUsedBytes = used
        diskTotalBytes = Number(d[2])
        diskUsage = used / (used + avail)
      }
    }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Process {
    id: sampler
    command: ["sh", "-c", "cat /proc/stat /proc/meminfo; df -P -B1 -- \"$1\" | tail -n1 | sed 's/^/DF /'; sed 's/^/NET /' /proc/net/dev", "sh", root.diskPath]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.parse(text)
    }
  }

  Timer {
    interval: Math.max(500, root.interval)
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: if (!sampler.running) sampler.running = true
  }

  // Smoothed display values so numbers count up/down instead of jumping.
  property real cpuShown: cpuTotal
  property real memShown: memUsage
  property real diskShown: diskUsage
  Behavior on cpuShown { NumberAnimation { duration: 700; easing.type: Easing.OutCubic } }
  Behavior on memShown { NumberAnimation { duration: 900; easing.type: Easing.OutCubic } }
  Behavior on diskShown { NumberAnimation { duration: 900; easing.type: Easing.OutCubic } }

  // Blend fg -> hot as load climbs past ~50%.
  function mix(a, b, t) {
    return Qt.rgba(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t, 1)
  }

  // Blend fg -> hot as load climbs past ~50% (via amber in hud mode).
  function heat(v) {
    var t = Math.max(0, Math.min(1, (v - 0.5) / 0.45))
    t = t * t * (3 - 2 * t)
    if (!hud) return mix(fg, hot, t)
    return t < 0.5 ? mix(fg, amber, t * 2) : mix(amber, hot, (t - 0.5) * 2)
  }

  // Circular gauge with an icon in the middle; sweeps smoothly and pulses when hot.
  component Ring: Item {
    id: ring
    property real value: 0
    property real threshold: 0.9
    property string icon: ""
    readonly property bool isHot: value > threshold
    readonly property color tint: root.heat(value)
    readonly property real size: Math.round(root.barSize * 0.62)
    implicitWidth: size
    implicitHeight: size

    property real drawn: value
    Behavior on drawn { NumberAnimation { duration: 900; easing.type: Easing.OutCubic } }
    property color drawnColor: tint
    Behavior on drawnColor { ColorAnimation { duration: 500 } }

    Shape {
      id: gauge
      anchors.fill: parent
      preferredRendererType: Shape.CurveRenderer
      readonly property real lw: Math.max(1.5, width * 0.13)
      readonly property real r: (width - lw) / 2

      ShapePath {
        fillColor: "transparent"
        strokeColor: Util.alpha(root.fg, button.tooltipHovered ? 0.35 : 0.2)
        strokeWidth: gauge.lw
        PathAngleArc {
          centerX: gauge.width / 2; centerY: gauge.height / 2
          radiusX: gauge.r; radiusY: gauge.r
          startAngle: 0; sweepAngle: 360
        }
      }
      ShapePath {
        fillColor: "transparent"
        strokeColor: ring.drawnColor
        strokeWidth: gauge.lw
        capStyle: ShapePath.RoundCap
        PathAngleArc {
          centerX: gauge.width / 2; centerY: gauge.height / 2
          radiusX: gauge.r; radiusY: gauge.r
          startAngle: -90; sweepAngle: Math.max(0.1, 360 * ring.drawn)
        }
      }
    }

    Text {
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: ring.icon
      color: ring.drawnColor
      font.family: button.fontFamily
      font.pixelSize: Math.max(7, Math.round(ring.size * 0.48))
    }

    SequentialAnimation on opacity {
      running: ring.isHot
      loops: Animation.Infinite
      onRunningChanged: if (!running) ring.opacity = 1
      NumberAnimation { to: 0.35; duration: 600; easing.type: Easing.InOutSine }
      NumberAnimation { to: 1; duration: 600; easing.type: Easing.InOutSine }
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    labelVisible: false
    hasVisualContent: true
    tooltipText: ""
    fixedWidth: root.vertical ? -1 : content.implicitWidth + scaledHorizontalMargin * 2
    fixedHeight: root.vertical ? content.implicitHeight + scaledVerticalPadding * 2 : -1

    onPressed: function(b) {
      if (root.bar) root.bar.run("omarchy-launch-or-focus-tui btop")
    }

    Grid {
      id: content
      anchors.centerIn: parent
      flow: root.vertical ? Grid.TopToBottom : Grid.LeftToRight
      columns: root.vertical ? 1 : 3
      rows: root.vertical ? 3 : 1
      columnSpacing: Style.spacing.lg
      rowSpacing: Style.spacing.md
      horizontalItemAlignment: Grid.AlignHCenter
      verticalItemAlignment: Grid.AlignVCenter

      // Fade + slide in when the widget loads.
      opacity: 0
      transform: Translate { id: intro; y: 6 }
      Component.onCompleted: introAnim.start()
      ParallelAnimation {
        id: introAnim
        NumberAnimation { target: content; property: "opacity"; to: 1; duration: 600; easing.type: Easing.OutCubic }
        NumberAnimation { target: intro; property: "y"; to: 0; duration: 700; easing.type: Easing.OutBack }
      }

      // Per-core bars (horizontal bar) or aggregate % (vertical bar).
      Row {
        visible: !root.vertical
        spacing: 1
        height: Math.round(root.barSize * 0.55)

        Repeater {
          model: root.cores.length
          Item {
            id: core
            required property int index
            readonly property real usage: root.cores[index] || 0
            readonly property real peak: root.peaks[index] || 0
            width: root.coreBarWidth
            height: parent.height
            clip: true

            Rectangle {
              anchors.fill: parent
              color: Util.alpha(root.fg, button.tooltipHovered ? 0.3 : 0.15)
              Behavior on color { ColorAnimation { duration: 200 } }
            }

            Rectangle {
              id: fill
              anchors.bottom: parent.bottom
              width: parent.width
              height: Math.max(1, Math.round(parent.height * core.usage))
              color: root.heat(core.usage)
              // Ripple: each core starts a few ms after its neighbour.
              Behavior on height {
                SequentialAnimation {
                  PauseAnimation { duration: core.index * 18 }
                  NumberAnimation { duration: 450; easing.type: Easing.OutBack; easing.overshoot: 1.4 }
                }
              }
              Behavior on color { ColorAnimation { duration: 400 } }

              SequentialAnimation on opacity {
                running: core.usage > 0.85
                loops: Animation.Infinite
                onRunningChanged: if (!running) fill.opacity = 1
                NumberAnimation { to: 0.45; duration: 450; easing.type: Easing.InOutSine }
                NumberAnimation { to: 1; duration: 450; easing.type: Easing.InOutSine }
              }
            }

            // Peak-hold cap that slowly falls back down.
            Rectangle {
              width: parent.width
              height: 1
              y: Math.min(parent.height - 1, Math.round(parent.height * (1 - core.peak)))
              visible: core.peak > core.usage + 0.04
              color: Util.alpha(root.heat(core.peak), 0.85)
              Behavior on y { NumberAnimation { duration: 800; easing.type: Easing.OutQuad } }
            }
          }
        }
      }

      Text {
        visible: root.vertical
        textFormat: Text.PlainText
        text: "\n" + Math.round(root.cpuShown * 100)
        horizontalAlignment: Text.AlignHCenter
        color: root.heat(root.cpuTotal)
        Behavior on color { ColorAnimation { duration: 400 } }
        font.family: button.fontFamily
        font.pixelSize: Style.font.caption
      }

      Grid {
        columns: root.vertical ? 1 : 2
        columnSpacing: Style.spacing.sm
        rowSpacing: Style.spacing.xxs
        horizontalItemAlignment: Grid.AlignHCenter
        verticalItemAlignment: Grid.AlignVCenter

        Ring { value: root.memUsage; icon: "\u{f035b}" }
        Text {
          textFormat: Text.PlainText
          text: root.vertical ? Math.round(root.memShown * 100) : root.pct(root.memShown)
          color: root.heat(root.memUsage)
          Behavior on color { ColorAnimation { duration: 400 } }
          font.family: button.fontFamily
          font.pixelSize: root.vertical ? Style.font.caption : Style.font.bodySmall
        }
      }

      Grid {
        columns: root.vertical ? 1 : 2
        columnSpacing: Style.spacing.sm
        rowSpacing: Style.spacing.xxs
        horizontalItemAlignment: Grid.AlignHCenter
        verticalItemAlignment: Grid.AlignVCenter

        Ring { value: root.diskUsage; icon: "\u{f02ca}" }
        Text {
          textFormat: Text.PlainText
          text: root.vertical ? Math.round(root.diskShown * 100) : root.pct(root.diskShown)
          color: root.heat(root.diskUsage)
          Behavior on color { ColorAnimation { duration: 400 } }
          font.family: button.fontFamily
          font.pixelSize: root.vertical ? Style.font.caption : Style.font.bodySmall
        }
      }
    }
  }

  // Hover popup: opens while the pill or the card itself is hovered.
  property bool pinned: false
  property bool hoverOpen: false
  readonly property bool hovering: button.tooltipHovered || popup.containsMouse
  onHoveringChanged: {
    if (hovering) { closeDelay.stop(); hoverOpen = true }
    else closeDelay.restart()
  }
  Timer { id: closeDelay; interval: 250; onTriggered: root.hoverOpen = false }

  function close() { pinned = false; hoverOpen = false }
  readonly property bool popupOpen: popup.open

  PopupCard {
    id: popup
    anchorItem: button
    bar: root.bar
    owner: root
    triggerMode: "hover"
    open: root.pinned || root.hoverOpen
    contentWidth: root.hud ? Math.min(Style.space(1400), availableCardWidth > 0 ? availableCardWidth : Style.space(1400))
                           : Style.space(root.popupStyle === "combined" ? 650 : 340)
    padding: root.hud ? 0 : Style.spacing.popupPadding
    borderColor: root.hud ? Util.alpha(root.accent, 0.55) : Color.popups.border
    contentHeight: styleLoader.implicitHeight + verticalContentInset

    Loader {
      id: styleLoader
      width: parent.width
      readonly property url styleUrl: Qt.resolvedUrl(
          root.popupStyle === "rings" ? "PopupRings.qml"
        : root.popupStyle === "graph" ? "PopupGraph.qml"
        : root.popupStyle === "dashboard" ? "PopupDashboard.qml"
        : root.popupStyle === "combined" ? "PopupCombined.qml"
        : "PopupHud.qml")
      // Pass mon as an initial property so bindings never see it null.
      function reload() { setSource(styleUrl, { mon: root }) }
      onStyleUrlChanged: reload()
      Component.onCompleted: reload()
      onLoaded: {
        item.width = Qt.binding(function() { return styleLoader.width })
        if ("maxHeight" in item)
          item.maxHeight = Qt.binding(function() { return popup.availableCardHeight - popup.verticalContentInset })
      }
    }
  }

  // Preview: write a style name to $XDG_RUNTIME_DIR/<plugin id>.preview to
  // pin the popup open in that style on the focused monitor; delete it to stop.
  // Extra words are disk paths to auto-expand, e.g. "combined / /home".
  FileView {
    path: Quickshell.env("XDG_RUNTIME_DIR") + "/" + root.moduleName + ".preview"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      var words = text().trim().split(/\s+/)
      var name = words[0] || ""
      root.previewExpand = words.slice(1)
      root.styleOverride = name
      // Only the focused monitor's bar pins: the popout coordinator is shared,
      // so pinning on every bar would just close each other's popups.
      var win = root.QsWindow.window
      var mine = win && win.screen ? win.screen.name : ""
      var focused = Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : ""
      root.pinned = name !== "" && mine === focused
    }
    onLoadFailed: { root.styleOverride = ""; root.pinned = false; root.previewExpand = [] }
  }
}
