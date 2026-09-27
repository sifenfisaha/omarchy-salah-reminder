# Contributing

Thanks for taking an interest. This is a small plugin with a clear job, and the
bar for a change is simply that it makes the plugin better for the people who
run it every day. Bug reports, fixes, new calculation methods, and better
wording are all welcome.

## Before you start

- Bugs and ideas go in [issues](../../issues). For a bug, say what you did,
  what you expected, and what happened instead, and paste anything the shell
  log says about the plugin (see [Reading the shell log](#reading-the-shell-log)).
- For anything larger than a fix, open an issue first so the shape can be
  agreed before the work is done.
- By contributing you agree that your work is released under the
  [MIT licence](LICENSE), and that you will follow the
  [code of conduct](CODE_OF_CONDUCT.md).

## Running your own copy

The shell loads the plugin from `~/.config/omarchy/plugins/salah.reminder`.
Clone straight into that directory, or clone elsewhere and symlink it:

```bash
git clone https://github.com/sifenfisaha/omarchy-salah-reminder.git \
  ~/.config/omarchy/plugins/salah.reminder
omarchy restart shell
omarchy bar move salah.reminder --section center   # if the pill is not in the bar yet
```

**Restart the shell after every change.** Saving a file under the plugins
directory makes the shell rebuild the plugin, but from Qt's cached components:
`Qt.clearComponentCache` is not available inside Quickshell, so edits are not
picked up until `omarchy restart shell`. That is true for the bar widget, the
panel, and the service alike.

Useful while iterating:

```bash
omarchy-shell salah.reminder settings   # open the panel straight on settings
omarchy-shell salah today               # what the service thinks today looks like
omarchy-shell salah test                # play the adhan; `stop` stops it
```

## Checks to run

```bash
node test/times.test.js     # the engine and config parsing; no network, sets its own zone
omarchy plugin validate .   # the manifest checks the shell enforces at install
```

The tests are golden-value checks against published timetables plus the
invariants a user notices instantly when they break, such as prayers staying in
order all year at high latitudes. If you touch `lib/`, add a check for what you
changed; the file is plain node with no framework.

Then try it for real: restart the shell, open the panel, change the setting you
touched, and confirm `~/.config/omarchy/salah/config.json` changes and the bar
follows.

## Reading the shell log

The running shell keeps a log that includes QML warnings and, at debug level,
every file the plugin reads:

```bash
qs log --pid "$(pgrep -f 'quickshell -n -p')" | grep -i salah
qs log --pid "$(pgrep -f 'quickshell -n -p')" -r '*.debug=true' --log-times | grep salah/config.json
```

A QML error in the plugin shows up here, not on the terminal.

## Where things live

| Path | What it is |
| --- | --- |
| `manifest.json` | The plugin declaration: one service, one bar widget |
| `Service.qml` | The only part that *acts*: adhan, notifications, network lookups, the state files |
| `BarWidget.qml` | The pill in the bar |
| `Panel.qml` | The day view and the settings behind it |
| `components/` | Reusable QML pieces used by the panel |
| `lib/` | Pure JavaScript: the astronomy, the Hijri calendar, the config shape. No QML, so node can test it |
| `assets/` | The bundled adhan recording |
| `test/` | The regression tests |
| `docs/` | Screenshots and [ARCHITECTURE.md](docs/ARCHITECTURE.md), which explains how the pieces fit |

Read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) before changing how the
three surfaces share state; it also lists the Quickshell behaviours that have
bitten this code before.

## Style

- Two-space indentation, no semicolons in QML and in `lib/`, LF line endings.
  `.editorconfig` carries the basics.
- Comments explain *why*, not what. Every non-obvious decision in this code
  has a sentence next to it saying what would go wrong otherwise; keep that up.
- Prefer the shell's own components from `qs.Ui` and its `Style` tokens over
  anything hand-rolled, so the plugin follows the user's theme.
- Side effects belong in `Service.qml`. The bar widget and the panel only read
  and write the config file.
- `lib/` stays free of QML and of anything node cannot load.
- Keep the README honest: if behaviour or a config key changes, change the
  README in the same commit, and add a line under *Unreleased* in
  `CHANGELOG.md`.

## Commits and pull requests

- One logical change per commit, with a subject like
  `Panel: each view opens at its top`: the area, a colon, then what the change
  does. The body says why.
- Fill in the pull request template, in particular how you checked the change
  in the running shell.
- Small, focused pull requests are reviewed sooner than large ones.
