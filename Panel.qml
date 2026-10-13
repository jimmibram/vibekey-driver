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
    tooltipText: Model.tooltip(root.state, root.daemonRunning, root.slotOrder.filter(root.isAssigned).length, root.slotOrder.length)
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.refreshFiles()
      else root.toggle()
    }
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

              front: MockWindow {
                anchors.fill: parent
                host: root
                onClicked: { game.reset(); root.gameOn = true }
              }

              back: Game {
                id: game
                anchors.fill: parent
                host: root
                onExit: root.gameOn = false
              }
            }

            // ----- The picker: tiles grouped by what they do -----
            Picker {
              id: picker
              anchors.fill: parent
              host: root
              visible: root.editing !== ""
            }
          }

          // ----- The keypad, with each control's assignment beside it -----
          Device {
            id: device
            host: root
            width: body.width - leftPane.width - body.spacing
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
