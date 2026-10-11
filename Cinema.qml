import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
Panel {
  id: root
  moduleName: "paul.jellyfin"
  ipcTarget: "paul.jellyfin"
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight
  property bool connected: false
  property bool accountOpen: false
  property var movies: []
  property var sessions: []
  readonly property var localSession: sessions.find(function(entry) { return entry.local }) || null
  property int total: 0
  property int offset: 0
  property string message: ""
  property string pendingSecret: ""
  property string action: "status"
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property string helper: Qt.resolvedUrl("bin/jellyfin-cinema").toString().replace("file://", "")
  function run(args) {
    if (worker.running) return
    action = args[0]; worker.command = [helper].concat(args); worker.running = true
  }
  function browse() { run(["library", search.text, String(offset)]) }
  function refreshPlayback() { if (connected && opened && !worker.running && !accountOpen) run(["sessions"]) }
  Component.onCompleted: run(["status"])
  onOpenedChanged: if (opened && connected && !worker.running) { browse(); pollPlayback.start() } else pollPlayback.stop()
  Timer { id: pollPlayback; interval: 5000; repeat: true; onTriggered: root.refreshPlayback() }
  Process {
    id: worker
    stdinEnabled: true
    onStarted: { if (root.action === "login") { write(root.pendingSecret + "\n"); root.pendingSecret = ""; password.text = "" } }
    stdout: StdioCollector { id: output }
    stderr: StdioCollector { id: errors }
    onExited: function(code) {
      if (code !== 0) { root.message = errors.text.trim(); return }
      try {
        var result = JSON.parse(output.text)
        if (result.server !== undefined) server.text = result.server
        if (result.username !== undefined) username.text = result.username
        if (result.loggedIn !== undefined) root.connected = result.loggedIn
        if (result.items !== undefined) { root.movies = result.items; root.total = result.total }
        if (result.sessions !== undefined) root.sessions = result.sessions
        if (root.action !== "sessions") root.message = result.message || ""
        if (root.action === "login") { root.accountOpen = false; Qt.callLater(root.browse) }
        if (root.action === "status" && root.connected && root.opened) Qt.callLater(root.browse)
        if (root.action === "logout") root.movies = []
      } catch(e) { root.message = "Could not read Jellyfin response." }
    }
  }
  BarIconButton {
    id: button; anchors.fill: parent; bar: root.bar; text: "󰎁"; active: root.opened
    tooltipText: "Jellyfin · browse movies"; onPressed: root.toggle()
  }
  KeyboardPanel {
    id: panel
    anchorItem: button; owner: root; bar: root.bar; open: root.opened; focusTarget: catcher
    contentWidth: panel.fittedContentWidth(Style.space(440))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(760))
    PanelKeyCatcher {
      id: catcher; anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      Column {
        id: column; width: parent.width; spacing: Style.space(10)
        PanelHero { width: parent.width; title: "Jellyfin"; meta: root.sessions.length ? "Now playing" : "Pick a movie"; detail: ""; foreground: root.foreground; fontFamily: Style.font.family }
        Row {
          visible: root.sessions.length > 0; width: parent.width; spacing: Style.space(10)
          Image {
            visible: root.sessions.length > 0 && !!root.sessions[0].poster
            source: root.sessions[0] ? root.sessions[0].poster : ""
            width: Style.space(56); height: Style.space(82); fillMode: Image.PreserveAspectCrop; asynchronous: true
          }
          Column {
            width: parent.width - (root.sessions[0] && root.sessions[0].poster ? Style.space(66) : 0)
            spacing: Style.space(4)
            Text { width: parent.width; text: root.sessions[0] ? root.sessions[0].title : ""; color: root.foreground; elide: Text.ElideRight; font.bold: true }
            Text { width: parent.width; wrapMode: Text.WordWrap; color: Qt.darker(root.foreground,1.2); font.pixelSize: Style.font.caption
              text: root.sessions.length ? (root.sessions[0].paused ? "Paused" : "Playing") + " on " + root.sessions[0].device + (root.sessions.length > 1 ? " · +" + (root.sessions.length-1) + " more" : "") : ""
            }
            Text { visible: root.sessions.length > 0; width: parent.width; text: "Stop playback before starting another movie."; color: Qt.darker(root.foreground,1.3); font.pixelSize: Style.font.caption }
          }
        }
        Row {
          visible: root.localSession !== null; spacing: Style.space(6)
          Text { text: "Subtitles · " + (root.localSession ? (root.localSession.subtitleStyle === "terminal" ? "Terminal" : "Standard") + " · " + root.localSession.subtitleSize + "px" : ""); color: root.foreground; font.pixelSize: Style.font.caption; verticalAlignment: Text.AlignVCenter }
          Repeater {
            model: ["A−", "A+", "Style"]
            Rectangle {
              required property int index; required property string modelData
              width: Style.space(42); height: Style.space(30); radius: 5; color: Qt.darker(root.foreground,4)
              Text { anchors.centerIn: parent; text: modelData; color: root.foreground; font.pixelSize: Style.font.caption }
              MouseArea { anchors.fill: parent; enabled: !worker.running; onClicked: root.run([["subtitle-smaller"],["subtitle-larger"],["subtitle-toggle"]][index]) }
            }
          }
        }
        Column {
          visible: !root.connected || root.accountOpen; width: parent.width; spacing: Style.space(6)
          Text { text: "Server URL"; color: root.foreground }
          Rectangle { width: parent.width; height: Style.space(36); color: Qt.darker(root.foreground,5); radius: 5
            TextInput { id: server; anchors.fill: parent; anchors.margins: 8; color: root.foreground; selectByMouse: true; clip: true }
          }
          Text { text: "Username"; color: root.foreground }
          Rectangle { width: parent.width; height: Style.space(36); color: Qt.darker(root.foreground,5); radius: 5
            TextInput { id: username; anchors.fill: parent; anchors.margins: 8; color: root.foreground; selectByMouse: true; clip: true }
          }
          Text { text: "Password (may be blank)"; color: root.foreground }
          Rectangle { width: parent.width; height: Style.space(36); color: Qt.darker(root.foreground,5); radius: 5
            TextInput { id: password; anchors.fill: parent; anchors.margins: 8; color: root.foreground; echoMode: TextInput.Password; selectByMouse: true; clip: true }
          }
          Rectangle { width: parent.width; height: Style.space(36); color: Qt.darker(root.foreground,4); radius: 5
            Text { anchors.centerIn: parent; text: "Connect"; color: root.foreground }
            MouseArea { anchors.fill: parent; enabled: !worker.running; onClicked: { root.pendingSecret=JSON.stringify({server:server.text, username:username.text, password:password.text}); root.run(["login"]) } }
          }
        }
        Rectangle {
          visible: root.connected && !root.accountOpen
          width: parent.width; height: Style.space(36); color: Qt.darker(root.foreground,5); radius: 5
          TextInput { id: search; anchors.fill: parent; anchors.margins: 8; color: root.foreground; clip: true; selectByMouse: true; onAccepted: { root.offset=0; root.browse() }
            Text { visible: !search.text && !search.activeFocus; text: "Search movies · Enter"; color: Qt.darker(root.foreground,1.5) }
          }
        }
        GridView {
          id: grid
          visible: root.connected && !root.accountOpen
          width: parent.width; height: Style.space(360); clip: true
          cellWidth: width/4; cellHeight: Style.space(164)
          model: root.movies; boundsBehavior: Flickable.StopAtBounds
          reuseItems: true
          cacheBuffer: cellHeight * 2
          maximumFlickVelocity: Style.space(6000)
          flickDeceleration: Style.space(1500)
          WheelHandler {
            target: null
            onWheel: function(event) {
              var delta = event.pixelDelta.y !== 0 ? event.pixelDelta.y * 1.5 : event.angleDelta.y / 120 * grid.cellHeight * 0.85
              grid.contentY = Math.max(0, Math.min(Math.max(0, grid.contentHeight - grid.height), grid.contentY - delta))
              event.accepted = true
            }
          }
          delegate: Item {
            required property var modelData
            width: grid.cellWidth; height: grid.cellHeight
            Column {
              anchors.left: parent.left; anchors.right: parent.right; anchors.margins: Style.space(5); spacing: Style.space(3)
              Rectangle {
                width: parent.width; height: Style.space(120); radius: Style.space(5); color: Qt.darker(root.foreground,5); clip: true
                Image { anchors.fill: parent; source: modelData.poster; sourceSize.width: 180; fillMode: Image.PreserveAspectCrop; asynchronous: true }
                Text { anchors.centerIn: parent; visible: !modelData.poster; text: "󰎁"; color: root.foreground; font.pixelSize: Style.space(30) }
                Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: Style.space(22); color: "#b0000000"
                  Text { anchors.centerIn: parent; text: modelData.resume ? "▶ Resume" : "▶ Play"; color: "white"; font.pixelSize: Style.font.caption }
                }
                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; enabled: !worker.running && root.sessions.length === 0; onClicked: { root.run(["play",modelData.id]); root.close() } }
              }
              Text { width: parent.width; text: modelData.name; color: root.foreground; elide: Text.ElideRight; font.pixelSize: Style.font.caption }
              Text { text: String(modelData.year); color: Qt.darker(root.foreground,1.4); font.pixelSize: Style.font.caption }
            }
          }
        }
        Row {
          visible: root.connected && !root.accountOpen; spacing: Style.space(8)
          Repeater {
            model: ["‹ Previous", "Next ›", "Refresh"]
            Rectangle {
              required property int index; required property string modelData
              width: Style.space(125); height: Style.space(32); radius: 5; color: Qt.darker(root.foreground,4)
              opacity: enabled ? 1 : .4
              enabled: !worker.running && (index === 0 ? root.offset>0 : index === 1 ? root.offset+24<root.total : true)
              Text { anchors.centerIn: parent; text: modelData; color: root.foreground; font.pixelSize: Style.font.caption }
              MouseArea { anchors.fill: parent; onClicked: { if(index===0) root.offset-=24; if(index===1) root.offset+=24; root.browse() } }
            }
          }
        }
        Text { visible: root.connected && !root.accountOpen; text: root.total ? (root.offset+1)+"–"+Math.min(root.offset+24,root.total)+" of "+root.total+" movies" : "No movies found"; color: root.foreground; font.pixelSize: Style.font.caption }
        Row {
          spacing: Style.space(6)
          Repeater {
            model: ["Pin player", "Small", "Large", "Account"]
            Rectangle {
              required property int index; required property string modelData
              width: Style.space(98); height: Style.space(32); radius: 5; color: Qt.darker(root.foreground,4)
              Text { anchors.centerIn: parent; text: modelData; color: root.foreground; font.pixelSize: Style.font.caption }
              MouseArea { anchors.fill: parent; enabled: !worker.running; onClicked: { if(index===3) root.accountOpen=!root.accountOpen; else root.run([["pin"],["compact"],["roomy"]][index]) } }
            }
          }
        }
        Rectangle {
          visible: root.accountOpen && root.connected; width: parent.width; height: Style.space(32); color: Qt.darker(root.foreground,4); radius: 5
          Text { anchors.centerIn: parent; text: "Sign out"; color: root.foreground }
          MouseArea { anchors.fill: parent; enabled: !worker.running; onClicked: root.run(["logout"]) }
        }
        Text { width: parent.width; wrapMode: Text.WordWrap; text: worker.running ? "Loading…" : root.message; color: root.foreground; font.pixelSize: Style.font.caption }
      }
    }
  }
}
