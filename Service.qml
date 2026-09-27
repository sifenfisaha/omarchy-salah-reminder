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

  // Prayers already announced, as "YYYY-MM-DD:key". Persisted so a shell reload
  // — which plugin edits trigger constantly — cannot re-announce a prayer the
  // user already heard.
  PersistentProperties {
    id: persisted
    reloadableId: "sallah-reminder"
    property string firedKeys: ""
    property string lastHijriSync: ""
  }

  function stampFor(date, key) {
    return date.getFullYear() + "-" + (date.getMonth() + 1) + "-" + date.getDate() + ":" + key
  }

  function alreadyFired(stamp) {
    return ("|" + persisted.firedKeys + "|").indexOf("|" + stamp + "|") !== -1
  }

  function markFired(stamp) {
    var parts = persisted.firedKeys ? persisted.firedKeys.split("|") : []
    parts.push(stamp)
    // Two days of history is all the guard needs; trimming keeps the persisted
    // string from growing without bound across a long-running session.
    if (parts.length > 24) parts = parts.slice(parts.length - 24)
    persisted.firedKeys = parts.join("|")
  }

  // ---------------------------------------------------------------- config
  FileView {
    id: configFile
    path: root.home + Model.CONFIG_PATH
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.config = Model.parseConfig(text())
    onLoadFailed: {
      // First run: materialise the file so the panel has something to edit and
      // the user has a plain JSON file to hand-edit or keep in version control.
      root.config = Model.defaults()
      root.writeConfig(root.config)
    }
  }

  FileView {
    id: weatherFile
    path: root.home + Model.WEATHER_LOCATION_PATH
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.weatherLocation = Model.parseWeatherLocation(text())
    onLoadFailed: root.weatherLocation = Model.parseWeatherLocation("")
  }

  // ---------------------------------------------------------------- location
  //
  // Only consulted when neither an explicit choice nor Omarchy's weather
  // location is available, so the common case makes no network call at all.
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

  function ensureLocation() {
    if (root.hasLocation || ipLookup.running) return
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
              persisted.lastHijriSync = root.todayKey()
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
    if (!root.config.hijriSync) return
    if (persisted.lastHijriSync === root.todayKey()) return
    if (hijriSync.running) return
    var d = new Date()
    var ds = ("0" + d.getDate()).slice(-2) + "-" + ("0" + (d.getMonth() + 1)).slice(-2) + "-" + d.getFullYear()
    hijriSync.command = ["curl", "-fsS", "--max-time", "8", "https://api.aladhan.com/v1/gToH/" + ds]
    hijriSync.running = true
  }

  // ---------------------------------------------------------------- writing
  Process { id: writer }

  function writeConfig(next) {
    root.config = next
    var json = Model.serializeConfig(next)
    writer.command = ["sh", "-c",
      "mkdir -p \"$(dirname \"$1\")\" && printf '%s' \"$2\" > \"$1\"",
      "sh", root.home + Model.CONFIG_PATH, json]
    writer.running = true
  }

  // A machine-readable copy of today's table, so scripts, waybar setups, and
  // `cat` can see what the bar is showing without reimplementing the astronomy.
  Process { id: stateWriter }

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
    stateWriter.command = ["sh", "-c",
      "mkdir -p \"$(dirname \"$1\")\" && printf '%s' \"$2\" > \"$1\"",
      "sh", root.home + Model.STATE_PATH, JSON.stringify(payload, null, 2) + "\n"]
    stateWriter.running = true
  }

  // ---------------------------------------------------------------- adhan
  Process {
    id: player
    onExited: root.playingPrayer = ""
  }

  function adhanPath() {
    var custom = String(root.config.audio.path || "").trim()
    if (custom.length > 0) return custom.replace(/^~/, root.home)
    return root.bundledAdhan
  }

  function playAdhan(prayerKey) {
    if (!root.config.audio.enabled) return
    stopAdhan()
    var volume = Model.clamp(root.config.audio.volume, 0, 150)
    root.playingPrayer = prayerKey || "test"
    player.command = ["mpv", "--no-video", "--really-quiet",
                      "--volume=" + volume, root.adhanPath()]
    player.running = true
  }

  function stopAdhan() {
    if (player.running) player.running = false
    root.playingPrayer = ""
  }

  Process { id: notifier }

  function notify(headline, body, glyph, urgency) {
    notifier.command = ["omarchy-notification-send",
                        "--app-name", "sallah-reminder",
                        "-g", glyph || "",
                        "-u", urgency || "normal",
                        headline, body]
    notifier.running = true
  }

  // ---------------------------------------------------------------- firing
  function announce(row) {
    var timeText = Model.formatTime(row.date, root.config.timeFormat)
    if (root.config.notify) {
      root.notify(row.label + " — " + timeText,
                  "It is time for " + row.label + " prayer.", "", "normal")
    }
    if (row.azan) root.playAdhan(row.key)
  }

  function remind(row, minutes) {
    if (!root.config.notify) return
    root.notify(row.label + " in " + minutes + " min",
                row.label + " at " + Model.formatTime(row.date, root.config.timeFormat),
                "", "low")
  }

  // Fire anything due since the last tick. The grace window is what makes
  // suspend-and-resume sane: a prayer whose moment passed while the lid was
  // shut is marked handled and skipped, instead of three adhans at once when
  // the laptop wakes up.
  readonly property int graceSeconds: 90

  function tick() {
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

      var stamp = root.stampFor(entry.date, entry.key)

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
      persisted.lastHijriSync = ""
      root.maybeSyncHijri()
    }
  }

  Component.onCompleted: {
    configFile.reload()
    weatherFile.reload()
  }
}
