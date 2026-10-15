import QtQuick
import Quickshell.Io
import qs.Commons

// Collapsible memory view. The header shows used / total RAM; expanding it
// lists processes by resident memory (RSS), refreshed live, loading more as
// you scroll. Your own processes can be ended (SIGTERM) or, by press-and-hold,
// force-killed (SIGKILL). Core session processes are locked.
Column {
  id: mem
  required property var mon
  spacing: Style.spacing.xs

  readonly property color fg: mon.fg
  readonly property color muted: Util.alpha(fg, 0.5)
  readonly property int pageSize: 15
  readonly property int rowHeight: Style.space(26)
  readonly property var protectedNames: ["Hyprland", "quickshell", "qs", "systemd", "uwsm", "dbus-broker", "dbus-daemon", "Xwayland", "pipewire", "wireplumber"]

  property bool expanded: false
  property bool loaded: false
  property int myUid: -1
  property var procs: []            // [{ pid, uid, rss, name }] sorted by rss desc
  property int shown: pageSize
  property int confirmPid: -1
  property int busyPid: -1
  property string errorText: ""

  // Freeze ordering while the pointer is over the list so rows don't move
  // out from under a click.
  readonly property bool frozen: listHover.hovered

  function fmt(bytes) {
    var units = [["GB", 1073741824], ["MB", 1048576], ["KB", 1024]]
    for (var i = 0; i < units.length; i++)
      if (bytes >= units[i][1]) return (bytes / units[i][1]).toFixed(1) + " " + units[i][0]
    return Math.round(bytes) + " B"
  }
  function pct(v) { return v < 0.001 ? "<0.1%" : v < 0.1 ? (v * 100).toFixed(1) + "%" : Math.round(v * 100) + "%" }
  function killable(p) { return p.uid === myUid && protectedNames.indexOf(p.name) < 0 }

  ListModel { id: rows }

  // Preview support: "mem" in the preview file expands this list.
  function autoExpand() {
    var want = mon.previewExpand || []
    if (want.indexOf("mem") >= 0 && !expanded) toggle()
  }
  Connections {
    target: mem.mon
    function onPreviewExpandChanged() { mem.autoExpand() }
  }
  Component.onCompleted: Qt.callLater(autoExpand)

  // ── Sampling ────────────────────────────────────────────────────────────
  Process {
    id: psProc
    command: ["sh", "-c", "id -u; ps -eo pid=,uid=,rss=,comm= --sort=-rss"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: mem.parse(text)
    }
  }

  Timer {
    interval: 3000
    repeat: true
    triggeredOnStart: true
    running: mem.expanded && mem.mon.popupOpen
    onTriggered: if (!psProc.running) psProc.running = true
  }

  function parse(text) {
    var lines = String(text || "").split("\n")
    myUid = Number(lines[0])
    var list = []
    for (var i = 1; i < lines.length; i++) {
      var m = lines[i].match(/^\s*(\d+)\s+(\d+)\s+(\d+)\s+(.+)$/)
      if (!m || Number(m[3]) === 0) continue      // skip kernel threads
      list.push({ pid: Number(m[1]), uid: Number(m[2]), rss: Number(m[3]) * 1024, name: m[4].trim() })
    }
    procs = list
    loaded = true
    sync()
    Qt.callLater(autoExpand)
  }

  // Bring the model in line with `procs`, moving rows instead of rebuilding
  // so the Column's move/add transitions animate the reorder.
  function sync() {
    if (!expanded) return
    var total = Math.max(1, mon.memTotalBytes)
    var byPid = {}
    for (var i = 0; i < procs.length; i++) byPid[procs[i].pid] = procs[i]

    // Drop rows whose process is gone.
    for (i = rows.count - 1; i >= 0; i--) {
      var r = rows.get(i)
      if (r.kind === "proc" && !byPid[r.pid]) rows.remove(i)
    }

    if (frozen) {
      // Update numbers only; keep positions stable.
      for (i = 0; i < rows.count; i++) {
        r = rows.get(i)
        var p = byPid[r.pid]
        if (r.kind === "proc" && p) { rows.setProperty(i, "rss", p.rss); rows.setProperty(i, "share", p.rss / total) }
      }
      return
    }

    var target = procs.slice(0, shown)
    for (i = 0; i < target.length; i++) {
      p = target[i]
      var at = -1
      for (var j = i; j < rows.count; j++) if (rows.get(j).kind === "proc" && rows.get(j).pid === p.pid) { at = j; break }
      var data = { kind: "proc", pid: p.pid, uid: p.uid, name: p.name, rss: p.rss, share: p.rss / total, locked: !killable(p) }
      if (at < 0) rows.insert(i, data)
      else {
        if (at !== i) rows.move(at, i, 1)
        rows.setProperty(i, "rss", p.rss)
        rows.setProperty(i, "share", p.rss / total)
      }
    }
    // Trim anything past the target (old "more" row, procs that fell off).
    if (rows.count > target.length) rows.remove(target.length, rows.count - target.length)

    var rest = procs.slice(shown)
    if (rest.length) {
      var restRss = rest.reduce(function(a, q) { return a + q.rss }, 0)
      rows.append({ kind: "more", pid: -1, uid: -1, name: rest.length + " more processes", rss: restRss, share: restRss / total, locked: true })
    }
  }

  function loadMore() {
    if (shown >= procs.length) return
    shown += pageSize
    sync()
  }

  function toggle() {
    confirmPid = -1
    expanded = !expanded
    if (expanded) { shown = pageSize; if (loaded) sync() }
    else rows.clear()
  }

  // ── Killing ─────────────────────────────────────────────────────────────
  Component {
    id: killer
    Process {
      id: kproc
      property int pid: -1
      property string name: ""
      property string signal: "TERM"
      // Re-check the name so a recycled PID is never signalled by mistake.
      command: ["sh", "-c", "[ \"$(cat /proc/$1/comm 2>/dev/null)\" = \"$2\" ] || exit 3; kill -s \"$3\" \"$1\"",
                "sh", String(pid), name, signal]
      stderr: StdioCollector { id: kerr; waitForEnd: true }
      onExited: function(code) {
        mem.killed(kproc.pid, kproc.name, code, String(kerr.text || "").trim())
        Qt.callLater(kproc.destroy)
      }
    }
  }

  function kill(pid, name, force) {
    confirmPid = -1
    busyPid = pid
    killer.createObject(mem, { pid: pid, name: name, signal: force ? "KILL" : "TERM" }).running = true
  }

  function killed(pid, name, code, message) {
    if (code !== 0) {
      busyPid = -1
      errorText = code === 3 ? name + " already exited" : "Couldn't stop " + name + (message ? ": " + message.split("\n")[0] : "")
      errorTimer.restart()
      return
    }
    // Give it a moment to exit, then resample.
    settleTimer.restart()
  }

  Timer { id: settleTimer; interval: 700; onTriggered: { mem.busyPid = -1; if (!psProc.running) psProc.running = true } }
  Timer { id: errorTimer; interval: 5000; onTriggered: mem.errorText = "" }
  Timer { interval: 8000; running: mem.confirmPid >= 0; onTriggered: mem.confirmPid = -1 }

  // ── Header ──────────────────────────────────────────────────────────────
  Item {
    width: parent.width
    height: header.implicitHeight

    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: mem.toggle()
    }

    Column {
      id: header
      width: parent.width
      spacing: Style.spacing.sm

      Item {
        width: parent.width
        height: Math.max(title.implicitHeight, stats.implicitHeight)

        Row {
          id: title
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.spacing.sm
          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: "\u{f0142}"
            color: mem.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            rotation: mem.expanded ? 90 : 0
            Behavior on rotation { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
          }
          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: "\u{f035b}  Memory"
            font.capitalization: mem.mon.hud ? Font.AllUppercase : Font.MixedCase
            font.letterSpacing: mem.mon.hud ? 2.5 : 0
            color: mem.fg
            font.family: Style.font.family
            font.pixelSize: Style.font.body
          }
          Text {
            anchors.verticalCenter: parent.verticalCenter
            visible: mem.expanded && mem.loaded
            text: mem.procs.length + " processes"
            color: mem.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            leftPadding: Style.spacing.md
          }
        }

        Text {
          id: stats
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.RichText
          text: "<span style='color:" + mem.muted + "'>" + mem.fmt(mem.mon.memUsedBytes) + " / " + mem.fmt(mem.mon.memTotalBytes) + "</span>&nbsp;&nbsp;<b>" + Math.round(mem.mon.memShown * 100) + "%</b>"
          color: mem.mon.heat(mem.mon.memUsage)
          font.family: Style.font.family
          font.pixelSize: Style.font.body
        }
      }

      Rectangle {
        width: parent.width
        height: Style.space(6)
        radius: height / 2
        color: Util.alpha(mem.fg, 0.1)
        clip: true
        Rectangle {
          height: parent.height
          radius: height / 2
          width: Math.max(height, parent.width * mem.mon.memShown)
          color: mem.mon.heat(mem.mon.memUsage)
          Behavior on color { ColorAnimation { duration: 500 } }
        }
        Rectangle {
          visible: mem.expanded && !mem.loaded
          height: parent.height
          radius: height / 2
          width: parent.width * 0.25
          color: Util.alpha(mem.fg, 0.35)
          NumberAnimation on x {
            running: mem.expanded && !mem.loaded
            loops: Animation.Infinite
            from: -parent.width * 0.25; to: parent.width
            duration: 1100; easing.type: Easing.InOutSine
          }
        }
      }
    }
  }

  Text {
    width: parent.width
    visible: opacity > 0
    opacity: mem.errorText !== "" ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: 200 } }
    text: "\u{f0026}  " + mem.errorText
    color: mem.mon.hot
    elide: Text.ElideRight
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
  }

  // ── Process rows ────────────────────────────────────────────────────────
  Flickable {
    id: scroller
    width: parent.width
    contentHeight: list.implicitHeight
    height: Math.min(contentHeight, Style.space(360))
    Behavior on height { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    visible: height > 0

    HoverHandler { id: listHover }

    Rectangle {
      parent: scroller
      visible: scroller.contentHeight > scroller.height
      anchors.right: parent.right
      width: Style.space(3)
      radius: width / 2
      y: scroller.visibleArea.yPosition * scroller.height
      height: scroller.visibleArea.heightRatio * scroller.height
      color: Util.alpha(mem.fg, 0.25)
      z: 10
    }

    Column {
      id: list
      width: scroller.width - Style.space(6)
      topPadding: rows.count ? Style.spacing.xs : 0

      move: Transition { NumberAnimation { properties: "y"; duration: 300; easing.type: Easing.OutCubic } }

      Repeater {
        model: rows
        delegate: Item {
          id: row
          required property int index
          required property string kind
          required property int pid
          required property int uid
          required property string name
          required property real rss
          required property real share
          required property bool locked

          readonly property bool isProc: kind === "proc"
          readonly property bool canKill: isProc && !locked
          readonly property bool confirming: isProc && mem.confirmPid === pid
          readonly property bool busy: isProc && mem.busyPid === pid
          readonly property color tint: mem.mon.heat(Math.min(1, 0.4 + share * 4))
          width: list.width
          height: mem.rowHeight

          // Infinite scroll trigger.
          readonly property bool inView: kind === "more" && (y - scroller.contentY) < scroller.height + mem.rowHeight * 2
          onInViewChanged: if (inView) pageTimer.restart()
          Timer { id: pageTimer; interval: 280; onTriggered: if (row.inView) mem.loadMore() }

          opacity: 0
          transform: Translate { id: shift; x: -Style.space(10) }
          Component.onCompleted: { appear.start(); if (inView) pageTimer.restart() }
          ParallelAnimation {
            id: appear
            NumberAnimation { target: row; property: "opacity"; to: 1; duration: 260; easing.type: Easing.OutCubic }
            NumberAnimation { target: shift; property: "x"; to: 0; duration: 300; easing.type: Easing.OutCubic }
          }

          Rectangle {
            anchors.fill: parent
            radius: Style.space(4)
            color: row.confirming ? Util.alpha(mem.mon.hot, 0.12)
                 : rowArea.containsMouse && row.isProc ? Util.alpha(mem.fg, 0.07) : "transparent"
            Behavior on color { ColorAnimation { duration: 150 } }
          }

          MouseArea {
            id: rowArea
            anchors.fill: parent
            hoverEnabled: true
            onClicked: if (row.confirming) mem.confirmPid = -1
          }

          Row {
            x: Style.spacing.xs
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.spacing.sm
            opacity: row.busy ? 0.4 : 1
            Behavior on opacity { NumberAnimation { duration: 200 } }

            Text {
              width: Style.space(14)
              anchors.verticalCenter: parent.verticalCenter
              horizontalAlignment: Text.AlignHCenter
              text: row.kind === "more" ? "\u{f0450}" : "\u{f08c6}"     // refresh / application-cog
              color: row.isProc ? row.tint : mem.muted
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              RotationAnimation on rotation {
                running: row.kind === "more" && row.inView
                loops: Animation.Infinite
                from: 0; to: 360; duration: 900
              }
            }
            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: row.busy ? row.name + "  — stopping…" : row.name
              color: row.isProc ? mem.fg : mem.muted
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              font.italic: !row.isProc
            }
            Text {
              anchors.verticalCenter: parent.verticalCenter
              visible: row.isProc
              text: row.pid
              color: Util.alpha(mem.fg, 0.35)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }

          // Normal right side: kill / lock, bar, size, %.
          Row {
            anchors.right: parent.right
            anchors.rightMargin: Style.spacing.sm
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.spacing.lg
            opacity: row.confirming ? 0 : 1
            visible: opacity > 0
            Behavior on opacity { NumberAnimation { duration: 150 } }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              visible: row.isProc && !row.busy
              text: row.canKill ? "\u{f0156}" : "\u{f033e}"    // close-circle / lock
              opacity: rowArea.containsMouse || killArea.containsMouse ? 1 : 0
              Behavior on opacity { NumberAnimation { duration: 150 } }
              color: row.canKill && killArea.containsMouse ? mem.mon.hot : mem.muted
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              MouseArea {
                id: killArea
                anchors.fill: parent
                anchors.margins: -Style.space(4)
                hoverEnabled: true
                enabled: row.canKill
                cursorShape: Qt.PointingHandCursor
                onClicked: mem.confirmPid = row.pid
              }
            }
            Rectangle {
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(90)
              height: Style.space(5)
              radius: height / 2
              color: Util.alpha(mem.fg, 0.08)
              Rectangle {
                height: parent.height
                radius: height / 2
                // Scaled so a process using 25% of RAM fills the bar.
                width: Math.max(height, parent.width * Math.min(1, row.share * 4))
                color: row.isProc ? row.tint : Util.alpha(mem.fg, 0.35)
                Behavior on width { NumberAnimation { duration: 500; easing.type: Easing.OutCubic } }
                Behavior on color { ColorAnimation { duration: 400 } }
              }
            }
            Text {
              width: Style.space(64)
              horizontalAlignment: Text.AlignRight
              text: mem.fmt(row.rss)
              color: mem.muted
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
            }
            Text {
              width: Style.space(44)
              horizontalAlignment: Text.AlignRight
              text: mem.pct(row.share)
              color: mem.fg
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              font.bold: true
            }
          }

          // Confirmation: Cancel · End · hold-to-Force kill.
          Row {
            anchors.right: parent.right
            anchors.rightMargin: Style.spacing.sm
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.spacing.sm
            opacity: row.confirming ? 1 : 0
            visible: opacity > 0
            Behavior on opacity { NumberAnimation { duration: 150 } }
            transform: Translate { x: row.confirming ? 0 : Style.space(12); Behavior on x { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } } }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "Stop " + row.name + " (" + mem.fmt(row.rss) + ")?"
              color: mem.fg
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              rightPadding: Style.spacing.xs
            }
            Pill {
              anchors.verticalCenter: parent.verticalCenter
              fg: mem.fg
              label: "Cancel"
              onActivated: mem.confirmPid = -1
            }
            Pill {
              anchors.verticalCenter: parent.verticalCenter
              fg: mem.fg
              label: "\u{f04db} End"
              tint: mem.mon.heat(0.75)
              onActivated: mem.kill(row.pid, row.name, false)
            }
            Pill {
              id: hold
              anchors.verticalCenter: parent.verticalCenter
              fg: mem.fg
              label: progress > 0 ? "Hold…" : "Hold to force kill"
              tint: mem.mon.hot
              strong: true
              onPressedChanged: {
                if (pressed) holdAnim.restart()
                else if (progress < 1) { holdAnim.stop(); resetAnim.restart() }
              }
              NumberAnimation {
                id: holdAnim
                target: hold; property: "progress"; to: 1; duration: 1500
                onFinished: if (hold.progress >= 1) mem.kill(row.pid, row.name, true)
              }
              NumberAnimation { id: resetAnim; target: hold; property: "progress"; to: 0; duration: 200 }
            }
          }
        }
      }
    }
  }
}
