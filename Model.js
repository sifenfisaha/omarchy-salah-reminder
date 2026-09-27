.pragma library

.import "PrayerTimes.js" as PrayerTimes
.import "Hijri.js" as Hijri

// Config shape, formatting, and the small derivations the bar widget, the
// panel, and the service all need to agree on.
//
// Every surface computes prayer times independently from the same config file
// and the same pure functions, so they cannot disagree. Nothing is passed
// between them at runtime — the config file is the only shared state, and the
// service is the only thing that acts on the result.

var CONFIG_DIR = "/.config/omarchy/sallah"
var CONFIG_PATH = CONFIG_DIR + "/config.json"
var STATE_DIR = "/.local/state/omarchy/sallah"
var STATE_PATH = STATE_DIR + "/state.json"

// Omarchy's weather plugin already asks the user where they are. Reusing that
// answer means most people never have to set a location twice.
var WEATHER_LOCATION_PATH = "/.local/state/omarchy/settings/weather.json"

function defaults() {
  return {
    location: { name: "", latitude: null, longitude: null, source: "weather" },
    method: "MWL",
    madhab: "Standard",
    highLats: "AngleBased",
    tune: { fajr: 0, sunrise: 0, dhuhr: 0, asr: 0, maghrib: 0, isha: 0 },
    hijriOffset: 0,
    // Learned by the service from an authoritative source; kept apart from the
    // user's own offset so a sync never silently overwrites a deliberate choice.
    hijriAutoOffset: 0,
    hijriSync: true,
    azan: { fajr: true, dhuhr: true, asr: true, maghrib: true, isha: true },
    audio: { enabled: true, path: "", volume: 75 },
    notify: true,
    reminderMinutes: 10,
    timeFormat: "24h",
    barMode: "countdown",
    showSeconds: true
  }
}

function isObject(v) {
  return v !== null && typeof v === "object" && !(v instanceof Array)
}

// Merge stored settings over the defaults one level deep, keeping any key the
// file omits. A config written by an older version stays loadable, and a
// hand-edited file with a typo loses one key rather than the whole config.
function mergeConfig(stored) {
  var out = defaults()
  if (!isObject(stored)) return out
  for (var key in out) {
    if (!(key in stored)) continue
    var value = stored[key]
    if (isObject(out[key]) && isObject(value)) {
      for (var sub in out[key]) {
        if (sub in value && value[sub] !== null && value[sub] !== undefined) out[key][sub] = value[sub]
      }
      // location.name is free text and may legitimately be absent.
      if (key === "location") {
        out.location.latitude = numOrNull(value.latitude)
        out.location.longitude = numOrNull(value.longitude)
      }
    } else if (value !== null && value !== undefined) {
      out[key] = value
    }
  }
  return out
}

function numOrNull(v) {
  var n = parseFloat(v)
  return isFinite(n) ? n : null
}

// Null, not defaults, when the text is not JSON. A watcher can catch the file
// between two writes, and a hand edit can be mid-typo; the right answer to
// both is to keep the last good configuration, not to replace it with a
// fresh one.
function parseConfig(text) {
  try {
    return mergeConfig(JSON.parse(String(text || "")))
  } catch (e) {
    return null
  }
}

function serializeConfig(config) {
  return JSON.stringify(config, null, 2) + "\n"
}

// Omarchy's weather state file, so a location set once serves both plugins.
function parseWeatherLocation(text) {
  try {
    var json = JSON.parse(String(text || ""))
    return {
      name: String(json.name || ""),
      latitude: numOrNull(json.latitude),
      longitude: numOrNull(json.longitude)
    }
  } catch (e) {
    return { name: "", latitude: null, longitude: null }
  }
}

function hasCoordinates(location) {
  return location && isFinite(Number(location.latitude)) && isFinite(Number(location.longitude))
    && location.latitude !== null && location.longitude !== null
}

