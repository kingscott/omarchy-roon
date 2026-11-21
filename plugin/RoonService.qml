pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// Runs roon-helper.py once for every bar surface and holds what it reports.
// Widgets call attach(host, port) when created and detach() when destroyed;
// the helper runs while at least one is alive.
Item {
  id: root

  readonly property string helperPath: decodeURIComponent(String(Qt.resolvedUrl("roon-helper.py")).replace(/^file:\/\//, ""))

  property int consumers: 0
  property string host: ""
  property int port: 9330

  // "starting", "no_host", "connecting", "waiting_auth", "connected", "error"
  property string status: "starting"
  property string coreName: ""
  property string message: ""
  property var zones: []
  // image key -> local file path, filled as the helper downloads album art
  property var artPaths: ({})

  // Zone the widget shows. Empty follows whichever zone is playing.
  property string selectedZoneId: ""

  readonly property var currentZone: {
    var list = root.zones
    var i
    for (i = 0; i < list.length; i++) if (list[i].id === root.selectedZoneId) return list[i]
    for (i = 0; i < list.length; i++) if (list[i].state === "playing") return list[i]
    for (i = 0; i < list.length; i++) if (list[i].title) return list[i]
    return list.length > 0 ? list[0] : null
  }

  onCurrentZoneChanged: requestArt()

  function attach(newHost, newPort) {
    root.consumers = root.consumers + 1
    configure(newHost, newPort)
    if (!helper.running && !retry.running) helper.running = true
  }

  // Restarts the helper when the Core address in the widget settings changes.
  function configure(newHost, newPort) {
    if (newHost === root.host && newPort === root.port) return
    root.host = newHost
    root.port = newPort
    root.status = "starting"
    root.zones = []
    if (helper.running) restart()
  }

  function detach() {
    root.consumers = Math.max(0, root.consumers - 1)
    if (root.consumers === 0) {
      retry.stop()
      helper.running = false
    }
  }

  function restart() {
    retry.interval = 200
    retry.restart()
    helper.running = false
  }

  function send(command) {
    if (helper.running) helper.write(JSON.stringify(command) + "\n")
  }

  function control(action) {
    if (root.currentZone) send({ cmd: "control", zone: root.currentZone.id, control: action })
  }

  // Moves what is playing to `zoneId` when that zone is not already playing
  // something of its own; either way the widget follows that zone from now on.
  function selectZone(zoneId) {
    var from = root.currentZone
    var to = null
    for (var i = 0; i < root.zones.length; i++) if (root.zones[i].id === zoneId) to = root.zones[i]
    if (from && to && from.id !== zoneId && from.state === "playing" && to.state !== "playing")
      send({ cmd: "transfer", from: from.id, to: zoneId })
    root.selectedZoneId = zoneId
  }

  function requestArt() {
    var zone = root.currentZone
    if (zone && zone.image && !root.artPaths[zone.image]) send({ cmd: "art", key: zone.image })
  }

  function handleLine(line) {
    if (line.length > 1000000) return
    var event
    try { event = JSON.parse(line) } catch (e) { return }
    if (!event || typeof event !== "object") return
    if (event.type === "status") {
      root.status = String(event.status || "")
      if (event.core) root.coreName = String(event.core)
      root.message = String(event.message || "")
      if (root.status !== "connected") root.zones = []
    } else if (event.type === "zones" && Array.isArray(event.zones)) {
      root.zones = event.zones
      requestArt()
    } else if (event.type === "art" && event.key && event.path) {
      var paths = Object.assign({}, root.artPaths)
      paths[String(event.key)] = String(event.path)
      root.artPaths = paths
    } else if (event.type === "art_removed" && Array.isArray(event.keys)) {
      // The helper pruned these files; forget them so they are fetched again.
      var kept = Object.assign({}, root.artPaths)
      for (var k = 0; k < event.keys.length; k++) delete kept[String(event.keys[k])]
      root.artPaths = kept
    }
  }

  Process {
    id: helper
    running: false
    stdinEnabled: true
    command: ["python3", "-I", root.helperPath, "--host", root.host, "--port", String(root.port)]
    stdout: SplitParser { onRead: function (line) { root.handleLine(String(line)) } }
    stderr: SplitParser { onRead: function (line) { console.log(String(line)) } }
    onRunningChanged: {
      if (!helper.running && root.consumers > 0 && !retry.running) {
        // The helper reconnects to the Core on its own; this only covers the
        // helper itself exiting.
        root.status = "error"
        retry.interval = 5000
        retry.restart()
      }
    }
  }

  Timer {
    id: retry
    repeat: false
    onTriggered: if (root.consumers > 0) helper.running = true
  }
}
