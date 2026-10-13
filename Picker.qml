import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The assignment picker: tiles grouped by what they do, plus a custom shell
// command or key combo.
Item {
  id: picker
  required property var host

  readonly property bool knobTurn: host.editing === "knob_turn"
  readonly property string currentMode: knobTurn ? host.knobTurnMode : host.editorMode
  readonly property var entry: host.editing !== "" ? host.assigned[host.editing] : null
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
          text: host.editing !== "" ? host.titleFor(host.editing).toUpperCase() : ""
          color: host.accent
          font.family: host.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
          font.letterSpacing: 1
        }
        Text {
          textFormat: Text.PlainText
          text: host.learned !== "" ? host.learned : (host.editing !== "" ? host.hintFor(host.editing) : "")
          color: host.learned !== "" ? host.accent : host.faint
          font.family: host.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      PanelActionButton {
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        iconText: "󰅖"  // close
        tooltipText: "Back (Esc)"
        foreground: host.muted
        hoverColor: host.foreground
        fontFamily: host.fontFamily
        onClicked: host.toggleEditor(host.editing)
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

          PanelSectionHeader { text: "TURNING THE KNOB"; foreground: host.foreground; fontFamily: host.fontFamily }

          Flow {
            width: parent.width
            spacing: picker.gap
            Repeater {
              model: host.knobTurnOptions.filter(function(o) { return o.value !== "none" })
              Tile {
                foreground: host.foreground
                accent: host.accent
                fontFamily: host.fontFamily
                onRevealRequested: function(tile) { picker.reveal(tile) }
                required property var modelData
                width: picker.tileWidth(parent.width)
                tileId: modelData.value
                label: modelData.label
                selected: picker.currentMode === modelData.value
                onPicked: function(id) { host.saveKnobTurn(id) }
              }
            }
          }
        }

        // Keys and the knob press: every preset, grouped.
        Repeater {
          model: picker.knobTurn ? [] : Model.groupedPresets(host.presets)
          Column {
            required property var modelData
            width: pickerColumn.width
            spacing: Style.space(4)

            PanelSectionHeader { text: modelData.name.toUpperCase(); foreground: host.foreground; fontFamily: host.fontFamily }

            Flow {
              width: parent.width
              spacing: picker.gap
              Repeater {
                model: modelData.presets
                Tile {
                  foreground: host.foreground
                  accent: host.accent
                  fontFamily: host.fontFamily
                  onRevealRequested: function(tile) { picker.reveal(tile) }
                  required property var modelData
                  width: picker.tileWidth(parent.width)
                  tileId: modelData.id
                  label: modelData.label
                  selected: picker.currentMode === modelData.id
                  onPicked: function(id) { host.choosePreset(host.editing, id) }
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

          PanelSectionHeader { text: "CUSTOM"; foreground: host.foreground; fontFamily: host.fontFamily }

          TextField {
            id: commandField
            width: parent.width
            placeholderText: "Shell command, Enter to save"
            text: picker.entry && picker.entry.command && !picker.entry.preset ? picker.entry.command : ""
            font.family: host.fontFamily
            foreground: host.foreground
            accent: host.accent
            onActiveFocusChanged: host.editorTyping = commandField.activeFocus || keysField.activeFocus
            Keys.onEscapePressed: host.toggleEditor(host.editing)
            onAccepted: host.saveButton(host.editing, Model.entryForCommand(text))
          }

          TextField {
            id: keysField
            width: parent.width
            placeholderText: "Key combo such as ctrl+shift+t, Enter to save"
            text: picker.entry && picker.entry.keys && !picker.entry.preset ? picker.entry.keys : ""
            font.family: host.fontFamily
            foreground: host.foreground
            accent: host.accent
            onActiveFocusChanged: host.editorTyping = commandField.activeFocus || keysField.activeFocus
            Keys.onEscapePressed: host.toggleEditor(host.editing)
            onAccepted: host.saveButton(host.editing, Model.entryForKeys(text))
          }

          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: "Commands run through bash. Modifiers: ctrl, shift, alt, super; keys: letters, F1–F24, Return, Escape, Tab, Space…"
            color: host.faint
            font.family: host.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }

        Button {
          visible: host.editing !== "" && host.isAssigned(host.editing)
          text: "Clear assignment"
          bordered: true
          foreground: host.muted
          accent: host.accent
          fontFamily: host.fontFamily
          onClicked: {
            if (picker.knobTurn) host.saveKnobTurn("none")
            else host.saveButton(host.editing, null)
          }
        }
      }
    }
  }
}
