#!/usr/bin/env node
// Golden-value regression test for the prayer-time engine.
//
// The expectations below were cross-checked against api.aladhan.com, which
// implements the same PrayTimes model, and independently against adhan-js.
// Where the two references disagreed the value here sits between them; where
// they agreed it matches both exactly.
//
//   node test/times.test.js
//
// No network and no dependencies: the point of the file is to catch a change
// to the astronomy that nobody meant to make.

const fs = require("fs");
const path = require("path");

// Expected values are local wall-clock times in Addis Ababa, so the test fixes
// its own zone rather than depending on the machine it runs on. TZ has to be
// set before the first Date is constructed, hence the re-exec.
const TZ = "Africa/Addis_Ababa";
if (process.env.TZ !== TZ) {
  const { spawnSync } = require("child_process");
  const r = spawnSync(process.execPath, [__filename], {
    stdio: "inherit",
    env: { ...process.env, TZ },
  });
  process.exit(r.status === null ? 1 : r.status);
}

function load(file) {
  // The sources are QML JS libraries; strip the QML-only directives and
  // satisfy their .import statements by hand.
  const src = fs.readFileSync(path.join(__dirname, "..", file), "utf8")
    .replace(/^\s*\.pragma\s+library\s*$/m, "")
    .replace(/^\s*\.import\s+.*$/gm, "");
  const mod = { exports: {} };
  new Function("module", "exports", "PrayerTimes", "Hijri", "Adhans", src)(
    mod, mod.exports, globalThis.PrayerTimes, globalThis.Hijri, globalThis.Adhans);
  return mod.exports;
}

globalThis.PrayerTimes = load("lib/PrayerTimes.js");
globalThis.Hijri = load("lib/Hijri.js");
globalThis.Adhans = load("lib/Adhans.js");
const PT = globalThis.PrayerTimes;
const H = globalThis.Hijri;

const hhmm = d => d
  ? String(d.getHours()).padStart(2, "0") + ":" + String(d.getMinutes()).padStart(2, "0")
  : "--:--";

let pass = 0;
const failures = [];

function check(name, actual, expected) {
  if (actual === expected) { pass++; return; }
  failures.push(`${name}\n      expected ${expected}\n      actual   ${actual}`);
}

function times(y, m, d, cfg) {
  return PT.timesForDate(new Date(y, m - 1, d), cfg);
}

// --- Addis Ababa, the reference city -------------------------------------
const ADDIS = { latitude: 9.0192, longitude: 38.7525 };

const mwl = times(2026, 9, 27, { ...ADDIS, method: "MWL", asr: "Standard" });
check("Addis MWL Fajr",    hhmm(mwl.fajr),    "05:04");
check("Addis MWL Sunrise", hhmm(mwl.sunrise), "06:14");
check("Addis MWL Dhuhr",   hhmm(mwl.dhuhr),   "12:16");
check("Addis MWL Asr",     hhmm(mwl.asr),     "15:32");
check("Addis MWL Maghrib", hhmm(mwl.maghrib), "18:18");
check("Addis MWL Isha",    hhmm(mwl.isha),    "19:24");

const hanafi = times(2026, 9, 27, { ...ADDIS, method: "MWL", asr: "Hanafi" });
check("Addis Hanafi Asr", hhmm(hanafi.asr), "16:35");

const egypt = times(2026, 9, 27, { ...ADDIS, method: "Egypt", asr: "Standard" });
check("Addis Egypt Fajr", hhmm(egypt.fajr), "04:58");
check("Addis Egypt Isha", hhmm(egypt.isha), "19:26");

// Diyanet publishes fixed corrections on top of the angles; without them the
// method silently returns times no mosque in Turkey would recognise.
const turkey = times(2026, 9, 27, { ...ADDIS, method: "Turkey", asr: "Standard" });
check("Turkey sunrise adjustment", hhmm(turkey.sunrise), "06:07");
check("Turkey dhuhr adjustment",   hhmm(turkey.dhuhr),   "12:21");
check("Turkey asr adjustment",     hhmm(turkey.asr),     "15:36");
check("Turkey maghrib adjustment", hhmm(turkey.maghrib), "18:25");

