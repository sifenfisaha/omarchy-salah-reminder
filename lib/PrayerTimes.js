.pragma library

// Prayer-time astronomy.
//
// Implements the solar-position model used by PrayTimes.org: mean anomaly and
// mean longitude give the ecliptic longitude, which yields the equation of time
// and the sun's declination for a given Julian day. Every prayer is then either
// a fixed hour angle away from solar noon (Fajr/Isha/sunrise/sunset) or a
// shadow-ratio time (Asr).
//
// Times are computed iteratively: each prayer's declination depends on the
// moment it occurs, which is what we're solving for, so we seed with rough
// hours and refine. Two passes converge to well under a second.
//
// All trigonometry here is in degrees, matching how the source formulae and
// every published method table are written. Wrapping Math.* once at the top
// keeps the formulae below readable against the references.

// ------------------------------------------------------------------ trig
function dtr(d) { return (d * Math.PI) / 180.0 }
function rtd(r) { return (r * 180.0) / Math.PI }

function sin(d) { return Math.sin(dtr(d)) }
function cos(d) { return Math.cos(dtr(d)) }
function tan(d) { return Math.tan(dtr(d)) }

function arcsin(x) { return rtd(Math.asin(x)) }
function arccos(x) { return rtd(Math.acos(x)) }
function arctan(x) { return rtd(Math.atan(x)) }
function arccot(x) { return rtd(Math.atan(1.0 / x)) }
function arctan2(y, x) { return rtd(Math.atan2(y, x)) }

function fix(a, b) {
  a = a - b * Math.floor(a / b)
  return a < 0 ? a + b : a
}
function fixAngle(a) { return fix(a, 360.0) }
function fixHour(a) { return fix(a, 24.0) }

// ------------------------------------------------------------------ methods
//
// Fajr/Isha are twilight depression angles in degrees unless given as a string
// like "90 min", which means "this many minutes after Maghrib" — Umm al-Qura
// and the Gulf authorities publish Isha that way rather than as an angle.
//
// `order` drives the settings dropdown; `region` is the hint shown under each
// name so the list is choosable without already knowing the answer.
var METHODS = {
  MWL: {
    name: "Muslim World League",
    region: "Europe, Far East, global default",
    params: { fajr: 18, isha: 17 }
  },
  Egypt: {
    name: "Egyptian General Authority",
    region: "Egypt, Horn of Africa, Syria, Iraq",
    params: { fajr: 19.5, isha: 17.5 }
  },
  Makkah: {
    name: "Umm al-Qura, Makkah",
    region: "Saudi Arabia",
    params: { fajr: 18.5, isha: "90 min" }
  },
  Karachi: {
    name: "University of Islamic Sciences, Karachi",
    region: "Pakistan, Bangladesh, India, Afghanistan",
    params: { fajr: 18, isha: 18 }
  },
  ISNA: {
    name: "Islamic Society of North America",
    region: "North America",
    params: { fajr: 15, isha: 15 }
  },
  Moonsighting: {
    name: "Moonsighting Committee",
    region: "North America, UK — seasonal twilight",
    params: { fajr: 18, isha: 18, shafaq: "general" }
  },
  Tehran: {
    name: "Institute of Geophysics, Tehran",
    region: "Iran, Shia communities",
    params: { fajr: 17.7, isha: 14, maghrib: 4.5, midnight: "Jafari" }
  },
  Jafari: {
    name: "Shia Ithna-Ashari, Leva Institute",
    region: "Shia Ithna-Ashari",
    params: { fajr: 16, isha: 14, maghrib: 4, midnight: "Jafari" }
  },
  Gulf: {
    name: "Gulf Region",
    region: "UAE, Kuwait, Bahrain",
    params: { fajr: 19.5, isha: "90 min" }
  },
  Kuwait: {
    name: "Kuwait",
    region: "Kuwait",
    params: { fajr: 18, isha: 17.5 }
  },
  Qatar: {
    name: "Qatar",
    region: "Qatar",
    params: { fajr: 18, isha: "90 min" }
  },
  Singapore: {
    name: "Majlis Ugama Islam Singapura",
    region: "Singapore, Malaysia, Indonesia",
    params: { fajr: 20, isha: 18 }
  },
  Turkey: {
    name: "Diyanet İşleri Başkanlığı",
    region: "Turkey",
    params: { fajr: 18, isha: 17 },
    // Diyanet publishes its timetable with these fixed corrections applied on
    // top of the angle solution, so the angles alone reproduce times that are
    // several minutes off what every mosque in Turkey prints. Both Aladhan and
    // adhan-js carry the same table.
    adjust: { sunrise: -7, dhuhr: 5, asr: 4, maghrib: 7 }
  },
  France: {
    name: "Union des Organisations Islamiques de France",
    region: "France",
    params: { fajr: 12, isha: 12 }
  },
  Russia: {
    name: "Spiritual Administration of Muslims of Russia",
    region: "Russia",
    params: { fajr: 16, isha: 15 }
  },
  Dubai: {
    name: "Dubai",
    region: "United Arab Emirates",
    params: { fajr: 18.2, isha: 18.2 }
  }
}

