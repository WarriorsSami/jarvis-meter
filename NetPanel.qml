import QtQuick
import QtQuick.Shapes
import Quickshell.Io
import qs.Commons

// Network section: live ↓/↑ throughput chart, then every socket from `ss`
// split into Outbound / Inbound / Listening tabs. Remote IPs are resolved to
// hostnames in the background (cached). Process names are only visible for
// your own sockets (root's need sudo).
Column {
  id: net
  required property var mon
  spacing: Style.spacing.lg

  readonly property color fg: mon.fg
  readonly property color muted: Util.alpha(fg, 0.5)
  readonly property color rxColor: mon.accent
  readonly property color txColor: mon.amber
  readonly property int rowHeight: Style.space(24)

  property string tab: "out"          // out | in | listen
  property var conns: []              // parsed sockets
  property var names: ({})            // ip -> hostname ("" = no PTR)
  property var seen: ({})             // keys already shown, for the new-row flash
  property string iface: ""
  property string localIp: ""
  property string gateway: ""

  readonly property var services: ({
    20: "ftp", 21: "ftp", 22: "ssh", 25: "smtp", 53: "dns", 67: "dhcp", 68: "dhcp", 80: "http",
    110: "pop3", 123: "ntp", 143: "imap", 443: "https", 465: "smtps", 546: "dhcp6", 547: "dhcp6",
    587: "smtp", 631: "ipp", 853: "dot", 993: "imaps", 1900: "ssdp", 3000: "dev", 3306: "mysql",
    5353: "mdns", 5355: "llmnr", 5432: "postgres", 5900: "vnc", 6379: "redis", 8080: "http-alt",
    8443: "https-alt", 9090: "web", 27017: "mongo", 51820: "wireguard"
  })

  function rate(bps) {
    var units = [["GB/s", 1073741824], ["MB/s", 1048576], ["KB/s", 1024]]
    for (var i = 0; i < units.length; i++)
      if (bps >= units[i][1]) return (bps / units[i][1]).toFixed(1) + " " + units[i][0]
    return Math.round(bps) + " B/s"
  }
  function svc(port) { return services[port] || "" }
  function host(ip) {
    if (ip === "*" || ip === "0.0.0.0" || ip === "::") return "any"
    var n = names[ip]
    return n ? n : ip
  }

  // ── Sockets ─────────────────────────────────────────────────────────────
  Process {
    id: ssProc
    command: ["sh", "-c", "ip -o -4 route get 1.1.1.1 2>/dev/null | sed 's/^/ROUTE /'; ss -tunapH 2>/dev/null"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: net.parse(text) }
  }
  Timer {
    interval: 3000; repeat: true; triggeredOnStart: true
    running: net.mon.popupOpen
    onTriggered: if (!ssProc.running) ssProc.running = true
  }

  function splitAddr(a) {
    var i = a.lastIndexOf(":")
    var ip = a.slice(0, i), port = a.slice(i + 1)
    ip = ip.replace(/^\[|\]$/g, "").replace(/%.*$/, "").replace(/^::ffff:/, "")
    return { ip: ip, port: port === "*" ? 0 : Number(port) }
  }

  function parse(text) {
    var lines = String(text || "").split("\n"), list = []
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i]
      if (line.indexOf("ROUTE ") === 0) {
        var r = line.match(/via (\S+) dev (\S+).*src (\S+)/)
        if (r) { gateway = r[1]; iface = r[2]; localIp = r[3] }
        continue
      }
      var f = line.trim().split(/\s+/)
      if (f.length < 6) continue
      var proc = line.match(/users:\(\("([^"]+)",pid=(\d+)/)
      var l = splitAddr(f[4]), p = splitAddr(f[5])
      list.push({ proto: f[0], state: f[1], local: l, peer: p,
                  name: proc ? proc[1] : "", pid: proc ? Number(proc[2]) : 0 })
    }
    // Listening sockets, and the ports they serve (for spotting inbound conns).
    var listenPorts = {}
    for (i = 0; i < list.length; i++) {
      var c = list[i]
      c.listen = c.state === "LISTEN" || (c.proto === "udp" && c.state === "UNCONN")
      if (c.listen) listenPorts[c.proto + c.local.port] = true
    }
    for (i = 0; i < list.length; i++) {
      c = list[i]
      c.dir = c.listen ? "listen" : listenPorts[c.proto + c.local.port] ? "in" : "out"
      c.key = c.proto + "|" + c.local.ip + ":" + c.local.port + "|" + c.peer.ip + ":" + c.peer.port
    }
    conns = list
    resolve()
    sync()
  }

  // ── Reverse DNS ─────────────────────────────────────────────────────────
  Process {
    id: dnsProc
    property var batch: []
    command: ["sh", "-c", "for ip; do printf '%s %s\\n' \"$ip\" \"$(timeout 1 getent hosts \"$ip\" | awk '{print $2; exit}')\" & done; wait", "sh"].concat(batch)
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var n = net.names, lines = String(text || "").split("\n")
        for (var i = 0; i < lines.length; i++) {
          var m = lines[i].match(/^(\S+)\s*(\S*)/)
          if (m) n[m[1]] = m[2]
        }
        for (var j = 0; j < dnsProc.batch.length; j++) if (n[dnsProc.batch[j]] === undefined) n[dnsProc.batch[j]] = ""
        net.names = n
        net.sync()
      }
    }
  }
  function resolve() {
    if (dnsProc.running) return
    var want = [], seenIp = {}
    for (var i = 0; i < conns.length && want.length < 24; i++) {
      var ip = conns[i].peer.ip
      if (conns[i].listen || !ip || ip === "*" || names[ip] !== undefined || seenIp[ip]) continue
      seenIp[ip] = true
      want.push(ip)
    }
    if (!want.length) return
    dnsProc.batch = want
    dnsProc.running = true
  }

  // ── Rows for the active tab ─────────────────────────────────────────────
  readonly property var counts: {
    var c = { out: 0, "in": 0, listen: 0 }
    for (var i = 0; i < conns.length; i++) c[conns[i].dir]++
    return c
  }

  ListModel { id: rows }
  onTabChanged: { rows.clear(); sync() }

  function sync() {
    var target = conns.filter(function(c) { return c.dir === net.tab })
    target.sort(function(a, b) {
      return (a.name || "~").localeCompare(b.name || "~") || a.peer.ip.localeCompare(b.peer.ip) || a.local.port - b.local.port
    })
    var keys = {}
    for (var i = 0; i < target.length; i++) keys[target[i].key] = true
    for (i = rows.count - 1; i >= 0; i--) if (!keys[rows.get(i).key]) rows.remove(i)

    var s = seen
    for (i = 0; i < target.length; i++) {
      var c = target[i]
      var data = {
        key: c.key, proto: c.proto.toUpperCase(), state: c.state,
        name: c.name || "—", pid: c.pid,
        lport: c.local.port, lsvc: svc(c.local.port), lip: c.local.ip === "*" ? "any" : c.local.ip,
        rhost: host(c.peer.ip), rip: c.peer.ip, rport: c.peer.port, rsvc: svc(c.peer.port),
        fresh: !!Object.keys(s).length && !s[c.key]
      }
      s[c.key] = true
      var at = -1
      for (var j = i; j < rows.count; j++) if (rows.get(j).key === c.key) { at = j; break }
      if (at < 0) rows.insert(i, data)
      else {
        if (at !== i) rows.move(at, i, 1)
        rows.setProperty(i, "state", data.state)
        rows.setProperty(i, "rhost", data.rhost)
      }
    }
    seen = s
  }

  // ── Throughput ──────────────────────────────────────────────────────────
  Item {
    width: parent.width
    height: Math.max(down.implicitHeight, linkInfo.implicitHeight)

    Row {
      id: down
      spacing: Style.space(26)
      Repeater {
        model: [
          { arrow: "↓", label: "INGRESS", value: net.mon.rxRate, color: net.rxColor },
          { arrow: "↑", label: "EGRESS", value: net.mon.txRate, color: net.txColor }
        ]
        Column {
          required property var modelData
          spacing: Style.spacing.xxs
          Text {
            text: modelData.label
            color: net.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            font.letterSpacing: 2.5
          }
          Text {
            text: modelData.arrow + " " + net.rate(modelData.value)
            color: modelData.color
            font.family: Style.font.family
            font.pixelSize: Style.font.heading
            font.bold: true
          }
        }
      }
    }
    Column {
      id: linkInfo
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.spacing.xxs
      Text {
        anchors.right: parent.right
        text: net.iface ? net.iface.toUpperCase() : "NO ROUTE"
        color: net.mon.accent
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        font.letterSpacing: 2
      }
      Text {
        anchors.right: parent.right
        text: net.localIp ? net.localIp + "  →  gw " + net.gateway : ""
        color: net.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }
    }
  }

  // Dual throughput chart: ingress area + egress line, shared auto-scale.
  Item {
    id: chart
    width: parent.width
    height: Style.space(64)
    clip: true
    readonly property int size: net.mon.historySize
    readonly property real step: width / Math.max(1, size - 2)
    readonly property real peak: Math.max(1024, Math.max.apply(null, net.mon.rxHistory.concat(net.mon.txHistory, [0])))
    onPeakChanged: {}
    Connections {
      target: net.mon
      function onRxHistoryChanged() { slide.restart() }
    }

    function pts(series, closed) {
      var out = [], n = series.length
      for (var i = 0; i < n; i++)
        out.push(Qt.point((size - n + i) * step, height - 1 - series[i] / peak * (height - 4)))
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
        color: Util.alpha(net.fg, 0.06)
      }
    }
    Text {
      anchors.right: parent.right
      text: "peak " + net.rate(chart.peak)
      color: Util.alpha(net.fg, 0.35)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }

    Item {
      width: chart.width + chart.step
      height: chart.height
      NumberAnimation on x { id: slide; from: chart.step; to: 0; duration: net.mon.interval }
      Shape {
        anchors.fill: parent
        preferredRendererType: Shape.CurveRenderer
        ShapePath {
          strokeColor: "transparent"
          fillGradient: LinearGradient {
            x1: 0; y1: 0; x2: 0; y2: chart.height
            GradientStop { position: 0; color: Util.alpha(net.rxColor, 0.4) }
            GradientStop { position: 1; color: Util.alpha(net.rxColor, 0.0) }
          }
          PathPolyline { path: chart.pts(net.mon.rxHistory, true) }
        }
        ShapePath {
          fillColor: "transparent"
          strokeColor: net.rxColor
          strokeWidth: Style.space(1.5)
          joinStyle: ShapePath.RoundJoin
          PathPolyline { path: chart.pts(net.mon.rxHistory, false) }
        }
        ShapePath {
          fillColor: "transparent"
          strokeColor: net.txColor
          strokeWidth: Style.space(1.5)
          joinStyle: ShapePath.RoundJoin
          PathPolyline { path: chart.pts(net.mon.txHistory, false) }
        }
      }
    }
  }

  // ── Tabs ────────────────────────────────────────────────────────────────
  Item {
    width: parent.width
    height: tabRow.implicitHeight + Style.space(6)

    Row {
      id: tabRow
      spacing: Style.space(22)
      Repeater {
        id: tabs
        model: [
          { id: "out", label: "OUTBOUND", icon: "↗" },
          { id: "in", label: "INBOUND", icon: "↙" },
          { id: "listen", label: "LISTENING", icon: "◉" }
        ]
        Item {
          id: tabItem
          required property var modelData
          required property int index
          readonly property bool active: net.tab === modelData.id
          width: tabContent.implicitWidth
          height: tabContent.implicitHeight
          Row {
            id: tabContent
            spacing: Style.spacing.sm
            Text {
              text: tabItem.modelData.icon + " " + tabItem.modelData.label
              color: tabItem.active ? net.mon.accent : net.muted
              Behavior on color { ColorAnimation { duration: 150 } }
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              font.letterSpacing: 2
              font.bold: tabItem.active
            }
            Rectangle {
              anchors.verticalCenter: parent.verticalCenter
              width: countText.implicitWidth + Style.spacing.md * 2
              height: countText.implicitHeight + Style.space(2)
              radius: height / 2
              color: Util.alpha(tabItem.active ? net.mon.accent : net.fg, tabItem.active ? 0.2 : 0.08)
              Text {
                id: countText
                anchors.centerIn: parent
                text: net.counts[tabItem.modelData.id]
                color: tabItem.active ? net.mon.accent : net.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                font.bold: true
              }
            }
          }
          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: net.tab = tabItem.modelData.id
          }
        }
      }
    }
    // Sliding underline under the active tab.
    Rectangle {
      readonly property Item target: tabs.count ? tabs.itemAt(net.tab === "out" ? 0 : net.tab === "in" ? 1 : 2) : null
      y: parent.height - height
      x: target ? target.x : 0
      width: target ? target.width : 0
      height: Style.space(2)
      color: net.mon.accent
      Behavior on x { NumberAnimation { duration: 250; easing.type: Easing.OutCubic } }
      Behavior on width { NumberAnimation { duration: 250; easing.type: Easing.OutCubic } }
    }
    Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Util.alpha(net.fg, 0.1) }
  }

  // ── Connection list ─────────────────────────────────────────────────────
  Flickable {
    id: scroller
    width: parent.width
    height: Math.max(net.rowHeight * 3, Math.min(list.implicitHeight, Style.space(330)))
    contentHeight: list.implicitHeight
    clip: true
    boundsBehavior: Flickable.StopAtBounds

    Rectangle {
      parent: scroller
      visible: scroller.contentHeight > scroller.height
      anchors.right: parent.right
      width: Style.space(3)
      radius: width / 2
      y: scroller.visibleArea.yPosition * scroller.height
      height: scroller.visibleArea.heightRatio * scroller.height
      color: Util.alpha(net.fg, 0.25)
      z: 10
    }

    Text {
      visible: rows.count === 0
      anchors.centerIn: parent
      text: ssProc.running && !net.conns.length ? "scanning sockets…" : "no " + (net.tab === "in" ? "inbound connections" : net.tab === "out" ? "outbound connections" : "listening sockets")
      color: net.muted
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      font.letterSpacing: 1.5
    }

    Column {
      id: list
      width: scroller.width - Style.space(6)
      move: Transition { NumberAnimation { properties: "y"; duration: 250; easing.type: Easing.OutCubic } }

      Repeater {
        model: rows
        delegate: Item {
          id: row
          required property string key
          required property string proto
          required property string state
          required property string name
          required property int pid
          required property int lport
          required property string lsvc
          required property string lip
          required property string rhost
          required property string rip
          required property int rport
          required property string rsvc
          required property bool fresh

          readonly property bool listening: net.tab === "listen"
          width: list.width
          height: net.rowHeight

          opacity: 0
          transform: Translate { id: shift; x: -Style.space(8) }
          Component.onCompleted: { appear.start(); if (fresh) flash.start() }
          ParallelAnimation {
            id: appear
            NumberAnimation { target: row; property: "opacity"; to: 1; duration: 240; easing.type: Easing.OutCubic }
            NumberAnimation { target: shift; property: "x"; to: 0; duration: 280; easing.type: Easing.OutCubic }
          }

          Rectangle {
            id: bg
            anchors.fill: parent
            radius: Style.space(3)
            color: hover.containsMouse ? Util.alpha(net.fg, 0.07) : "transparent"
          }
          // New connection: brief accent flash.
          Rectangle {
            id: flashRect
            anchors.fill: parent
            radius: Style.space(3)
            color: net.mon.accent
            opacity: 0
            SequentialAnimation {
              id: flash
              NumberAnimation { target: flashRect; property: "opacity"; to: 0.25; duration: 120 }
              NumberAnimation { target: flashRect; property: "opacity"; to: 0; duration: 900; easing.type: Easing.OutCubic }
            }
          }
          MouseArea { id: hover; anchors.fill: parent; hoverEnabled: true }

          Row {
            id: cells
            anchors.verticalCenter: parent.verticalCenter
            x: Style.spacing.xs
            spacing: Style.spacing.md

            // Protocol badge.
            Rectangle {
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(30)
              height: Style.space(15)
              radius: Style.space(2)
              color: "transparent"
              border.width: 1
              border.color: Util.alpha(row.proto === "TCP" ? net.mon.accent : net.txColor, 0.6)
              Text {
                anchors.centerIn: parent
                text: row.proto
                color: row.proto === "TCP" ? net.mon.accent : net.txColor
                font.family: Style.font.family
                font.pixelSize: Style.font.caption - 1
                font.bold: true
              }
            }
            // Process.
            Text {
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(130)
              elide: Text.ElideRight
              text: row.name + (row.pid ? "  " : "")
              color: row.name === "—" ? net.muted : net.fg
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
            }
            // Local side.
            Text {
              anchors.verticalCenter: parent.verticalCenter
              width: row.listening ? Style.space(150) : Style.space(80)
              elide: Text.ElideRight
              text: row.listening ? row.lip : ":" + row.lport
              color: net.muted
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
            }
            // Direction arrow, or the listening port.
            Text {
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(row.listening ? 110 : 22)
              text: row.listening ? ":" + row.lport + (row.lsvc ? "  " + row.lsvc : "") : (net.tab === "in" ? "←" : "→")
              color: row.listening ? net.fg : (net.tab === "in" ? net.rxColor : net.txColor)
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              font.bold: !row.listening
            }
            // Remote host:port (host elides in the middle; port stays visible).
            Row {
              anchors.verticalCenter: parent.verticalCenter
              visible: !row.listening
              spacing: 0
              readonly property real avail: Math.max(0, row.width - cells.x - x - stateText.implicitWidth - Style.spacing.lg * 2)
              Text {
                width: Math.min(implicitWidth, parent.avail - portText.implicitWidth)
                elide: Text.ElideMiddle
                text: row.rhost
                color: net.fg
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
              }
              Text {
                id: portText
                text: ":" + row.rport + (row.rsvc ? " " + row.rsvc : "")
                color: net.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
              }
            }
          }

          // State chip.
          Text {
            id: stateText
            anchors.right: parent.right
            anchors.rightMargin: Style.spacing.sm
            anchors.verticalCenter: parent.verticalCenter
            text: row.state
            color: row.state === "ESTAB" ? net.mon.accent : row.state === "LISTEN" || row.state === "UNCONN" ? net.fg : net.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            font.letterSpacing: 1
          }
        }
      }
    }
  }
}
