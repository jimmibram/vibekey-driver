import QtQuick

// The Vibekey as a glyph: three microphone grille lines above the knob, a
// ring with a dot in the middle. Drawn with rectangles so it stays crisp at
// bar size.
Item {
  id: root

  property real iconSize: 16
  property color color: "white"
  property color background: "transparent"  // unused; kept so callers need not change

  width: iconSize
  height: iconSize
  implicitWidth: iconSize
  implicitHeight: iconSize

  readonly property real stroke: Math.max(1, Math.round(iconSize / 11))
  readonly property real grilleHeight: Math.round(iconSize * 0.2)
  readonly property real ringSize: Math.round(iconSize * 0.66)

  // Grille: three short bars across the top.
  Row {
    anchors.top: parent.top
    anchors.horizontalCenter: parent.horizontalCenter
    spacing: Math.max(1, Math.round(root.iconSize / 9))
    Repeater {
      model: 3
      Rectangle {
        width: root.stroke
        height: root.grilleHeight
        radius: width / 2
        color: root.color
      }
    }
  }

  // Knob: a ring with a dot in the middle.
  Rectangle {
    anchors.bottom: parent.bottom
    anchors.horizontalCenter: parent.horizontalCenter
    width: root.ringSize
    height: root.ringSize
    radius: width / 2
    color: "transparent"
    border.width: root.stroke
    border.color: root.color
    antialiasing: true

    Rectangle {
      anchors.centerIn: parent
      width: Math.max(2, Math.round(root.ringSize * 0.28))
      height: width
      radius: width / 2
      color: root.color
      antialiasing: true
    }
  }
}