var METHOD_ORDER = [
  "MWL", "Egypt", "Makkah", "Karachi", "ISNA", "Moonsighting", "Turkey",
  "Singapore", "Gulf", "Dubai", "Kuwait", "Qatar", "France", "Russia",
  "Tehran", "Jafari"
]

var DEFAULT_PARAMS = {
  dhuhr: "0 min",
  asr: "Standard",
  maghrib: "0 min",
  highLats: "AngleBased",
  midnight: "Standard"
}

// The six daily anchors plus the derived ones the panel shows. `sunrise` is not
// a prayer, but it closes the Fajr window and so belongs in the same ordering.
var TIME_NAMES = ["fajr", "sunrise", "dhuhr", "asr", "sunset", "maghrib", "isha", "midnight"]

// Only these are announced and counted down to.
var PRAYER_NAMES = ["fajr", "sunrise", "dhuhr", "asr", "maghrib", "isha"]

// Code points rather than literal characters: these live in the Nerd Font
// private-use planes above U+FFFF, where a hand-written JS escape means getting
// a surrogate pair right by hand. String.fromCodePoint does not miscount.
var LABELS = {
  fajr:     { en: "Fajr",     ar: "الفجر",       icon: 0xF0594 },
  sunrise:  { en: "Sunrise",  ar: "الشروق",      icon: 0xE34C  },
  dhuhr:    { en: "Dhuhr",    ar: "الظهر",       icon: 0xE30D  },
  asr:      { en: "Asr",      ar: "العصر",       icon: 0xF185  },
  sunset:   { en: "Sunset",   ar: "الغروب",      icon: 0xE34D  },
  maghrib:  { en: "Maghrib",  ar: "المغرب",      icon: 0xE34D  },
  isha:     { en: "Isha",     ar: "العشاء",      icon: 0xF0979 },
  midnight: { en: "Midnight", ar: "منتصف الليل", icon: 0xF0594 },
  lastThird:{ en: "Last third", ar: "الثلث الأخير", icon: 0xF0594 },
  duha:     { en: "Duha",     ar: "الضحى",       icon: 0xE30D  }
}

// The plugin's own mark, used in the bar and on notifications.
var MOSQUE_ICON = 0xF1477

function icon(key) {
  var entry = LABELS[key]
  return String.fromCodePoint(entry ? entry.icon : MOSQUE_ICON)
}

function mosqueIcon() {
  return String.fromCodePoint(MOSQUE_ICON)
}

function methodKeys() { return METHOD_ORDER.slice() }

function methodInfo(key) {
  return METHODS[key] || METHODS.MWL
}

function methodName(key) {
  return methodInfo(key).name
}

// ------------------------------------------------------------------ calendar
function isLeapYear(year) {
  return (year % 4 === 0 && year % 100 !== 0) || year % 400 === 0
}

function julian(year, month, day) {
  if (month <= 2) {
    year -= 1
    month += 12
  }
  var a = Math.floor(year / 100)
  var b = 2 - a + Math.floor(a / 4)
  return Math.floor(365.25 * (year + 4716)) + Math.floor(30.6001 * (month + 1)) + day + b - 1524.5
}

