import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

// Collapsible disk-usage tree. The header shows the filesystem (used / total,
// %); expanding it scans folders lazily with `du -d1` (cached), each row
// showing its size and its share of the parent folder.
//   - Infinite scroll: children load in pages as the list is scrolled.
//   - Delete: folders inside $HOME get a trash button. Click "Trash" to move
//     to the trash (undoable), or press-and-hold "Delete" to remove for good.
Column {
  id: tree
  required property var mon
  spacing: Style.spacing.xs

  readonly property color fg: mon.fg
  readonly property color muted: Util.alpha(fg, 0.5)
  readonly property int pageSize: 12
  readonly property int rowHeight: Style.space(26)
  readonly property int indent: Style.space(16)
  readonly property string home: Quickshell.env("HOME")
  readonly property string rootPath: mon.diskPath

  property bool rootExpanded: false
  property bool rootLoading: false
  property var cache: ({})          // path -> { total, children: [{ path, name, size }] }
  property var shown: ({})          // path -> how many children are listed
  property string confirmPath: ""   // row currently asking for delete confirmation
  property string busyPath: ""      // row currently being deleted
  property string errorText: ""

  function fmt(bytes) {
    var units = [["GB", 1073741824], ["MB", 1048576], ["KB", 1024]]
    for (var i = 0; i < units.length; i++)
      if (bytes >= units[i][1]) return (bytes / units[i][1]).toFixed(1) + " " + units[i][0]
    return Math.round(bytes) + " B"
  }
  function pct(v) { return v >= 0.995 ? "100%" : v < 0.001 ? "<0.1%" : v < 0.1 ? (v * 100).toFixed(1) + "%" : Math.round(v * 100) + "%" }
  function deletable(path) { return path.indexOf(home + "/") === 0 && path.length > home.length + 1 }

  ListModel { id: rows }

  // ── Preview support: auto-expand the listed paths ───────────────────────
  function autoExpand() {
    var want = mon.previewExpand || []
    if (want.indexOf(rootPath) >= 0 && !rootExpanded) toggleRoot()
    for (var i = 0; i < rows.count; i++) {
      var r = rows.get(i)
      if (r.kind === "dir" && want.indexOf(r.path) >= 0 && !r.expanded) toggle(i)
    }
  }
  Connections {
    target: tree.mon
    function onPreviewExpandChanged() { tree.autoExpand() }
  }
  Component.onCompleted: Qt.callLater(autoExpand)

  // ── Background processes ────────────────────────────────────────────────
  Component {
    id: scanner
    Process {
      id: proc
      property string target: ""
      command: ["sh", "-c",
        "nice -n19 du -d1 -B1 --exclude=/proc --exclude=/sys --exclude=/dev --exclude=/run --exclude=.snapshots -- \"$1\" 2>/dev/null",
        "sh", target]
      stdout: StdioCollector {
        waitForEnd: true
        onStreamFinished: {
          tree.finish(proc.target, text)
          Qt.callLater(proc.destroy)
        }
      }
    }
  }

  Component {
    id: deleter
    Process {
      id: dproc
      property string target: ""
      property bool permanent: false
      command: permanent
        ? ["rm", "-rf", "--one-file-system", "--", target]
        : ["gio", "trash", "--", target]
      stderr: StdioCollector { id: err; waitForEnd: true }
      onExited: function(code) {
        tree.deleted(dproc.target, code === 0, String(err.text || "").trim())
        Qt.callLater(dproc.destroy)
      }
    }
  }

  function scan(path) {
    scanner.createObject(tree, { target: path }).running = true
  }

  function remove(path, permanent) {
    if (!deletable(path) || busyPath !== "") return
    confirmPath = ""
    busyPath = path
    deleter.createObject(tree, { target: path, permanent: permanent }).running = true
  }

  function finish(path, text) {
    var total = 0, kids = []
    var lines = String(text || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var m = lines[i].match(/^(\d+)\s+(.+)$/)
      if (!m) continue
      var size = Number(m[1]), p = m[2]
      if (p === path) total = size
      else kids.push({ path: p, name: p.slice(p.lastIndexOf("/") + 1), size: size })
    }
    kids.sort(function(a, b) { return b.size - a.size })
    var c = cache
    c[path] = { total: total, children: kids }
    cache = c

    if (path === rootPath) {
      rootLoading = false
      if (rootExpanded && rows.count === 0) insertChildren(-1, path, 0)
      return
    }
    var idx = indexOf(path)
    if (idx < 0) return
    rows.setProperty(idx, "loading", false)
    rows.setProperty(idx, "size", total)
    if (rows.get(idx).expanded) insertChildren(idx, path, rows.get(idx).depth)
  }

  // ── Tree operations ─────────────────────────────────────────────────────
  function indexOf(path) {
    for (var i = 0; i < rows.count; i++) if (rows.get(i).path === path) return i
    return -1
  }

  function makeRow(parent, path, name, size, total, depth, kind) {
    return { path: path, parentPath: parent, name: name, size: size, share: size / Math.max(1, total),
             depth: depth, kind: kind, expanded: false, loading: false, empty: kind !== "dir" }
  }

  // Index just past `idx` and all of its descendants.
  function subtreeEnd(idx) {
    var depth = idx >= 0 ? rows.get(idx).depth : 0
    var i = idx + 1
    while (i < rows.count && rows.get(i).depth > depth) i++
    return i
  }

  // List the first page of children plus the trailing "files" / "more" rows.
  function insertChildren(idx, path, depth) {
    var entry = cache[path]
    if (!entry) return
    var s = shown; s[path] = 0; shown = s
    if (!entry.children.length && idx >= 0) rows.setProperty(idx, "empty", true)
    var at = idx + 1
    var kidsTotal = entry.children.reduce(function(a, k) { return a + k.size }, 0)
    var files = entry.total - kidsTotal
    if (files > entry.total * 0.005)
      rows.insert(at, makeRow(path, path + "\u0000files", "files", files, entry.total, depth + 1, "files"))
    appendPage(path)
  }

  // Insert the next page of `path`'s children before its trailing rows.
  function appendPage(path) {
    var entry = cache[path]
    if (!entry) return
    var parentIdx = path === rootPath ? -1 : indexOf(path)
    if (path !== rootPath && parentIdx < 0) return
    var depth = parentIdx >= 0 ? rows.get(parentIdx).depth : 0

    var moreIdx = indexOf(path + "\u0000more")
    if (moreIdx >= 0) rows.remove(moreIdx)

    // Insert after the already-listed children, before the "files" row.
    var at = parentIdx + 1
    var end = subtreeEnd(parentIdx)
    while (at < end && rows.get(at).kind !== "files") at = subtreeEnd(at)

    var from = shown[path] || 0
    var page = entry.children.slice(from, from + pageSize)
    for (var i = 0; i < page.length; i++)
      rows.insert(at++, makeRow(path, page[i].path, page[i].name, page[i].size, entry.total, depth + 1, "dir"))
    var s = shown; s[path] = from + page.length; shown = s

    var rest = entry.children.slice(from + page.length)
    if (rest.length) {
      var restSize = rest.reduce(function(a, k) { return a + k.size }, 0)
      rows.insert(at, makeRow(path, path + "\u0000more", rest.length + " more folders", restSize, entry.total, depth + 1, "more"))
    }
    Qt.callLater(autoExpand)
  }

  function collapse(idx) {
    var end = subtreeEnd(idx)
    if (end > idx + 1) rows.remove(idx + 1, end - idx - 1)
    rows.setProperty(idx, "expanded", false)
  }

  function toggle(idx) {
    var row = rows.get(idx)
    if (row.kind !== "dir" || row.empty) return
    confirmPath = ""
    if (row.expanded) { collapse(idx); return }
    rows.setProperty(idx, "expanded", true)
    if (cache[row.path]) insertChildren(idx, row.path, row.depth)
    else { rows.setProperty(idx, "loading", true); scan(row.path) }
  }

  function toggleRoot() {
    confirmPath = ""
    if (rootExpanded) { rootExpanded = false; rows.clear(); return }
    rootExpanded = true
    if (cache[rootPath]) insertChildren(-1, rootPath, 0)
    else { rootLoading = true; scan(rootPath) }
  }

  function refresh() {
    cache = ({})
    shown = ({})
    confirmPath = ""
    rows.clear()
    rootLoading = true
    scan(rootPath)
  }

  // After a delete: drop the row + subtree, and shrink every ancestor.
  function deleted(path, ok, message) {
    busyPath = ""
    if (!ok) {
      errorText = "Couldn't delete " + path.slice(path.lastIndexOf("/") + 1) + (message ? ": " + message.split("\n")[0] : "")
      errorTimer.restart()
      return
    }
    var idx = indexOf(path)
    if (idx < 0) return
    var size = rows.get(idx).size
    rows.remove(idx, subtreeEnd(idx) - idx)

    var c = cache
    for (var key in c) if (key === path || key.indexOf(path + "/") === 0) delete c[key]
    var p = path.slice(0, path.lastIndexOf("/")) || "/"
    var child = path
    while (true) {
      var e = c[p]
      if (e) {
        e.total = Math.max(0, e.total - size)
        e.children = e.children.filter(function(k) { return k.path !== child })
        for (var i = 0; i < e.children.length; i++)
          if (path.indexOf(e.children[i].path + "/") === 0) e.children[i].size = Math.max(0, e.children[i].size - size)
        e.children.sort(function(a, b) { return b.size - a.size })
      }
      if (p === rootPath || p === "/") break
      p = p.slice(0, p.lastIndexOf("/")) || "/"
    }
    cache = c
    if (child === path) {
      var s = shown, parent = path.slice(0, path.lastIndexOf("/")) || "/"
      if (s[parent]) s[parent]--
      shown = s
    }
    // Refresh sizes and shares of the rows still on screen.
    for (var r = 0; r < rows.count; r++) {
      var row = rows.get(r)
      if (row.kind === "dir" && path.indexOf(row.path + "/") === 0)
        rows.setProperty(r, "size", Math.max(0, row.size - size))
    }
    for (r = 0; r < rows.count; r++) {
      row = rows.get(r)
      var pe = cache[row.parentPath]
      if (pe && pe.total > 0) rows.setProperty(r, "share", row.size / pe.total)
    }
  }

  Timer { id: errorTimer; interval: 5000; onTriggered: tree.errorText = "" }
  Timer { id: confirmTimer; interval: 8000; running: tree.confirmPath !== ""; onTriggered: tree.confirmPath = "" }

  // ── Header: the filesystem itself ───────────────────────────────────────
  Item {
    width: parent.width
    height: header.implicitHeight

    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: tree.toggleRoot()
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
            color: tree.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            rotation: tree.rootExpanded ? 90 : 0
            Behavior on rotation { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
          }
          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: "\u{f02ca}  Disk " + tree.rootPath
            font.capitalization: tree.mon.hud ? Font.AllUppercase : Font.MixedCase
            font.letterSpacing: tree.mon.hud ? 2.5 : 0
            color: tree.fg
            font.family: Style.font.family
            font.pixelSize: Style.font.body
          }
          Text {
            anchors.verticalCenter: parent.verticalCenter
            visible: tree.rootExpanded
            text: tree.rootLoading ? "scanning…" : "\u{f0450}"
            color: refreshArea.containsMouse ? tree.fg : tree.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            leftPadding: Style.spacing.md
            MouseArea {
              id: refreshArea
              anchors.fill: parent
              hoverEnabled: true
              enabled: !tree.rootLoading
              cursorShape: Qt.PointingHandCursor
              onClicked: tree.refresh()
            }
          }
        }

        Text {
          id: stats
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.RichText
          text: "<span style='color:" + tree.muted + "'>" + tree.fmt(tree.mon.diskUsedBytes) + " / " + tree.fmt(tree.mon.diskTotalBytes) + "</span>&nbsp;&nbsp;<b>" + Math.round(tree.mon.diskShown * 100) + "%</b>"
          color: tree.mon.heat(tree.mon.diskUsage)
          font.family: Style.font.family
          font.pixelSize: Style.font.body
        }
      }

      Rectangle {
        width: parent.width
        height: Style.space(6)
        radius: height / 2
        color: Util.alpha(tree.fg, 0.1)
        clip: true
        Rectangle {
          height: parent.height
          radius: height / 2
          width: Math.max(height, parent.width * tree.mon.diskShown)
          color: tree.mon.heat(tree.mon.diskUsage)
          Behavior on color { ColorAnimation { duration: 500 } }
        }
        Rectangle {
          visible: tree.rootLoading
          height: parent.height
          radius: height / 2
          width: parent.width * 0.25
          color: Util.alpha(tree.fg, 0.35)
          NumberAnimation on x {
            running: tree.rootLoading
            loops: Animation.Infinite
            from: -parent.width * 0.25; to: parent.width
            duration: 1100; easing.type: Easing.InOutSine
          }
        }
      }
    }
  }

  // Error toast.
  Text {
    width: parent.width
    visible: opacity > 0
    opacity: tree.errorText !== "" ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: 200 } }
    text: "\u{f0026}  " + tree.errorText
    color: tree.mon.hot
    elide: Text.ElideRight
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
  }

  // ── Folder rows (scrolls; pages load as you reach the end) ──────────────
  Flickable {
    id: scroller
    width: parent.width
    contentHeight: list.implicitHeight
    height: Math.min(contentHeight, Style.space(360))
    Behavior on height { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    visible: height > 0

    // Thin scroll indicator.
    Rectangle {
      parent: scroller
      visible: scroller.contentHeight > scroller.height
      anchors.right: parent.right
      width: Style.space(3)
      radius: width / 2
      y: scroller.visibleArea.yPosition * scroller.height
      height: scroller.visibleArea.heightRatio * scroller.height
      color: Util.alpha(tree.fg, 0.25)
      z: 10
    }

    Column {
      id: list
      width: scroller.width - Style.space(6)
      topPadding: rows.count ? Style.spacing.xs : 0

      Repeater {
        model: rows
        delegate: Item {
          id: row
          required property int index
          required property string path
          required property string parentPath
          required property string name
          required property real size
          required property real share
          required property int depth
          required property string kind
          required property bool expanded
          required property bool loading
          required property bool empty

          readonly property bool clickable: kind === "dir" && !empty
          readonly property bool canDelete: kind === "dir" && tree.deletable(path)
          readonly property bool confirming: tree.confirmPath === path
          readonly property bool busy: tree.busyPath === path
          width: list.width
          height: tree.rowHeight

          // Infinite scroll: the "more" row loads the next page once visible.
          readonly property bool inView: kind === "more" && (y - scroller.contentY) < scroller.height + tree.rowHeight * 2
          onInViewChanged: if (inView) pageTimer.restart()
          Timer {
            id: pageTimer
            interval: 280
            onTriggered: if (row.inView) tree.appendPage(row.parentPath)
          }

          opacity: 0
          transform: Translate { id: shift; x: -Style.space(10) }
          Component.onCompleted: {
            appear.start()
            if (inView) pageTimer.restart()
          }
          ParallelAnimation {
            id: appear
            NumberAnimation { target: row; property: "opacity"; to: 1; duration: 260; easing.type: Easing.OutCubic }
            NumberAnimation { target: shift; property: "x"; to: 0; duration: 300; easing.type: Easing.OutCubic }
          }

          Rectangle {
            anchors.fill: parent
            radius: Style.space(4)
            color: row.confirming ? Util.alpha(tree.mon.hot, 0.12)
                 : rowArea.containsMouse && row.clickable ? Util.alpha(tree.fg, 0.07) : "transparent"
            Behavior on color { ColorAnimation { duration: 150 } }
          }

          MouseArea {
            id: rowArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: row.clickable ? Qt.PointingHandCursor : Qt.ArrowCursor
            onClicked: {
              if (row.confirming) tree.confirmPath = ""
              else if (row.clickable) tree.toggle(row.index)
            }
          }

          Row {
            id: content
            x: (row.depth - 1) * tree.indent + Style.spacing.xs
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.spacing.sm
            opacity: row.busy ? 0.4 : 1

            Text {
              width: Style.space(12)
              anchors.verticalCenter: parent.verticalCenter
              horizontalAlignment: Text.AlignHCenter
              text: row.loading || row.kind === "more" ? "\u{f0450}" : row.clickable ? "\u{f0142}" : ""
              color: tree.muted
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              rotation: row.expanded && !row.loading ? 90 : 0
              Behavior on rotation { enabled: !row.loading; NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
              RotationAnimation on rotation {
                running: row.loading || (row.kind === "more" && row.inView)
                loops: Animation.Infinite
                from: 0; to: 360; duration: 900
              }
            }
            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: row.kind === "files" ? "\u{f0214}" : row.kind === "more" ? "\u{f01d8}" : row.expanded ? "\u{f0770}" : "\u{f024b}"
              color: row.kind === "dir" ? tree.mon.heat(Math.min(1, row.share * 1.2)) : tree.muted
              font.family: Style.font.family
              font.pixelSize: Style.font.body
            }
            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: row.busy ? row.name + "  — deleting…" : row.name
              color: row.kind === "dir" ? tree.fg : tree.muted
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              font.italic: row.kind !== "dir"
            }
          }

          // Normal right side: delete button, share bar, size, %.
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
              text: "\u{f0a7a}"     // trash-can-outline
              visible: row.canDelete && !row.busy
              opacity: rowArea.containsMouse || trashArea.containsMouse ? 1 : 0
              Behavior on opacity { NumberAnimation { duration: 150 } }
              color: trashArea.containsMouse ? tree.mon.hot : tree.muted
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              MouseArea {
                id: trashArea
                anchors.fill: parent
                anchors.margins: -Style.space(4)
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: tree.confirmPath = row.path
              }
            }
            Rectangle {
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(90)
              height: Style.space(5)
              radius: height / 2
              color: Util.alpha(tree.fg, 0.08)
              Rectangle {
                height: parent.height
                radius: height / 2
                width: Math.max(height, parent.width * row.share)
                color: row.kind === "dir" ? tree.mon.heat(Math.min(1, row.share * 1.2)) : Util.alpha(tree.fg, 0.35)
                Behavior on width { NumberAnimation { duration: 500; easing.type: Easing.OutCubic } }
              }
            }
            Text {
              width: Style.space(64)
              horizontalAlignment: Text.AlignRight
              text: tree.fmt(row.size)
              color: tree.muted
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
            }
            Text {
              width: Style.space(44)
              horizontalAlignment: Text.AlignRight
              text: tree.pct(row.share)
              color: tree.fg
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              font.bold: true
            }
          }

          // Confirmation: Cancel · Trash · hold-to-Delete.
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
              text: "Delete " + tree.fmt(row.size) + "?"
              color: tree.fg
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              rightPadding: Style.spacing.xs
            }
            Pill {
              anchors.verticalCenter: parent.verticalCenter
              fg: tree.fg
              label: "Cancel"
              onActivated: tree.confirmPath = ""
            }
            Pill {
              anchors.verticalCenter: parent.verticalCenter
              fg: tree.fg
              label: "\u{f0a7a} Trash"
              tint: tree.mon.heat(0.75)
              onActivated: tree.remove(row.path, false)
            }
            Pill {
              id: hold
              anchors.verticalCenter: parent.verticalCenter
              fg: tree.fg
              label: progress > 0 ? "Hold…" : "Hold to delete"
              tint: tree.mon.hot
              strong: true
              onPressedChanged: {
                if (pressed) { confirmTimer.stop(); holdAnim.restart() }
                else if (progress < 1) { holdAnim.stop(); resetAnim.restart() }
              }
              NumberAnimation {
                id: holdAnim
                target: hold; property: "progress"; to: 1; duration: 1500
                onFinished: if (hold.progress >= 1) tree.remove(row.path, true)
              }
              NumberAnimation { id: resetAnim; target: hold; property: "progress"; to: 0; duration: 200 }
            }
          }
        }
      }
    }
  }
}
