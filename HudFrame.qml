import QtQuick
import qs.Commons

// Holographic panel: dark glass, faint grid, corner brackets, a scanning line,
// and a boot sequence (brackets expand, content flickers on) each time it opens.
Item {
  id: frame
  required property var mon
  property bool active: true
  default property alias content: inner.data
  property int pad: Style.space(20)
  property real maxHeight: Infinity     // content scrolls inside the frame past this
  readonly property color glow: mon.accent

  implicitHeight: Math.min(inner.childrenRect.height + pad * 2, maxHeight)

  property real spread: 1      // 0 = brackets collapsed at centre, 1 = at corners
  property real reveal: 1      // portion of the content revealed top→bottom

  onActiveChanged: if (active) boot.restart()
  Component.onCompleted: boot.restart()

  SequentialAnimation {
    id: boot
    ScriptAction { script: { frame.spread = 0; frame.reveal = 0; inner.opacity = 0 } }
    NumberAnimation { target: frame; property: "spread"; to: 1; duration: 420; easing.type: Easing.OutCubic }
    ParallelAnimation {
      NumberAnimation { target: frame; property: "reveal"; to: 1; duration: 520; easing.type: Easing.OutQuad }
      SequentialAnimation {
        NumberAnimation { target: inner; property: "opacity"; to: 0.75; duration: 50 }
        NumberAnimation { target: inner; property: "opacity"; to: 0.15; duration: 60 }
        NumberAnimation { target: inner; property: "opacity"; to: 0.9; duration: 50 }
        NumberAnimation { target: inner; property: "opacity"; to: 0.35; duration: 40 }
        NumberAnimation { target: inner; property: "opacity"; to: 1; duration: 160 }
      }
    }
  }

  // Glass.
  Rectangle {
    anchors.fill: parent
    gradient: Gradient {
      GradientStop { position: 0; color: Qt.rgba(0.02, 0.10, 0.15, 0.97) }
      GradientStop { position: 1; color: Qt.rgba(0.01, 0.04, 0.08, 0.97) }
    }
  }

  // Grid.
  Canvas {
    id: grid
    anchors.fill: parent
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()
    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      var step = Style.space(24), g = frame.glow
      ctx.strokeStyle = "rgba(" + Math.round(g.r * 255) + "," + Math.round(g.g * 255) + "," + Math.round(g.b * 255) + ",0.05)"
      ctx.lineWidth = 1
      ctx.beginPath()
      for (var x = 0.5; x < width; x += step) { ctx.moveTo(x, 0); ctx.lineTo(x, height) }
      for (var y = 0.5; y < height; y += step) { ctx.moveTo(0, y); ctx.lineTo(width, y) }
      ctx.stroke()
    }
  }

  // Scanning line with a fading trail.
  Item {
    id: scan
    width: parent.width
    height: Style.space(60)
    opacity: 0.8
    Rectangle {
      anchors.fill: parent
      gradient: Gradient {
        GradientStop { position: 0; color: "transparent" }
        GradientStop { position: 1; color: Util.alpha(frame.glow, 0.06) }
      }
    }
    Rectangle {
      anchors.bottom: parent.bottom
      width: parent.width
      height: 1
      gradient: Gradient {
        orientation: Gradient.Horizontal
        GradientStop { position: 0; color: "transparent" }
        GradientStop { position: 0.5; color: Util.alpha(frame.glow, 0.5) }
        GradientStop { position: 1; color: "transparent" }
      }
    }
    NumberAnimation on y {
      from: -scan.height; to: frame.height
      duration: 4200; loops: Animation.Infinite
      running: frame.visible
    }
  }

  // Content, revealed top→bottom during boot; scrolls if taller than the frame.
  Flickable {
    id: body
    x: frame.pad
    y: frame.pad
    width: frame.width - frame.pad * 2
    height: (frame.height - frame.pad * 2) * frame.reveal
    contentHeight: inner.childrenRect.height
    interactive: contentHeight > frame.height - frame.pad * 2
    boundsBehavior: Flickable.StopAtBounds
    clip: true
    Item {
      id: inner
      width: body.width
      height: childrenRect.height
    }
  }
  Rectangle {
    visible: body.interactive
    x: frame.width - frame.pad / 2 - width / 2
    y: frame.pad + body.visibleArea.yPosition * body.height
    width: Style.space(3)
    height: body.visibleArea.heightRatio * body.height
    radius: width / 2
    color: Util.alpha(frame.glow, 0.5)
  }
  // Bright edge riding the reveal.
  Rectangle {
    visible: frame.reveal > 0 && frame.reveal < 1
    x: frame.pad
    y: frame.pad + (frame.height - frame.pad * 2) * frame.reveal
    width: frame.width - frame.pad * 2
    height: 2
    color: frame.glow
    opacity: 0.8
  }

  // Corner brackets.
  component Bracket: Item {
    id: br
    property bool atRight: false
    property bool atBottom: false
    readonly property real len: Style.space(22)
    readonly property real th: Style.space(2)
    width: len; height: len
    x: (frame.width - len) / 2 + ((atRight ? frame.width - len - Style.space(6) : Style.space(6)) - (frame.width - len) / 2) * frame.spread
    y: (frame.height - len) / 2 + ((atBottom ? frame.height - len - Style.space(6) : Style.space(6)) - (frame.height - len) / 2) * frame.spread
    Rectangle { width: br.len; height: br.th; y: br.atBottom ? br.len - br.th : 0; color: frame.glow }
    Rectangle { width: br.th; height: br.len; x: br.atRight ? br.len - br.th : 0; color: frame.glow }
  }
  Bracket {}
  Bracket { atRight: true }
  Bracket { atBottom: true }
  Bracket { atRight: true; atBottom: true }

  // Edge ticks along the top and bottom.
  Repeater {
    model: 24
    Rectangle {
      required property int index
      x: Style.space(40) + index * (frame.width - Style.space(80)) / 23
      y: Style.space(6)
      width: 1
      height: index % 6 === 0 ? Style.space(6) : Style.space(3)
      color: Util.alpha(frame.glow, 0.45)
      opacity: frame.spread
    }
  }
}