function dayOfYear(year, month, day) {
  var cumulative = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334]
  var doy = cumulative[month - 1] + day
  if (month > 2 && isLeapYear(year)) doy += 1
  return doy
}

// ------------------------------------------------------------------ sun
function sunPosition(jd) {
  var d = jd - 2451545.0
  var g = fixAngle(357.529 + 0.98560028 * d)
  var q = fixAngle(280.459 + 0.98564736 * d)
  var l = fixAngle(q + 1.915 * sin(g) + 0.020 * sin(2 * g))
  var e = 23.439 - 0.00000036 * d
  var ra = arctan2(cos(e) * sin(l), cos(l)) / 15.0
  return {
    declination: arcsin(sin(e) * sin(l)),
    equation: q / 15.0 - fixHour(ra)
  }
}

// ------------------------------------------------------------------ engine
//
// `ctx` carries everything a single day's computation needs so the helpers stay
// pure: no module-level mutable state, so two panels computing different days
// can never tread on each other.
function makeContext(opts) {
  var params = {}
  var key
  for (key in DEFAULT_PARAMS) params[key] = DEFAULT_PARAMS[key]
  var method = methodInfo(opts.method)
  for (key in method.params) params[key] = method.params[key]
  if (opts.asr) params.asr = opts.asr
  if (opts.highLats) params.highLats = opts.highLats

  return {
    methodKey: METHODS[opts.method] ? opts.method : "MWL",
    params: params,
    adjust: method.adjust || {},
    lat: Number(opts.latitude) || 0,
    lng: Number(opts.longitude) || 0,
    elv: Number(opts.elevation) || 0,
    // Hours east of UTC for the target date, including DST. Callers pass this
    // measured from a real Date so we never re-derive a zone from longitude.
    timezone: Number(opts.timezone) || 0,
    tune: opts.tune || {},
    year: opts.year,
    month: opts.month,
    day: opts.day,
    jd: julian(opts.year, opts.month, opts.day) - (Number(opts.longitude) || 0) / (15.0 * 24.0)
  }
}

// Minutes value like "90 min" -> 90; anything else -> null.
function minutesValue(value) {
  if (typeof value !== "string") return null
  var match = value.match(/^\s*(-?[\d.]+)\s*min/i)
  return match ? parseFloat(match[1]) : null
}

function evaluate(value) {
  var mins = minutesValue(value)
  return mins === null ? (Number(value) || 0) : mins
}

// Hour angle, in hours, between solar noon and the moment the sun sits `angle`
// degrees below the horizon. Returns NaN inside a polar day/night, where no such
// moment exists — the high-latitude rules below are what rescue that case.
function sunAngleTime(ctx, angle, t, direction) {
  var decl = sunPosition(ctx.jd + t).declination
  var noon = midDay(ctx, t)
  var numerator = -sin(angle) - sin(decl) * sin(ctx.lat)
  var denominator = cos(decl) * cos(ctx.lat)
  var ratio = numerator / denominator
  if (ratio > 1 || ratio < -1) return NaN
  var span = arccos(ratio) / 15.0
  return noon + (direction === "ccw" ? -span : span)
}

function midDay(ctx, t) {
  var eqt = sunPosition(ctx.jd + t).equation
  return fixHour(12 - eqt)
}

// Asr is when an object's shadow equals its noon shadow plus `factor` times the
// object's height: 1 for Shafi'i/Maliki/Hanbali, 2 for Hanafi.
function asrTime(ctx, factor, t) {
  var decl = sunPosition(ctx.jd + t).declination
  var angle = -arccot(factor + tan(Math.abs(ctx.lat - decl)))
  return sunAngleTime(ctx, angle, t, "cw")
}

function asrFactor(asrParam) {
  return String(asrParam).toLowerCase() === "hanafi" ? 2 : 1
}

// Atmospheric refraction at the horizon plus the dip from observer elevation.
function riseSetAngle(elevation) {
  return 0.833 + 0.0347 * Math.sqrt(Math.max(0, elevation))
}

// Rough starting hours for the iterative refinement. Any value within a few
// hours of the truth converges; these are the conventional seeds.
function seedTimes() {
  return {
    fajr: 5, sunrise: 6, dhuhr: 12,
    asr: 13, sunset: 18, maghrib: 18, isha: 18
  }
}

