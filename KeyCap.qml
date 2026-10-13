import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui
import "Model.js" as Model

// A round key on the drawing.
Rectangle {
  id: cap
  required property var host
  required property string controlKey
  property string icon: ""
  readonly property bool lit: host.flashing === controlKey
  readonly property bool editingThis: host.editing === controlKey
  width: Style.space(40)
  height: width
  radius: width / 2
  color: lit ? host.accent : Qt.alpha(host.foreground, editingThis ? 0.22 : 0.12)
  border.width: Math.max(1, Style.space(1))
  border.color: editingThis || lit ? host.accent : Qt.alpha(host.foreground, 0.35)
  Behavior on color { ColorAnimation { duration: 120 } }

  Text {
    anchors.centerIn: parent
    textFormat: Text.PlainText
    text: cap.icon
    color: cap.lit ? Color.popups.background : host.foreground
    font.family: host.fontFamily
    font.pixelSize: Style.font.icon
  }

  MouseArea {
    anchors.fill: parent
    cursorShape: Qt.PointingHandCursor
    onClicked: host.toggleEditor(cap.controlKey)
  }
}
