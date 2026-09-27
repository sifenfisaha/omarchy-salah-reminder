.pragma library

// The voices offered under Settings › Voice.
//
// Only the first ships with the plugin. The others are fetched on request from
// Wikimedia Commons, where every file carries a reviewed free licence, into
// ~/.local/state/omarchy/salah/adhan/, and the attribution each licence asks
// for is shown under the setting. Recordings by the muezzins people ask for by
// name are copyrighted and cannot be redistributed by a free plugin; `custom`
// points the plugin at a file of your own instead.
//
// Special:FilePath is a stable redirect to the current upload, so a file that
// is re-uploaded on Commons keeps working here. Sizes are approximate and only
// shown to the user before a download.
var COMMONS = "https://commons.wikimedia.org/wiki/"

var VOICES = [
  {
    id: "bundled",
    label: "Bundled recording",
    detail: "Ships with the plugin",
    author: "Aishatu98",
    licence: "CC0 1.0",
    page: COMMONS + "File:Adhan.ogg",
    url: "",
    ext: "ogg",
    bytes: 338741,
    seconds: 42
  },
  {
    id: "madinah",
    label: "Madinah, the Prophet's Mosque",
    detail: "Live recording from Masjid an-Nabawi",
    author: "ejaz215",
    licence: "CC BY 3.0",
    page: COMMONS + "File:33937_ejaz215_call-to-prayer-from-the-prophet-s-mo.ogg",
    url: COMMONS + "Special:FilePath/33937_ejaz215_call-to-prayer-from-the-prophet-s-mo.ogg",
    ext: "ogg",
    bytes: 2973696,
    seconds: 187
  },
  {
    id: "makkah",
    label: "Makkah, Masjid al-Haram",
    detail: "Live recording from the Grand Mosque, January 2013",
    author: "Seyfula Islam",
    licence: "CC BY 3.0",
    page: COMMONS + "File:Adhan,_Great_Mosque_of_Mecca_-_Jan_21,_2013.webm",
    url: COMMONS + "Special:FilePath/Adhan,_Great_Mosque_of_Mecca_-_Jan_21,_2013.webm",
    ext: "webm",
    bytes: 9359360,
    seconds: 197
  },
  {
    id: "aaqib-azeez",
    label: "Aaqib Azeez",
    detail: "Studio recitation",
    author: "Atcovi",
    licence: "CC BY-SA 4.0",
    page: COMMONS + "File:The_Adhan_-_Muslim_Call_to_Prayer_-_Aaqib_Azeez.mp3",
    url: COMMONS + "Special:FilePath/The_Adhan_-_Muslim_Call_to_Prayer_-_Aaqib_Azeez.mp3",
    ext: "mp3",
    bytes: 1447936,
    seconds: 87
  },
  {
    id: "nigeria",
    label: "Nigeria, mosque recording",
    detail: "Live recording, Wiki Loves Africa 2026",
    author: "Isaacayodele32",
    licence: "CC BY-SA 4.0",
    page: COMMONS + "File:Call_to_prayer.ogg",
    url: COMMONS + "Special:FilePath/Call_to_prayer.ogg",
    ext: "ogg",
    bytes: 624640,
    seconds: 65
  },
  {
    id: "custom",
    label: "A file of your own",
    detail: "Anything mpv can play",
    author: "",
    licence: "",
    page: "",
    url: "",
    ext: "",
    bytes: 0,
    seconds: 0
  }
]

function voice(id) {
  for (var i = 0; i < VOICES.length; i++) {
    if (VOICES[i].id === id) return VOICES[i]
  }
  return VOICES[0]
}

function isKnown(id) {
  for (var i = 0; i < VOICES.length; i++) {
    if (VOICES[i].id === id) return true
  }
  return false
}

// Fetched rather than shipped or supplied: everything with a source URL.
function isDownloadable(v) {
  return !!(v && v.url)
}

// The shape the settings dropdown takes.
function options() {
  var out = []
  for (var i = 0; i < VOICES.length; i++) out.push({ value: VOICES[i].id, label: VOICES[i].label })
  return out
}

// The credit a licence asks for, in one line.
function attribution(v) {
  if (!v || !v.author) return ""
  return "Recording by " + v.author + ", " + v.licence
}

function sizeText(bytes) {
  if (bytes >= 1048576) return (bytes / 1048576).toFixed(1) + " MB"
  return Math.round(bytes / 1024) + " KB"
}

function durationText(seconds) {
  var m = Math.floor(seconds / 60)
  var s = seconds % 60
  return m + ":" + (s < 10 ? "0" + s : String(s))
}

if (typeof module !== "undefined" && module.exports) {
  module.exports = {
    VOICES: VOICES, voice: voice, isKnown: isKnown, isDownloadable: isDownloadable,
    options: options, attribution: attribution, sizeText: sizeText, durationText: durationText
  }
}
