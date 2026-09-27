.pragma library

// Hijri calendar conversion.
//
// Uses the arithmetic ("Kuwaiti") civil Islamic calendar: a fixed 30-year cycle
// of 11 leap years, which is what Microsoft's HijriCalendar and most libraries
// implement. It tracks the observed Umm al-Qura calendar to within a day or so.
//
// A day of slack is unavoidable rather than a defect: month starts depend on
// local moon sighting, so two mosques in the same city can disagree. The panel
// exposes a -2..+2 day correction for exactly that reason, and anyone who needs
// their local authority's reckoning sets it once.

var MONTHS = [
  "Muharram", "Safar", "Rabi' al-Awwal", "Rabi' al-Thani",
  "Jumada al-Ula", "Jumada al-Akhirah", "Rajab", "Sha'ban",
  "Ramadan", "Shawwal", "Dhu al-Qi'dah", "Dhu al-Hijjah"
]

var MONTHS_AR = [
  "محرم", "صفر", "ربيع الأول", "ربيع الآخر",
  "جمادى الأولى", "جمادى الآخرة", "رجب", "شعبان",
  "رمضان", "شوال", "ذو القعدة", "ذو الحجة"
]

var WEEKDAYS = ["al-Ahad", "al-Ithnayn", "ath-Thulatha", "al-Arbi'a", "al-Khamis", "al-Jumu'ah", "as-Sabt"]
var WEEKDAYS_AR = ["الأحد", "الاثنين", "الثلاثاء", "الأربعاء", "الخميس", "الجمعة", "السبت"]

function gregorianToJD(year, month, day) {
  if (month < 3) {
    year -= 1
    month += 12
  }
  var a = Math.floor(year / 100.0)
  var b = 2 - a + Math.floor(a / 4.0)
  return Math.floor(365.25 * (year + 4716)) + Math.floor(30.6001 * (month + 1)) + day + b - 1524
}

// Gregorian calendar date -> { year, month (1-12), day }.
function fromGregorian(year, month, day, dayOffset) {
  var jd = gregorianToJD(year, month, day) + (Number(dayOffset) || 0)

  var l = jd - 1948440 + 10632
  var n = Math.floor((l - 1) / 10631)
  l = l - 10631 * n + 354
  var j = Math.floor((10985 - l) / 5316) * Math.floor((50 * l) / 17719) +
          Math.floor(l / 5670) * Math.floor((43 * l) / 15238)
  l = l - Math.floor((30 - j) / 15) * Math.floor((17719 * j) / 50) -
          Math.floor(j / 16) * Math.floor((15238 * j) / 43) + 29

  var hMonth = Math.floor((24 * l) / 709)
  var hDay = l - Math.floor((709 * hMonth) / 24)
  var hYear = 30 * n + j - 30

  return { year: hYear, month: hMonth, day: hDay }
}

function fromDate(date, dayOffset) {
  return fromGregorian(date.getFullYear(), date.getMonth() + 1, date.getDate(), dayOffset)
}

function monthName(month) { return MONTHS[Math.max(0, Math.min(11, month - 1))] }
function monthNameAr(month) { return MONTHS_AR[Math.max(0, Math.min(11, month - 1))] }

function format(date, dayOffset) {
  var h = fromDate(date, dayOffset)
  return h.day + " " + monthName(h.month) + " " + h.year + " AH"
}

function formatShort(date, dayOffset) {
  var h = fromDate(date, dayOffset)
  return h.day + " " + monthName(h.month)
}

function formatAr(date, dayOffset) {
  var h = fromDate(date, dayOffset)
  return h.day + " " + monthNameAr(h.month) + " " + h.year
}

function weekdayName(date) { return WEEKDAYS[date.getDay()] }
function weekdayNameAr(date) { return WEEKDAYS_AR[date.getDay()] }

// Months that carry their own observances, so the panel can say why today is
// not an ordinary day without hardcoding a calendar of events.
function monthNote(month, day) {
  if (month === 9) return "Ramadan — month of fasting"
  if (month === 12 && day >= 8 && day <= 13) return "Days of Hajj"
  if (month === 12 && day === 10) return "Eid al-Adha"
  if (month === 10 && day === 1) return "Eid al-Fitr"
  if (month === 1 && day === 10) return "Day of Ashura"
  if (month === 7) return "Rajab — a sacred month"
  if (month === 8) return "Sha'ban"
  return ""
}

if (typeof module !== "undefined" && module.exports) {
  module.exports = {
    MONTHS: MONTHS, MONTHS_AR: MONTHS_AR,
    fromGregorian: fromGregorian, fromDate: fromDate, format: format,
    formatShort: formatShort, formatAr: formatAr, monthName: monthName,
    monthNameAr: monthNameAr, monthNote: monthNote,
    weekdayName: weekdayName, weekdayNameAr: weekdayNameAr
  }
}
