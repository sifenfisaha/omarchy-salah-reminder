import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "PrayerTimes.js" as PrayerTimes
import "Model.js" as Model

// The pill in the bar: which prayer is next, and how long is left.
//
// It reads the same config file the service does and computes times itself
// rather than asking the service for them. The astronomy is a few dozen float
// operations, so recomputing every tick is cheaper than any cross-component
// plumbing would be — and the bar still draws correctly if the service is
// disabled or has not mounted yet.
BarWidget {
  id: root
  moduleName: "sallah.reminder"

  readonly property string home: Quickshell.env("HOME")

  property var config: Model.defaults()
  property var weatherLocation: ({ name: "", latitude: null, longitude: null })
  property var day: null

  readonly property var location: Model.effectiveLocation(config, weatherLocation, null)
  readonly property string countdown: day ? Model.formatCountdown(day.remainingMs, config.showSeconds) : ""
  readonly property string prayerName: (day && day.next) ? Model.prayerLabel(day.next.key) : ""
  readonly property string prayerIcon: (day && day.next) ? PrayerTimes.icon(day.next.key) : PrayerTimes.mosqueIcon()

  readonly property string displayText: day ? Model.barText(day, config) : ""

  // Warn as the moment approaches, so the bar is glanceable without opening
  // anything. The threshold is the user's own reminder window, which keeps the
  // colour change and the notification telling the same story.
  readonly property int warnSeconds: Math.max(60, (Number(config.reminderMinutes) || 10) * 60)
  readonly property bool imminent: day !== null && day.next !== null && day.remainingMs <= warnSeconds * 1000

  // Vertical bars are one icon wide, so the label becomes a stack: the mark,
  // then the minutes left. Seconds are dropped — they will not fit.
  readonly property var verticalLines: root.location === null
    ? [PrayerTimes.mosqueIcon()]
    : [prayerIcon, day ? Model.formatCountdown(day.remainingMs, false).replace(/\s+/g, "") : ""]

  function refresh() {
    configFile.reload()
    weatherFile.reload()
    recompute()
  }

  function recompute() {
    root.day = Model.buildDay(new Date(), root.config, root.location)
  }

  onConfigChanged: recompute()
  onLocationChanged: recompute()

  FileView {
    id: configFile
    path: root.home + Model.CONFIG_PATH
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.config = Model.parseConfig(text())
    onLoadFailed: root.config = Model.defaults()
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

  // One second while a seconds-precision countdown is on screen, otherwise five
  // — there is nothing to redraw between minute boundaries.
  Timer {
    interval: root.config.showSeconds ? 1000 : 5000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.recompute()
  }

  // ---- Panel wiring. The bar tracks the widget in the slot, not the panel
  //      nested inside it, so open/close/opened live here and forward inward.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function open() {
    if (panelLoader.item && panelLoader.item.openFromHotkey) panelLoader.item.openFromHotkey()
  }

  function close() {
    if (panelLoader.item && panelLoader.item.close) panelLoader.item.close()
  }

  function togglePanel() {
    if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle()
  }

  function openSettings() {
    if (!panelLoader.item) return
    panelLoader.item.view = "settings"
    if (!root.opened) panelLoader.item.openFromHotkey()
  }

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  // The pill paints a label rather than a centred icon, so the bar's
  // open-panel dot should span the label, matching the clock.
  readonly property real openPanelIndicatorWidth: button.labelWidth
  readonly property real openPanelIndicatorHeight: Math.max(Style.space(10), Math.round(Style.bar.iconSlot * 0.55))

  visible: true
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  IpcHandler {
    target: "sallah.reminder"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.togglePanel() }
    function refresh(): void { root.broadcast("refresh") }
    function settings(): void { root.openSettings() }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // With no location there is nothing to count down to, so the pill falls
    // back to the plugin's mark — an invisible zero-width slot would leave a
    // first-run user nothing to click.
    text: root.vertical ? "" : (root.location === null ? PrayerTimes.mosqueIcon() : root.displayText)
    labelVisible: !root.vertical
    hasVisualContent: root.vertical ? root.verticalLines[0] !== "" : text !== ""
    fixedHeight: root.vertical ? root.verticalLines.length * Style.bar.iconSlot : -1
    horizontalMargin: 8.75
    verticalPadding: 8.75

    // WidgetButton already owns the urgent tint; flagging the button is all it
    // takes, instead of painting a second label on top to recolour it.
    active: root.imminent
    tooltipText: root.location === null
      ? "Sallah — no location set yet, click to choose one"
      : ""

    onPressed: function(b) {
      if (!root.bar) return
      if (b === Qt.RightButton) root.bar.run("omarchy-shell sallah stop")
      else if (b === Qt.MiddleButton) root.refresh()
      else root.togglePanel()
    }

    // A slow pulse in the final minutes. Tied to the label rather than the
    // whole button so the hover fill underneath stays steady.
    SequentialAnimation on opacity {
      running: root.imminent && !root.opened
      loops: Animation.Infinite
      alwaysRunToEnd: true
      NumberAnimation { from: 1.0; to: 0.5; duration: 1300; easing.type: Easing.InOutQuad }
      NumberAnimation { from: 0.5; to: 1.0; duration: 1300; easing.type: Easing.InOutQuad }
    }

    Column {
      visible: root.vertical
      anchors.fill: parent

      Repeater {
        model: root.verticalLines

        OpticalGlyph {
          required property string modelData
          width: button.width
          height: Style.bar.iconSlot
          text: modelData
          fontFamily: button.fontFamily
          fontSize: modelData.length > 3 ? button.fontSize * 0.85 : button.fontSize
          color: button.active && button.useActiveColor ? button.activeColor : button.foreground
        }
      }
    }
  }
}