function computeRaw(ctx, times) {
  var t = {}
  for (var key in times) t[key] = times[key] / 24.0

  var out = {}
  out.fajr = sunAngleTime(ctx, evaluate(ctx.params.fajr), t.fajr, "ccw")
  out.sunrise = sunAngleTime(ctx, riseSetAngle(ctx.elv), t.sunrise, "ccw")
  out.dhuhr = midDay(ctx, t.dhuhr)
  out.asr = asrTime(ctx, asrFactor(ctx.params.asr), t.asr)
  out.sunset = sunAngleTime(ctx, riseSetAngle(ctx.elv), t.sunset, "cw")
  out.maghrib = sunAngleTime(ctx, evaluate(ctx.params.maghrib), t.maghrib, "cw")
  out.isha = sunAngleTime(ctx, evaluate(ctx.params.isha), t.isha, "cw")
  return out
}

// ------------------------------------------------------------------ high latitudes
//
// Above roughly 48° the sun can fail to reach the Fajr/Isha depression angle at
// all, leaving those times undefined for part of the year. Each rule caps the
// twilight portion of the night at some fraction instead.
function nightPortion(ctx, angle, night) {
  var rule = ctx.params.highLats
  var portion = 1 / 2
  if (rule === "AngleBased") portion = (1 / 60) * angle
  else if (rule === "OneSeventh") portion = 1 / 7
  return portion * night
}

function timeDiff(a, b) { return fixHour(b - a) }

function adjustHighLats(ctx, times) {
  if (ctx.params.highLats === "None") return times

  var nightTime = timeDiff(times.sunset, times.sunrise)

  times.fajr = refineHighLat(ctx, times.fajr, times.sunrise, evaluate(ctx.params.fajr), nightTime, "ccw")
  times.isha = refineHighLat(ctx, times.isha, times.sunset, evaluate(ctx.params.isha), nightTime, "cw")
  times.maghrib = refineHighLat(ctx, times.maghrib, times.sunset, evaluate(ctx.params.maghrib), nightTime, "cw")
  return times
}

function refineHighLat(ctx, time, base, angle, night, direction) {
  var portion = nightPortion(ctx, angle, night)
  var diff = direction === "ccw" ? timeDiff(time, base) : timeDiff(base, time)
  if (isNaN(time) || diff > portion) {
    return direction === "ccw" ? base - portion : base + portion
  }
  return time
}

// ------------------------------------------------------------------ moonsighting
//
// The Moonsighting Committee does not use a fixed depression angle. It shifts
// Fajr and Isha by a seasonal offset from sunrise/sunset that widens with
// latitude, fitted to observation rather than derived from geometry.
function daysSinceSolstice(doy, year, latitude) {
  var leap = isLeapYear(year)
  var daysInYear = leap ? 366 : 365
  var days
  if (latitude >= 0) {
    days = doy + 10
    if (days >= daysInYear) days -= daysInYear
  } else {
    days = doy - (leap ? 173 : 172)
    if (days < 0) days += daysInYear
  }
  return days
}

function seasonalInterpolate(a, b, c, d, dyy) {
  if (dyy < 91) return a + ((b - a) / 91.0) * dyy
  if (dyy < 137) return b + ((c - b) / 46.0) * (dyy - 91)
  if (dyy < 183) return c + ((d - c) / 46.0) * (dyy - 137)
  if (dyy < 229) return d + ((c - d) / 46.0) * (dyy - 183)
  if (dyy < 275) return c + ((b - c) / 46.0) * (dyy - 229)
  return b + ((a - b) / 91.0) * (dyy - 275)
}

function moonsightingFajr(ctx, sunrise, dyy) {
  var lat = Math.abs(ctx.lat)
  var a = 75 + (28.65 / 55.0) * lat
  var b = 75 + (19.44 / 55.0) * lat
  var c = 75 + (32.74 / 55.0) * lat
  var d = 75 + (48.10 / 55.0) * lat
  return sunrise - Math.round(seasonalInterpolate(a, b, c, d, dyy)) / 60.0
}