// The coordinates actually used, preferring an explicit choice over the
// borrowed weather location over whatever IP lookup found.
function effectiveLocation(config, weatherLocation, ipLocation) {
  if (config.location.source === "manual" && hasCoordinates(config.location)) return config.location
  if (config.location.source !== "ip" && hasCoordinates(weatherLocation)) return weatherLocation
  if (hasCoordinates(config.location)) return config.location
  if (hasCoordinates(weatherLocation)) return weatherLocation
  if (hasCoordinates(ipLocation)) return ipLocation
  return null
}

function timesConfig(config, location) {
  return {
    latitude: location ? Number(location.latitude) : 0,
    longitude: location ? Number(location.longitude) : 0,
    method: config.method,
    asr: config.madhab,
    highLats: config.highLats,
    tune: config.tune
  }
}

// ------------------------------------------------------------------ formatting
function pad(n) { return n < 10 ? "0" + n : String(n) }

function formatTime(date, timeFormat) {
  if (!date) return "--:--"
  var h = date.getHours()
  var m = date.getMinutes()
  if (timeFormat === "12h") {
    var suffix = h >= 12 ? "PM" : "AM"
    var h12 = h % 12
    if (h12 === 0) h12 = 12
    return h12 + ":" + pad(m) + " " + suffix
  }
  return pad(h) + ":" + pad(m)
}

// Countdown as H:MM:SS, dropping the hours once inside the last hour so the
// bar pill stays narrow for most of the day.
function formatCountdown(ms, showSeconds) {
  if (!isFinite(ms) || ms < 0) ms = 0
  var total = Math.floor(ms / 1000)
  var h = Math.floor(total / 3600)
  var m = Math.floor((total % 3600) / 60)
  var s = total % 60

  if (!showSeconds) {
    // Round up so a pill reading "1m" never sits there for a full minute
    // before the adhan; it reads 1m until the moment it reads now.
    var mins = Math.ceil(total / 60)
    if (mins >= 60) return Math.floor(mins / 60) + "h " + (mins % 60) + "m"
    return mins + "m"
  }
  if (h > 0) return h + ":" + pad(m) + ":" + pad(s)
  return m + ":" + pad(s)
}

// Long human phrasing for the hero line and notifications.
function formatDuration(ms) {
  if (!isFinite(ms) || ms < 0) ms = 0
  var total = Math.round(ms / 1000)
  var h = Math.floor(total / 3600)
  var m = Math.round((total % 3600) / 60)
  if (m === 60) { h += 1; m = 0 }
  if (h > 0 && m > 0) return h + " hr " + m + " min"
  if (h > 0) return h + " hr"
  if (m > 0) return m + " min"
  return "now"
}

function prayerLabel(key) {
  var entry = PrayerTimes.LABELS[key]
  return entry ? entry.en : key
}

function prayerLabelAr(key) {
  var entry = PrayerTimes.LABELS[key]
  return entry ? entry.ar : ""
}

// ------------------------------------------------------------------ day view
//
// One object with everything a surface needs to draw: today's table, where we
// are in it, and what comes next. Built fresh on each tick — it is a few dozen
// float operations, far cheaper than caching it correctly would be.
function buildDay(now, config, location) {
  if (!location) return null

  var cfg = timesConfig(config, location)
  var today = PrayerTimes.timesForDate(now, cfg)

  // One schedule, spanning yesterday through tomorrow, answers both "what is
  // next" and "what are we inside of" — and, for the service, "what just became
  // due". Building it once is what keeps a per-second tick cheap.
  var schedule = PrayerTimes.buildSchedule(now, cfg)
  var next = PrayerTimes.findNext(schedule, now, true)
  var current = PrayerTimes.findCurrent(schedule, now, true)

  var rows = []
  for (var i = 0; i < PrayerTimes.PRAYER_NAMES.length; i++) {
    var key = PrayerTimes.PRAYER_NAMES[i]
    var date = today[key]
    rows.push({
      key: key,
      label: prayerLabel(key),
      labelAr: prayerLabelAr(key),
      date: date,
      isPrayer: key !== "sunrise",
      isNext: next !== null && next.key === key && next.dayOffset === 0,
      isCurrent: current !== null && current.key === key && current.dayOffset === 0,
      isPast: date !== null && date.getTime() <= now.getTime(),
      azan: key !== "sunrise" && config.azan[key] !== false
    })
  }

  // Fraction of the way from the previous prayer to the next, for the progress
  // ring. Null before the first prayer of the very first day we can see.
  var progress = null
  if (current && next) {
    var span = next.date.getTime() - current.date.getTime()
    if (span > 0) progress = Math.max(0, Math.min(1, (now.getTime() - current.date.getTime()) / span))
  }

  return {
    rows: rows,
    times: today,
    // Announcing walks this rather than `rows`: an Isha that falls after
    // midnight belongs to the previous calendar day, so it is absent from the
    // new day's table and would otherwise never be announced at all.
    schedule: schedule,
    next: next,
    current: current,
    progress: progress,
    remainingMs: next ? Math.max(0, next.date.getTime() - now.getTime()) : 0,
    hijri: Hijri.fromDate(now, totalHijriOffset(config)),
    hijriText: Hijri.format(now, totalHijriOffset(config))
  }
}

