import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Ulanzi Vibekey: a bar icon plus a popup control panel.
//
// The panel owns the driver: while this widget is in the bar, bin/vibekeyd runs
// as a child process, holds the dongle open, grabs its keystrokes and runs the
// action assigned to each control. The daemon publishes what it sees to
// $XDG_RUNTIME_DIR/vibekey/state.json; assignments live in
// ~/.config/omarchy/vibekey/config.json and are written through
// bin/vibekey-config so the file is never half-written.
Panel {
  id: root
  moduleName: "jimmibram.vibekey"
  ipcTarget: "jimmibram.vibekey"
  manageIpc: false

  readonly property string pluginDir: decodeURIComponent(String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "")).replace(/\/$/, "")
  readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") || "/tmp"
  readonly property string configHome: Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")
  readonly property string statePath: runtimeDir + "/vibekey/state.json"
  readonly property string configPath: configHome + "/omarchy/vibekey/config.json"
  readonly property string seenPath: configHome + "/omarchy/vibekey/seen.json"

  readonly property color foreground: bar ? bar.barForeground : Color.foreground
  readonly property color accent: Color.accent
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color muted: Qt.darker(foreground, 1.4)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property string glyph: "󰌌"  // nf-md-keyboard_variant

  property var state: ({})
  property var config: ({})
  property var seen: ({})
  property var presets: []

  readonly property bool daemonRunning: daemon.running
  readonly property bool connected: state.connected === true
  readonly property bool accessDenied: state.access === "denied"
  readonly property bool grabbing: !(config && config.grab === false)
  readonly property var rows: Model.controls(config, seen, presets)
  readonly property var editorOptions: Model.editorOptions(presets)
  readonly property string statusText: Model.statusText(state, daemonRunning)

  // The row whose editor is open, and the one the device just sent.
  property string editing: ""
  property string flashing: ""
  property real lastEventAt: 0
  property bool installingAccess: false
  property string saveError: ""

  // Keyboard cursor over the rows (j/k, Enter opens the editor).
  property bool cursorActive: false
  property int cursorIndex: 0

  // ------------------------------------------------------------ data files

  function applyState(text) {
    var next = Model.parseJson(text, null)
    if (!next) return
    root.state = next
    var last = next.last
    if (last && Number(last.at) > root.lastEventAt) {
      if (root.lastEventAt > 0) {
        root.flashing = String(last.slot || last.id || "")
        flashTimer.restart()
      }
      root.lastEventAt = Number(last.at)
    }
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

  function runConfig(args) {
    if (configProc.running) {
      pendingWrites.push(args)
      return
    }
    configProc.command = ["python3", root.pluginDir + "/bin/vibekey-config"].concat(args)
    configProc.running = true
  }
  property var pendingWrites: []

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

  function setGrab(enabled) {
    var next = Model.isObject(root.config) ? JSON.parse(JSON.stringify(root.config)) : {}
    next.grab = enabled
    root.config = next
    root.runConfig(["set", "grab", enabled ? "true" : "false"])
  }

  function chooseMode(key, mode) {
    if (mode === "none") { root.saveButton(key, null); return }
    if (mode === "custom" || mode === "keys") {
      // Keep whatever is there until the text is saved; the editor shows the field.
      var current = Model.buttons(root.config)[key]
      var kept = Model.isObject(current) ? JSON.parse(JSON.stringify(current)) : {}
      delete kept.preset
      if (mode === "custom") { delete kept.keys; delete kept.release_keys; if (!kept.command) kept.command = ""; }
      else { delete kept.command; delete kept.release_command; if (!kept.keys) kept.keys = ""; }
      root.draftMode = mode
      root.draftKey = key
      return
    }
    root.draftMode = ""
    root.saveButton(key, Model.entryForPreset(Model.presetById(root.presets, mode)))
  }

  // A free-form choice picked in the dropdown but not typed yet.
  property string draftMode: ""
  property string draftKey: ""

  function editorModeFor(row) {
    if (root.draftMode !== "" && root.draftKey === row.key) return root.draftMode
    return Model.editorMode(row.entry, root.presets)
  }

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
      // The daemon retries on its own every two seconds.
    }
  }

  // ------------------------------------------------------------ cursor

  function moveCursor(delta) {
    if (root.rows.length === 0) return
    cursorIndex = Math.max(0, Math.min(root.rows.length - 1, cursorIndex + delta))
  }

  function toggleEditor(key) {
    if (root.editing === key) {
      root.editing = ""
      root.draftMode = ""
    } else {
      root.editing = key
      root.draftMode = ""
    }
  }

  function activateCursor() {
    if (cursorIndex < 0 || cursorIndex >= root.rows.length) return
    toggleEditor(root.rows[cursorIndex].key)
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

  // ------------------------------------------------------------ popup

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight, Style.space(720))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.editing !== "" && (root.editorModeFor({ key: root.editing, entry: Model.buttons(root.config)[root.editing] }) === "custom"
                                        || root.editorModeFor({ key: root.editing, entry: Model.buttons(root.config)[root.editing] }) === "keys")
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

          // ---------- Controls ----------
          Item {
            width: parent.width
            implicitHeight: controlsHeader.implicitHeight

            PanelSectionHeader {
              id: controlsHeader
              text: "CONTROLS"
              foreground: root.foreground
              fontFamily: root.fontFamily
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            Text {
              textFormat: Text.PlainText
              text: root.connected ? "press one to find it" : ""
              color: root.muted
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              anchors.right: parent.right
              anchors.rightMargin: Style.space(6)
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          Repeater {
            model: root.rows

            delegate: Column {
              id: rowItem
              required property var modelData
              required property int index
              readonly property string key: modelData.key
              readonly property bool editingThis: root.editing === key
              readonly property bool flashingThis: root.flashing === key
              readonly property string mode: root.editorModeFor(modelData)
              width: panelColumn.width
              spacing: Style.space(6)

              CursorSurface {
                id: rowSurface
                width: parent.width
                height: Style.space(46)
                hasCursor: root.cursorActive && root.cursorIndex === rowItem.index
                current: rowItem.editingThis || rowItem.flashingThis
                foreground: rowItem.flashingThis ? root.accent : root.foreground
                accent: root.accent
                outline: rowItem.flashingThis

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onContainsMouseChanged: if (containsMouse) { root.cursorActive = true; root.cursorIndex = rowItem.index }
                  onClicked: root.toggleEditor(rowItem.key)
                }

                Row {
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(10)
                  anchors.rightMargin: Style.space(10)
                  spacing: Style.space(10)

                  Column {
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - chevron.width - parent.spacing
                    spacing: Style.space(2)

                    Text {
                      width: parent.width
                      textFormat: Text.PlainText
                      text: rowItem.modelData.label
                      color: rowItem.flashingThis ? root.accent : root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      font.bold: rowItem.flashingThis
                      elide: Text.ElideRight
                    }

                    Text {
                      width: parent.width
                      textFormat: Text.PlainText
                      text: rowItem.modelData.summary
                      color: rowItem.modelData.entry ? root.muted : Qt.darker(root.foreground, 1.9)
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      font.italic: !rowItem.modelData.entry
                      elide: Text.ElideRight
                    }
                  }

                  Text {
                    id: chevron
                    anchors.verticalCenter: parent.verticalCenter
                    textFormat: Text.PlainText
                    text: rowItem.editingThis ? "󰅃" : "󰅂"  // chevron-up / chevron-down
                    color: root.muted
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.icon
                  }
                }
              }

              // ---------- Editor ----------
              Column {
                width: parent.width - Style.space(12)
                anchors.right: parent.right
                visible: rowItem.editingThis
                spacing: Style.space(8)

                SearchableDropdown {
                  width: parent.width
                  label: "Action"
                  showLabel: false
                  placeholderText: "Search actions…"
                  fontFamily: root.fontFamily
                  options: root.editorOptions
                  value: rowItem.mode
                  onChanged: function(value) { root.chooseMode(rowItem.key, value) }
                }

                TextField {
                  id: commandField
                  width: parent.width
                  visible: rowItem.mode === "custom"
                  placeholderText: "Shell command, e.g. omarchy toggle nightlight"
                  text: rowItem.modelData.entry && rowItem.modelData.entry.command ? rowItem.modelData.entry.command : ""
                  font.family: root.fontFamily
                  foreground: root.foreground
                  accent: root.accent
                  onVisibleChanged: if (visible) Qt.callLater(function() { commandField.forceActiveFocus() })
                  onAccepted: {
                    root.draftMode = ""
                    root.saveButton(rowItem.key, Model.entryForCommand(text))
                  }
                }

                TextField {
                  id: keysField
                  width: parent.width
                  visible: rowItem.mode === "keys"
                  placeholderText: "Key combo, e.g. ctrl+shift+t or Return"
                  text: rowItem.modelData.entry && rowItem.modelData.entry.keys ? rowItem.modelData.entry.keys : ""
                  font.family: root.fontFamily
                  foreground: root.foreground
                  accent: root.accent
                  onVisibleChanged: if (visible) Qt.callLater(function() { keysField.forceActiveFocus() })
                  onAccepted: {
                    root.draftMode = ""
                    root.saveButton(rowItem.key, Model.entryForKeys(text))
                  }
                }

                Row {
                  visible: rowItem.mode === "custom" || rowItem.mode === "keys"
                  spacing: Style.space(8)

                  Button {
                    text: "Save"
                    bordered: true
                    foreground: root.foreground
                    accent: root.accent
                    fontFamily: root.fontFamily
                    onClicked: {
                      root.draftMode = ""
                      if (rowItem.mode === "custom") root.saveButton(rowItem.key, Model.entryForCommand(commandField.text))
                      else root.saveButton(rowItem.key, Model.entryForKeys(keysField.text))
                    }
                  }

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    textFormat: Text.PlainText
                    text: rowItem.mode === "keys"
                      ? "Modifiers: ctrl, shift, alt, super. Keys: letters, F1–F24, Return, Escape, Tab, Space…"
                      : "Runs through bash with your session environment."
                    color: root.muted
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    width: parent.parent.width - Style.space(90)
                    wrapMode: Text.WordWrap
                  }
                }

                Text {
                  width: parent.width
                  textFormat: Text.PlainText
                  text: rowItem.modelData.hint + (rowItem.modelData.extra ? "" : "")
                  color: Qt.darker(root.foreground, 1.9)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }
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
              ? "Last: " + root.state.last.label + (root.state.last.action ? "  →  " + root.state.last.action : "  (nothing assigned)")
              : "Press a key or turn the knob on the Vibekey to see it here."
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