function moonsightingIsha(ctx, sunset, dyy, shafaq) {
  var lat = Math.abs(ctx.lat)
  var a, b, c, d
  if (shafaq === "ahmer") {
    a = 62 + (17.40 / 55.0) * lat
    b = 62 - (7.160 / 55.0) * lat
    c = 62 + (5.120 / 55.0) * lat
    d = 62 + (19.44 / 55.0) * lat
  } else if (shafaq === "abyad") {
    a = 75 + (25.60 / 55.0) * lat
    b = 75 + (7.160 / 55.0) * lat
    c = 75 + (36.84 / 55.0) * lat
    d = 75 + (81.84 / 55.0) * lat
  } else {
    a = 75 + (25.60 / 55.0) * lat
    b = 75 + (2.050 / 55.0) * lat
    c = 75 - (9.210 / 55.0) * lat
    d = 75 + (6.140 / 55.0) * lat
  }
  return sunset + Math.round(seasonalInterpolate(a, b, c, d, dyy)) / 60.0
}

// ------------------------------------------------------------------ public API
//
// Returns each name mapped to hours-past-local-midnight as a float, so callers
// can format, diff, and compare without parsing strings back apart. A value may
// exceed 24 (Isha after midnight) or go negative; `toDate` normalizes that onto
// the right calendar day.
function computeTimes(opts) {
  var ctx = makeContext(opts)
  var times = seedTimes()

  // computeRaw takes hours and returns hours, so each pass feeds the next.
  for (var i = 0; i < 3; i++) times = computeRaw(ctx, times)

  times = adjustHighLats(ctx, times)

  if (ctx.methodKey === "Moonsighting") {
    var dyy = daysSinceSolstice(dayOfYear(ctx.year, ctx.month, ctx.day), ctx.year, ctx.lat)
    times.fajr = moonsightingFajr(ctx, times.sunrise, dyy)
    times.isha = moonsightingIsha(ctx, times.sunset, dyy, ctx.params.shafaq || "general")
  }

  // Minute-offset parameters, applied after the angle solution.
  var maghribMin = minutesValue(ctx.params.maghrib)
  if (maghribMin !== null) times.maghrib = times.sunset + maghribMin / 60.0

  var ishaMin = minutesValue(ctx.params.isha)
  if (ishaMin !== null) times.isha = times.maghrib + ishaMin / 60.0

  times.dhuhr = times.dhuhr + evaluate(ctx.params.dhuhr) / 60.0

  // Fixed per-method corrections, applied before the derived times below so the
  // whole panel stays internally consistent — a Diyanet sunrise shown at 06:07
  // should be the same sunrise Duha is measured from.
  for (var adjName in ctx.adjust) {
    if (times[adjName] !== undefined) times[adjName] += Number(ctx.adjust[adjName]) / 60.0
  }

  // Islamic midnight: the middle of the night. Jafari measures it to Fajr
  // rather than to sunrise, which lands it earlier.
  var nightEnd = ctx.params.midnight === "Jafari" ? times.fajr : times.sunrise
  times.midnight = times.sunset + timeDiff(times.sunset, nightEnd) / 2.0

  // The last third of the night, when tahajjud is prayed.
  times.lastThird = times.sunset + (timeDiff(times.sunset, nightEnd) * 2.0) / 3.0

  // Duha begins once the sun has fully risen, conventionally ~15 minutes after
  // sunrise, and runs until just before Dhuhr.
  times.duha = times.sunrise + 15 / 60.0

  // Shift from mean solar time at this longitude to the local civil clock.
  var offset = ctx.timezone - ctx.lng / 15.0
  for (var name in times) {
    if (typeof times[name] === "number") times[name] = times[name] + offset
  }

  // Per-prayer user corrections, in minutes.
  for (var tuneName in ctx.tune) {
    var delta = Number(ctx.tune[tuneName])
    if (times[tuneName] !== undefined && isFinite(delta)) {
      times[tuneName] = times[tuneName] + delta / 60.0
    }
  }

  return times
}