// Umm al-Qura defines Isha as a fixed interval after Maghrib, not an angle.
const makkah = times(2026, 9, 27, { ...ADDIS, method: "Makkah", asr: "Standard" });
check("Makkah Isha is Maghrib + 90",
  Math.round((makkah.isha - makkah.maghrib) / 60000), 90);

// --- Derived times --------------------------------------------------------
check("Duha follows sunrise",
  Math.round((mwl.duha - mwl.sunrise) / 60000), 15);
check("Last third is after midnight point", mwl.lastThird > mwl.midnight, true);

// --- Ordering invariants, swept across a whole year -----------------------
// Ordering is the property a user notices instantly when it breaks, and the
// one most likely to break quietly at an odd latitude or season.
for (const place of [
  { n: "Addis",   latitude: 9.0192,  longitude: 38.7525 },
  { n: "Jakarta", latitude: -6.2088, longitude: 106.8456 },
  { n: "London",  latitude: 51.5074, longitude: -0.1278 },
  { n: "Oslo",    latitude: 59.9139, longitude: 10.7522 },
]) {
  let ordered = true;
  let finite = true;
  for (let doy = 1; doy <= 365; doy += 7) {
    const d = new Date(2026, 0, doy);
    const t = times(d.getFullYear(), d.getMonth() + 1, d.getDate(),
      { ...place, method: "MWL", asr: "Standard", highLats: "AngleBased" });
    for (const k of ["fajr", "sunrise", "dhuhr", "asr", "maghrib", "isha"]) {
      if (!t[k] || isNaN(t[k].getTime())) finite = false;
    }
    if (!(t.fajr < t.sunrise && t.sunrise < t.dhuhr &&
          t.dhuhr < t.asr && t.asr < t.maghrib && t.maghrib < t.isha)) {
      ordered = false;
    }
  }
  check(`${place.n}: every prayer defined all year`, finite, true);
  check(`${place.n}: prayers stay in order all year`, ordered, true);
}

// --- Schedule spans midnight ---------------------------------------------
// At high latitudes Isha can land after midnight, which puts it on the previous
// calendar day's table and off the next day's. The service announces from the
// schedule rather than from one day's table precisely so that prayer still
// fires; this pins that the schedule really does carry it.
{
  const oslo = { latitude: 59.9139, longitude: 10.7522, method: "MWL",
                 asr: "Standard", highLats: "AngleBased" };
  const jun = new Date(2026, 5, 21);
  const table = PT.timesForDate(jun, oslo);

  // Isha on 21 June in Oslo belongs to the small hours of the 22nd.
  check("Oslo June Isha crosses midnight", table.isha.getDate(), 22);

  // Standing just before it, the schedule must still offer it as next.
  const justBefore = new Date(table.isha.getTime() - 60 * 1000);
  const sched = PT.buildSchedule(justBefore, oslo);
  const next = PT.findNext(sched, justBefore, false);
  check("Oslo past-midnight Isha is reachable", next && next.key, "isha");
  check("Oslo past-midnight Isha is the same moment",
    next && next.date.getTime(), table.isha.getTime());
}

// --- Hijri ----------------------------------------------------------------
// Anchors that a reader would notice being wrong.
check("Ramadan 1447 begins 18 Feb 2026",
  (() => { const h = H.fromGregorian(2026, 2, 19, 0); return `${h.day}/${h.month}`; })(), "2/9");
check("Eid al-Fitr 1447 on 20 Mar 2026",
  (() => { const h = H.fromGregorian(2026, 3, 20, 0); return `${h.day}/${h.month}`; })(), "1/10");
check("Hijri offset shifts the day",
  H.fromGregorian(2026, 9, 27, 2).day - H.fromGregorian(2026, 9, 27, 0).day, 2);

