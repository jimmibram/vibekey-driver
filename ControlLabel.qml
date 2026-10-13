import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui
import "Model.js" as Model

// A control's name and assignment, beside its spot on the drawing.
CursorSurface {
  id: label
  required property var host
  required property string controlKey
  property bool compact: false
  readonly property bool editingThis: host.editing === controlKey
  readonly property bool flashingThis: host.flashing === controlKey
    || (controlKey === "knob_turn" && (host.flashing === "knob_right" || host.flashing === "knob_left"))
  readonly property bool assignedThis: host.isAssigned(controlKey)

  height: compact ? Style.space(30) : Style.space(40)
  hasCursor: host.cursorActive && host.cursorKeys[host.cursorIndex] === controlKey
  current: editingThis
  foreground: flashingThis ? host.accent : host.foreground
  accent: host.accent
  outline: flashingThis

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onContainsMouseChanged: if (containsMouse) { host.cursorActive = true; host.cursorIndex = host.cursorKeys.indexOf(label.controlKey) }
    onClicked: host.toggleEditor(label.controlKey)
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
      text: host.titleFor(label.controlKey).toUpperCase()
      color: label.flashingThis ? host.accent : (label.editingThis ? host.foreground : host.muted)
      font.family: host.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      font.letterSpacing: 1
      elide: Text.ElideRight
    }

    Text {
      width: parent.width
      textFormat: Text.PlainText
      text: host.summaryFor(label.controlKey)
      color: label.assignedThis ? host.foreground : host.faint
      font.family: host.fontFamily
      font.pixelSize: label.compact ? Style.font.caption : Style.font.body
      font.italic: !label.assignedThis
      elide: Text.ElideRight
    }
  }
}
