# Changelog

All notable changes to this project are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- A **Voice** setting. The default is now a live recording from the Prophet's
  Mosque in Madinah, fetched from Wikimedia Commons the first time the plugin
  runs; the bundled recording plays until it has arrived. The setting also
  offers a live recording from Masjid al-Haram in Makkah, a studio recitation
  by Aaqib Azeez, a mosque recording from Nigeria, the bundled recording for a
  plugin that never touches the network, and a file of your own. Each
  download is credited under the setting, an existing custom path keeps
  working, and `omarchy-shell salah fetch` retries a failed download.

### Removed

- The Imsak line in the day view. It sat ten minutes before Fajr, a convention
  some timetables print but one with no basis in the Sunnah: the fast begins
  at Fajr itself, and the scholars quoted in
  [#3](https://github.com/sifenfisaha/omarchy-salah-reminder/issues/3) call
  an earlier cut-off an innovation. The Fajr row already marks the moment.

### Fixed

- The configuration could silently reset to defaults. Rewriting `config.json`
  in place let a watcher read it half-written, and the empty result parsed as a
  fresh configuration; the next click would have written that over the real
  one. Writes are now atomic, an unparseable file is ignored rather than
  defaulted, and a file that does not exist yet is polled until it does.
- A prayer announced once was never announced again at a moved time, and a
  shell restart inside the grace window announced it twice. Announcements are
  now keyed by day, prayer and minute and remembered in
  `~/.local/state/omarchy/salah/announced.json`.
- Settings dropdowns kept showing their last pick after the file changed
  underneath them.
- Pressing Play while the adhan was already playing left the panel showing
  nothing playing, with Stop disabled.
- Detect and the city search failed silently; both now say what happened, and a
  failed IP lookup is retried every five minutes instead of every second.
- Switching the Umm al-Qura correction off kept the learned offset; it is now
  forgotten, and switching the correction back on re-syncs immediately.
- "Use weather location" lit up even when Omarchy had no weather location.
- Escape did nothing inside the city and custom-file fields.
- Stop looked clickable while nothing was playing.
- Settings reopened wherever they had last been scrolled to.

### Changed

- "Salah" is now spelt the standard way everywhere, and the plugin id is
  `salah.reminder`. That changes the `omarchy-shell salah` and
  `salah.reminder` IPC targets, the notification source, the repository name,
  and the configuration and state directories, now `~/.config/omarchy/salah`
  and `~/.local/state/omarchy/salah`. To carry an existing install over: move
  both old `sallah` directories to their new names, rename the plugin folder
  under `~/.config/omarchy/plugins` to `salah.reminder`, replace
  `sallah.reminder` in `~/.config/omarchy/shell.json` and in any keybinds,
  and restart the shell.
- Repository layout: the pure JavaScript engine now lives in `lib/`, reusable
  QML in `components/`. Contributor documentation, a changelog, issue and pull
  request templates, and a CI workflow were added.

## [1.0.0] - 2026-09-27

### Added

- Prayer times in the Omarchy bar with a live countdown, and a day view with a
  progress ring, every prayer with its Arabic name, the Hijri date, and the
  derived times: Imsak, Duha, Islamic midnight and the last third of the night.
- The adhan at each prayer, with a bundled CC0 recording, per-prayer bells, a
  volume, a custom file, desktop notifications and a heads-up reminder.
- Sixteen calculation methods, both Asr conventions, four high-latitude rules
  and per-prayer fine tuning, computed locally with no network.
- Location from a chosen city, Omarchy's weather location, or an IP lookup.
- A daily Hijri correction against Umm al-Qura, with a manual shift.
- A command-line surface through `omarchy-shell salah` and a machine-readable
  `state.json`.
