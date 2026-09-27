# How it fits together

Three surfaces, one file, and one part that acts. Keep that shape and most
changes stay small.

```
                 ~/.config/omarchy/salah/config.json
                    ▲ writes            ▲ writes (hijri correction)
                    │                   │
   ┌────────────────┴───┐   ┌───────────┴─────────┐   ┌─────────────────────┐
   │ Panel.qml          │   │ Service.qml         │   │ BarWidget.qml       │
   │ day view, settings │   │ adhan, notifications│   │ the pill            │
   │ reads + writes     │   │ lookups, state files│   │ reads only          │
   └────────────────────┘   └─────────────────────┘   └─────────────────────┘
              │ computes            │ computes                │ computes
              └─────────────────────┼─────────────────────────┘
                                    ▼
                          lib/  PrayerTimes.js · Hijri.js · Model.js
```

## The three surfaces

**Service.qml** is mounted once per shell. It is the only file that does
anything to the world: plays the adhan, sends notifications, runs `curl`, and
writes `state.json` and `announced.json`. Bar widgets exist once per monitor, so
if playback lived there a three-monitor desk would hear three adhans.

**BarWidget.qml** is instantiated by the bar in each slot it occupies. It draws
the pill and hosts the panel through a `Loader`, and forwards open, close and
toggle to it because the bar identifies a panel by the widget in the slot.

**Panel.qml** is the popup: the day view and, behind a crossfade, the settings.
It is the only place settings are edited.

Each surface computes prayer times *itself* from the config file and the pure
functions in `lib/`. Nothing is passed between them at runtime, which is what
keeps the bar correct when the service is disabled, and makes it impossible for
the pill and the panel to disagree.

## The config file is the only shared state

Every write goes through a `FileView` with `atomicWrites: true`, so the file is
replaced by rename and a watcher can never read it half-written. That is not a
nicety: rewriting the file in place raised two change notifications, a watcher
that read between the truncate and the write saw an empty file, and Quickshell
drops a `reload()` while one is already in flight, so that watcher kept the
empty result. `Model.parseConfig` returns `null` for anything that is not valid
JSON, and every loader keeps its last good config when it gets `null`; only a
file that does not exist means "start from defaults".

`Model.mergeConfig` lays the stored file over the defaults one level deep, so a
config written by an older version stays loadable and a hand-edited file with a
missing key loses that key rather than everything.

Writers apply the change to their in-memory copy first so the UI answers a click
immediately; the write comes back through the watcher as the same value.

## The engine

`lib/PrayerTimes.js` implements the PrayTimes solar model: mean anomaly and mean
longitude give the ecliptic longitude, which yields the equation of time and the
declination for a Julian day; each prayer is then a fixed depression angle away
from solar noon, or a shadow ratio for Asr. The method table carries the
published angles, Diyanet's fixed minute corrections, and the Moonsighting
Committee's seasonal fit. Everything is in degrees to match the references.

`buildSchedule` flattens yesterday, today and tomorrow into one ordered list of
announceable prayers. "What is next" is then a scan, and an Isha that crosses
midnight at high latitude is still found, because it sits on the previous
calendar day's table.

`lib/Model.js` holds the config shape, the location precedence, the day model
the surfaces draw from, and every formatting rule. `lib/Hijri.js` is the
arithmetic (Kuwaiti) calendar. None of these files import QML, so
`node test/times.test.js` can load them directly; keep it that way.

## Announcing

The service ticks once a second and compares wall-clock time against the
schedule rather than arming a long timer, because a timer armed hours out does
not survive suspend, a clock correction, or a timezone change.

Each prayer is identified by `Model.announceStamp`, which is the day, the
prayer and the minute. A prayer whose time moves through a tune, a new method
or a new city becomes a new announcement. Stamps are recorded in
`~/.local/state/omarchy/salah/announced.json` so that neither a reload nor a
restart announces a prayer twice, and a prayer whose moment passed while the
machine was asleep is marked and skipped rather than fired on resume. The
90-second grace window is what makes that distinction.

Nothing fires until the config, the weather location and the announcement
record have each been read once. Before that the config is the built-in
default, which has no location, and acting on it meant an IP lookup on every
start.

## Location

`Model.effectiveLocation` prefers a city chosen in the panel, then Omarchy's
weather location from `~/.local/state/omarchy/settings/weather.json`, then an
IP lookup, and the panel's caption says which one is in use. A failed IP lookup
is retried after five minutes, not on the next tick.

## Playback

One `Process` runs `mpv`. Quickshell only starts a process's new command after
the old one has exited, so a Play during playback is parked in `pendingPrayer`
and started from the exit handler; doing it directly cleared the playing state
after it had been set for the new adhan.

The recording that plays is the voice chosen in settings, from the catalogue in
`lib/Adhans.js`. Only the bundled one ships with the plugin; the others are
fetched from Wikimedia Commons into `~/.local/state/omarchy/salah/adhan/` the
first time they are chosen, with a `test -s` probe rather than a `FileView` to
learn whether the file is there, and a `.part` file that only becomes the real
one once it is recording-sized. Until then, or if the download fails, the
bundled recording plays, so a prayer is never silent because of the network.

## Quickshell behaviours worth knowing

These have each cost a debugging session. Check them before assuming the code
is wrong.

- **A `FileView` cannot watch a file that does not exist yet**, and it does not
  notice the file appearing later. Loaders poll every few seconds while a file
  is missing and stop once a load succeeds.
- **`reload()` is ignored while a load is already in flight** for the same
  path. Combined with in-place writes this produced the reset described above.
- **`FileView.setText` with `atomicWrites` creates missing parent
  directories** and is seen by other watchers of the same path in the same
  process. The `mkdir -p` at startup is belt and braces.
- **The shell's plugin hot reload does not load new code.** It re-creates the
  plugin from cached components because `Qt.clearComponentCache` is undefined
  inside Quickshell. Run `omarchy restart shell` after every edit.
- **The shell keeps a service instance across a rescan** unless the plugin is
  removed or disabled, so a service is never re-created by saving a file.
- **`Process.running = true` while the old process is alive is deferred** until
  that process exits; `onExited` fires for the old one first.
- **The shell's `Dropdown` assigns its own `value` on selection**, which
  removes any binding the caller gave it. `components/SettingsDropdown.qml`
  exists for exactly that reason.
- **Assigning a bound property from JavaScript removes the binding**; to reset
  a `TextField` to its bound value, assign `Qt.binding(...)` again.