// Turn hours-past-midnight into a real Date on the given calendar day. Hours
// outside [0,24) roll the date, which is what makes an Isha at 24.3 land at
// 00:18 the next morning instead of being clamped.
//
// Rounded to the whole minute, the convention every published timetable uses.
// It also keeps the adhan honest: the notification fires at exactly the minute
// the panel prints, instead of up to 59 seconds after it.
function toDate(year, month, day, hours) {
  if (!isFinite(hours)) return null
  var base = new Date(year, month - 1, day, 0, 0, 0, 0)
  return new Date(base.getTime() + Math.round(hours * 60) * 60000)
}

// Local UTC offset in hours for a specific date, DST included.
function timezoneFor(date) {
  return -date.getTimezoneOffset() / 60.0
}

function timesForDate(date, config) {
  var times = computeTimes({
    year: date.getFullYear(),
    month: date.getMonth() + 1,
    day: date.getDate(),
    latitude: config.latitude,
    longitude: config.longitude,
    elevation: config.elevation || 0,
    timezone: timezoneFor(date),
    method: config.method,
    asr: config.asr,
    highLats: config.highLats,
    tune: config.tune
  })

  var out = {}
  for (var name in times) {
    out[name] = toDate(date.getFullYear(), date.getMonth() + 1, date.getDate(), times[name])
  }
  return out
}

// ------------------------------------------------------------------ schedule
//
// Flattens today's and tomorrow's tables into one forward-ordered list of
// announceable prayers, so "what's next" is a scan rather than a pile of
// midnight special cases. Yesterday is included because Isha frequently belongs
// to the previous calendar day once it crosses midnight.
function buildSchedule(now, config) {
  var entries = []
  var offsets = [-1, 0, 1]

  for (var i = 0; i < offsets.length; i++) {
    var date = new Date(now.getFullYear(), now.getMonth(), now.getDate() + offsets[i])
    var times = timesForDate(date, config)
    for (var p = 0; p < PRAYER_NAMES.length; p++) {
      var key = PRAYER_NAMES[p]
      if (!times[key]) continue
      entries.push({
        key: key,
        date: times[key],
        // Sunrise closes Fajr but is not itself prayed; the UI and the adhan
        // scheduler both need to tell those apart.
        isPrayer: key !== "sunrise",
        dayOffset: offsets[i]
      })
    }
  }

  entries.sort(function(a, b) { return a.date.getTime() - b.date.getTime() })
  return entries
}

// The scan halves take a prebuilt schedule: callers that want both answers —
// which is every caller — would otherwise pay for six days of astronomy to get
// two lookups out of the same three.
function findNext(schedule, now, includeSunrise) {
  for (var i = 0; i < schedule.length; i++) {
    var entry = schedule[i]
    if (!includeSunrise && !entry.isPrayer) continue
    if (entry.date.getTime() > now.getTime()) return entry
  }
  return null
}

function findCurrent(schedule, now, includeSunrise) {
  var found = null
  for (var i = 0; i < schedule.length; i++) {
    var entry = schedule[i]
    if (!includeSunrise && !entry.isPrayer) continue
    if (entry.date.getTime() <= now.getTime()) found = entry
    else break
  }
  return found
}

function nextPrayer(now, config, includeSunrise) {
  return findNext(buildSchedule(now, config), now, includeSunrise)
}

function currentPrayer(now, config, includeSunrise) {
  return findCurrent(buildSchedule(now, config), now, includeSunrise)
}

if (typeof module !== "undefined" && module.exports) {
  module.exports = {
    METHODS: METHODS, METHOD_ORDER: METHOD_ORDER, TIME_NAMES: TIME_NAMES,
    PRAYER_NAMES: PRAYER_NAMES, LABELS: LABELS,
    computeTimes: computeTimes, timesForDate: timesForDate, toDate: toDate,
    buildSchedule: buildSchedule, nextPrayer: nextPrayer, currentPrayer: currentPrayer,
    findNext: findNext, findCurrent: findCurrent,
    methodKeys: methodKeys, methodInfo: methodInfo, methodName: methodName,
    icon: icon, mosqueIcon: mosqueIcon, MOSQUE_ICON: MOSQUE_ICON,
    julian: julian, sunPosition: sunPosition, dayOfYear: dayOfYear
  }
}
