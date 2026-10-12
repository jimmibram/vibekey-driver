import QtQuick

// The top of the Vibekey as a glyph: the rounded end of the slab, open at the
// bottom, with the microphone grille and the knob (a ring with a dot) inside.
// Drawn with rectangles so it stays crisp at bar size.
Item {
  id: root

  property real iconSize: 16
  property color color: "white"

  // The keypad is a tall slab: narrower than it is high.
  readonly property real bodyWidth: Math.round(iconSize * 0.8)
  readonly property real stroke: Math.max(1, Math.round(iconSize / 14))
  readonly property real grilleTop: Math.round(iconSize * 0.18)
  readonly property real grilleHeight: Math.max(2, Math.round(iconSize * 0.17))
  readonly property real ringSize: Math.round(bodyWidth * 0.66)
  readonly property real ringTop: Math.round(iconSize * 0.44)

  width: bodyWidth
  height: iconSize
  implicitWidth: bodyWidth
  implicitHeight: iconSize
  clip: true  // cuts the outline off at the bottom: only the top of the slab shows

  // The slab's rounded top and its sides.
  Rectangle {
    x: 0
    y: 0
    width: root.bodyWidth
    height: root.iconSize * 1.6
    radius: Math.round(root.bodyWidth * 0.3)
    color: "transparent"
    border.width: root.stroke
    border.color: root.color
    antialiasing: true
  }

  // Grille: four short bars under the top edge.
  Row {
    anchors.top: parent.top
    anchors.topMargin: root.grilleTop
    anchors.horizontalCenter: parent.horizontalCenter
    spacing: Math.max(1, Math.round(root.iconSize / 14))
    Repeater {
      model: 4
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
    y: root.ringTop
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
      width: Math.max(2, Math.round(root.ringSize * 0.3))
      height: width
      radius: width / 2
      color: root.color
      antialiasing: true
    }
  }
}
