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
  property bool hasSavedToken: false
  property bool authExpired: false
  property bool accountOpen: false
  property bool httpWarningAccepted: false
  property bool offlineMode: false
  property bool downloadRunning: false
  property bool offlineAllAccounts: true
  property var movies: []
  property var offlineMovies: []
  property var offlineJob: ({})
  property var syncPreview: null
  property string downloadDirectory: ""
  property string deleteCandidate: ""
  property bool folderEditorOpen: false
  property double offlineBytes: 0
  property var sessions: []
  readonly property var localSession: sessions.find(function(entry) { return entry.local }) || null
  property int total: 0
  property int offset: 0
  property string message: ""
  property string pendingSecret: ""
  property string action: "status"
  property string launchId: ""
  property bool waitingForPlayer: false
  property var pendingActions: []
  property var pendingPosterRefs: []
  property int libraryGeneration: 0
  property int posterRequestGeneration: 0
  property int pendingPosterGeneration: 0
  property int sessionGeneration: 0
  property int sessionRequestGeneration: 0
  property int sessionPosterRequestGeneration: 0
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property string helper: Qt.resolvedUrl("bin/jellyfin-cinema").toString().replace("file://", "")
  function run(args) {
    if (worker.running) {
      for (var i = 0; i < pendingActions.length; i++) {
        if (pendingActions[i][0] === args[0]) {
          pendingActions[i] = args
          return
        }
      }
      if (pendingActions.length >= 6) {
        message = "Busy with another Jellyfin request. Please wait and retry."
        return
      }
      pendingActions.push(args)
      return
    }
    action = args[0]; worker.command = [helper].concat(args); worker.running = true
  }
  function runNext() {
    if (!pendingActions.length) return
    var next = pendingActions.shift()
    Qt.callLater(function() { root.run(next) })
  }
  function finishPlayerLaunch(status, text) {
    waitingForPlayer = false
    launchId = ""
    pendingActions = pendingActions.filter(function(args) { return args[0] !== "launch-status" })
    if (status === "ready") root.close()
    else message = text || "The movie could not be started."
  }
  function expireLogin() {
    authExpired = true
    connected = false
    accountOpen = true
    movies = []
    sessions = sessions.filter(function(entry) { return entry.local })
    libraryGeneration++
    sessionGeneration++
    pendingPosterRefs = []
    message = "Jellyfin rejected the saved login. Clear it, then connect again."
    Qt.callLater(root.refreshOffline)
  }
  function queuePageWork(items) {
    libraryGeneration++
    var refs = items.filter(function(item) { return !!item.id && !!item.imageTag }).map(function(item) { return item.id + "~" + item.imageTag })
    if (refs.length) root.queuePosters(refs)
    root.refreshPlayback()
  }
  function queuePosters(refs) {
    if (posterWorker.running) {
      pendingPosterRefs = refs
      pendingPosterGeneration = libraryGeneration
      return
    }
    posterRequestGeneration = libraryGeneration
    posterWorker.command = [helper, "posters", refs.slice(0, 24).join(",")]
    posterWorker.running = true
  }
  function applyPosters(posters) {
    var updated = movies.slice()
    for (var m = 0; m < updated.length; m++) {
      var image = posters[updated[m].id]
      if (image && image.tag === updated[m].imageTag && image.url) updated[m].poster = image.url
    }
    movies = updated
  }
  function queueSessionPosters(records) {
    if (sessionPosterWorker.running) return
    var refs = records.filter(function(entry) { return !!entry.id && !!entry.imageTag && !entry.poster }).map(function(entry) { return entry.id + "~" + entry.imageTag })
    if (!refs.length) return
    sessionPosterRequestGeneration = sessionGeneration
    sessionPosterWorker.command = [helper, "posters", refs.slice(0, 8).join(",")]
    sessionPosterWorker.running = true
  }
  function browse() { run(["library", search.text, String(offset)]) }
  function refreshOffline() {
    if (offlineWorker.running) return
    offlineWorker.command = [helper, "offline-list"]
    offlineWorker.running = true
  }
  function offlineSaved(itemId) {
    for (var i = 0; i < offlineMovies.length; i++) if (offlineMovies[i].itemId === itemId) return true
    return false
  }
  function syncSavedFlags() {
    var saved = {}
    for (var i = 0; i < offlineMovies.length; i++) saved[offlineMovies[i].itemId] = true
    var updated = movies.slice()
    var changed = false
    for (var j = 0; j < updated.length; j++) {
      var flag = !!saved[updated[j].id]
      if (!!updated[j].downloaded !== flag) { updated[j].downloaded = flag; changed = true }
    }
    if (changed) movies = updated
  }
  function downloadFraction() {
    var total = Number(offlineJob.total || 0)
    if (total <= 0) return 0
    return Math.max(0, Math.min(1, Number(offlineJob.bytes || 0) / total))
  }
  function downloadStatusLine() {
    var job = offlineJob || {}
    var title = job.title || "Movie"
    if (downloadRunning && job.status !== "interrupted" && job.status !== "failed") {
      var pct = Number(job.total || 0) > 0 ? Math.round(downloadFraction() * 100) + "% · " : ""
      return title + " · " + pct + formatBytes(job.bytes) + (job.total ? " of " + formatBytes(job.total) : "")
    }
    return title + " · " + (job.message || job.status || "Download needs attention")
  }
  function startDownload(itemId) {
    if (!connected || downloadRunning || worker.running || waitingForPlayer) return
    var name = "Movie"
    for (var i = 0; i < movies.length; i++) if (movies[i].id === itemId) name = movies[i].name
    if (offlineJob && offlineJob.itemId === itemId && offlineJob.title) name = offlineJob.title
    message = "Saving " + name + "…"
    downloadRunning = true
    offlineJob = { status: "running", itemId: itemId, title: name, bytes: offlineJob && offlineJob.itemId === itemId ? offlineJob.bytes : 0, total: offlineJob && offlineJob.itemId === itemId ? offlineJob.total : 0, message: "Starting download…" }
    downloadWorker.command = [helper, "download", itemId]
    downloadWorker.running = true
    downloadPoll.start()
  }
  function startOfflinePlay(key) {
    if (worker.running || waitingForPlayer || localSession) return
    message = "Opening offline movie…"
    run(["play-offline", key])
  }
  function cancelDownload() {
    if (downloadCancelWorker.running) return
    downloadCancelWorker.command = [helper, "download-cancel"]
    downloadCancelWorker.running = true
  }
  function formatTicks(ticks) {
    var seconds = Math.floor(Number(ticks || 0) / 10000000)
    var hours = Math.floor(seconds / 3600)
    var minutes = Math.floor((seconds % 3600) / 60)
    var remainder = seconds % 60
    function pad(value) { return value < 10 ? "0" + value : String(value) }
    return hours ? hours + ":" + pad(minutes) + ":" + pad(remainder) : minutes + ":" + pad(remainder)
  }
  function formatBytes(bytes) {
    var value = Number(bytes || 0)
    if (value < 1024 * 1024) return Math.round(value / 1024) + " KB"
    if (value < 1024 * 1024 * 1024) return (value / (1024 * 1024)).toFixed(1) + " MB"
    return (value / (1024 * 1024 * 1024)).toFixed(1) + " GB"
  }
  function refreshPlayback() {
    if (!opened || accountOpen || waitingForPlayer || sessionWorker.running) return
    sessionRequestGeneration = sessionGeneration
    sessionWorker.command = [helper, "sessions"]
    sessionWorker.running = true
  }
  Component.onCompleted: { run(["status"]); refreshOffline() }
  onOpenedChanged: if (opened) { if (connected && !worker.running && !offlineMode) browse(); root.refreshPlayback(); refreshOffline(); pollPlayback.start() } else pollPlayback.stop()
  Timer { id: pollPlayback; interval: 5000; repeat: true; onTriggered: root.refreshPlayback() }
  Timer {
    id: pollPlayerLaunch; interval: 1000; repeat: true; running: root.waitingForPlayer
    onTriggered: if (root.launchId && !worker.running) root.run(["launch-status", root.launchId])
  }
  Process {
    id: worker
    stdinEnabled: true
    onStarted: { if (root.action === "login") { write(root.pendingSecret + "\n"); root.pendingSecret = ""; password.text = "" } }
    stdout: StdioCollector { id: output }
    stderr: StdioCollector { id: errors }
    onExited: function(code) {
      if (code !== 0) {
        if (root.action === "play" || root.action === "play-offline" || root.action === "launch-status") root.finishPlayerLaunch("failed", errors.text.trim() || "Could not start this movie.")
        if ((errors.text || "").indexOf("Jellyfin rejected the saved login") === 0) root.expireLogin()
        root.message = errors.text.trim() || "Jellyfin request failed. Check the server and try again."
        root.runNext()
        return
      }
      try {
        var result = JSON.parse(output.text)
        if (result.server !== undefined) server.text = result.server
        if (result.username !== undefined) username.text = result.username
        if (result.loggedIn !== undefined) { root.connected = result.loggedIn; root.hasSavedToken = result.loggedIn }
        if ((root.action === "offline-list" || root.action === "download-status") && result.items !== undefined) {
          root.offlineMovies = result.items
          root.offlineBytes = result.bytes || 0
          root.downloadDirectory = result.directory || root.downloadDirectory
          root.offlineJob = result.job || ({})
          root.offlineAllAccounts = result.allAccounts !== false
          if (result.job && result.job.status === "running") root.downloadRunning = !!result.active
        } else if (result.items !== undefined) {
          root.movies = result.items
          root.total = result.total
          if (!result.authExpired) root.queuePageWork(result.items)
        }
        if (result.sessions !== undefined) { root.sessions = result.sessions; root.queueSessionPosters(result.sessions) }
        if (result.subtitleStyle !== undefined && root.localSession) {
          var subtitleSessions = root.sessions.slice()
          for (var s = 0; s < subtitleSessions.length; s++) {
            if (subtitleSessions[s].local) {
              subtitleSessions[s].subtitleStyle = result.subtitleStyle
              subtitleSessions[s].subtitleSize = result.subtitleSize
            }
          }
          root.sessions = subtitleSessions
        }
        if (root.action === "play" || root.action === "play-offline") {
          root.launchId = result.launchId || ""
          if (result.status === "ready") root.finishPlayerLaunch("ready", result.message)
          else if (result.status === "starting" && root.launchId) {
            root.waitingForPlayer = true
            root.message = result.message || "Starting movie…"
          } else root.finishPlayerLaunch("failed", result.message)
        } else if (root.action === "launch-status") {
          if (result.status === "ready" || result.status === "failed") root.finishPlayerLaunch(result.status, result.message)
          else root.message = result.message || "Starting movie…"
        } else root.message = result.statusError ? "Playback status unavailable: " + result.statusError : (root.action === "sessions" ? "" : (result.message || ""))
        if (root.action === "offline-progress-preview") root.syncPreview = result
        if (root.action === "offline-progress-sync") { root.syncPreview = null; root.refreshOffline() }
        if (root.action === "offline-progress-keep-server") { root.syncPreview = null; root.refreshOffline() }
        if (root.action === "offline-delete") { root.deleteCandidate = ""; root.refreshOffline() }
        if (root.action === "offline-set-directory") { root.downloadDirectory = result.directory || root.downloadDirectory; root.refreshOffline() }
        if (root.action === "login") root.authExpired = false
        if (result.authExpired) root.expireLogin()
        if (root.action === "login") {
          root.authExpired = false
          root.sessionGeneration++
          root.sessions = []
          root.accountOpen = false
          Qt.callLater(root.browse)
          Qt.callLater(root.refreshOffline)
        }
        if (root.action === "status" && root.connected && root.opened) {
          Qt.callLater(root.browse)
          Qt.callLater(root.refreshPlayback)
          Qt.callLater(root.refreshOffline)
        }
        if (root.action === "logout") {
          root.hasSavedToken = false
          root.authExpired = false
          root.movies = []; root.sessions = []; root.accountOpen = false
          root.libraryGeneration++
          root.sessionGeneration++
          root.pendingPosterRefs = []
          Qt.callLater(root.refreshOffline)
        }
      } catch(e) {
        if (root.action === "play" || root.action === "play-offline" || root.action === "launch-status") root.finishPlayerLaunch("failed", "Could not read playback startup status.")
        else root.message = "Could not read Jellyfin response."
      }
      if (root.opened && root.connected && !root.waitingForPlayer) pollPlayback.start()
      root.runNext()
    }
  }
  Process {
    id: offlineWorker
    stdout: StdioCollector { id: offlineOutput }
    stderr: StdioCollector { id: offlineErrors }
    onExited: function(code) {
      if (code !== 0) { if (offlineErrors.text.trim()) root.message = offlineErrors.text.trim(); return }
      try {
        var result = JSON.parse(offlineOutput.text)
        root.offlineMovies = result.items || []
        root.offlineBytes = result.bytes || 0
        root.downloadDirectory = result.directory || root.downloadDirectory
        root.offlineJob = result.job || ({})
        root.offlineAllAccounts = result.allAccounts !== false
        root.downloadRunning = !!result.active || downloadWorker.running
        root.syncSavedFlags()
        if (result.active && !downloadWorker.running) Qt.callLater(root.refreshOffline)
      } catch(e) { root.message = "Could not read the offline library." }
    }
  }
  Process {
    id: downloadWorker
    stdout: StdioCollector { id: downloadOutput }
    stderr: StdioCollector { id: downloadErrors }
    onExited: function(code) {
      root.downloadRunning = false
      downloadPoll.stop()
      if (code === 0) {
        try { root.message = JSON.parse(downloadOutput.text).message || "Download complete." }
        catch(e) { root.message = "Download complete." }
      } else {
        var downloadError = downloadErrors.text.trim()
        if (downloadError.indexOf("Jellyfin rejected the saved login") === 0) root.expireLogin()
        root.message = downloadError || "The download failed. Retry from the same movie to resume when supported."
      }
      root.refreshOffline()
    }
  }
  Process {
    id: downloadCancelWorker
    stdout: StdioCollector { id: cancelOutput }
    stderr: StdioCollector { id: cancelErrors }
    onExited: function(code) {
      if (code === 0) {
        try { root.message = JSON.parse(cancelOutput.text).message || "Cancel requested." }
        catch(e) { root.message = "Cancel requested." }
      } else root.message = cancelErrors.text.trim() || "Could not cancel the download."
      root.refreshOffline()
    }
  }
  Timer { id: downloadPoll; interval: 1000; repeat: true; onTriggered: root.refreshOffline() }
  Process {
    id: sessionWorker
    stdout: StdioCollector { id: sessionOutput }
    stderr: StdioCollector { id: sessionErrors }
    onExited: function(code) {
      if (root.sessionRequestGeneration !== root.sessionGeneration) return
      if (code !== 0) { root.message = "Playback status unavailable: " + (sessionErrors.text.trim() || "Could not refresh playback status."); return }
      try {
        var result = JSON.parse(sessionOutput.text)
        if (result.sessions !== undefined) { root.sessions = result.sessions; root.queueSessionPosters(result.sessions) }
        if (result.authExpired) root.expireLogin()
        else if (result.statusError) root.message = "Playback status unavailable: " + result.statusError
        else if (root.message.indexOf("Playback status unavailable:") === 0) root.message = ""
      } catch(e) { root.message = "Could not read playback status." }
    }
  }
  Process {
    id: posterWorker
    stdout: StdioCollector { id: posterOutput }
    stderr: StdioCollector { id: posterErrors }
    onExited: function(code) {
      if (code === 0) {
        try {
          var result = JSON.parse(posterOutput.text)
          if (root.posterRequestGeneration === root.libraryGeneration)
            root.applyPosters(result.posters || {})
        } catch(e) {}
      }
      if (root.pendingPosterRefs.length) {
        var refs = root.pendingPosterRefs
        root.pendingPosterRefs = []
        root.libraryGeneration = root.pendingPosterGeneration
        root.queuePosters(refs)
      }
    }
  }
  Process {
    id: sessionPosterWorker
    stdout: StdioCollector { id: sessionPosterOutput }
    stderr: StdioCollector { id: sessionPosterErrors }
    onExited: function(code) {
      if (code !== 0 || root.sessionPosterRequestGeneration !== root.sessionGeneration) return
      try {
        var result = JSON.parse(sessionPosterOutput.text)
        var posters = result.posters || {}; var updated = root.sessions.slice()
        for (var i = 0; i < updated.length; i++) {
          var image = posters[updated[i].id]
          if (image && image.tag === updated[i].imageTag && image.url) updated[i].poster = image.url
        }
        root.sessions = updated
      } catch(e) {}
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
    contentHeight: panel.fittedContentHeight(Style.space(640))
    PanelKeyCatcher {
      id: catcher; anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      Item { id: layout; anchors.fill: parent; clip: true
      Column {
        id: column; anchors.top: parent.top; anchors.left: parent.left; anchors.right: parent.right; width: parent.width; spacing: Style.space(8)
        PanelHero { width: parent.width; title: "Jellyfin"; meta: root.sessions.length ? "Now playing" : "Pick a movie"; detail: ""; foreground: root.foreground; fontFamily: Style.font.family }
        Row {
          width: parent.width; spacing: Style.space(8)
          Repeater {
            model: ["Browse", "Offline · " + root.offlineMovies.length]
            Rectangle {
              required property int index; required property string modelData
              width: (parent.width - Style.space(8)) / 2; height: Style.space(32); radius: 5
              color: root.offlineMode === (index === 1) ? Qt.darker(root.foreground,3) : Qt.darker(root.foreground,5)
              opacity: index === 0 && !root.connected ? .45 : 1
              border.width: modeTab.activeFocus ? 2 : 0; border.color: root.foreground
              Text { anchors.centerIn: parent; text: modelData; color: root.foreground; font.pixelSize: Style.font.caption }
              MouseArea {
                id: modeTab; anchors.fill: parent; enabled: index === 1 || root.connected; focus: true; activeFocusOnTab: true
                function activate() {
                  if (!enabled) return
                  root.offlineMode = index === 1
                  root.accountOpen = false
                  if (root.offlineMode) root.refreshOffline()
                  else root.browse()
                }
                onClicked: activate()
                Keys.onReturnPressed: function(event) { activate(); event.accepted = true }
                Keys.onEnterPressed: function(event) { activate(); event.accepted = true }
                Keys.onSpacePressed: function(event) { activate(); event.accepted = true }
              }
            }
          }
        }
        Rectangle {
          id: downloadCard
          visible: root.downloadRunning || ["running", "interrupted", "failed"].indexOf(String(root.offlineJob.status || "")) >= 0
          width: parent.width; height: Style.space(58); radius: 6; color: Qt.darker(root.foreground, 5); clip: true
          Column {
            anchors.fill: parent; anchors.margins: Style.space(8); spacing: Style.space(5)
            Row {
              width: parent.width; spacing: Style.space(6)
              Text {
                width: parent.width - downloadCardActions.width - Style.space(6)
                text: root.downloadStatusLine()
                color: root.foreground; font.pixelSize: Style.font.caption; font.bold: true; elide: Text.ElideRight
                verticalAlignment: Text.AlignVCenter; height: Style.space(28)
              }
              Row {
                id: downloadCardActions; spacing: Style.space(4)
                Rectangle {
                  visible: root.offlineJob.status === "interrupted" || root.offlineJob.status === "failed"
                  width: Style.space(68); height: Style.space(28); radius: 4; color: Qt.darker(root.foreground, 3)
                  opacity: root.connected && !root.downloadRunning ? 1 : .4
                  border.width: retryDownloadArea.activeFocus ? 2 : 0; border.color: root.foreground
                  Text { anchors.centerIn: parent; text: root.offlineJob.status === "failed" ? "Retry" : "Resume"; color: root.foreground; font.pixelSize: Style.font.caption }
                  MouseArea {
                    id: retryDownloadArea; anchors.fill: parent; enabled: root.connected && !root.downloadRunning && !root.waitingForPlayer; focus: true; activeFocusOnTab: true
                    function activate() { if (enabled && root.offlineJob.itemId) root.startDownload(root.offlineJob.itemId) }
                    onClicked: activate()
                    Keys.onReturnPressed: function(event) { activate(); event.accepted = true }
                    Keys.onEnterPressed: function(event) { activate(); event.accepted = true }
                    Keys.onSpacePressed: function(event) { activate(); event.accepted = true }
                  }
                }
                Rectangle {
                  visible: root.downloadRunning || ["running", "interrupted", "failed"].indexOf(String(root.offlineJob.status || "")) >= 0
                  width: Style.space(72); height: Style.space(28); radius: 4; color: Qt.darker(root.foreground, 3)
                  border.width: cardCancelArea.activeFocus ? 2 : 0; border.color: root.foreground
                  Text { anchors.centerIn: parent; text: root.downloadRunning || root.offlineJob.status === "running" ? "Cancel" : "Remove"; color: root.foreground; font.pixelSize: Style.font.caption }
                  MouseArea {
                    id: cardCancelArea; anchors.fill: parent; enabled: !downloadCancelWorker.running; focus: true; activeFocusOnTab: true
                    function activate() { if (enabled) root.cancelDownload() }
                    onClicked: activate()
                    Keys.onReturnPressed: function(event) { activate(); event.accepted = true }
                    Keys.onEnterPressed: function(event) { activate(); event.accepted = true }
                    Keys.onSpacePressed: function(event) { activate(); event.accepted = true }
                  }
                }
              }
            }
            Rectangle {
              width: parent.width; height: Style.space(6); radius: 3; color: Qt.darker(root.foreground, 3); clip: true
              Rectangle {
                width: parent.width * (root.downloadRunning && !(root.offlineJob.total > 0) ? 0.08 : root.downloadFraction())
                height: parent.height; radius: 3; color: root.foreground
              }
            }
          }
        }
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
            Text { visible: root.sessions.length > 0; width: parent.width; text: root.localSession ? "A movie is playing on this computer." : "Remote playback continues if you start a movie here."; color: Qt.darker(root.foreground,1.3); font.pixelSize: Style.font.caption }
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
          visible: !root.offlineMode && (!root.connected || root.accountOpen); width: parent.width; spacing: Style.space(6)
          Text { text: "Server URL"; color: root.foreground }
          Rectangle { width: parent.width; height: Style.space(36); color: Qt.darker(root.foreground,5); radius: 5
            TextInput { id: server; anchors.fill: parent; anchors.margins: 8; color: root.foreground; selectByMouse: true; clip: true; onTextChanged: root.httpWarningAccepted = false }
          }
          Row {
            visible: server.text.toLowerCase().indexOf("http://") === 0; spacing: Style.space(6); width: parent.width
            Rectangle { width: Style.space(18); height: Style.space(18); radius: 3; color: root.httpWarningAccepted ? Qt.darker(root.foreground,2) : Qt.darker(root.foreground,5); border.color: root.foreground
              Text { anchors.centerIn: parent; text: root.httpWarningAccepted ? "✓" : ""; color: root.foreground; font.pixelSize: Style.font.caption }
              MouseArea { anchors.fill: parent; onClicked: root.httpWarningAccepted = !root.httpWarningAccepted }
            }
            Text { width: parent.width - Style.space(25); wrapMode: Text.WordWrap; text: "I trust this network. HTTP sends my password and session token without encryption."; color: root.foreground; font.pixelSize: Style.font.caption
              MouseArea { anchors.fill: parent; onClicked: root.httpWarningAccepted = !root.httpWarningAccepted }
            }
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
            MouseArea { anchors.fill: parent; enabled: !worker.running && (server.text.toLowerCase().indexOf("http://") !== 0 || root.httpWarningAccepted); onClicked: { root.pendingSecret=JSON.stringify({server:server.text, username:username.text, password:password.text, allowInsecureHttp:root.httpWarningAccepted}); root.run(["login"]) } }
          }
        }
        Rectangle {
          visible: root.connected && !root.accountOpen && !root.offlineMode
          width: parent.width; height: Style.space(36); color: Qt.darker(root.foreground,5); radius: 5
          TextInput { id: search; anchors.fill: parent; anchors.margins: 8; color: root.foreground; clip: true; selectByMouse: true; onAccepted: { root.offset=0; root.browse() }
            Text { visible: !search.text && !search.activeFocus; text: "Search movies · Enter"; color: Qt.darker(root.foreground,1.5) }
          }
        }
      }
        GridView {
          id: grid
          visible: root.connected && !root.accountOpen && !root.offlineMode
          anchors.left: parent.left; anchors.right: parent.right
          anchors.top: column.bottom; anchors.topMargin: Style.space(8)
          anchors.bottom: footer.top; anchors.bottomMargin: Style.space(8)
          clip: true
          cellWidth: width/4; cellHeight: Style.space(168)
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
                id: onlinePoster
                width: parent.width; height: Style.space(96); radius: Style.space(5); color: Qt.darker(root.foreground,5); clip: true
                border.width: onlinePlayArea.activeFocus ? 2 : 0; border.color: root.foreground
                Image { anchors.fill: parent; source: modelData.poster; sourceSize.width: 180; fillMode: Image.PreserveAspectCrop; asynchronous: true }
                Text { anchors.centerIn: parent; visible: !modelData.poster; text: "󰎁"; color: root.foreground; font.pixelSize: Style.space(30) }
                Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: Style.space(22); color: "#b0000000"
                  Text { anchors.centerIn: parent; text: modelData.resume ? "▶ Resume" : "▶ Play"; color: "white"; font.pixelSize: Style.font.caption }
                }
                Rectangle {
                  visible: root.offlineJob.itemId === modelData.id && (root.downloadRunning || root.offlineJob.status === "running") && root.offlineJob.total > 0
                  anchors.bottom: parent.bottom; anchors.bottomMargin: Style.space(22)
                  width: parent.width * root.downloadFraction(); height: Style.space(3); color: root.foreground
                }
                MouseArea { id: onlinePlayArea; anchors.fill: parent; cursorShape: Qt.PointingHandCursor; enabled: !worker.running && !root.localSession && !root.waitingForPlayer; focus: true; activeFocusOnTab: true
                  function activate() { root.message = "Opening movie…"; root.run(["play",modelData.id]) }
                  onClicked: activate()
                  Keys.onReturnPressed: function(event) { activate(); event.accepted = true }
                  Keys.onEnterPressed: function(event) { activate(); event.accepted = true }
                }
              }
              Text { width: parent.width; text: modelData.name + (modelData.year ? " · " + modelData.year : ""); color: root.foreground; elide: Text.ElideRight; font.pixelSize: Style.font.caption }
              Rectangle {
                width: parent.width; height: Style.space(22); radius: 4
                property bool saved: !!modelData.downloaded || root.offlineSaved(modelData.id)
                property bool savingThis: root.offlineJob.itemId === modelData.id && (root.downloadRunning || root.offlineJob.status === "running")
                color: saved ? Qt.darker(root.foreground, 5) : Qt.darker(root.foreground, 3.2)
                opacity: saved || savingThis || !root.downloadRunning ? 1 : .4
                border.width: onlineDownloadArea.activeFocus ? 2 : 0; border.color: root.foreground
                Text {
                  anchors.centerIn: parent; font.pixelSize: Style.font.caption; color: root.foreground
                  text: parent.saved ? "Saved" : parent.savingThis ? (root.offlineJob.total > 0 ? Math.round(root.downloadFraction() * 100) + "%" : "Saving…") : "Download"
                }
                MouseArea {
                  id: onlineDownloadArea; anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                  enabled: !parent.saved && !parent.savingThis && !root.downloadRunning; focus: true; activeFocusOnTab: true
                  onClicked: root.startDownload(modelData.id)
                  Keys.onReturnPressed: function(event) { if (enabled) root.startDownload(modelData.id); event.accepted = true }
                  Keys.onEnterPressed: function(event) { if (enabled) root.startDownload(modelData.id); event.accepted = true }
                  Keys.onSpacePressed: function(event) { if (enabled) root.startDownload(modelData.id); event.accepted = true }
                }
              }
            }
          }
        }
        Column {
          id: offlineBody
          visible: root.offlineMode
          anchors.left: parent.left; anchors.right: parent.right
          anchors.top: column.bottom; anchors.topMargin: Style.space(8)
          anchors.bottom: footer.top; anchors.bottomMargin: Style.space(8)
          spacing: Style.space(6)
          Row {
            width: parent.width; spacing: Style.space(6)
            Text {
              width: parent.width - Style.space(92)
              text: root.formatBytes(root.offlineBytes) + " saved · " + (root.downloadDirectory || "Downloads/Jellyfin Cinema")
              color: root.foreground; font.pixelSize: Style.font.caption; elide: Text.ElideMiddle; verticalAlignment: Text.AlignVCenter; height: Style.space(30)
            }
            Rectangle {
              width: Style.space(86); height: Style.space(30); radius: 5; color: Qt.darker(root.foreground, 4)
              border.width: folderToggle.activeFocus ? 2 : 0; border.color: root.foreground
              Text { anchors.centerIn: parent; text: root.folderEditorOpen ? "Close" : "Folder"; color: root.foreground; font.pixelSize: Style.font.caption }
              MouseArea {
                id: folderToggle; anchors.fill: parent; focus: true; activeFocusOnTab: true
                function activate() { root.folderEditorOpen = !root.folderEditorOpen }
                onClicked: activate()
                Keys.onReturnPressed: function(event) { activate(); event.accepted = true }
                Keys.onEnterPressed: function(event) { activate(); event.accepted = true }
                Keys.onSpacePressed: function(event) { activate(); event.accepted = true }
              }
            }
          }
          Text { width: parent.width; elide: Text.ElideRight; color: Qt.darker(root.foreground, 1.35); font.pixelSize: Style.font.caption
            text: root.offlineAllAccounts ? "Every account on this computer. Files stay until you delete them." : "This account. Files stay on this computer after sign-out."
          }
          Row {
            visible: root.folderEditorOpen; width: parent.width; spacing: Style.space(6)
            Rectangle { width: parent.width - Style.space(78); height: Style.space(34); color: Qt.darker(root.foreground, 5); radius: 5
              TextInput { id: offlineDirectory; anchors.fill: parent; anchors.margins: 7; text: root.downloadDirectory; color: root.foreground; selectByMouse: true; clip: true; font.pixelSize: Style.font.caption }
            }
            Rectangle { width: Style.space(72); height: Style.space(34); color: Qt.darker(root.foreground, 4); radius: 5; opacity: root.downloadRunning ? .4 : 1
              border.width: setFolder.activeFocus ? 2 : 0; border.color: root.foreground
              Text { anchors.centerIn: parent; text: "Save"; color: root.foreground; font.pixelSize: Style.font.caption }
              MouseArea { id: setFolder; anchors.fill: parent; enabled: !root.downloadRunning && !worker.running; focus: true; activeFocusOnTab: true
                function activate() { if (enabled) root.run(["offline-set-directory", offlineDirectory.text]) }
                onClicked: activate()
                Keys.onReturnPressed: function(event) { activate(); event.accepted = true }
                Keys.onEnterPressed: function(event) { activate(); event.accepted = true }
                Keys.onSpacePressed: function(event) { activate(); event.accepted = true }
              }
            }
          }
        Column {
          id: offlineSync
          visible: !!root.syncPreview; width: parent.width; spacing: Style.space(5)
          Text { width: parent.width; wrapMode: Text.WordWrap; color: root.foreground; font.pixelSize: Style.font.caption
            text: root.syncPreview ? root.syncPreview.name + " · local " + root.formatTicks(root.syncPreview.localTicks) + " / server " + root.formatTicks(root.syncPreview.serverTicks) + ". Choose which position to keep." : ""
          }
          Row { spacing: Style.space(6)
            Rectangle { width: Style.space(190); height: Style.space(30); radius: 5; color: Qt.darker(root.foreground,4)
              Text { anchors.centerIn: parent; text: "Send local position"; color: root.foreground; font.pixelSize: Style.font.caption }
              border.width: sendProgress.activeFocus ? 2 : 0; border.color: root.foreground
              MouseArea { id: sendProgress; anchors.fill: parent; enabled: !!root.syncPreview && !worker.running; focus: true; activeFocusOnTab: true
                function activate() { if(enabled) root.run(["offline-progress-sync",root.syncPreview.key,String(root.syncPreview.serverTicks)]) }
                onClicked: activate()
                Keys.onReturnPressed: function(event) { activate(); event.accepted = true }
              }
            }
            Rectangle { width: Style.space(135); height: Style.space(30); radius: 5; color: Qt.darker(root.foreground,4)
              Text { anchors.centerIn: parent; text: "Use server here"; color: root.foreground; font.pixelSize: Style.font.caption }
              border.width: keepServerProgress.activeFocus ? 2 : 0; border.color: root.foreground
              MouseArea { id: keepServerProgress; anchors.fill: parent; enabled: !!root.syncPreview && root.connected && !worker.running; focus: true; activeFocusOnTab: true; onClicked: root.run(["offline-progress-keep-server",root.syncPreview.key,String(root.syncPreview.serverTicks)])
                Keys.onReturnPressed: function(event) { if(enabled) root.run(["offline-progress-keep-server",root.syncPreview.key,String(root.syncPreview.serverTicks)]); event.accepted = true }
              }
            }
          }
        }
        ListView {
          id: offlineList
          visible: root.offlineMovies.length > 0
          width: parent.width
          height: Math.max(Style.space(72), offlineBody.height - offlineList.y)
          clip: true
          spacing: Style.space(6)
          model: root.offlineMovies; boundsBehavior: Flickable.StopAtBounds
          reuseItems: true
          WheelHandler {
            target: null
            onWheel: function(event) {
              var delta = event.pixelDelta.y !== 0 ? event.pixelDelta.y * 1.5 : event.angleDelta.y / 120 * Style.space(70)
              offlineList.contentY = Math.max(0, Math.min(Math.max(0, offlineList.contentHeight - offlineList.height), offlineList.contentY - delta))
              event.accepted = true
            }
          }
          delegate: Rectangle {
            required property var modelData
            width: offlineList.width; height: Style.space(86); radius: 6; color: Qt.darker(root.foreground, 5)
            Row {
              anchors.fill: parent; anchors.margins: Style.space(6); spacing: Style.space(8)
              Rectangle {
                width: Style.space(48); height: Style.space(72); radius: 4; color: Qt.darker(root.foreground, 4); clip: true
                border.width: offlinePlayArea.activeFocus ? 2 : 0; border.color: root.foreground
                Image { anchors.fill: parent; source: modelData.poster; sourceSize.width: 120; fillMode: Image.PreserveAspectCrop; asynchronous: true }
                Text { anchors.centerIn: parent; visible: !modelData.poster; text: "󰎁"; color: root.foreground }
                MouseArea { id: offlinePlayArea; anchors.fill: parent; cursorShape: Qt.PointingHandCursor; enabled: !worker.running && !root.localSession && !root.waitingForPlayer; focus: true; activeFocusOnTab: true
                  onClicked: root.startOfflinePlay(modelData.key)
                  Keys.onReturnPressed: function(event) { root.startOfflinePlay(modelData.key); event.accepted = true }
                  Keys.onEnterPressed: function(event) { root.startOfflinePlay(modelData.key); event.accepted = true }
                  Keys.onSpacePressed: function(event) { root.startOfflinePlay(modelData.key); event.accepted = true }
                }
              }
              Column {
                width: parent.width - Style.space(56); spacing: Style.space(4)
                Text { width: parent.width; text: modelData.name + (modelData.year ? " · " + modelData.year : ""); color: root.foreground; font.bold: true; elide: Text.ElideRight; font.pixelSize: Style.font.caption }
                Text {
                  width: parent.width; color: Qt.darker(root.foreground, 1.3); font.pixelSize: Style.font.caption; elide: Text.ElideRight
                  text: root.formatBytes(modelData.bytes) + (modelData.positionTicks > 0 ? " · resume " + root.formatTicks(modelData.positionTicks) : " · not started")
                }
                Row { spacing: Style.space(4)
                  Rectangle { width: Style.space(72); height: Style.space(26); radius: 4; color: Qt.darker(root.foreground, 3)
                    border.width: offlinePlayButton.activeFocus ? 2 : 0; border.color: root.foreground
                    Text { anchors.centerIn: parent; text: modelData.positionTicks > 0 ? "Resume" : "Play"; color: root.foreground; font.pixelSize: Style.font.caption }
                    MouseArea { id: offlinePlayButton; anchors.fill: parent; enabled: !worker.running && !root.localSession && !root.waitingForPlayer; focus: true; activeFocusOnTab: true
                      function activate() { if (enabled) root.startOfflinePlay(modelData.key) }
                      onClicked: activate()
                      Keys.onReturnPressed: function(event) { activate(); event.accepted = true }
                      Keys.onEnterPressed: function(event) { activate(); event.accepted = true }
                      Keys.onSpacePressed: function(event) { activate(); event.accepted = true }
                    }
                  }
                  Rectangle { visible: root.connected; width: Style.space(64); height: Style.space(26); radius: 4; color: Qt.darker(root.foreground, 3)
                    border.width: syncArea.activeFocus ? 2 : 0; border.color: root.foreground
                    Text { anchors.centerIn: parent; text: root.syncPreview && root.syncPreview.key === modelData.key ? "Sync…" : "Sync"; color: root.foreground; font.pixelSize: Style.font.caption }
                    MouseArea { id: syncArea; anchors.fill: parent; enabled: root.connected && !worker.running; focus: true; activeFocusOnTab: true
                      function activate() { if (enabled) { root.syncPreview = null; root.run(["offline-progress-preview", modelData.key]) } }
                      onClicked: activate()
                      Keys.onReturnPressed: function(event) { activate(); event.accepted = true }
                      Keys.onEnterPressed: function(event) { activate(); event.accepted = true }
                      Keys.onSpacePressed: function(event) { activate(); event.accepted = true }
                    }
                  }
                  Rectangle { width: Style.space(78); height: Style.space(26); radius: 4; color: root.deleteCandidate === modelData.key ? "#803030" : Qt.darker(root.foreground, 3)
                    border.width: deleteArea.activeFocus ? 2 : 0; border.color: root.foreground
                    Text { anchors.centerIn: parent; text: root.deleteCandidate === modelData.key ? "Confirm" : "Delete"; color: root.foreground; font.pixelSize: Style.font.caption }
                    MouseArea { id: deleteArea; anchors.fill: parent; enabled: !worker.running; focus: true; activeFocusOnTab: true
                      function activate() {
                        if (root.deleteCandidate === modelData.key) root.run(["offline-delete", modelData.key])
                        else { root.deleteCandidate = modelData.key; root.message = "Tap Confirm to delete " + modelData.name + "." }
                      }
                      onClicked: activate()
                      Keys.onReturnPressed: function(event) { activate(); event.accepted = true }
                      Keys.onEnterPressed: function(event) { activate(); event.accepted = true }
                      Keys.onSpacePressed: function(event) { activate(); event.accepted = true }
                    }
                  }
                }
              }
            }
          }
        }
        Text { visible: root.offlineMovies.length === 0; width: parent.width; wrapMode: Text.WordWrap; color: root.foreground; font.pixelSize: Style.font.caption
          text: "No movies saved yet. On Browse, use Download under a poster. Playback works here without the server."
        }
        }
        Column {
          id: footer
          anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
          spacing: Style.space(6)
          Rectangle {
            visible: root.connected && !root.accountOpen && !root.offlineMode
            width: parent.width; height: Style.space(34); radius: Math.min(Style.cornerRadius, Style.space(6)); color: Qt.darker(root.foreground, 5.5)
            Row {
              id: pageBar; anchors.fill: parent
              Item {
                width: Style.space(78); height: parent.height
                opacity: root.offset > 0 && !worker.running ? 1 : 0.35
                Text { anchors.centerIn: parent; text: "Previous"; color: root.foreground; font.pixelSize: Style.font.caption }
                MouseArea { anchors.fill: parent; enabled: root.offset > 0 && !worker.running; onClicked: { root.offset = Math.max(0, root.offset - 24); root.browse() } }
              }
              Rectangle { width: 1; height: parent.height; color: Qt.darker(root.foreground, 3) }
              Item {
                width: Math.max(0, pageBar.width - Style.space(156) - 2); height: parent.height
                Text { anchors.centerIn: parent; color: root.foreground; font.pixelSize: Style.font.caption
                  text: root.total ? ((root.offset + 1) + "–" + Math.min(root.offset + 24, root.total) + " of " + root.total) : "No movies"
                }
                MouseArea { anchors.fill: parent; enabled: !worker.running; onClicked: root.browse() }
              }
              Rectangle { width: 1; height: parent.height; color: Qt.darker(root.foreground, 3) }
              Item {
                width: Style.space(78); height: parent.height
                opacity: !worker.running && root.offset + 24 < root.total ? 1 : 0.35
                Text { anchors.centerIn: parent; text: "Next"; color: root.foreground; font.pixelSize: Style.font.caption }
                MouseArea { anchors.fill: parent; enabled: !worker.running && root.offset + 24 < root.total; onClicked: { root.offset += 24; root.browse() } }
              }
            }
          }
          Rectangle {
            width: parent.width; height: Style.space(34); radius: Math.min(Style.cornerRadius, Style.space(6)); color: Qt.darker(root.foreground, 5.5)
            Row {
              id: actionBar; anchors.fill: parent
              Repeater {
                model: ["Pin", "Small", "Large", "Account"]
                Item {
                  required property int index; required property string modelData
                  width: actionBar.width / 4; height: actionBar.height
                  opacity: (!worker.running && !root.waitingForPlayer && (index !== 3 || !root.downloadRunning)) ? 1 : 0.4
                  Rectangle { visible: index > 0; anchors.left: parent.left; width: 1; height: parent.height; color: Qt.darker(root.foreground, 3) }
                  Text { anchors.centerIn: parent; text: modelData; color: root.foreground; font.pixelSize: Style.font.caption }
                  MouseArea {
                    anchors.fill: parent
                    enabled: !worker.running && !root.waitingForPlayer && (index !== 3 || !root.downloadRunning)
                    onClicked: { if (index === 3) root.accountOpen = !root.accountOpen; else root.run([["pin"], ["compact"], ["roomy"]][index]) }
                  }
                }
              }
            }
          }
          Rectangle {
            visible: root.accountOpen && root.hasSavedToken
            width: parent.width; height: Style.space(34); radius: Math.min(Style.cornerRadius, Style.space(6)); color: Qt.darker(root.foreground, 5.5)
            opacity: (!worker.running && !root.waitingForPlayer && !root.downloadRunning) ? 1 : 0.4
            Text { anchors.centerIn: parent; text: root.authExpired ? "Clear saved login" : "Sign out"; color: root.foreground; font.pixelSize: Style.font.caption }
            MouseArea { anchors.fill: parent; enabled: !worker.running && !root.waitingForPlayer && !root.downloadRunning; onClicked: root.run(["logout"]) }
          }
          Text {
            width: parent.width; visible: text !== ""; elide: Text.ElideRight
            text: root.waitingForPlayer ? root.message : worker.running ? "Loading…" : root.message
            color: Qt.darker(root.foreground, 1.25); font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }
}
