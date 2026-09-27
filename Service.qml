import QtQuick
import Quickshell
import Quickshell.Io
import "PrayerTimes.js" as PrayerTimes
import "Model.js" as Model
import "Hijri.js" as Hijri

// The only part of the plugin that *acts*: it owns the adhan, the
// notifications, and the two lookups that touch the network.
//
// A service is mounted once per shell, while bar widgets exist per monitor, so
// putting side effects here is what keeps a three-monitor desk from playing the
// adhan three times over.
//
// Firing is driven by a one-second tick comparing wall-clock against the
// schedule, not by a long-armed Timer. A timer armed five hours out does not
// survive suspend, a clock correction, or a timezone change on a travelling
// laptop; re-deriving the answer every second always does, and costs nothing
// next to the shell's own repaint.
Item {
  id: root

  property var shell: null

  readonly property string home: Quickshell.env("HOME")
  readonly property string bundledAdhan: Qt.resolvedUrl("assets/adhan.ogg").toString().replace(/^file:\/\//, "")

  property var config: Model.defaults()
  property var weatherLocation: ({ name: "", latitude: null, longitude: null })
  property var ipLocation: null

  readonly property var location: Model.effectiveLocation(config, weatherLocation, ipLocation)
  readonly property bool hasLocation: location !== null

  property var day: null
  property string playingPrayer: ""

  // Nothing fires until every file has been read once. Before that the config
  // is the built-in default — no location — and acting on it meant an IP
  // lookup on every shell start, even for someone who chose a city long ago.
  property bool configLoaded: false
  property bool weatherLoaded: false
  property bool announcedLoaded: false
  readonly property bool ready: configLoaded && weatherLoaded && announcedLoaded

  onReadyChanged: if (ready) root.maybeSyncHijri()

  // ---------------------------------------------------------------- files
  //
  // Both directories are created up front: a FileView write replaces the file
  // by rename, which needs the directory to exist, and on a fresh install it
  // does not. The config and the announcement record are read once mkdir has
  // finished, so a first-run write cannot land before its directory.
  property bool dirsReady: false

  Process {
    id: dirs
    command: ["mkdir", "-p", root.home + Model.CONFIG_DIR, root.home + Model.STATE_DIR]
    onExited: {
      root.dirsReady = true
      configFile.reload()
      announcedFile.reload()
    }
  }

  // Quickshell cannot watch a file that does not exist yet. The config is
  // created below on first run, and Omarchy's weather location can appear at
  // any time; while either is missing, poll gently, and once a load succeeds
  // the watcher takes over.
  property bool configMissing: false
  property bool weatherMissing: false

  Timer {
    interval: 3000
    repeat: true
    running: root.configMissing || root.weatherMissing
    onTriggered: {
      if (root.configMissing) configFile.reload()
      if (root.weatherMissing) weatherFile.reload()
    }
  }

  // Writes go through the FileView with atomicWrites, so a watcher can never
  // read the file half-written. Rewriting it in place used to leave whichever
  // watcher read between the truncate and the write holding an empty file —
  // which parsed as defaults — with the second change notification dropped
  // because a read was already in flight.
  FileView {
    id: configFile
    path: root.home + Model.CONFIG_PATH
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      var parsed = Model.parseConfig(text())
      if (parsed) root.config = parsed
      root.configMissing = false
      root.configLoaded = true
    }
    onLoadFailed: function(error) {
      root.configLoaded = true
      if (error !== FileViewError.FileNotFound) {
        console.warn("sallah: could not read " + path + ": " + error)
        return
      }
      // First run: materialise the file so the panel has something to edit and
      // the user has a plain JSON file to hand-edit or keep in version control.
      root.configMissing = true
      root.config = Model.defaults()
      if (root.dirsReady) root.writeConfig(root.config)
    }
    onSaveFailed: function(error) { console.warn("sallah: could not write " + path + ": " + error) }
  }

  FileView {
    id: weatherFile
    path: root.home + Model.WEATHER_LOCATION_PATH
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      root.weatherLocation = Model.parseWeatherLocation(text())
      root.weatherMissing = false
      root.weatherLoaded = true
    }
    onLoadFailed: function(error) {
      root.weatherLocation = Model.parseWeatherLocation("")
      root.weatherMissing = error === FileViewError.FileNotFound
      root.weatherLoaded = true
    }
  }

  function writeConfig(next) {
    root.config = next
    configFile.setText(Model.serializeConfig(next))
  }

  // ---------------------------------------------------------------- announced
  //
  // Prayers already announced, as "YYYY-MM-DD:key:HH:MM". Kept in the state
  // directory rather than in PersistentProperties: those survive the reloads
  // that plugin edits trigger, but not a restart, and a restart inside the
  // grace window announced the same prayer twice. The minute is part of the
  // stamp so a prayer whose time moves — a tune, a new method, a new city —
  // is a new announcement rather than one already made.
  property var announced: []
  property string hijriSyncDay: ""

  FileView {
    id: announcedFile
    path: root.home + Model.ANNOUNCED_PATH
    atomicWrites: true
    printErrors: false
    onLoaded: {
      var parsed = Model.parseAnnounced(text())
      root.announced = parsed.announced
      root.hijriSyncDay = parsed.hijriSyncDay
      root.announcedLoaded = true
    }
    onLoadFailed: function(error) {
      // Absent on first run, which means exactly what an empty list means.
      if (error !== FileViewError.FileNotFound) console.warn("sallah: could not read " + path + ": " + error)
      root.announcedLoaded = true
    }
    onSaveFailed: function(error) { console.warn("sallah: could not write " + path + ": " + error) }
  }

  function saveAnnounced() {
    announcedFile.setText(Model.serializeAnnounced(root.announced, root.hijriSyncDay))
  }

  function alreadyFired(stamp) {
    return root.announced.indexOf(stamp) !== -1
  }

  function markFired(stamp) {
    var next = root.announced.slice()
    next.push(stamp)
    // Two days of history is all the guard needs; trimming keeps the file
    // from growing without bound.
    if (next.length > 24) next = next.slice(next.length - 24)
    root.announced = next
    root.saveAnnounced()
  }

  // ---------------------------------------------------------------- location
  //
  // Only consulted when neither an explicit choice nor Omarchy's weather
  // location is available, so the common case makes no network call at all.
  // A failed lookup — offline, or a rate-limited API — waits five minutes
  // before trying again rather than retrying on the next tick.
  Process {
    id: ipLookup
    command: ["curl", "-fsS", "--max-time", "6", "https://ipapi.co/json/"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var parsed = Model.parseIpLocation(text)
        if (parsed) root.ipLocation = parsed
      }
    }
  }

  property double ipLookupNotBefore: 0
  readonly property int ipLookupRetrySeconds: 300

  function ensureLocation() {
    if (root.hasLocation || ipLookup.running) return
    var now = Date.now()
    if (now < root.ipLookupNotBefore) return
    root.ipLookupNotBefore = now + root.ipLookupRetrySeconds * 1000
    ipLookup.running = true
  }

  // ---------------------------------------------------------------- hijri sync
  //
  // The arithmetic calendar drifts a day against Umm al-Qura for stretches of
  // several months. Rather than make the user notice and correct it, ask an
  // authority once a day and remember the correction — which then keeps working
  // offline until the calendars slip again.
  Process {
    id: hijriSync
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        if (!raw) return
        try {
          var json = JSON.parse(raw)
          var authoritative = Number(json.data.hijri.day)
          if (!isFinite(authoritative)) return
          var now = new Date()
          // Search a small window for the offset that reproduces the
          // authoritative day number; anything larger than two days would be a
          // parsing problem, not calendar drift, so leave it alone.
          for (var delta = -3; delta <= 3; delta++) {
            if (Hijri.fromDate(now, (Number(root.config.hijriOffset) || 0) + delta).day === authoritative) {
              if (root.config.hijriAutoOffset !== delta) {
                var next = JSON.parse(JSON.stringify(root.config))
                next.hijriAutoOffset = delta
                root.writeConfig(next)
              }
              root.hijriSyncDay = root.todayKey()
              root.saveAnnounced()
              return
            }
          }
        } catch (e) {
          // Offline or a changed response shape: the arithmetic calendar still
          // works, just without today's correction.
        }
      }
    }
  }

  function todayKey() {
    var d = new Date()
    return d.getFullYear() + "-" + (d.getMonth() + 1) + "-" + d.getDate()
  }

  function maybeSyncHijri() {
    if (!root.ready || !root.config.hijriSync) return
    if (root.hijriSyncDay === root.todayKey()) return
    if (hijriSync.running) return
    var d = new Date()
    var ds = ("0" + d.getDate()).slice(-2) + "-" + ("0" + (d.getMonth() + 1)).slice(-2) + "-" + d.getFullYear()
    hijriSync.command = ["curl", "-fsS", "--max-time", "8", "https://api.aladhan.com/v1/gToH/" + ds]
    hijriSync.running = true
  }

  // ---------------------------------------------------------------- state file
  //
  // A machine-readable copy of today's table, so scripts, waybar setups, and
  // `cat` can see what the bar is showing without reimplementing the astronomy.
  FileView {
    id: stateFile
    path: root.home + Model.STATE_PATH
    atomicWrites: true
    printErrors: false
    onSaveFailed: function(error) { console.warn("sallah: could not write " + path + ": " + error) }
  }

  function writeState() {
    if (!root.day) return
    var payload = {
      updated: new Date().toISOString(),
      location: root.location,
      method: root.config.method,
      madhab: root.config.madhab,
      hijri: root.day.hijriText,
      next: root.day.next ? { name: Model.prayerLabel(root.day.next.key), at: root.day.next.date.toISOString() } : null,
      times: {}
    }
    for (var i = 0; i < root.day.rows.length; i++) {
      var row = root.day.rows[i]
      payload.times[row.key] = row.date ? row.date.toISOString() : null
    }
    stateFile.setText(JSON.stringify(payload, null, 2) + "\n")
  }

  // ---------------------------------------------------------------- adhan
  //
  // One Process, restarted with a new command, is how a second Play works — but
  // Quickshell only starts the new command once the old process has exited, and
  // that exit used to clear playingPrayer *after* it had been set for the new
  // one. The panel then showed nothing playing, with Stop disabled, while the
  // adhan sounded. A Play during playback is therefore parked in pendingPrayer
  // and started from the exit handler instead.
  property string pendingPrayer: ""

  Process {
    id: player
    onExited: {
      if (root.pendingPrayer !== "") {
        var key = root.pendingPrayer
        root.pendingPrayer = ""
        root.startPlayer(key)
      } else {
        root.playingPrayer = ""
      }
    }
  }

  function adhanPath() {
    var custom = String(root.config.audio.path || "").trim()
    if (custom.length > 0) return custom.replace(/^~/, root.home)
    return root.bundledAdhan
  }

  function startPlayer(prayerKey) {
    var volume = Model.clamp(root.config.audio.volume, 0, 150)
    root.playingPrayer = prayerKey
    player.command = ["mpv", "--no-video", "--really-quiet",
                      "--volume=" + volume, root.adhanPath()]
    player.running = true
  }

  function playAdhan(prayerKey) {
    if (!root.config.audio.enabled) return
    var key = prayerKey || "test"
    if (player.running) {
      root.pendingPrayer = key
      player.running = false
      return
    }
    root.pendingPrayer = ""
    root.startPlayer(key)
  }

  function stopAdhan() {
    root.pendingPrayer = ""
    if (player.running) player.running = false
    root.playingPrayer = ""
  }

  Process { id: notifier }

  function notify(headline, body, glyph, urgency) {
    notifier.command = ["omarchy-notification-send",
                        "--app-name", "sallah-reminder",
                        "-g", glyph || "",
                        "-u", urgency || "normal",
                        headline, body]
    notifier.running = true
  }

  // ---------------------------------------------------------------- firing
  function announce(row) {
    var timeText = Model.formatTime(row.date, root.config.timeFormat)
    if (root.config.notify) {
      root.notify(row.label + " — " + timeText,
                  "It is time for " + row.label + " prayer.", "", "normal")
    }
    if (row.azan) root.playAdhan(row.key)
  }

  function remind(row, minutes) {
    if (!root.config.notify) return
    root.notify(row.label + " in " + minutes + " min",
                row.label + " at " + Model.formatTime(row.date, root.config.timeFormat),
                "", "low")
  }

  // Fire anything due since the last tick. The grace window is what makes
  // suspend-and-resume sane: a prayer whose moment passed while the lid was
  // shut is marked handled and skipped, instead of three adhans at once when
  // the laptop wakes up.
  readonly property int graceSeconds: 90

  function tick() {
    if (!root.ready) return
    var now = new Date()
    root.ensureLocation()
    if (!root.hasLocation) return

    root.day = Model.buildDay(now, root.config, root.location)
    if (!root.day) return

    // Walk the three-day schedule rather than today's table. At high latitudes
    // Isha can fall after midnight, which puts it on the previous calendar
    // day's table and off the new day's entirely — announcing from `rows` would
    // silently skip it.
    var schedule = root.day.schedule
    var reminderAt = Number(root.config.reminderMinutes) || 0

    for (var i = 0; i < schedule.length; i++) {
      var entry = schedule[i]
      if (!entry.isPrayer || !entry.date) continue

      var elapsed = (now.getTime() - entry.date.getTime()) / 1000
      // Yesterday's prayers are in the schedule so the countdown can look
      // backwards; they are far outside the grace window and only exist here
      // to be marked, so skip them before they cost anything.
      if (elapsed > 86400) continue

      var stamp = Model.announceStamp(entry.date, entry.key)

      if (elapsed >= 0) {
        if (!root.alreadyFired(stamp)) {
          root.markFired(stamp)
          if (elapsed <= root.graceSeconds) root.announce(root.rowFor(entry))
        }
        continue
      }

      if (reminderAt > 0) {
        var until = -elapsed
        var reminderStamp = stamp + ":pre"
        if (until <= reminderAt * 60 && until > reminderAt * 60 - root.graceSeconds
            && !root.alreadyFired(reminderStamp)) {
          root.markFired(reminderStamp)
          root.remind(root.rowFor(entry), reminderAt)
        }
      }
    }
  }

  // announce/remind speak in rows; the schedule speaks in entries. One shape
  // conversion keeps both of those readable.
  function rowFor(entry) {
    return {
      key: entry.key,
      label: Model.prayerLabel(entry.key),
      date: entry.date,
      azan: root.config.azan[entry.key] !== false
    }
  }

  Timer {
    interval: 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.tick()
  }

  // State file and calendar sync change at most once a day; a minute-resolution
  // timer for both keeps them off the one-second path.
  Timer {
    interval: 60000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      root.maybeSyncHijri()
      root.writeState()
    }
  }

  // ---------------------------------------------------------------- ipc
  //
  // `omarchy-shell sallah <command>` — lets the panel drive playback without
  // reaching across into this object, and gives the user a scriptable surface
  // for keybinds.
  IpcHandler {
    target: "sallah"

    function test(): void { root.playAdhan("test") }
    function stop(): void { root.stopAdhan() }
    function next(): string {
      if (!root.day || !root.day.next) return "unknown"
      return Model.prayerLabel(root.day.next.key) + " " +
             Model.formatTime(root.day.next.date, root.config.timeFormat) +
             " (in " + Model.formatDuration(root.day.remainingMs) + ")"
    }
    function today(): string {
      if (!root.day) return "no location configured"
      var out = []
      for (var i = 0; i < root.day.rows.length; i++) {
        var row = root.day.rows[i]
        out.push(row.label + " " + Model.formatTime(row.date, root.config.timeFormat))
      }
      return out.join("   ")
    }
    function sync(): void {
      root.hijriSyncDay = ""
      root.maybeSyncHijri()
    }
  }

  Component.onCompleted: {
    dirs.running = true
    weatherFile.reload()
  }
}
