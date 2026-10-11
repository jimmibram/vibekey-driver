import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
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
  readonly property string glyph: "󰌌"  // nf-md-keyboard_variant

  property var state: ({})
  property var config: ({})
  property var seen: ({})
  property var presets: []
  property var knobPresets: []

  readonly property bool daemonRunning: daemon.running
  readonly property bool connected: state.connected === true
  readonly property bool accessDenied: state.access === "denied"
  readonly property bool grabbing: !(config && config.grab === false)
  readonly property var assigned: Model.buttons(config)
  readonly property var rows: Model.controls(config, seen, presets)
  readonly property var extras: rows.filter(function(r) { return r.extra })
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
  property real knobAngle: 0
  readonly property real knobStep: 18
  property bool installingAccess: false
  property string saveError: ""

  // Keyboard cursor over the controls (j/k, Enter opens the editor).
  property bool cursorActive: false
  property int cursorIndex: 0
  readonly property var cursorKeys: slotOrder.concat(extras.map(function(r) { return r.key }))

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
        // Learning: with a key's editor open, a control the firmware sends under
        // some other code becomes that key.
        var learnable = ["key1", "key2", "key3", "knob"].indexOf(root.editing) !== -1
        if (root.opened && learnable && last.id && !Model.FACTORY_IDS[last.id] && slot !== root.editing) {
          root.runConfig(["alias", String(last.id), root.editing])
          root.learned = root.titleFor(root.editing) + " now answers to " + String(last.label || last.id)
          slot = root.editing
        }
        root.flashing = slot || String(last.id || "")
        flashTimer.restart()
        // Turn the drawn knob with the real one: one step per notch seen.
        var notches = root.lastEvents >= 0 && events > root.lastEvents ? events - root.lastEvents : 1
        if (last.slot === "knob_right") root.knobAngle += root.knobStep * notches
        else if (last.slot === "knob_left") root.knobAngle -= root.knobStep * notches
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

  function setGrab(enabled) {
    var next = Model.isObject(root.config) ? JSON.parse(JSON.stringify(root.config)) : {}
    next.grab = enabled
    root.config = next
    root.runConfig(["set", "grab", enabled ? "true" : "false"])
  }

  // A free-form choice picked in the dropdown but not typed yet.
  property string draftMode: ""

  function chooseMode(key, mode) {
    if (mode === "none") { root.draftMode = ""; root.saveButton(key, null); return }
    if (mode === "custom" || mode === "keys") { root.draftMode = mode; return }
    root.draftMode = ""
    root.saveButton(key, Model.entryForPreset(Model.presetById(root.presets, mode)))
  }

  readonly property bool editingExtra: root.editing !== "" && root.slotOrder.indexOf(root.editing) === -1

  function setAlias(rawId, slot) {
    root.runConfig(["alias", rawId, slot])
    if (slot !== "none") {
      root.learned = root.titleFor(slot) + " now answers to " + root.titleFor(rawId)
      root.editing = slot
    }
  }

  function forgetControl(rawId) {
    root.runConfig(["forget", rawId])
    root.editing = ""
    Qt.callLater(function() { seenFile.reload() })
  }

  readonly property string editorMode: root.editing === "" || root.editing === "knob_turn"
    ? "none"
    : (root.draftMode !== "" ? root.draftMode : Model.editorMode(root.assigned[root.editing], root.presets))
  readonly property bool editorTyping: editorMode === "custom" || editorMode === "keys"

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
    root.draftMode = ""
    root.learned = ""
    root.editing = root.editing === key ? "" : key
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
      root.draftMode = ""
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
  }

  // ------------------------------------------------------------ bar button

  visible: true
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.glyph
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

  // ------------------------------------------------------------ popup

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(440))
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight, Style.space(820))

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

      ScrollView {
        id: scrollArea
        anchors.fill: parent
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: panelColumn.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff

        Binding {
          target: scrollArea.contentItem
          property: "interactive"
          value: panelColumn.implicitHeight > scrollArea.height
        }

        Column {
          id: panelColumn
          width: scrollArea.availableWidth
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
              Text {
                text: root.glyph
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
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

          // ---------- The keypad, with each control's assignment beside it ----------
          Item {
            id: device
            width: parent.width
            implicitHeight: body.height + Style.space(8)

            // Geometry of the drawing: the knob and three keys, top to bottom.
            readonly property real bodyWidth: Style.space(104)
            readonly property real bodyHeight: Style.space(318)
            readonly property real knobSize: Style.space(80)
            readonly property real knobCenterY: Style.space(92)
            readonly property real keySize: Style.space(40)
            readonly property real keyGap: Style.space(12)
            readonly property real keysTop: Style.space(150)
            readonly property real labelX: bodyWidth + Style.space(26)
            readonly property real knobRowStep: Style.space(22)
            readonly property real knobEdge: body.x + bodyWidth / 2 + knobSize / 2
            readonly property real keyEdge: body.x + bodyWidth / 2 + keySize / 2

            function keyCenterY(index) {
              return keysTop + Style.space(10) + keySize / 2 + index * (keySize + keyGap)
            }

            // The slab.
            Rectangle {
              id: body
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

              // Microphone grille.
              Row {
                anchors.top: parent.top
                anchors.topMargin: Style.space(26)
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: Style.space(5)
                Repeater {
                  model: 6
                  Rectangle {
                    width: Style.space(4)
                    height: Style.space(14)
                    radius: width / 2
                    color: Qt.alpha(root.foreground, 0.3)
                  }
                }
              }

              // The knob: a ring with a position tick that turns with the real one.
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

                // Faint detents so the turn is visible.
                Repeater {
                  model: 12
                  Rectangle {
                    required property int index
                    width: Math.max(1, Style.space(1))
                    height: Style.space(4)
                    x: knob.width / 2 - width / 2
                    y: Style.space(5)
                    transformOrigin: Item.Center
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

              // The knob centre marks a press.
              Rectangle {
                x: (parent.width - width) / 2
                y: device.knobCenterY - height / 2
                width: Style.space(10)
                height: width
                radius: width / 2
                color: root.flashing === "knob" ? root.accent : Qt.alpha(root.foreground, root.editing === "knob" ? 0.5 : 0.2)
                Behavior on color { ColorAnimation { duration: 120 } }
              }

              // Power switch on the edge.
              Rectangle {
                x: parent.width - width / 2
                y: device.knobCenterY - height / 2
                width: Style.space(5)
                height: Style.space(18)
                radius: width / 2
                color: Qt.alpha(root.foreground, 0.35)
              }

              // The lit frame around the three keys.
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

              KeyCap { controlKey: "key1"; icon: "󰍬"; x: (parent.width - width) / 2; y: device.keyCenterY(0) - height / 2 }  // microphone
              KeyCap { controlKey: "key2"; icon: "󰄬"; x: (parent.width - width) / 2; y: device.keyCenterY(1) - height / 2 }  // check
              KeyCap { controlKey: "key3"; icon: "󰅖"; x: (parent.width - width) / 2; y: device.keyCenterY(2) - height / 2 }  // close
            }

            // Leader lines from the drawing to the labels.
            Repeater {
              model: [
                { key: "knob_turn", y: body.y + device.knobCenterY - device.knobRowStep, from: device.knobEdge },
                { key: "knob", y: body.y + device.knobCenterY + device.knobRowStep, from: device.knobEdge },
                { key: "key1", y: body.y + device.keyCenterY(0), from: device.keyEdge },
                { key: "key2", y: body.y + device.keyCenterY(1), from: device.keyEdge },
                { key: "key3", y: body.y + device.keyCenterY(2), from: device.keyEdge }
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

            ControlLabel { controlKey: "knob_turn"; x: device.labelX; y: body.y + device.knobCenterY - device.knobRowStep - height / 2; width: device.width - device.labelX }
            ControlLabel { controlKey: "knob";      x: device.labelX; y: body.y + device.knobCenterY + device.knobRowStep - height / 2; width: device.width - device.labelX }
            ControlLabel { controlKey: "key1"; x: device.labelX; y: body.y + device.keyCenterY(0) - height / 2; width: device.width - device.labelX }
            ControlLabel { controlKey: "key2"; x: device.labelX; y: body.y + device.keyCenterY(1) - height / 2; width: device.width - device.labelX }
            ControlLabel { controlKey: "key3"; x: device.labelX; y: body.y + device.keyCenterY(2) - height / 2; width: device.width - device.labelX }
          }

          Text {
            width: parent.width
            visible: root.connected
            textFormat: Text.PlainText
            text: "Preview: while this panel is open the Vibekey only lights up what you press. Click a control to change what it does."
            color: root.faint
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          // ---------- Controls remapped in firmware (rare) ----------
          Column {
            width: parent.width
            spacing: Style.space(4)
            visible: root.extras.length > 0

            PanelSectionHeader {
              text: "ALSO SEEN"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.extras
              delegate: ControlLabel {
                required property var modelData
                controlKey: modelData.key
                compact: true
                width: panelColumn.width
              }
            }
          }

          // ---------- Editor for the chosen control ----------
          Column {
            id: editor
            width: parent.width
            spacing: Style.space(8)
            visible: root.editing !== ""

            PanelSeparator { foreground: root.foreground }

            Item {
              width: parent.width
              implicitHeight: editHeader.implicitHeight

              PanelSectionHeader {
                id: editHeader
                text: root.editing !== "" ? root.titleFor(root.editing).toUpperCase() : ""
                foreground: root.accent
                fontFamily: root.fontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                textFormat: Text.PlainText
                text: root.editing !== "" ? root.hintFor(root.editing) : ""
                color: root.faint
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            Text {
              width: parent.width
              visible: root.learned !== ""
              textFormat: Text.PlainText
              text: root.learned
              color: root.accent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Text {
              width: parent.width
              visible: ["key1", "key2", "key3", "knob"].indexOf(root.editing) !== -1 && root.learned === ""
              textFormat: Text.PlainText
              text: "Press this control on the Vibekey now if it does not light up on its own: it will be learned."
              color: root.faint
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            // A control the firmware sends under its own code: say which key it is.
            Row {
              width: parent.width
              visible: root.editingExtra
              spacing: Style.space(10)

              Dropdown {
                id: slotPicker
                width: parent.width - forgetButton.width - parent.spacing
                label: "This is the"
                showLabel: false
                fontFamily: root.fontFamily
                options: Model.slotOptions()
                value: root.editingExtra ? Model.aliasOf(root.config, root.editing) : "none"
                onChanged: function(value) { root.setAlias(root.editing, value) }
              }

              Button {
                id: forgetButton
                anchors.verticalCenter: parent.verticalCenter
                text: "Forget"
                tooltipText: "Drop it from this list"
                bordered: true
                foreground: root.foreground
                accent: root.accent
                fontFamily: root.fontFamily
                onClicked: root.forgetControl(root.editing)
              }
            }

            // The knob turn: pick what turning does; both directions follow.
            SearchableDropdown {
              width: parent.width
              visible: root.editing === "knob_turn"
              label: "Turning the knob"
              showLabel: false
              placeholderText: "Search…"
              fontFamily: root.fontFamily
              options: root.knobTurnOptions
              value: root.knobTurnMode
              onChanged: function(value) { root.saveKnobTurn(value) }
            }

            SearchableDropdown {
              width: parent.width
              visible: root.editing !== "" && root.editing !== "knob_turn"
              label: "Action"
              showLabel: false
              placeholderText: "Search actions…"
              fontFamily: root.fontFamily
              options: root.editorOptions
              value: root.editorMode
              onChanged: function(value) { root.chooseMode(root.editing, value) }
            }

            TextField {
              id: commandField
              width: parent.width
              visible: root.editorMode === "custom"
              placeholderText: "Shell command, e.g. omarchy toggle nightlight"
              text: root.editing !== "" && root.assigned[root.editing] && root.assigned[root.editing].command ? root.assigned[root.editing].command : ""
              font.family: root.fontFamily
              foreground: root.foreground
              accent: root.accent
              onVisibleChanged: if (visible) Qt.callLater(function() { commandField.forceActiveFocus() })
              onAccepted: {
                root.draftMode = ""
                root.saveButton(root.editing, Model.entryForCommand(text))
              }
            }

            TextField {
              id: keysField
              width: parent.width
              visible: root.editorMode === "keys"
              placeholderText: "Key combo, e.g. ctrl+shift+t or Return"
              text: root.editing !== "" && root.assigned[root.editing] && root.assigned[root.editing].keys ? root.assigned[root.editing].keys : ""
              font.family: root.fontFamily
              foreground: root.foreground
              accent: root.accent
              onVisibleChanged: if (visible) Qt.callLater(function() { keysField.forceActiveFocus() })
              onAccepted: {
                root.draftMode = ""
                root.saveButton(root.editing, Model.entryForKeys(text))
              }
            }

            Row {
              width: parent.width
              visible: root.editorTyping
              spacing: Style.space(10)

              Button {
                id: saveButton
                text: "Save"
                bordered: true
                foreground: root.foreground
                accent: root.accent
                fontFamily: root.fontFamily
                onClicked: {
                  root.draftMode = ""
                  if (root.editorMode === "custom") root.saveButton(root.editing, Model.entryForCommand(commandField.text))
                  else root.saveButton(root.editing, Model.entryForKeys(keysField.text))
                }
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - saveButton.width - parent.spacing
                textFormat: Text.PlainText
                text: root.editorMode === "keys"
                  ? "Modifiers: ctrl, shift, alt, super. Keys: letters, F1–F24, Return, Escape, Tab, Space…"
                  : "Runs through bash with your session environment."
                color: root.muted
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
            }
          }

          PanelSeparator { foreground: root.foreground }

          // ---------- Options ----------
          Toggle {
            width: parent.width
            label: "Block the factory keystrokes"
            description: root.grabbing
              ? "Enter, Esc, PrintScreen and the arrows from the Vibekey stay inside this plugin."
              : "Off: the Vibekey also types its factory keys into whatever is focused."
            checked: root.grabbing
            foreground: root.foreground
            accent: root.accent
            fontFamily: root.fontFamily
            onClicked: root.setGrab(!root.grabbing)
          }

          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: root.state && root.state.last && root.state.last.label
              ? "Last: " + root.state.last.label
                + (root.state.last.preview ? "  (preview, not run)" : (root.state.last.action ? "  →  " + root.state.last.action : "  (nothing assigned)"))
              : ""
            visible: text !== ""
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }
      }
    }
  }
}