// --- Config file handling -------------------------------------------------
// A watcher can catch config.json between two writes, and a hand edit can be
// mid-typo. Neither may turn into a fresh default configuration: the three
// consumers keep their last good config when parseConfig returns null.
const M = load("lib/Model.js");
check("Empty config text is rejected, not defaulted", M.parseConfig(""), null);
check("Truncated config text is rejected, not defaulted",
  M.parseConfig('{"location": {"name": "Addis'), null);
check("Valid config keeps its own values", M.parseConfig('{"method": "Egypt"}').method, "Egypt");
check("Valid config fills omitted keys from defaults",
  M.parseConfig('{"method": "Egypt", "audio": {"volume": 40}}').audio.enabled, true);

// --- Voices ---------------------------------------------------------------
// The catalogue is data the service acts on blindly, so every entry must be
// complete, and the config must keep an old custom path working.
{
  const A = globalThis.Adhans;
  const ids = A.VOICES.map(v => v.id);
  check("Voice ids are unique", new Set(ids).size, ids.length);
  check("The default voice is Madinah", A.DEFAULT, "madinah");
  check("The default voice is listed first", ids[0], A.DEFAULT);
  check("The fallback never needs the network", A.isDownloadable(A.voice(A.FALLBACK)), false);
  check("Fresh defaults choose the default voice", M.defaults().audio.adhan, A.DEFAULT);
  check("A custom file is offered last", ids[ids.length - 1], "custom");
  let complete = true;
  for (const v of A.VOICES) {
    if (!A.isDownloadable(v)) continue;
    if (!/^https:\/\/commons\.wikimedia\.org\/wiki\/Special:FilePath\//.test(v.url)) complete = false;
    if (!v.author || !v.licence || !v.page || !v.ext || !(v.bytes > 0) || !(v.seconds > 0)) complete = false;
  }
  check("Every downloadable voice has a Commons URL, credit, licence, type and size", complete, true);
  check("An unknown voice id falls back to the bundled recording", A.voice("nope").id, "bundled");
  check("Old config with a custom path keeps playing it",
    M.parseConfig('{"audio": {"path": "~/adhan.ogg"}}').audio.adhan, "custom");
  check("Old config without a custom path takes the default voice",
    M.parseConfig('{"audio": {"path": ""}}').audio.adhan, "madinah");
  check("A chosen voice survives alongside a custom path",
    M.parseConfig('{"audio": {"adhan": "makkah", "path": "~/x.ogg"}}').audio.adhan, "makkah");
  check("Unknown voice in the file resolves to bundled",
    M.adhanSelection(M.parseConfig('{"audio": {"adhan": "gone"}}')), "bundled");
  check("Cache path carries the id and the file type",
    M.voiceCachePath(A.voice("makkah")), "/.local/state/omarchy/salah/adhan/makkah.webm");
  check("Sizes read naturally", A.sizeText(2973696) + " " + A.sizeText(624640), "2.8 MB 610 KB");
}

// --- Announcements --------------------------------------------------------
// A prayer whose time moves is a new announcement; the same time is not.
{
  const isha = new Date(2026, 8, 27, 19, 24);
  check("Announcement stamp carries day, prayer and minute",
    M.announceStamp(isha, "isha"), "2026-09-27:isha:19:24");
  check("A nudged prayer gets a new stamp",
    M.announceStamp(new Date(2026, 8, 27, 19, 3), "isha") !== M.announceStamp(isha, "isha"), true);
  const round = M.parseAnnounced(M.serializeAnnounced(["2026-09-27:isha:19:24"], "2026-9-27"));
  check("Announced list round-trips", round.announced.join("|"), "2026-09-27:isha:19:24");
  check("Hijri sync day round-trips", round.hijriSyncDay, "2026-9-27");
  check("Garbage announced file reads as nothing announced", M.parseAnnounced("nope").announced.length, 0);
}

// --- Report ---------------------------------------------------------------
if (failures.length) {
  console.error(`\n  ${failures.length} failed, ${pass} passed\n`);
  failures.forEach(f => console.error("  ✗ " + f + "\n"));
  process.exit(1);
}
console.log(`  ${pass} checks passed`);
