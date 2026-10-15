import QtQuick
import qs.Commons

// Style "hud": holographic diagnostics console wrapped around the combined view.
HudFrame {
  id: view
  active: mon.popupOpen

  readonly property color muted: Util.alpha(mon.fg, 0.5)
  readonly property int busiest: {
    var c = mon.cores, best = 0
    for (var i = 1; i < c.length; i++) if (c[i] > c[best]) best = i
    return best
  }
  readonly property real peak: Math.max.apply(null, mon.cpuHistory.length ? mon.cpuHistory : [0])
  property string clock: ""
  Timer {
    interval: 1000; repeat: true; triggeredOnStart: true; running: view.visible
    onTriggered: view.clock = Qt.formatTime(new Date(), "HH:mm:ss")
  }

  component Label: Text {
    color: view.muted
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
    font.letterSpacing: 2.5
  }

  Column {
    width: parent.width
    spacing: Style.spacing.xl

    // ── Title bar ───────────────────────────────────────────────────────────
    Item {
      width: parent.width
      height: titleText.implicitHeight
      Row {
        spacing: Style.spacing.md
        Text {
          text: "◢"
          color: view.mon.accent
          font.pixelSize: Style.font.caption
          anchors.verticalCenter: parent.verticalCenter
        }
        Text {
          id: titleText
          text: "SYSTEM DIAGNOSTICS"
          color: view.mon.fg
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          font.bold: true
          font.letterSpacing: 3
        }
        Label { text: "// HOLO-INTERFACE"; anchors.verticalCenter: parent.verticalCenter }
      }
      Row {
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.spacing.md
        Rectangle {
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(6); height: width; radius: width / 2
          color: view.mon.accent
          SequentialAnimation on opacity {
            loops: Animation.Infinite
            NumberAnimation { to: 0.2; duration: 700 }
            NumberAnimation { to: 1; duration: 700 }
          }
        }
        Label { text: "ONLINE · " + view.clock; color: view.mon.accent }
      }
    }
    Rectangle {
      width: parent.width
      height: 1
      gradient: Gradient {
        orientation: Gradient.Horizontal
        GradientStop { position: 0; color: Util.alpha(view.mon.accent, 0.7) }
        GradientStop { position: 1; color: "transparent" }
      }
    }

    // Two columns: CPU + memory telemetry | network + storage.
    Row {
      id: cols
      width: parent.width
      spacing: Style.space(26)
      readonly property real leftWidth: Math.round((width - spacing * 2 - 1) * 0.55)

      Column {
        id: leftCol
        width: cols.leftWidth
        spacing: Style.spacing.xl

        // ── Hero: reactor + readouts ────────────────────────────────────────────
        Row {
          width: parent.width
          spacing: Style.space(28)

          Reactor {
            width: Style.space(170)
            mon: view.mon
            value: view.mon.cpuTotal
            shown: view.mon.cpuShown
          }

          Column {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - Style.space(170) - parent.spacing
            spacing: Style.spacing.lg

            component Readout: Column {
              id: ro
              property string label: ""
              property string value: ""
              property real level: 0
              width: parent.width
              spacing: Style.spacing.xs
              Item {
                width: parent.width
                height: roValue.implicitHeight
                Label { text: ro.label; anchors.verticalCenter: parent.verticalCenter }
                Text {
                  id: roValue
                  anchors.right: parent.right
                  text: ro.value
                  color: view.mon.fg
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                  font.bold: true
                }
              }
              SegBar {
                mon: view.mon
                value: ro.level
                count: 32
                segWidth: (ro.width - spacing * (count - 1)) / count
                segHeight: Style.space(6)
              }
            }

            Readout {
              label: "CORE LOAD · PEAK " + Math.round(view.peak * 100) + "%"
              value: view.mon.cores.length + " CORES"
              level: view.mon.cpuShown
            }
            Readout {
              label: "HOTTEST CORE"
              value: "C" + ("0" + view.busiest).slice(-2) + " · " + Math.round((view.mon.cores[view.busiest] || 0) * 100) + "%"
              level: view.mon.cores[view.busiest] || 0
            }
            Readout {
              label: "MEMORY"
              value: view.mon.gib(view.mon.memUsedBytes) + " / " + view.mon.gib(view.mon.memTotalBytes)
              level: view.mon.memShown
            }
            Readout {
              label: "STORAGE " + view.mon.diskPath
              value: view.mon.gib(view.mon.diskUsedBytes) + " / " + view.mon.gib(view.mon.diskTotalBytes)
              level: view.mon.diskShown
            }
          }
        }

        // ── Detail: the combined telemetry view ─────────────────────────────────
        Row {
          width: parent.width
          spacing: Style.spacing.md
          Label { text: "CORE TELEMETRY"; color: view.mon.accent }
          Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - x
            height: 1
            color: Util.alpha(view.mon.accent, 0.25)
          }
        }

        PopupCombined {
          width: parent.width
          mon: view.mon
          showHeader: false
          showDisk: false
        }
      }

      Rectangle {
        width: 1
        height: Math.max(leftCol.height, rightCol.height)
        gradient: Gradient {
          GradientStop { position: 0; color: Util.alpha(view.mon.accent, 0.5) }
          GradientStop { position: 1; color: "transparent" }
        }
      }

      Column {
        id: rightCol
        width: cols.width - cols.leftWidth - cols.spacing * 2 - 1
        spacing: Style.spacing.xl

        component Section: Row {
          property string title: ""
          width: parent.width
          spacing: Style.spacing.md
          Label { id: secLabel; text: parent.title; color: view.mon.accent }
          Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - secLabel.width - parent.spacing
            height: 1
            color: Util.alpha(view.mon.accent, 0.25)
          }
        }

        Section { title: "NETWORK" }
        NetPanel {
          width: parent.width
          mon: view.mon
        }
        Section { title: "STORAGE" }
        DiskTree {
          width: parent.width
          mon: view.mon
        }
      }
    }
  }
}
