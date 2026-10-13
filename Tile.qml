import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui
import "Model.js" as Model

// One choice in the picker: a tile that lights when it is the assignment.
CursorSurface {
  id: tile
  property string fontFamily: ""
  signal revealRequested(var tile)
  required property string tileId
  required property string label
  property bool selected: false
  signal picked(string id)
  height: Style.space(46)
  current: selected
  hasCursor: tileMouse.containsMouse
  outline: selected

  // Opening the editor for a control whose preset sits far down the
  // list: bring that tile into view.
  onSelectedChanged: if (selected) revealRequested(tile)
  Component.onCompleted: if (selected) revealRequested(tile)

  // A faint resting outline so the tiles read as buttons, not loose text.
  // Hover and selection paint their own border, so this one steps aside.
  Rectangle {
    anchors.fill: parent
    radius: tile.radius
    color: "transparent"
    border.width: Math.max(1, Style.space(1))
    border.color: Qt.alpha(tile.foreground, 0.16)
    visible: !tile.hasCursor && !tile.selected
  }

  Text {
    anchors.fill: parent
    anchors.margins: Style.space(6)
    textFormat: Text.PlainText
    text: tile.label
    color: tile.selected ? tile.accent : tile.foreground
    font.family: tile.fontFamily
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
