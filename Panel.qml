import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Ulanzi Vibekey: a bar icon plus a popup control panel drawn as the keypad
// itself, with each control's assignment beside it.
//
// The panel owns the driver: while this widget is in the bar, bin/vibekeyd runs
// as a child process, holds the dongle open, grabs its keystrokes and runs the
// action assigned to each control. The daemon publishes what it sees to
// $XDG_RUNTIME_DIR/vibekey/state.json; assignments live in
// ~/.config/omarchy/vibekey/config.json and are written through
// bin/vibekey-config so the file is never half-written. While the popup is
// open it heartbeats $XDG_RUNTIME_DIR/vibekey/preview, and the daemon only
// reports controls instead of running their actions.
Panel {
  id: root
  moduleName: "jimmibram.vibekey"
  ipcTarget: "jimmibram.vibekey"
  manageIpc: false

  readonly property string pluginDir: decodeURIComponent(String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "")).replace(/\/$/, "")
  readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") || "/tmp"
  readonly property string configHome: Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")
  readonly property string statePath: runtimeDir + "/vibekey/state.json"
  readonly property string previewPath: runtimeDir + "/vibekey/preview"
  readonly property string configPath: configHome + "/omarchy/vibekey/config.json"
  readonly property string seenPath: configHome + "/omarchy/vibekey/seen.json"

  readonly property color foreground: bar ? bar.barForeground : Color.foreground
  readonly property color accent: Color.accent
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color muted: Qt.darker(foreground, 1.4)
  readonly property color faint: Qt.darker(foreground, 1.9)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  property var state: ({})
  property var config: ({})
  property var seen: ({})
  property var presets: []
  property var knobPresets: []

  readonly property bool daemonRunning: daemon.running
  readonly property bool connected: state.connected === true
  readonly property bool accessDenied: state.access === "denied"
  readonly property var assigned: Model.buttons(config)
  readonly property var rows: Model.controls(config, seen, presets)
  readonly property var editorOptions: Model.editorOptions(presets)
  readonly property var knobTurnOptions: Model.knobTurnOptions(knobPresets)
  readonly property string knobTurnMode: Model.knobTurnMode(config, knobPresets)
  readonly property string statusText: Model.statusText(state, daemonRunning)

  // Controls in the order the drawing shows them, top to bottom. The knob
  // turn is one setting that covers both directions.
  readonly property var slotOrder: ["knob_turn", "knob", "key1", "key2", "key3"]
  readonly property var slotTitles: ({
    knob_turn: "Turn knob", knob: "Press knob",
    key1: "Voice key", key2: "Confirm key", key3: "Cancel key"
  })
  readonly property var slotHints: ({
    knob_turn: "Either direction, one notch at a time", knob: "Push the knob",
    key1: "Top key with the microphone", key2: "The ✓ key", key3: "The ✕ key"
  })

  function isKnobTurn(key) { return key === "knob_turn" || key === "knob_right" || key === "knob_left" }
  function isAssigned(key) {
    if (key === "knob_turn") return !!(root.assigned.knob_right || root.assigned.knob_left)
    return !!root.assigned[key]
  }
  function summaryFor(key) {
    if (key === "knob_turn") return Model.knobTurnSummary(root.config, root.knobPresets, root.presets)
    return Model.summary(root.assigned[key], root.presets)
  }
  function titleFor(key) {
    if (root.slotTitles[key]) return root.slotTitles[key]
    for (var i = 0; i < root.rows.length; i++) if (root.rows[i].key === key) return root.rows[i].label
    return key
  }
  function hintFor(key) {
    if (root.slotHints[key]) return root.slotHints[key]
    for (var i = 0; i < root.rows.length; i++) if (root.rows[i].key === key) return root.rows[i].hint
    return key
  }

  // The control whose editor is open, and the one the device just sent.
  property string editing: ""
  property string flashing: ""
  property string learned: ""   // "<slot> now answers to <label>", shown in the editor
  property real lastEventAt: 0
  property int lastEvents: -1
  // The drawn knob follows the daemon's running notch count, so a burst of
  // turns that outruns the file watch still lands on the right angle.
  readonly property real knobAngle: Number(state.knob_position || 0) * knobStep
  readonly property real knobStep: 18
  property bool installingAccess: false
  property string saveError: ""

  // Keyboard cursor over the controls (j/k, Enter opens the editor).
  property bool cursorActive: false
  property int cursorIndex: 0
  readonly property var cursorKeys: slotOrder

  // ------------------------------------------------------------ simulator

  // The fake herdr window reacts to what the keypad does: the knob scrolls
  // its scribbled text, keys show their action in its status line.
  property string simControl: ""
  property string simStatus: ""
  property int simAgent: 1
  readonly property int simAgents: 5
  readonly property int knobPosition: Number(state.knob_position || 0)

  // The window's back: a game of boxes, driven by the real keypad.
  property bool gameOn: false

  function simulate(key) {
    if (root.gameOn) {
      if (key === "knob") game.reset()
      else if (key === "key1" || key === "key2" || key === "key3") game.fire(key)
      return
    }
    if (key === "knob_right" || key === "knob_left") return  // the scroll itself shows
    root.simControl = key
    root.simStatus = root.summaryFor(key)
    var entry = root.assigned[key]
    var preset = entry ? String(entry.preset || "") : ""
    if (preset === "herdr_next") root.simAgent = (root.simAgent + 1) % root.simAgents
    else if (preset === "herdr_prev") root.simAgent = (root.simAgent + root.simAgents - 1) % root.simAgents
    simTimer.restart()
  }

  Timer {
    id: simTimer
    interval: 1400
    onTriggered: { root.simControl = ""; root.simStatus = "" }
  }

  // ------------------------------------------------------------ data files

  function applyState(text) {
    var next = Model.parseJson(text, null)
    if (!next) return
    root.state = next
    var events = Number(next.events || 0)
    var last = next.last
    if (last && Number(last.at) > root.lastEventAt) {
      if (root.lastEventAt > 0) {
        var slot = String(last.slot || "")
        // Learning: with a key's editor open, whatever the keypad sends (a turn
        // excepted) becomes that key, factory code or not.
        var learnable = ["key1", "key2", "key3", "knob"].indexOf(root.editing) !== -1
        var turning = /^(wheel|pan):/.test(String(last.id || ""))
        if (root.opened && learnable && last.id && !turning && slot !== root.editing) {
          root.runConfig(["alias", String(last.id), root.editing])
          root.learned = root.titleFor(root.editing) + " now answers to " + String(last.label || last.id)
          slot = root.editing
        }
        root.flashing = slot || String(last.id || "")
        flashTimer.restart()
        root.simulate(slot || String(last.id || ""))
      }
      root.lastEventAt = Number(last.at)
    }
    root.lastEvents = events
  }

  function refreshFiles() {
    stateFile.reload()
    configFile.reload()
    seenFile.reload()
  }

  FileView {
    id: stateFile
    path: root.statePath
    watchChanges: true
    printErrors: false
    onLoaded: root.applyState(text())
    onFileChanged: reload()
  }

  FileView {
    id: configFile
    path: root.configPath
    watchChanges: true
    printErrors: false
    onLoaded: root.config = Model.parseJson(text(), {})
    onFileChanged: reload()
  }

  FileView {
    id: seenFile
    path: root.seenPath
    watchChanges: true
    printErrors: false
    onLoaded: root.seen = Model.parseJson(text(), {})
    onFileChanged: reload()
  }

  FileView {
    id: presetsFile
    path: root.pluginDir + "/actions.json"
    printErrors: false
    onLoaded: {
      var parsed = Model.parseJson(text(), {})
      root.presets = Array.isArray(parsed.presets) ? parsed.presets : []
      root.knobPresets = Array.isArray(parsed.knob_turn) ? parsed.knob_turn : []
    }
  }

  // Files replaced by rename slip past a path watch, and state.json may not
  // exist yet when the widget loads; a slow poll covers both.
  Timer {
    interval: root.opened ? 1000 : 5000
    running: true
    repeat: true
    onTriggered: root.refreshFiles()
  }

  Timer {
    id: flashTimer
    interval: 1200
    onTriggered: root.flashing = ""
  }

  // ------------------------------------------------------------ preview mode

  // While the panel is open the daemon must only report controls, not run
  // them. It trusts the heartbeat for six seconds, so a crashed shell never
  // leaves the keypad dead.
  function writePreview(value) {
    Quickshell.execDetached(["bash", "-c",
      "mkdir -p " + Util.shellQuote(root.runtimeDir + "/vibekey") + " && printf '%s' " + Util.shellQuote(value) + " > " + Util.shellQuote(root.previewPath)])
  }

  Timer {
    interval: 2000
    running: root.opened
    repeat: true
    triggeredOnStart: true
    onTriggered: root.writePreview("open")
  }

  // ------------------------------------------------------------ the driver

  Process {
    id: daemon
    command: ["python3", root.pluginDir + "/bin/vibekeyd"]
    running: true
    stderr: SplitParser {
      onRead: function(line) { if (line) console.log("[vibekey] " + line) }
    }
    onExited: function(code) {
      console.log("[vibekey] driver exited with " + code)
      restartTimer.start()
    }
  }

  Timer {
    id: restartTimer
    interval: 2000
    onTriggered: if (!daemon.running) daemon.running = true
  }

  // ------------------------------------------------------------ writes

  property var pendingWrites: []

  function runConfig(args) {
    if (configProc.running) {
      pendingWrites.push(args)
      return
    }
    configProc.command = ["python3", root.pluginDir + "/bin/vibekey-config"].concat(args)
    configProc.running = true
  }

  Process {
    id: configProc
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (String(text || "").trim() !== "") root.saveError = String(text).trim()
    }
    onExited: function(code) {
      if (code === 0) root.saveError = ""
      configFile.reload()
      if (root.pendingWrites.length > 0) {
        var next = root.pendingWrites.shift()
        root.pendingWrites = root.pendingWrites
        root.runConfig(next)
      }
    }
  }

  function saveButton(key, entry) {
    // Optimistic: redraw now, the file write comes back through configFile.
    var next = Model.isObject(root.config) ? JSON.parse(JSON.stringify(root.config)) : {}
    if (!Model.isObject(next.buttons)) next.buttons = {}
    if (entry) next.buttons[key] = entry
    else delete next.buttons[key]
    root.config = next
    root.runConfig(["set-button", key, JSON.stringify(entry)])
  }

  function saveKnobTurn(mode) {
    var pair = mode === "none" ? { right: null, left: null } : Model.entriesForKnobPreset(Model.presetById(root.knobPresets, mode))
    if (!pair) return
    root.saveButton("knob_right", pair.right)
    root.saveButton("knob_left", pair.left)
  }

  function choosePreset(key, id) {
    root.saveButton(key, Model.entryForPreset(Model.presetById(root.presets, id)))
  }

  readonly property string editorMode: root.editing === "" || root.editing === "knob_turn"
    ? "none"
    : Model.editorMode(root.assigned[root.editing], root.presets)
  // A text field in the picker has the keyboard: the panel's own keys stand back.
  property bool editorTyping: false

  function installAccess() {
    if (accessProc.running) return
    root.installingAccess = true
    accessProc.running = true
  }

  Process {
    id: accessProc
    command: ["bash", root.pluginDir + "/bin/vibekey-install-access"]
    onExited: function(code) {
      root.installingAccess = false
      if (code !== 0) root.saveError = "Could not install the device rule (exit " + code + ")"
      // The daemon retries on its own.
    }
  }

  // ------------------------------------------------------------ cursor

  function moveCursor(delta) {
    if (root.cursorKeys.length === 0) return
    cursorIndex = Math.max(0, Math.min(root.cursorKeys.length - 1, cursorIndex + delta))
  }

  function toggleEditor(key) {
    root.learned = ""
    root.editing = root.editing === key ? "" : key
    if (root.editing === "") Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    var at = root.cursorKeys.indexOf(key)
    if (at >= 0) root.cursorIndex = at
  }

  function activateCursor() {
    if (cursorIndex < 0 || cursorIndex >= root.cursorKeys.length) return
    toggleEditor(root.cursorKeys[cursorIndex])
  }

  onOpenedChanged: {
    if (opened) {
      root.refreshFiles()
      root.cursorActive = false
      root.cursorIndex = 0
      Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    } else {
      root.editing = ""
      root.gameOn = false
      root.writePreview("closed")
    }
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refreshFiles(); return "ok" }
    function restartDriver(): string { daemon.running = false; restartTimer.start(); return "ok" }
    function edit(key: string): string { root.open(); root.toggleEditor(String(key || "")); return root.editing }
    function flash(): void { root.flash() }
  }

  // ------------------------------------------------------------ flash

  // A brief Vibekey icon where Omarchy's OSD sits: feedback for an action a
  // control just ran, without words.
  property bool flashShown: false

  function flash() {
    root.flashShown = true
    flashHideTimer.restart()
  }

  Timer {
    id: flashHideTimer
    interval: 650
    onTriggered: root.flashShown = false
  }

  PanelWindow {
    visible: root.flashShown
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "vibekey-flash"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    mask: Region {}

    BorderSurface {
      id: flashCard
      readonly property real pad: Style.space(14)
      width: flashCard.borderLeft + pad + flashIcon.width + pad + flashCard.borderRight
      height: flashCard.borderTop + pad + flashIcon.height + pad + flashCard.borderBottom
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.bottom: parent.bottom
      anchors.bottomMargin: Style.space(67)
      color: Util.alpha(Color.background, 0.97)
      borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))
      radius: Style.cornerRadius

      VibekeyIcon {
        id: flashIcon
        anchors.centerIn: parent
        iconSize: Style.font.displayLarge
        color: Color.foreground
      }
    }
  }

  // ------------------------------------------------------------ bar button

  visible: true
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    iconComponent: Component {
      Item {
        VibekeyIcon {
          anchors.centerIn: parent
          iconSize: Style.bar.iconCanvas
          color: button.active ? button.activeColor : button.foreground
          background: root.bar ? root.bar.background : Color.bar.background
        }
      }
    }
    active: root.accessDenied
    activeColor: root.urgent
    opacity: root.connected || root.accessDenied ? 1 : 0.55
    tooltipText: Model.tooltip(root.state, root.daemonRunning, root.rows)
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.refreshFiles()
      else root.toggle()
    }
  }

  // ------------------------------------------------------------ pieces

  // A control's name and assignment, beside its spot on the drawing.
  component ControlLabel: CursorSurface {
    id: label
    required property string controlKey
    property bool compact: false
    readonly property bool editingThis: root.editing === controlKey
    readonly property bool flashingThis: root.flashing === controlKey
      || (controlKey === "knob_turn" && (root.flashing === "knob_right" || root.flashing === "knob_left"))
    readonly property bool assignedThis: root.isAssigned(controlKey)

    height: compact ? Style.space(30) : Style.space(40)
    hasCursor: root.cursorActive && root.cursorKeys[root.cursorIndex] === controlKey
    current: editingThis
    foreground: flashingThis ? root.accent : root.foreground
    accent: root.accent
    outline: flashingThis

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onContainsMouseChanged: if (containsMouse) { root.cursorActive = true; root.cursorIndex = root.cursorKeys.indexOf(label.controlKey) }
      onClicked: root.toggleEditor(label.controlKey)
    }

    Column {
      anchors.verticalCenter: parent.verticalCenter
      anchors.left: parent.left
      anchors.leftMargin: Style.space(8)
      anchors.right: parent.right
      anchors.rightMargin: Style.space(8)
      spacing: Style.space(1)

      Text {
        width: parent.width
        textFormat: Text.PlainText
        text: root.titleFor(label.controlKey).toUpperCase()
        color: label.flashingThis ? root.accent : (label.editingThis ? root.foreground : root.muted)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        font.letterSpacing: 1
        elide: Text.ElideRight
      }

      Text {
        width: parent.width
        textFormat: Text.PlainText
        text: root.summaryFor(label.controlKey)
        color: label.assignedThis ? root.foreground : root.faint
        font.family: root.fontFamily
        font.pixelSize: label.compact ? Style.font.caption : Style.font.body
        font.italic: !label.assignedThis
        elide: Text.ElideRight
      }
    }
  }

  // A round key on the drawing.
  component KeyCap: Rectangle {
    id: cap
    required property string controlKey
    property string icon: ""
    readonly property bool lit: root.flashing === controlKey
    readonly property bool editingThis: root.editing === controlKey
    width: Style.space(40)
    height: width
    radius: width / 2
    color: lit ? root.accent : Qt.alpha(root.foreground, editingThis ? 0.22 : 0.12)
    border.width: Math.max(1, Style.space(1))
    border.color: editingThis || lit ? root.accent : Qt.alpha(root.foreground, 0.35)
    Behavior on color { ColorAnimation { duration: 120 } }

    Text {
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: cap.icon
      color: cap.lit ? Color.popups.background : root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.icon
    }

    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: root.toggleEditor(cap.controlKey)
    }
  }

  // ------------------------------------------------------------ pieces (picker)

  // One choice in the picker: a tile that lights when it is the assignment.
  component Tile: CursorSurface {
    id: tile
    required property string tileId
    required property string label
    property string description: ""
    property bool selected: false
    signal picked(string id)
    height: Style.space(46)
    current: selected
    hasCursor: tileMouse.containsMouse
    foreground: root.foreground
    accent: root.accent
    outline: selected

    // Opening the editor for a control whose preset sits far down the
    // list: bring that tile into view.
    onSelectedChanged: if (selected) picker.reveal(tile)
    Component.onCompleted: if (selected) picker.reveal(tile)

    // A faint resting outline so the tiles read as buttons, not loose text.
    // Hover and selection paint their own border, so this one steps aside.
    Rectangle {
      anchors.fill: parent
      radius: tile.radius
      color: "transparent"
      border.width: Style.hairline
      border.color: Qt.alpha(root.foreground, 0.16)
      visible: !tile.hasCursor && !tile.selected
    }

    Text {
      anchors.fill: parent
      anchors.margins: Style.space(6)
      textFormat: Text.PlainText
      text: tile.label
      color: tile.selected ? root.accent : root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: tile.selected
      horizontalAlignment: Text.AlignHCenter
      verticalAlignment: Text.AlignVCenter
      wrapMode: Text.WordWrap
      elide: Text.ElideRight
      maximumLineCount: 2
    }

    MouseArea {
      id: tileMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: tile.picked(tile.tileId)
    }
  }

  // A line of fake text: a rounded bar whose width looks like a sentence.
  component Scribble: Rectangle {
    property int seed: 0
    property real maxWidth: 100
    property bool prompt: false
    height: Style.space(5)
    radius: height / 2
    width: Math.round(maxWidth * (0.25 + 0.7 * Model.noise(seed)))
    color: Qt.alpha(root.foreground, prompt ? 0.5 : 0.28)
  }

  // ------------------------------------------------------------ popup

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(790))
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight, Style.space(640))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.editorTyping
      onCloseRequested: {
        if (root.editing !== "") root.toggleEditor(root.editing)
        else root.close()
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dy !== 0) root.moveCursor(dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()

      Column {
        id: panelColumn
        width: parent.width
        spacing: Style.space(10)

        // ---------- Hero ----------
        PanelHero {
          width: parent.width
          title: "Vibekey"
          meta: root.statusText
          foreground: root.foreground
          fontFamily: root.fontFamily
          iconOpacity: root.connected ? 1 : 0.5

          iconComponent: Component {
            VibekeyIcon {
              iconSize: Style.font.display
              color: root.foreground
              background: Color.popups.background
            }
          }

          trailingControl: Component {
            Text {
              visible: text !== ""
              text: Model.batteryGlyph(root.state ? root.state.battery : null)
              color: root.state && root.state.battery && Number(root.state.battery.percent) <= 15 && root.state.battery.charging !== true ? root.urgent : root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.iconLarge
            }
          }
        }

        PanelSeparator { foreground: root.foreground }

        // ---------- Access / driver problems ----------
        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: root.accessDenied || !root.daemonRunning || root.saveError !== ""

          Text {
            width: parent.width
            visible: root.accessDenied
            textFormat: Text.PlainText
            text: "Linux only lets root read the Vibekey until a udev rule gives your login access. Installing it asks for your password once; no replug needed."
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Button {
            visible: root.accessDenied
            text: root.installingAccess ? "Waiting for password…" : "Grant device access"
            iconText: "󰌾"  // nf-md-lock_open_variant
            enabled: !root.installingAccess
            bordered: true
            foreground: root.foreground
            accent: root.accent
            fontFamily: root.fontFamily
            onClicked: root.installAccess()
          }

          Text {
            width: parent.width
            visible: !root.daemonRunning
            textFormat: Text.PlainText
            text: "The driver is not running. It restarts by itself; check the shell log if this persists."
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Text {
            width: parent.width
            visible: root.saveError !== ""
            textFormat: Text.PlainText
            text: root.saveError
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }
        }

        // ---------- Body: simulator or picker on the left, the keypad on the right ----------
        Row {
          id: body
          width: parent.width
          spacing: Style.space(18)

          Item {
            id: leftPane
            width: Style.space(350)
            height: device.implicitHeight

            // ----- The fake herdr window, with a game on its back -----
            // A click on the window flips it over: the knob drives a paddle,
            // the three keys fire balls carrying their own symbols, and the
            // boxes along the top are there to be broken.
            Flipable {
              id: flip
              anchors.fill: parent
              visible: root.editing === ""

              transform: Rotation {
                origin.x: flip.width / 2
                origin.y: flip.height / 2
                axis { x: 0; y: 1; z: 0 }
                angle: root.gameOn ? 180 : 0
                Behavior on angle { NumberAnimation { duration: 450; easing.type: Easing.InOutQuad } }
              }

              front: Rectangle {
                id: sim
                anchors.fill: parent
                radius: Style.space(10)
                color: Qt.alpha(root.foreground, 0.05)
                border.width: Math.max(1, Style.space(1))
                border.color: Qt.alpha(root.foreground, 0.22)
                clip: true

                readonly property real pad: Style.space(10)
                readonly property real lineStep: Style.space(11)

                // Title bar: window dots, a scribbled title, a recording light.
                Item {
                  id: simTitle
                  x: sim.pad
                  y: 0
                  width: parent.width - sim.pad * 2
                  height: Style.space(24)

                  Row {
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(5)
                    Repeater {
                      model: 3
                      Rectangle { width: Style.space(7); height: width; radius: width / 2; color: Qt.alpha(root.foreground, 0.3) }
                    }
                  }

                  Scribble { anchors.centerIn: parent; seed: 99; maxWidth: parent.width * 0.4 }

                  Rectangle {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    width: Style.space(8)
                    height: width
                    radius: width / 2
                    color: root.urgent
                    opacity: root.simControl === "key1" ? 1 : 0
                    Behavior on opacity { NumberAnimation { duration: 150 } }
                  }
                }

                Rectangle {
                  x: 0; y: simTitle.height
                  width: parent.width
                  height: Math.max(1, Style.space(1))
                  color: Qt.alpha(root.foreground, 0.15)
                }

                // Sidebar: the agents, one of them selected.
                Column {
                  id: simSidebar
                  x: sim.pad
                  y: simTitle.height + Style.space(10)
                  width: Style.space(66)
                  spacing: Style.space(8)

                  Repeater {
                    model: root.simAgents
                    Rectangle {
                      required property int index
                      width: simSidebar.width
                      height: Style.space(16)
                      radius: Style.space(4)
                      color: index === root.simAgent ? Qt.alpha(root.accent, 0.25) : "transparent"
                      Behavior on color { ColorAnimation { duration: 150 } }
                      Scribble {
                        anchors.verticalCenter: parent.verticalCenter
                        x: Style.space(6)
                        seed: 300 + index
                        maxWidth: parent.width - Style.space(12)
                        prompt: index === root.simAgent
                      }
                    }
                  }
                }

                Rectangle {
                  x: simSidebar.x + simSidebar.width + sim.pad
                  y: simTitle.height
                  width: Math.max(1, Style.space(1))
                  height: parent.height - simTitle.height - simStatusBar.height
                  color: Qt.alpha(root.foreground, 0.15)
                }

                // Main pane: scribbled output that the knob scrolls.
                Item {
                  id: simMain
                  x: simSidebar.x + simSidebar.width + sim.pad * 2
                  y: simTitle.height + Style.space(8)
                  width: parent.width - x - sim.pad
                  height: parent.height - y - simStatusBar.height - Style.space(6)
                  clip: true

                  readonly property int lineCount: 48
                  readonly property real total: lineCount * sim.lineStep
                  // Knob right scrolls up: earlier lines come down into view.
                  readonly property real wrapped: ((root.knobPosition * sim.lineStep) % total + total) % total

                  Item {
                    y: -simMain.total + simMain.wrapped
                    width: parent.width
                    height: simMain.total * 2

                    Repeater {
                      model: simMain.lineCount * 2
                      Item {
                        required property int index
                        readonly property int line: index % simMain.lineCount
                        readonly property bool prompt: line % 9 === 0
                        y: index * sim.lineStep
                        width: parent.width
                        height: sim.lineStep

                        Rectangle {
                          visible: parent.prompt
                          x: 0
                          anchors.verticalCenter: parent.verticalCenter
                          width: Style.space(5)
                          height: width
                          radius: Style.space(1)
                          color: root.accent
                        }

                        Scribble {
                          x: parent.prompt ? Style.space(9) : (parent.line % 4 === 2 ? Style.space(12) : 0)
                          anchors.verticalCenter: parent.verticalCenter
                          seed: parent.line
                          maxWidth: parent.width - x
                          prompt: parent.prompt
                        }
                      }
                    }
                  }
                }

                // Status line: what the last key did, or scribbles when idle.
                Rectangle {
                  id: simStatusBar
                  x: 0
                  y: parent.height - height
                  width: parent.width
                  height: Style.space(22)
                  color: Qt.alpha(root.foreground, 0.07)

                  Row {
                    anchors.verticalCenter: parent.verticalCenter
                    x: sim.pad
                    spacing: Style.space(8)
                    visible: root.simStatus === ""
                    Scribble { anchors.verticalCenter: parent.verticalCenter; seed: 501; maxWidth: Style.space(70) }
                    Scribble { anchors.verticalCenter: parent.verticalCenter; seed: 502; maxWidth: Style.space(50) }
                  }

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    x: sim.pad
                    width: parent.width - sim.pad * 2
                    visible: root.simStatus !== ""
                    textFormat: Text.PlainText
                    text: root.simStatus
                    color: root.accent
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    elide: Text.ElideRight
                  }
                }

                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: { game.reset(); root.gameOn = true }
                }
              }

              back: Rectangle {
                id: game
                anchors.fill: parent
                radius: Style.space(10)
                color: Qt.alpha(root.foreground, 0.05)
                border.width: Math.max(1, Style.space(1))
                border.color: Qt.alpha(root.foreground, 0.22)
                clip: true

                readonly property real pad: Style.space(10)
                readonly property real titleH: Style.space(24)
                readonly property int cols: 7
                // Each level adds a row of boxes, up to six, and some speed.
                readonly property int rows: Math.min(6, 3 + level)
                readonly property real boxGap: Style.space(4)
                readonly property real boxH: Style.space(14)
                readonly property real boxTop: titleH + Style.space(12)
                readonly property real boxW: (width - pad * 2 - boxGap * (cols - 1)) / cols
                readonly property real paddleW: Style.space(60)
                readonly property real paddleH: Style.space(6)
                readonly property real paddleY: height - Style.space(18)
                readonly property real notch: Style.space(10)   // paddle travel per knob click
                readonly property real ballR: Style.space(6)
                readonly property real speed: Style.spaceReal(190) * (1 + 0.2 * (level - 1)) // per second, a fifth faster each level
                readonly property var icons: ({ key1: "\u{F036C}", key2: "\u{F012C}", key3: "\u{F0156}" })

                property var alive: []
                property int boxesLeft: 0
                property int shots: 0
                property int level: 1
                property int score: 0
                property int lastBonus: 0
                property int knobBase: 0
                property real lastTick: 0
                // The knob's running notch count, measured from where the game started.
                readonly property real paddleX: Math.max(0, Math.min(width - paddleW,
                  (width - paddleW) / 2 + (root.knobPosition - knobBase) * notch))

                // A fresh game from level one.
                function reset() {
                  level = 1
                  score = 0
                  newRound()
                }

                function newRound() {
                  var a = []
                  for (var i = 0; i < cols * rows; i++) a.push(true)
                  alive = a
                  boxesLeft = cols * rows
                  shots = 0
                  lastBonus = 0
                  balls.clear()
                  knobBase = root.knobPosition
                  lastTick = 0
                }

                // Points per box: the top row pays most, and every level pays more.
                function pointsFor(index) {
                  return 10 * (rows - Math.floor(index / cols)) * level
                }

                // key1 fires up-left, key2 straight up, key3 up-right.
                function fire(key) {
                  if (boxesLeft === 0) { level++; newRound(); return }
                  var a = (key === "key1" ? -30 : key === "key3" ? 30 : 0) * Math.PI / 180
                  balls.append({
                    x: paddleX + paddleW / 2, y: paddleY - ballR - 1,
                    vx: speed * Math.sin(a), vy: -speed * Math.cos(a),
                    icon: icons[key] || ""
                  })
                  shots++
                }

                function step() {
                  var now = Date.now()
                  var dt = lastTick > 0 ? Math.min(0.04, (now - lastTick) / 1000) : 0.016
                  lastTick = now
                  var r = ballR, hit = false
                  for (var i = balls.count - 1; i >= 0; i--) {
                    var b = balls.get(i)
                    var x = b.x + b.vx * dt, y = b.y + b.vy * dt, vx = b.vx, vy = b.vy
                    if (x < r) { x = r; vx = Math.abs(vx) }
                    if (x > width - r) { x = width - r; vx = -Math.abs(vx) }
                    if (y < titleH + r) { y = titleH + r; vy = Math.abs(vy) }
                    // Paddle: where the ball lands along it sets the bounce angle.
                    if (vy > 0 && y + r >= paddleY && b.y + r <= paddleY + paddleH
                        && x >= paddleX - r && x <= paddleX + paddleW + r) {
                      var rel = Math.max(-1, Math.min(1, (x - (paddleX + paddleW / 2)) / (paddleW / 2)))
                      var ang = rel * 60 * Math.PI / 180
                      vx = speed * Math.sin(ang); vy = -speed * Math.cos(ang)
                      y = paddleY - r
                    }
                    // Boxes: the shallower overlap tells which face was struck.
                    if (y - r < boxTop + rows * (boxH + boxGap)) {
                      for (var k = 0; k < alive.length; k++) {
                        if (!alive[k]) continue
                        var bx = pad + (k % cols) * (boxW + boxGap)
                        var by = boxTop + Math.floor(k / cols) * (boxH + boxGap)
                        if (x + r <= bx || x - r >= bx + boxW || y + r <= by || y - r >= by + boxH) continue
                        alive[k] = false; boxesLeft--; hit = true
                        score += pointsFor(k)
                        if (boxesLeft === 0) {
                          // Clearing pays a bonus that shrinks with every shot it took.
                          lastBonus = Math.max(0, 100 * level - 10 * (shots - 1))
                          score += lastBonus
                        }
                        var ox = Math.min(x + r - bx, bx + boxW - (x - r))
                        var oy = Math.min(y + r - by, by + boxH - (y - r))
                        if (ox < oy) { vx = -vx; x += vx > 0 ? ox : -ox }
                        else { vy = -vy; y += vy > 0 ? oy : -oy }
                        break
                      }
                    }
                    if (y - r > height) { balls.remove(i); continue }
                    balls.set(i, { x: x, y: y, vx: vx, vy: vy, icon: b.icon })
                  }
                  if (hit) alive = alive.slice()
                }

                ListModel { id: balls }

                Timer {
                  interval: 16
                  repeat: true
                  running: root.gameOn && root.opened && root.editing === "" && balls.count > 0
                  onTriggered: game.step()
                }

                Component.onCompleted: reset()

                // Title bar, same dots as the window it is the back of.
                Item {
                  x: game.pad
                  width: parent.width - game.pad * 2
                  height: game.titleH

                  Row {
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(5)
                    Repeater {
                      model: 3
                      Rectangle { width: Style.space(7); height: width; radius: width / 2; color: Qt.alpha(root.foreground, 0.3) }
                    }
                  }

                  Text {
                    anchors.centerIn: parent
                    textFormat: Text.PlainText
                    text: "LEVEL " + game.level
                    color: root.faint
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }

                  Text {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    textFormat: Text.PlainText
                    text: game.score + " pts"
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }
                }

                Rectangle {
                  x: 0; y: game.titleH
                  width: parent.width
                  height: Math.max(1, Style.space(1))
                  color: Qt.alpha(root.foreground, 0.15)
                }

                Repeater {
                  model: game.cols * game.rows
                  Rectangle {
                    required property int index
                    x: game.pad + (index % game.cols) * (game.boxW + game.boxGap)
                    y: game.boxTop + Math.floor(index / game.cols) * (game.boxH + game.boxGap)
                    width: game.boxW
                    height: game.boxH
                    radius: Style.space(3)
                    // Like the window's scribbles: foreground, fading row by row.
                    color: Qt.alpha(root.foreground, 0.5 - Math.floor(index / game.cols) * 0.06)
                    opacity: game.alive[index] ? 1 : 0
                    scale: game.alive[index] ? 1 : 1.6
                    Behavior on opacity { NumberAnimation { duration: 180 } }
                    Behavior on scale { NumberAnimation { duration: 180 } }
                  }
                }

                Repeater {
                  model: balls
                  Rectangle {
                    required property var model
                    x: model.x - width / 2
                    y: model.y - width / 2
                    width: game.ballR * 2
                    height: width
                    radius: width / 2
                    color: root.accent
                    Text {
                      anchors.centerIn: parent
                      textFormat: Text.PlainText
                      text: model.icon
                      color: Color.popups.background
                      font.family: root.fontFamily
                      font.pixelSize: game.ballR * 1.5
                    }
                  }
                }

                Rectangle {
                  x: game.paddleX
                  y: game.paddleY
                  width: game.paddleW
                  height: game.paddleH
                  radius: height / 2
                  color: root.foreground
                  Behavior on x { NumberAnimation { duration: 50 } }
                }

                Text {
                  anchors.centerIn: parent
                  width: parent.width - game.pad * 4
                  visible: balls.count === 0
                  textFormat: Text.PlainText
                  text: game.boxesLeft === 0
                    ? "Level " + game.level + " cleared in " + game.shots + (game.shots === 1 ? " shot" : " shots")
                      + (game.lastBonus > 0 ? ", +" + game.lastBonus + " bonus" : "") + ". Press a key for level " + (game.level + 1) + "."
                    : (game.score === 0 && game.level === 1
                      ? "Turn the knob to move the bar, press a key to fire. The knob press starts over; a click turns the window back."
                      : game.boxesLeft + " to go. Press a key to fire.")
                  color: root.faint
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  horizontalAlignment: Text.AlignHCenter
                  wrapMode: Text.WordWrap
                }

                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.gameOn = false
                }
              }
            }

            // ----- The picker: tiles grouped by what they do -----
            Item {
              id: picker
              anchors.fill: parent
              visible: root.editing !== ""

              readonly property bool knobTurn: root.editing === "knob_turn"
              readonly property string currentMode: knobTurn ? root.knobTurnMode : root.editorMode
              readonly property var entry: root.editing !== "" ? root.assigned[root.editing] : null
              readonly property int columns: 3
              readonly property real gap: Style.space(6)

              function tileWidth(rowWidth) {
                return Math.floor((rowWidth - gap * (columns - 1)) / columns)
              }

              // Scroll the picker just enough that the tile is fully visible.
              // Deferred a frame so freshly built tiles have been laid out
              // by their Flow before their position is read.
              property var revealTile: null
              function reveal(tile) {
                revealTile = tile
                revealTimer.restart()
              }
              Timer {
                id: revealTimer
                interval: 30
                onTriggered: {
                  var tile = picker.revealTile
                  picker.revealTile = null
                  if (!tile || !tile.selected) return
                  var flick = pickerScroll.contentItem
                  var top = tile.mapToItem(pickerColumn, 0, 0).y
                  var bottom = top + tile.height
                  var margin = Style.space(8)
                  var target = flick.contentY
                  if (top < target) target = top - margin
                  else if (bottom > target + flick.height) target = bottom - flick.height + margin
                  flick.contentY = Math.max(0, Math.min(target, Math.max(0, flick.contentHeight - flick.height)))
                }
              }

              Column {
                anchors.fill: parent
                spacing: Style.space(6)

                Item {
                  width: parent.width
                  height: Style.space(28)

                  Column {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(1)
                    Text {
                      textFormat: Text.PlainText
                      text: root.editing !== "" ? root.titleFor(root.editing).toUpperCase() : ""
                      color: root.accent
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      font.bold: true
                      font.letterSpacing: 1
                    }
                    Text {
                      textFormat: Text.PlainText
                      text: root.learned !== "" ? root.learned : (root.editing !== "" ? root.hintFor(root.editing) : "")
                      color: root.learned !== "" ? root.accent : root.faint
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                  }

                  PanelActionButton {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    iconText: "󰅖"  // close
                    tooltipText: "Back (Esc)"
                    foreground: root.muted
                    hoverColor: root.foreground
                    fontFamily: root.fontFamily
                    onClicked: root.toggleEditor(root.editing)
                  }
                }

                ScrollView {
                  id: pickerScroll
                  width: parent.width
                  height: parent.height - y
                  clip: true
                  contentWidth: availableWidth
                  ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
                  ScrollBar.vertical.policy: ScrollBar.AlwaysOff  // wheel and knob still scroll; the bar was too thin to grab

                  Column {
                    id: pickerColumn
                    width: pickerScroll.availableWidth
                    spacing: Style.space(8)

                    // Knob turn: one group of modes.
                    Column {
                      width: parent.width
                      spacing: Style.space(4)
                      visible: picker.knobTurn

                      PanelSectionHeader { text: "TURNING THE KNOB"; foreground: root.foreground; fontFamily: root.fontFamily }

                      Flow {
                        width: parent.width
                        spacing: picker.gap
                        Repeater {
                          model: root.knobTurnOptions.filter(function(o) { return o.value !== "none" })
                          Tile {
                            required property var modelData
                            width: picker.tileWidth(parent.width)
                            tileId: modelData.value
                            label: modelData.label
                            selected: picker.currentMode === modelData.value
                            onPicked: function(id) { root.saveKnobTurn(id) }
                          }
                        }
                      }
                    }

                    // Keys and the knob press: every preset, grouped.
                    Repeater {
                      model: picker.knobTurn ? [] : Model.groupedPresets(root.presets)
                      Column {
                        required property var modelData
                        width: pickerColumn.width
                        spacing: Style.space(4)

                        PanelSectionHeader { text: modelData.name.toUpperCase(); foreground: root.foreground; fontFamily: root.fontFamily }

                        Flow {
                          width: parent.width
                          spacing: picker.gap
                          Repeater {
                            model: modelData.presets
                            Tile {
                              required property var modelData
                              width: picker.tileWidth(parent.width)
                              tileId: modelData.id
                              label: modelData.label
                              selected: picker.currentMode === modelData.id
                              onPicked: function(id) { root.choosePreset(root.editing, id) }
                            }
                          }
                        }
                      }
                    }

                    // Custom: a shell command or a key combo of your own.
                    Column {
                      width: parent.width
                      spacing: Style.space(6)
                      visible: !picker.knobTurn

                      PanelSectionHeader { text: "CUSTOM"; foreground: root.foreground; fontFamily: root.fontFamily }

                      TextField {
                        id: commandField
                        width: parent.width
                        placeholderText: "Shell command, Enter to save"
                        text: picker.entry && picker.entry.command && !picker.entry.preset ? picker.entry.command : ""
                        font.family: root.fontFamily
                        foreground: root.foreground
                        accent: root.accent
                        onActiveFocusChanged: root.editorTyping = commandField.activeFocus || keysField.activeFocus
                        Keys.onEscapePressed: root.toggleEditor(root.editing)
                        onAccepted: root.saveButton(root.editing, Model.entryForCommand(text))
                      }

                      TextField {
                        id: keysField
                        width: parent.width
                        placeholderText: "Key combo such as ctrl+shift+t, Enter to save"
                        text: picker.entry && picker.entry.keys && !picker.entry.preset ? picker.entry.keys : ""
                        font.family: root.fontFamily
                        foreground: root.foreground
                        accent: root.accent
                        onActiveFocusChanged: root.editorTyping = commandField.activeFocus || keysField.activeFocus
                        Keys.onEscapePressed: root.toggleEditor(root.editing)
                        onAccepted: root.saveButton(root.editing, Model.entryForKeys(text))
                      }

                      Text {
                        width: parent.width
                        textFormat: Text.PlainText
                        text: "Commands run through bash. Modifiers: ctrl, shift, alt, super; keys: letters, F1–F24, Return, Escape, Tab, Space…"
                        color: root.faint
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        wrapMode: Text.WordWrap
                      }
                    }

                    Button {
                      visible: root.editing !== "" && root.isAssigned(root.editing)
                      text: "Clear assignment"
                      bordered: true
                      foreground: root.muted
                      accent: root.accent
                      fontFamily: root.fontFamily
                      onClicked: {
                        if (picker.knobTurn) root.saveKnobTurn("none")
                        else root.saveButton(root.editing, null)
                      }
                    }
                  }
                }
              }
            }
          }

          // ----- The keypad, with each control's assignment beside it -----
          Item {
            id: device
            width: body.width - leftPane.width - body.spacing
            implicitHeight: deviceBody.height + Style.space(8)
            height: implicitHeight

            readonly property real bodyWidth: Style.space(104)
            readonly property real bodyHeight: Style.space(318)
            readonly property real knobSize: Style.space(80)
            readonly property real knobCenterY: Style.space(92)
            readonly property real keySize: Style.space(40)
            readonly property real keyGap: Style.space(12)
            readonly property real keysTop: Style.space(150)
            readonly property real labelX: bodyWidth + Style.space(26)
            readonly property real knobRowStep: Style.space(22)
            readonly property real knobEdge: deviceBody.x + bodyWidth / 2 + knobSize / 2
            readonly property real keyEdge: deviceBody.x + bodyWidth / 2 + keySize / 2

            function keyCenterY(index) {
              return keysTop + Style.space(10) + keySize / 2 + index * (keySize + keyGap)
            }

            Rectangle {
              id: deviceBody
              x: Style.space(2)
              y: Style.space(4)
              width: device.bodyWidth
              height: device.bodyHeight
              radius: Style.space(20)
              color: Qt.alpha(root.foreground, 0.06)
              border.width: Math.max(1, Style.space(1))
              border.color: Qt.alpha(root.foreground, 0.28)

              Text {
                anchors.top: parent.top
                anchors.topMargin: Style.space(8)
                anchors.horizontalCenter: parent.horizontalCenter
                textFormat: Text.PlainText
                text: "VibeKey"
                color: root.faint
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }

              Row {
                anchors.top: parent.top
                anchors.topMargin: Style.space(26)
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: Style.space(5)
                Repeater {
                  model: 6
                  Rectangle { width: Style.space(4); height: Style.space(14); radius: width / 2; color: Qt.alpha(root.foreground, 0.3) }
                }
              }

              Rectangle {
                id: knob
                readonly property bool lit: root.isKnobTurn(root.flashing) || root.flashing === "knob"
                readonly property bool editingThis: root.isKnobTurn(root.editing) || root.editing === "knob"
                x: (parent.width - width) / 2
                y: device.knobCenterY - height / 2
                width: device.knobSize
                height: width
                radius: width / 2
                color: Qt.alpha(root.foreground, editingThis ? 0.2 : 0.1)
                border.width: Math.max(2, Style.space(3))
                border.color: lit ? root.accent : (editingThis ? Qt.alpha(root.accent, 0.8) : Qt.alpha(root.foreground, 0.4))
                rotation: root.knobAngle
                Behavior on rotation { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
                Behavior on border.color { ColorAnimation { duration: 120 } }

                Rectangle {
                  anchors.horizontalCenter: parent.horizontalCenter
                  y: Style.space(8)
                  width: Math.max(2, Style.space(3))
                  height: Style.space(12)
                  radius: width / 2
                  color: knob.lit ? root.accent : Qt.alpha(root.foreground, 0.6)
                }

                Repeater {
                  model: 12
                  Rectangle {
                    required property int index
                    width: Math.max(1, Style.space(1))
                    height: Style.space(4)
                    x: knob.width / 2 - width / 2
                    y: Style.space(5)
                    transform: Rotation { origin.x: width / 2; origin.y: knob.height / 2 - Style.space(5); angle: index * 30 }
                    color: Qt.alpha(root.foreground, 0.18)
                    visible: index !== 0
                  }
                }

                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.toggleEditor("knob")
                }
              }

              Rectangle {
                x: (parent.width - width) / 2
                y: device.knobCenterY - height / 2
                width: Style.space(10)
                height: width
                radius: width / 2
                color: root.flashing === "knob" ? root.accent : Qt.alpha(root.foreground, root.editing === "knob" ? 0.5 : 0.2)
                Behavior on color { ColorAnimation { duration: 120 } }
              }

              Rectangle {
                x: parent.width - width / 2
                y: device.knobCenterY - height / 2
                width: Style.space(5)
                height: Style.space(18)
                radius: width / 2
                color: Qt.alpha(root.foreground, 0.35)
              }

              Rectangle {
                x: (parent.width - width) / 2
                y: device.keysTop
                width: device.keySize + Style.space(20)
                height: device.keySize * 3 + device.keyGap * 2 + Style.space(20)
                radius: Style.space(10)
                color: "transparent"
                border.width: Math.max(1, Style.space(1))
                border.color: Qt.alpha(root.accent, 0.45)
              }

              KeyCap { controlKey: "key1"; icon: "󰍬"; x: (parent.width - width) / 2; y: device.keyCenterY(0) - height / 2 }
              KeyCap { controlKey: "key2"; icon: "󰄬"; x: (parent.width - width) / 2; y: device.keyCenterY(1) - height / 2 }
              KeyCap { controlKey: "key3"; icon: "󰅖"; x: (parent.width - width) / 2; y: device.keyCenterY(2) - height / 2 }
            }

            Repeater {
              model: [
                { key: "knob_turn", y: deviceBody.y + device.knobCenterY - device.knobRowStep, from: device.knobEdge },
                { key: "knob", y: deviceBody.y + device.knobCenterY + device.knobRowStep, from: device.knobEdge },
                { key: "key1", y: deviceBody.y + device.keyCenterY(0), from: device.keyEdge },
                { key: "key2", y: deviceBody.y + device.keyCenterY(1), from: device.keyEdge },
                { key: "key3", y: deviceBody.y + device.keyCenterY(2), from: device.keyEdge }
              ]
              delegate: Rectangle {
                required property var modelData
                readonly property bool hot: root.editing === modelData.key
                  || root.flashing === modelData.key
                  || (modelData.key === "knob_turn" && root.isKnobTurn(root.flashing))
                x: modelData.from + Style.space(6)
                y: modelData.y
                width: device.labelX - x - Style.space(4)
                height: Math.max(1, Style.space(1))
                color: hot ? root.accent : Qt.alpha(root.foreground, 0.22)
                Rectangle {
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(5)
                  height: width
                  radius: width / 2
                  color: parent.color
                }
              }
            }

            ControlLabel { controlKey: "knob_turn"; x: device.labelX; y: deviceBody.y + device.knobCenterY - device.knobRowStep - height / 2; width: device.width - device.labelX }
            ControlLabel { controlKey: "knob";      x: device.labelX; y: deviceBody.y + device.knobCenterY + device.knobRowStep - height / 2; width: device.width - device.labelX }
            ControlLabel { controlKey: "key1"; x: device.labelX; y: deviceBody.y + device.keyCenterY(0) - height / 2; width: device.width - device.labelX }
            ControlLabel { controlKey: "key2"; x: device.labelX; y: deviceBody.y + device.keyCenterY(1) - height / 2; width: device.width - device.labelX }
            ControlLabel { controlKey: "key3"; x: device.labelX; y: deviceBody.y + device.keyCenterY(2) - height / 2; width: device.width - device.labelX }
          }
        }

        Text {
          width: parent.width
          visible: root.connected
          textFormat: Text.PlainText
          text: root.editing === ""
            ? "Preview: while this panel is open the Vibekey only acts in the window on the left. Click a control to change what it does."
            : (root.editing === "knob_turn" ? "Both directions follow the choice." : "Press this control on the Vibekey now if it does not light up on its own: it will be learned.")
          color: root.faint
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }
    }
  }
}