function totalHijriOffset(config) {
  return (Number(config.hijriOffset) || 0) + (Number(config.hijriAutoOffset) || 0)
}

// ------------------------------------------------------------------ bar pill
function barText(day, config) {
  if (!day || !day.next) return ""
  var label = prayerLabel(day.next.key)
  var mode = config.barMode

  if (mode === "time") return label + " " + formatTime(day.next.date, config.timeFormat)
  if (mode === "both") {
    return label + " " + formatTime(day.next.date, config.timeFormat) +
      "  " + formatCountdown(day.remainingMs, config.showSeconds)
  }
  return label + " " + formatCountdown(day.remainingMs, config.showSeconds)
}

// ------------------------------------------------------------------ misc
function clamp(value, lo, hi) {
  var n = Number(value)
  if (!isFinite(n)) return lo
  return Math.max(lo, Math.min(hi, n))
}

// Geocoding results from Open-Meteo, shaped for the location picker.
function parseGeocodingResults(text) {
  try {
    var json = JSON.parse(String(text || ""))
    var results = json.results || []
    var out = []
    for (var i = 0; i < results.length && i < 8; i++) {
      var r = results[i]
      var parts = [r.name]
      if (r.admin1 && r.admin1 !== r.name) parts.push(r.admin1)
      if (r.country) parts.push(r.country)
      out.push({
        name: r.name,
        label: parts.join(", "),
        latitude: r.latitude,
        longitude: r.longitude
      })
    }
    return out
  } catch (e) {
    return []
  }
}

function parseIpLocation(text) {
  try {
    var json = JSON.parse(String(text || ""))
    var lat = numOrNull(json.latitude !== undefined ? json.latitude : json.lat)
    var lon = numOrNull(json.longitude !== undefined ? json.longitude : json.lon)
    if (lat === null || lon === null) return null
    return { name: String(json.city || json.region || ""), latitude: lat, longitude: lon }
  } catch (e) {
    return null
  }
}

if (typeof module !== "undefined" && module.exports) {
  module.exports = {
    defaults: defaults, mergeConfig: mergeConfig, parseConfig: parseConfig,
    serializeConfig: serializeConfig, parseWeatherLocation: parseWeatherLocation,
    effectiveLocation: effectiveLocation, hasCoordinates: hasCoordinates,
    timesConfig: timesConfig, buildDay: buildDay, barText: barText,
    formatTime: formatTime, formatCountdown: formatCountdown, formatDuration: formatDuration,
    prayerLabel: prayerLabel, prayerLabelAr: prayerLabelAr,
    totalHijriOffset: totalHijriOffset, parseGeocodingResults: parseGeocodingResults,
    parseIpLocation: parseIpLocation, clamp: clamp,
    CONFIG_DIR: CONFIG_DIR, CONFIG_PATH: CONFIG_PATH,
    STATE_DIR: STATE_DIR, STATE_PATH: STATE_PATH,
    WEATHER_LOCATION_PATH: WEATHER_LOCATION_PATH
  }
}
