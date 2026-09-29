import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "components"
import "lib/PrayerTimes.js" as PrayerTimes
import "lib/Model.js" as Model
import "lib/Hijri.js" as Hijri
import "lib/Adhans.js" as Adhans

// The popup: today's table, where you are in it, and everything that decides
// those numbers.
//
// Two views share one surface — the day, and the settings behind it — because
// the questions that send someone to the settings ("why is Asr at 15:32?") are
// asked while looking at the day. Crossfading in place keeps the answer next to
// the thing that prompted it.
Panel {
  id: root
  moduleName: "salah.reminder"
  ipcTarget: "salah.reminder.panel"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property bool openedFromHotkey: false

  // The bar tracks the widget mounted in its slot, not this nested panel, so
  // everything the bar identifies a panel by has to be that widget.
  readonly property var barIdentity: hostWidget || root

  readonly property string home: Quickshell.env("HOME")

  property var config: Model.defaults()
  property var weatherLocation: ({ name: "", latitude: null, longitude: null })
  property var ipLocation: null
  property var day: null
  property var rightNow: new Date()

  property string view: "today"
  property string locationQuery: ""
  property var locationSuggestions: []
  // A search or lookup that came back with nothing to show, in words.
  property string locationNotice: ""
  // Derived rather than bookkept: a superseded search and its replacement
  // share one Process, and hand-set flags fell out of step with it.
  readonly property bool locating: (geocodeDebounce.running && String(locationQuery).trim().length >= 2)
    || geocode.running || ipLookup.running

  readonly property var location: Model.effectiveLocation(config, weatherLocation, ipLocation)
  readonly property string locationName: location
    ? (String(location.name || "").length > 0
        ? location.name
        : Number(location.latitude).toFixed(2) + ", " + Number(location.longitude).toFixed(2))
    : ""

  readonly property bool hasWeatherLocation: Model.hasCoordinates(weatherLocation)
  // True only while the weather location is really the one in use. Choosing it
  // with none set keeps the last city, and the button has to say so rather than
  // light up as if the weather location had taken over.
  readonly property bool usingWeatherLocation: hasWeatherLocation && location === weatherLocation
  readonly property string locationCaption: location === null
    ? "Nothing set yet. Omarchy's weather location is used when you have one."
    : (usingWeatherLocation
        ? "Using Omarchy's weather location, " + locationName
        : (config.location.source === "weather" && !hasWeatherLocation
            ? "Omarchy has no weather location yet, so " + locationName + " is still used."
            : "Using " + locationName))

  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(fg, 1.45)
  readonly property color dimmer: Qt.rgba(fg.r, fg.g, fg.b, 0.38)
  readonly property color accent: bar ? bar.urgent : Color.urgent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // The service owns playback, so the panel asks it rather than keeping a
  // second copy of the same fact that could drift out of step. A plugin is
  // allowed to look up its own service; if that ever returns null the panel
  // simply never shows the playing strip, which is the right way to fail.
  readonly property var service: (bar && bar.shell && typeof bar.shell.serviceFor === "function")
    ? bar.shell.serviceFor("salah.reminder") : null
  readonly property string playingPrayer: service ? String(service.playingPrayer || "") : ""
  readonly property bool adhanPlaying: playingPrayer !== ""
  readonly property bool volumeMuted: Math.round(Number(config.audio.volume) || 0) <= 0

  // The voice, and what the service says about fetching it. The service owns
  // the download; with no service the caption falls back to the credit alone.
  readonly property var voice: Adhans.voice(Model.adhanSelection(config))
  readonly property string voiceStatus: service ? String(service.voiceStatus || "") : ""
  readonly property string voiceStatusText: service ? String(service.voiceStatusText || "") : ""
  readonly property string voiceCaption: {
    var v = voice
    if (v.id === "custom") return "Anything mpv can play. Leave the path empty for the bundled recording."
    var parts = [v.detail + ", " + Adhans.durationText(v.seconds)]
    var credit = Adhans.attribution(v)
    if (credit) parts.push(credit)
    if (Adhans.isDownloadable(v)) {
      if (voiceStatus === "ready") parts.push("downloaded")
      else if (voiceStatus === "downloading" || voiceStatus === "failed") parts.push(voiceStatusText)
      else parts.push(Adhans.sizeText(v.bytes) + " download, the bundled recording plays until it arrives")
    }
    return parts.join(" · ")
  }
  readonly property string playingLabel: (playingPrayer === "" || playingPrayer === "test")
    ? "" : Model.prayerLabel(playingPrayer)

  readonly property string nextLabel: (day && day.next) ? Model.prayerLabel(day.next.key) : ""
  readonly property string nextLabelAr: (day && day.next) ? Model.prayerLabelAr(day.next.key) : ""
  readonly property string nextIcon: (day && day.next) ? PrayerTimes.icon(day.next.key) : PrayerTimes.mosqueIcon()
  readonly property string nextTime: (day && day.next) ? Model.formatTime(day.next.date, config.timeFormat) : "--:--"
  readonly property string remaining: day ? Model.formatDuration(day.remainingMs) : ""

  // ---------------------------------------------------------------- lifecycle
  function open() {
    openedFromHotkey = false
    setCenterHoverRevealSuppressed(false)
    root.controller.show()
    root.refresh()
  }

  function openFromHotkey() {
    openedFromHotkey = true
    root.controller.show()
    root.refresh()
    // Set after showing: showing hands the popout coordinator over, which
    // closes whichever panel was open, and that close clears the shared flag.
    Qt.callLater(function() {
      if (root.opened) setCenterHoverRevealSuppressed(true)
    })
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    root.view = "today"
    root.cancelSearch()
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.openFromHotkey()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && typeof root.bar.setCenterHoverRevealSuppressed === "function")
      root.bar.setCenterHoverRevealSuppressed(value)
    else if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  function refresh() {
    configFile.reload()
    weatherFile.reload()
    recompute()
  }

  function recompute() {
    root.rightNow = new Date()
    root.day = Model.buildDay(root.rightNow, root.config, root.location)
  }

  onConfigChanged: recompute()
  onLocationChanged: recompute()

  // Each view starts at its top. The Flickables keep their offset across a
  // close, so settings used to reopen wherever they were last scrolled to,
  // with the header and the search box out of sight.
  onViewChanged: Qt.callLater(root.resetScroll)
  onOpenedChanged: if (opened) Qt.callLater(root.resetScroll)

  function resetScroll() {
    todayScroll.contentY = 0
    settingsScroll.contentY = 0
  }

  Timer {
    interval: 1000
    running: root.opened
    repeat: true
    triggeredOnStart: true
    onTriggered: root.recompute()
  }

  // ---------------------------------------------------------------- config io
  //
  // Writes go through the FileView with atomicWrites, so the bar widget and
  // the service — which watch the same file — can never read it half-written.
  // Rewriting it in place used to leave whichever watcher read between the
  // truncate and the write holding an empty file, which parsed as defaults;
  // one more click would then have written those defaults over the real
  // configuration.
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
    }
    onLoadFailed: function(error) {
      // Only a missing file means "start from defaults"; anything else keeps
      // what is already loaded.
      if (error !== FileViewError.FileNotFound) return
      root.config = Model.defaults()
      root.configMissing = true
    }
    onSaveFailed: function(error) { console.warn("salah: could not write " + path + ": " + error) }
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
    }
    onLoadFailed: function(error) {
      root.weatherLocation = Model.parseWeatherLocation("")
      root.weatherMissing = error === FileViewError.FileNotFound
    }
  }

  // Quickshell cannot watch a file that does not exist yet: the config is
  // created by the service on first run, and Omarchy's weather location can
  // appear at any time. Poll gently while either is missing; once a load
  // succeeds the watcher takes over.
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

  // The service creates this directory too, but saving a setting must not
  // depend on the service being enabled.
  Process {
    id: dirs
    command: ["mkdir", "-p", root.home + Model.CONFIG_DIR]
  }

  // Applied to the in-memory copy first so the UI answers the click
  // immediately; the file write comes back through FileView as the same value.
  function patch(mutator) {
    var next = JSON.parse(JSON.stringify(root.config))
    mutator(next)
    root.config = next
    configFile.setText(Model.serializeConfig(next))
  }

  function setValue(key, value) {
    root.patch(function(c) { c[key] = value })
  }

  function setNested(group, key, value) {
    root.patch(function(c) { c[group][key] = value })
  }

  function toggleAzan(key) {
    root.patch(function(c) { c.azan[key] = c.azan[key] === false })
  }

  function chooseLocation(entry) {
    root.patch(function(c) {
      c.location = {
        name: entry.label || entry.name,
        latitude: entry.latitude,
        longitude: entry.longitude,
        source: "manual"
      }
    })
    root.cancelSearch()
  }

  function useWeatherLocation() {
    root.patch(function(c) { c.location.source = "weather" })
    root.cancelSearch()
  }

  // Drops the query, the suggestions, and any search still in flight.
  function cancelSearch() {
    geocodeDebounce.stop()
    geocode.running = false
    root.locationNotice = ""
    root.locationSuggestions = []
    root.locationQuery = ""
  }

  // ---------------------------------------------------------------- lookups
  //
  // Both lookups say what happened when they come back with nothing. A search
  // that failed and a search that matched no city used to look identical —
  // "Searching…" simply vanished — and so did a rate-limited Detect.
  Process {
    id: geocode
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var results = Model.parseGeocodingResults(text)
        root.locationSuggestions = results
        // An answer with nothing in it differs from no answer at all: curl -f
        // leaves no body on a failure, and that case is reported from onExited.
        var q = String(root.locationQuery || "").trim()
        if (results.length === 0 && q.length >= 2 && String(text || "").trim() !== "")
          root.locationNotice = "No city matches \u201c" + q + "\u201d."
      }
    }
    // A search superseded by a newer one is terminated, which reports as a
    // crash exit; only curl's own failures are worth a message.
    onExited: function(exitCode, exitStatus) {
      if (exitStatus !== 0 || exitCode === 0) return
      root.locationNotice = "City search failed. Check the connection and try again."
    }
  }

  Timer {
    id: geocodeDebounce
    interval: 320
    onTriggered: {
      var q = String(root.locationQuery || "").trim()
      if (q.length < 2) {
        root.locationSuggestions = []
        return
      }
      geocode.running = false
      geocode.command = ["curl", "-fsS", "--max-time", "8",
        "https://geocoding-api.open-meteo.com/v1/search?count=8&language=en&format=json&name=" + encodeURIComponent(q)]
      geocode.running = true
    }
  }

  onLocationQueryChanged: {
    root.locationNotice = ""
    geocodeDebounce.restart()
  }

  Process {
    id: ipLookup
    command: ["curl", "-fsS", "--max-time", "6", "https://ipapi.co/json/"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var parsed = Model.parseIpLocation(text)
        if (!parsed) {
          // curl -f leaves no body on an HTTP error, so this covers being
          // offline, a rate-limited API, and an unexpected answer alike.
          root.locationNotice = "Could not detect a location. Check the connection, or search for a city instead."
          return
        }
        root.ipLocation = parsed
        root.chooseLocation({ label: parsed.name, latitude: parsed.latitude, longitude: parsed.longitude })
      }
    }
  }

  function detectLocation() {
    if (ipLookup.running) return
    root.locationNotice = ""
    ipLookup.running = true
  }

  function run(command) {
    if (root.bar) root.bar.run(command)
  }

  // ---------------------------------------------------------------- surface
  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(430))
    contentHeight: panel.fittedContentHeight(
      root.view === "settings" ? settingsColumn.implicitHeight : todayColumn.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: locationField.activeFocus || audioPathField.activeFocus
      onCloseRequested: {
        if (root.view === "settings") root.view = "today"
        else root.close()
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }

      // ---- Today -------------------------------------------------------
      Flickable {
        id: todayScroll
        anchors.fill: parent
        contentWidth: width
        contentHeight: todayColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height
        visible: opacity > 0
        opacity: root.view === "today" ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 130; easing.type: Easing.OutQuad } }

        Column {
          id: todayColumn
          width: todayScroll.width
          spacing: Style.space(12)

          // ---- Adhan playing. Sits above everything because while it is
          //      sounding it is the only thing anyone opens this panel for,
          //      and the one control they want is Stop. Collapses to zero
          //      height the rest of the time rather than holding space.
          Item {
            width: parent.width
            visible: root.adhanPlaying
            height: visible ? Style.space(52) : 0

            Rectangle {
              anchors.fill: parent
              anchors.leftMargin: Style.space(12)
              anchors.rightMargin: Style.space(12)
              anchors.topMargin: Style.space(8)
              radius: Style.cornerRadius
              color: Style.selectedFillFor(root.accent, root.accent)

              Text {
                id: playingIcon
                anchors.left: parent.left
                anchors.leftMargin: Style.space(14)
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: "\uf028"
                color: root.accent
                font.family: root.fontFamily
                font.pixelSize: Style.font.iconLarge

                SequentialAnimation on opacity {
                  running: root.adhanPlaying
                  loops: Animation.Infinite
                  alwaysRunToEnd: true
                  NumberAnimation { from: 1.0; to: 0.35; duration: 900; easing.type: Easing.InOutQuad }
                  NumberAnimation { from: 0.35; to: 1.0; duration: 900; easing.type: Easing.InOutQuad }
                }
              }

              Column {
                anchors.left: playingIcon.right
                anchors.leftMargin: Style.space(12)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(1)

                Text {
                  textFormat: Text.PlainText
                  text: root.playingLabel === "" ? "Adhan" : root.playingLabel
                  color: root.fg
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.subtitle
                  font.bold: true
                }

                Text {
                  textFormat: Text.PlainText
                  text: root.playingLabel === "" ? "test playback" : "adhan playing"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }

              Button {
                anchors.right: parent.right
                anchors.rightMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                text: "Stop"
                iconText: "\uf04d"
                bordered: true
                foreground: root.fg
                accent: root.accent
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                onClicked: root.run("omarchy-shell salah stop")
              }
            }
          }

          // ---- Hero: progress ring, next prayer, countdown
          Item {
            width: parent.width
            height: Math.max(ring.height, heroText.implicitHeight) + Style.space(18)
            visible: root.location !== null

            Item {
              id: ring
              width: Style.space(76)
              height: width
              anchors.left: parent.left
              anchors.leftMargin: Style.space(18)
              anchors.verticalCenter: parent.verticalCenter

              Canvas {
                id: ringCanvas
                anchors.fill: parent
                // Repaint whenever anything it draws from moves, including a
                // theme switch — a stale ring in the old accent is the one
                // artefact a canvas will happily keep showing.
                property real progress: (root.day && root.day.progress !== null) ? root.day.progress : 0
                property color trackColor: root.dimmer
                property color fillColor: root.accent
                onProgressChanged: requestPaint()
                onTrackColorChanged: requestPaint()
                onFillColorChanged: requestPaint()

                onPaint: {
                  var ctx = getContext("2d")
                  ctx.reset()
                  var cx = width / 2
                  var cy = height / 2
                  var lw = Math.max(2, Math.round(width * 0.055))
                  var r = width / 2 - lw
                  ctx.lineWidth = lw
                  ctx.lineCap = "round"

                  ctx.strokeStyle = trackColor
                  ctx.beginPath()
                  ctx.arc(cx, cy, r, 0, Math.PI * 2)
                  ctx.stroke()

                  if (progress > 0) {
                    ctx.strokeStyle = fillColor
                    ctx.beginPath()
                    ctx.arc(cx, cy, r, -Math.PI / 2, -Math.PI / 2 + Math.PI * 2 * progress)
                    ctx.stroke()
                  }
                }
              }

              Text {
                anchors.centerIn: parent
                textFormat: Text.PlainText
                text: root.nextIcon
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Math.round(ring.width * 0.42)
              }
            }

            Column {
              id: heroText
              anchors.left: ring.right
              anchors.leftMargin: Style.space(16)
              anchors.right: parent.right
              anchors.rightMargin: Style.space(18)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(3)

              Text {
                textFormat: Text.PlainText
                text: root.nextLabel === "" ? "—" : ("NEXT · " + root.nextLabel.toUpperCase())
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.3
              }

              Row {
                spacing: Style.space(8)

                Text {
                  id: heroTime
                  textFormat: Text.PlainText
                  text: root.nextTime
                  color: root.fg
                  font.family: root.fontFamily
                  // Hero read-out, deliberately outside the Style.font.* scale.
                  font.pixelSize: Math.round(Style.font.displayLarge * 1.55)
                  font.bold: true
                }

                Text {
                  textFormat: Text.PlainText
                  anchors.baseline: heroTime.baseline
                  text: root.nextLabelAr
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.heading
                }
              }

              Text {
                textFormat: Text.PlainText
                text: root.remaining === "now" ? "it is time" : ("in " + root.remaining)
                color: root.accent
                font.family: root.fontFamily
                font.pixelSize: Style.font.subtitle
                font.bold: true
              }
            }
          }

          // ---- No location yet
          Column {
            width: parent.width
            visible: root.location === null
            spacing: Style.space(10)
            topPadding: Style.space(18)

            Text {
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              textFormat: Text.PlainText
              text: PrayerTimes.mosqueIcon()
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.displayLarge
            }

            Text {
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              textFormat: Text.PlainText
              text: "Set a location to see prayer times"
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
            }

            Item {
              width: parent.width
              height: firstRunButton.implicitHeight

              Button {
                id: firstRunButton
                anchors.horizontalCenter: parent.horizontalCenter
                text: "Choose a location"
                iconText: ""
                bordered: true
                foreground: root.fg
                accent: root.accent
                fontFamily: root.fontFamily
                onClicked: root.view = "settings"
              }
            }
          }

          // ---- Hijri strip
          Item {
            width: parent.width
            height: hijriRow.implicitHeight + Style.space(4)
            visible: root.day !== null

            Row {
              id: hijriRow
              anchors.horizontalCenter: parent.horizontalCenter
              spacing: Style.space(8)

              Text {
                textFormat: Text.PlainText
                text: ""
                color: root.dimmer
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                textFormat: Text.PlainText
                text: root.day ? root.day.hijriText : ""
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                textFormat: Text.PlainText
                visible: text !== ""
                text: root.day ? Hijri.monthNote(root.day.hijri.month, root.day.hijri.day) : ""
                color: root.accent
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.bold: true
                anchors.verticalCenter: parent.verticalCenter
              }
            }
          }

          PanelSeparator { foreground: root.fg; visible: root.day !== null }

          // ---- The six rows
          Column {
            width: parent.width
            visible: root.day !== null

            Repeater {
              model: root.day ? root.day.rows : []

              CursorSurface {
                id: prayerRow
                required property var modelData
                required property int index

                width: todayColumn.width
                height: Style.space(38)
                foreground: root.fg
                accent: root.accent
                current: modelData.isCurrent
                hasCursor: rowHover.hovered
                radius: Style.cornerRadius

                HoverHandler { id: rowHover }

                // Dim what has already passed so the eye lands on what is
                // still ahead; the next prayer keeps full weight plus a mark.
                readonly property real rowOpacity: modelData.isNext ? 1.0 : (modelData.isPast ? 0.42 : 0.82)

                Rectangle {
                  visible: prayerRow.modelData.isNext
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(2)
                  height: parent.height * 0.55
                  radius: width
                  color: root.accent
                }

                Text {
                  id: rowIcon
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(18)
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  text: PrayerTimes.icon(prayerRow.modelData.key)
                  color: prayerRow.modelData.isNext ? root.accent : root.fg
                  opacity: prayerRow.rowOpacity
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.icon
                }

                Text {
                  id: rowName
                  anchors.left: rowIcon.right
                  anchors.leftMargin: Style.space(14)
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  text: prayerRow.modelData.label
                  color: root.fg
                  opacity: prayerRow.rowOpacity
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: prayerRow.modelData.isNext
                }

                Text {
                  anchors.left: rowName.right
                  anchors.leftMargin: Style.space(10)
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  text: prayerRow.modelData.labelAr
                  color: root.dim
                  opacity: prayerRow.rowOpacity
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }

                Text {
                  id: rowTime
                  anchors.right: rowBell.left
                  anchors.rightMargin: Style.space(10)
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  text: Model.formatTime(prayerRow.modelData.date, root.config.timeFormat)
                  color: prayerRow.modelData.isNext ? root.accent : root.fg
                  opacity: prayerRow.rowOpacity
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.subtitle
                  font.bold: true
                }

                // Sunrise is not prayed, so it gets no bell rather than a
                // disabled one — nothing to decide, nothing to show.
                PanelActionButton {
                  id: rowBell
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(12)
                  anchors.verticalCenter: parent.verticalCenter
                  visible: prayerRow.modelData.isPrayer
                  iconText: prayerRow.modelData.azan ? "" : ""
                  tooltipText: prayerRow.modelData.azan
                    ? "Adhan on for " + prayerRow.modelData.label
                    : "Adhan off for " + prayerRow.modelData.label
                  foreground: prayerRow.modelData.azan ? root.fg : root.dimmer
                  hoverColor: root.accent
                  fontSize: Style.font.bodySmall
                  onClicked: root.toggleAzan(prayerRow.modelData.key)
                }
              }
            }
          }

          PanelSeparator { foreground: root.fg; visible: root.day !== null }

          // ---- Derived times
          Column {
            width: parent.width
            visible: root.day !== null
            spacing: Style.space(6)

            PanelSectionHeader {
              x: Style.space(18)
              text: "ALSO TODAY"
              foreground: root.fg
              fontFamily: root.fontFamily
            }

            Grid {
              x: Style.space(18)
              width: parent.width - Style.space(36)
              columns: 2
              columnSpacing: Style.space(14)
              rowSpacing: Style.space(5)

              Repeater {
                model: root.day ? [
                  { label: "Duha",       key: "duha" },
                  { label: "Sunset",     key: "sunset" },
                  { label: "Midnight",   key: "midnight" },
                  { label: "Last third", key: "lastThird" }
                ] : []

                Item {
                  required property var modelData
                  width: Math.floor((todayColumn.width - Style.space(50)) / 2)
                  height: Style.space(20)

                  Text {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    textFormat: Text.PlainText
                    text: modelData.label
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }

                  Text {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    textFormat: Text.PlainText
                    text: root.day ? Model.formatTime(root.day.times[modelData.key], root.config.timeFormat) : ""
                    color: root.fg
                    opacity: 0.85
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    font.bold: true
                  }
                }
              }
            }
          }

          PanelSeparator { foreground: root.fg; visible: root.day !== null }

          // ---- Footer
          Item {
            width: parent.width
            height: footerRow.implicitHeight + Style.space(12)

            Column {
              id: footerRow
              anchors.left: parent.left
              anchors.leftMargin: Style.space(18)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Row {
                spacing: Style.space(6)

                Text {
                  textFormat: Text.PlainText
                  text: ""
                  color: root.dimmer
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  anchors.verticalCenter: parent.verticalCenter
                }

                Text {
                  textFormat: Text.PlainText
                  text: root.locationName === "" ? "No location" : root.locationName
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  anchors.verticalCenter: parent.verticalCenter
                }
              }

              Text {
                textFormat: Text.PlainText
                text: PrayerTimes.methodName(root.config.method) +
                      " · " + (root.config.madhab === "Hanafi" ? "Hanafi" : "Standard")
                color: root.dimmer
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                width: todayColumn.width - Style.space(150)
                elide: Text.ElideRight
              }
            }

            Row {
              anchors.right: parent.right
              anchors.rightMargin: Style.space(14)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(4)

              // Playback controls live in settings, next to the adhan options
              // they belong to. What stays here is the one thing that is about
              // this view rather than about configuration.
              PanelActionButton {
                iconText: "\uf013"
                tooltipText: "Settings"
                foreground: root.fg
                hoverColor: root.accent
                onClicked: root.view = "settings"
              }
            }
          }
        }
      }

      // ---- Settings ----------------------------------------------------
      Flickable {
        id: settingsScroll
        anchors.fill: parent
        contentWidth: width
        contentHeight: settingsColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height
        visible: opacity > 0
        opacity: root.view === "settings" ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 130; easing.type: Easing.OutQuad } }

        Column {
          id: settingsColumn
          width: settingsScroll.width
          spacing: Style.space(10)

          // ---- Header with a way back
          Item {
            width: parent.width
            height: Style.space(42)

            Text {
              anchors.left: parent.left
              anchors.leftMargin: Style.space(18)
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: "SETTINGS"
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.3
            }

            PanelActionButton {
              anchors.right: parent.right
              anchors.rightMargin: Style.space(12)
              anchors.verticalCenter: parent.verticalCenter
              iconText: ""
              tooltipText: "Back to today"
              foreground: root.fg
              hoverColor: root.accent
              onClicked: root.view = "today"
            }
          }

          PanelSeparator { foreground: root.fg }

          // ---- Location
          Column {
            x: Style.space(18)
            width: settingsColumn.width - Style.space(36)
            spacing: Style.space(7)

            PanelSectionHeader { text: "LOCATION"; foreground: root.fg; fontFamily: root.fontFamily }

            TextField {
              id: locationField
              width: parent.width
              placeholderText: "Search for a city…"
              text: root.locationQuery
              foreground: root.fg
              accent: root.accent
              font.family: root.fontFamily
              onTextChanged: root.locationQuery = text
              // Escape cancels the search and hands the keys back to the
              // panel, so a second Escape closes it as it does everywhere else.
              Keys.onEscapePressed: function(event) {
                root.cancelSearch()
                keyCatcher.forceActiveFocus()
                event.accepted = true
              }
            }

            Text {
              visible: root.locating
              textFormat: Text.PlainText
              text: "Searching…"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Column {
              width: parent.width
              spacing: 1

              Repeater {
                model: root.locationSuggestions

                CursorSurface {
                  id: suggestion
                  required property var modelData
                  width: parent.width
                  height: Style.space(28)
                  foreground: root.fg
                  accent: root.accent
                  hasCursor: suggestionHover.hovered
                  radius: Style.cornerRadius

                  HoverHandler { id: suggestionHover; cursorShape: Qt.PointingHandCursor }
                  TapHandler { onTapped: root.chooseLocation(suggestion.modelData) }

                  Text {
                    anchors.left: parent.left
                    anchors.leftMargin: Style.space(8)
                    anchors.right: parent.right
                    anchors.rightMargin: Style.space(8)
                    anchors.verticalCenter: parent.verticalCenter
                    textFormat: Text.PlainText
                    text: suggestion.modelData.label
                    color: root.fg
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    elide: Text.ElideRight
                  }
                }
              }
            }

            Row {
              spacing: Style.space(6)

              Button {
                text: "Use weather location"
                bordered: true
                fontSize: Style.font.caption
                foreground: root.fg
                accent: root.accent
                fontFamily: root.fontFamily
                enabled: root.hasWeatherLocation
                opacity: enabled ? 1 : 0.45
                selected: root.usingWeatherLocation
                onClicked: root.useWeatherLocation()
              }

              Button {
                text: "Detect"
                iconText: ""
                bordered: true
                fontSize: Style.font.caption
                foreground: root.fg
                accent: root.accent
                fontFamily: root.fontFamily
                enabled: !ipLookup.running
                opacity: enabled ? 1 : 0.45
                onClicked: root.detectLocation()
              }
            }

            Text {
              width: parent.width
              visible: root.locationNotice !== ""
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              text: root.locationNotice
              color: root.accent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Text {
              width: parent.width
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              text: root.locationCaption
              color: root.dimmer
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          PanelSeparator { foreground: root.fg }

          // ---- Calculation
          Column {
            x: Style.space(18)
            width: settingsColumn.width - Style.space(36)
            spacing: Style.space(8)

            PanelSectionHeader { text: "CALCULATION"; foreground: root.fg; fontFamily: root.fontFamily }

            SettingsDropdown {
              width: parent.width
              label: "Method"
              source: root.config.method
              foreground: root.fg
              accent: root.accent
              fontFamily: root.fontFamily
              options: {
                var keys = PrayerTimes.methodKeys()
                var out = []
                for (var i = 0; i < keys.length; i++) {
                  out.push({ value: keys[i], label: PrayerTimes.methodInfo(keys[i]).name })
                }
                return out
              }
              onChanged: function(v) { root.setValue("method", v) }
            }

            Text {
              width: parent.width
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              text: PrayerTimes.methodInfo(root.config.method).region
              color: root.dimmer
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            SettingsDropdown {
              width: parent.width
              label: "Asr (madhab)"
              source: root.config.madhab
              foreground: root.fg
              accent: root.accent
              fontFamily: root.fontFamily
              options: [
                { value: "Standard", label: "Standard — Shafi'i, Maliki, Hanbali" },
                { value: "Hanafi", label: "Hanafi" }
              ]
              onChanged: function(v) { root.setValue("madhab", v) }
            }

            SettingsDropdown {
              width: parent.width
              label: "High latitudes"
              source: root.config.highLats
              foreground: root.fg
              accent: root.accent
              fontFamily: root.fontFamily
              options: [
                { value: "AngleBased", label: "Angle based" },
                { value: "NightMiddle", label: "Middle of the night" },
                { value: "OneSeventh", label: "One seventh of the night" },
                { value: "None", label: "None" }
              ]
              onChanged: function(v) { root.setValue("highLats", v) }
            }

            Text {
              width: parent.width
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              text: "Only matters far from the equator, where the sun never dips far enough below the horizon for Fajr and Isha to have a true angle."
              color: root.dimmer
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          PanelSeparator { foreground: root.fg }

          // ---- Adhan
          Column {
            x: Style.space(18)
            width: settingsColumn.width - Style.space(36)
            spacing: Style.space(9)

            PanelSectionHeader { text: "ADHAN & REMINDERS"; foreground: root.fg; fontFamily: root.fontFamily }

            Item {
              width: parent.width
              height: Style.space(24)

              Text {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: "Desktop notification"
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }

              ToggleSwitch {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                checked: root.config.notify
                foreground: root.fg
                accent: root.accent
                onToggled: root.setValue("notify", !root.config.notify)
              }
            }

            Item {
              width: parent.width
              height: Style.space(24)

              Text {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: "Play the adhan"
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }

              ToggleSwitch {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                checked: root.config.audio.enabled
                foreground: root.fg
                accent: root.accent
                onToggled: root.setNested("audio", "enabled", !root.config.audio.enabled)
              }
            }

            // Test playback. Deliberately ignores the toggle above and the
            // per-prayer bells: pressed while the adhan is switched off, a
            // silent button cannot be told apart from a broken one.
            Row {
              width: parent.width
              spacing: Style.space(6)

              Button {
                text: root.adhanPlaying ? "Playing…" : "Play adhan"
                iconText: "\uf04b"
                bordered: true
                fontSize: Style.font.caption
                foreground: root.fg
                accent: root.accent
                fontFamily: root.fontFamily
                active: root.adhanPlaying
                onClicked: root.run("omarchy-shell salah test")
              }

              Button {
                text: "Stop"
                iconText: "\uf04d"
                bordered: true
                fontSize: Style.font.caption
                foreground: root.fg
                accent: root.accent
                fontFamily: root.fontFamily
                enabled: root.adhanPlaying
                // The kit's Button has no disabled look of its own.
                opacity: enabled ? 1 : 0.45
                onClicked: root.run("omarchy-shell salah stop")
              }
            }

            Column {
              width: parent.width
              spacing: Style.space(4)
              opacity: root.config.audio.enabled ? 1 : 0.45

              SettingsDropdown {
                width: parent.width
                label: "Voice"
                source: Model.adhanSelection(root.config)
                enabled: root.config.audio.enabled
                foreground: root.fg
                accent: root.accent
                fontFamily: root.fontFamily
                options: Adhans.options()
                onChanged: function(v) { root.setNested("audio", "adhan", v) }
              }

              Text {
                width: parent.width
                textFormat: Text.PlainText
                wrapMode: Text.WordWrap
                text: root.voiceCaption
                color: root.voiceStatus === "failed" ? root.accent : root.dimmer
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Button {
                visible: root.voiceStatus === "failed"
                text: "Try the download again"
                iconText: "\uf021"
                bordered: true
                fontSize: Style.font.caption
                foreground: root.fg
                accent: root.accent
                fontFamily: root.fontFamily
                onClicked: root.run("omarchy-shell salah fetch")
              }

              Row {
                width: parent.width
                spacing: Style.space(8)

                Text {
                  width: Style.space(60)
                  textFormat: Text.PlainText
                  text: "Volume"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  anchors.verticalCenter: parent.verticalCenter
                }

                PanelSlider {
                  width: parent.width - Style.space(110)
                  anchors.verticalCenter: parent.verticalCenter
                  bar: root.bar
                  minimum: 0
                  maximum: 130
                  step: 5
                  integer: true
                  value: root.config.audio.volume
                  enabled: root.config.audio.enabled
                  onReleased: function(v) { root.setNested("audio", "volume", Math.round(v)) }
                }

                // Zero is a second, invisible mute hiding behind the toggle
                // above: the adhan still "plays", just inaudibly, and a missed
                // prayer looks like a broken plugin. Naming the state is
                // cheaper than forbidding it.
                Text {
                  width: Style.space(44)
                  horizontalAlignment: Text.AlignRight
                  textFormat: Text.PlainText
                  text: root.volumeMuted ? "muted" : (Math.round(root.config.audio.volume) + "%")
                  color: root.volumeMuted ? root.accent : root.fg
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.bold: root.volumeMuted
                  anchors.verticalCenter: parent.verticalCenter
                }
              }

              Text {
                width: parent.width
                visible: root.volumeMuted && root.config.audio.enabled
                textFormat: Text.PlainText
                wrapMode: Text.WordWrap
                text: "At zero the adhan still runs, just silently. Raise the volume, or switch it off above if that is what you meant."
                color: root.accent
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              TextField {
                id: audioPathField
                width: parent.width
                visible: root.voice.id === "custom"
                placeholderText: "Custom adhan file — leave empty for the bundled one"
                text: root.config.audio.path
                enabled: root.config.audio.enabled
                foreground: root.fg
                accent: root.accent
                font.family: root.fontFamily
                onEditingFinished: if (text !== root.config.audio.path) root.setNested("audio", "path", text)
                // Escape puts the saved path back and hands the keys to the
                // panel, so a second Escape leaves settings as usual.
                Keys.onEscapePressed: function(event) {
                  text = Qt.binding(function() { return root.config.audio.path })
                  keyCatcher.forceActiveFocus()
                  event.accepted = true
                }
              }
            }

            Row {
              width: parent.width
              spacing: Style.space(8)

              Text {
                width: Style.space(60)
                textFormat: Text.PlainText
                text: "Remind"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                anchors.verticalCenter: parent.verticalCenter
              }

              PanelSlider {
                width: parent.width - Style.space(140)
                anchors.verticalCenter: parent.verticalCenter
                bar: root.bar
                minimum: 0
                maximum: 45
                step: 5
                integer: true
                value: root.config.reminderMinutes
                onReleased: function(v) { root.setValue("reminderMinutes", Math.round(v)) }
              }

              Text {
                width: Style.space(64)
                horizontalAlignment: Text.AlignRight
                textFormat: Text.PlainText
                text: root.config.reminderMinutes > 0
                  ? (Math.round(root.config.reminderMinutes) + " min before") : "off"
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                anchors.verticalCenter: parent.verticalCenter
              }
            }
          }

          PanelSeparator { foreground: root.fg }

          // ---- Display
          Column {
            x: Style.space(18)
            width: settingsColumn.width - Style.space(36)
            spacing: Style.space(8)

            PanelSectionHeader { text: "DISPLAY"; foreground: root.fg; fontFamily: root.fontFamily }

            SettingsDropdown {
              width: parent.width
              label: "Clock"
              source: root.config.timeFormat
              foreground: root.fg
              accent: root.accent
              fontFamily: root.fontFamily
              options: [
                { value: "24h", label: "24 hour" },
                { value: "12h", label: "12 hour" }
              ]
              onChanged: function(v) { root.setValue("timeFormat", v) }
            }

            SettingsDropdown {
              width: parent.width
              label: "Bar shows"
              source: root.config.barMode
              foreground: root.fg
              accent: root.accent
              fontFamily: root.fontFamily
              options: [
                { value: "countdown", label: "Name and countdown" },
                { value: "time", label: "Name and time" },
                { value: "both", label: "Name, time and countdown" }
              ]
              onChanged: function(v) { root.setValue("barMode", v) }
            }

            Item {
              width: parent.width
              height: Style.space(24)

              Text {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: "Count seconds"
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }

              ToggleSwitch {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                checked: root.config.showSeconds
                foreground: root.fg
                accent: root.accent
                onToggled: root.setValue("showSeconds", !root.config.showSeconds)
              }
            }
          }

          PanelSeparator { foreground: root.fg }

          // ---- Calendar
          Column {
            x: Style.space(18)
            width: settingsColumn.width - Style.space(36)
            spacing: Style.space(8)

            PanelSectionHeader { text: "HIJRI CALENDAR"; foreground: root.fg; fontFamily: root.fontFamily }

            Item {
              width: parent.width
              height: Style.space(24)

              Text {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: "Correct against Umm al-Qura"
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }

              ToggleSwitch {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                checked: root.config.hijriSync
                foreground: root.fg
                accent: root.accent
                // Off means off: the learned correction goes too, so the shift
                // shown below is the whole shift.
                onToggled: root.patch(function(c) {
                  c.hijriSync = !c.hijriSync
                  if (!c.hijriSync) c.hijriAutoOffset = 0
                })
              }
            }

            Row {
              width: parent.width
              spacing: Style.space(8)

              Text {
                textFormat: Text.PlainText
                text: "Shift by"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                anchors.verticalCenter: parent.verticalCenter
              }

              PanelActionButton {
                iconText: ""
                foreground: root.fg
                hoverColor: root.accent
                fontSize: Style.font.caption
                enabled: root.config.hijriOffset > -2
                onClicked: root.setValue("hijriOffset", Model.clamp(root.config.hijriOffset - 1, -2, 2))
              }

              Text {
                width: Style.space(50)
                horizontalAlignment: Text.AlignHCenter
                textFormat: Text.PlainText
                text: (root.config.hijriOffset > 0 ? "+" : "") + root.config.hijriOffset + " day"
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.bold: true
                anchors.verticalCenter: parent.verticalCenter
              }

              PanelActionButton {
                iconText: ""
                foreground: root.fg
                hoverColor: root.accent
                fontSize: Style.font.caption
                enabled: root.config.hijriOffset < 2
                onClicked: root.setValue("hijriOffset", Model.clamp(root.config.hijriOffset + 1, -2, 2))
              }
            }

            Text {
              width: parent.width
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              text: "Months begin on a local sighting, so mosques in one city can differ by a day. This shifts the displayed date without touching prayer times."
              color: root.dimmer
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          PanelSeparator { foreground: root.fg }

          // ---- Per-prayer correction
          Column {
            x: Style.space(18)
            width: settingsColumn.width - Style.space(36)
            spacing: Style.space(5)
            bottomPadding: Style.space(16)

            PanelSectionHeader { text: "FINE TUNING"; foreground: root.fg; fontFamily: root.fontFamily }

            Text {
              width: parent.width
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              text: "Nudge an individual prayer to match your mosque's timetable."
              color: root.dimmer
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              bottomPadding: Style.space(4)
            }

            Repeater {
              model: PrayerTimes.PRAYER_NAMES

              Item {
                id: tuneRow
                required property string modelData
                readonly property int offset: Number(root.config.tune[modelData]) || 0

                width: settingsColumn.width - Style.space(36)
                height: Style.space(26)

                Text {
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  text: Model.prayerLabel(tuneRow.modelData)
                  color: root.fg
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }

                Row {
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(6)

                  PanelActionButton {
                    iconText: ""
                    foreground: root.fg
                    hoverColor: root.accent
                    fontSize: Style.font.caption
                    enabled: tuneRow.offset > -60
                    onClicked: root.setNested("tune", tuneRow.modelData, tuneRow.offset - 1)
                  }

                  Text {
                    width: Style.space(52)
                    horizontalAlignment: Text.AlignHCenter
                    anchors.verticalCenter: parent.verticalCenter
                    textFormat: Text.PlainText
                    text: (tuneRow.offset > 0 ? "+" : "") + tuneRow.offset + " min"
                    color: tuneRow.offset === 0 ? root.dimmer : root.accent
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }

                  PanelActionButton {
                    iconText: ""
                    foreground: root.fg
                    hoverColor: root.accent
                    fontSize: Style.font.caption
                    enabled: tuneRow.offset < 60
                    onClicked: root.setNested("tune", tuneRow.modelData, tuneRow.offset + 1)
                  }
                }
              }
            }
          }
        }
      }
    }
  }

  Component.onCompleted: {
    dirs.running = true
    configFile.reload()
    weatherFile.reload()
  }
}
