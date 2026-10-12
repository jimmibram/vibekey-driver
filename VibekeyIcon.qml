import QtQuick

// The top of the Vibekey as a glyph, inverted: a solid slab with the
// microphone grille and the knob (ring and dot) cut out of it in the
// background colour. Square top, sides running off the bottom edge.
Item {
  id: root

  property real iconSize: 16
  property color color: "white"
  property color background: "black"

  // The keypad is a tall slab: narrower than it is high.
  readonly property real bodyWidth: Math.round(iconSize * 0.8)
  readonly property real stroke: Math.max(1, Math.round(iconSize / 14))
  readonly property real grilleTop: Math.round(iconSize * 0.16)
  readonly property real grilleHeight: Math.max(2, Math.round(iconSize * 0.18))
  readonly property real ringSize: Math.round(bodyWidth * 0.66)
  readonly property real ringTop: Math.round(iconSize * 0.44)
  readonly property color cut: Qt.rgba(background.r, background.g, background.b, 1)

  width: bodyWidth
  height: iconSize
  implicitWidth: bodyWidth
  implicitHeight: iconSize

  // The slab.
  Rectangle {
    anchors.fill: parent
    color: root.color
  }

  // Grille: four short slots under the top edge.
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
        color: root.cut
      }
    }
  }

  // Knob: a ring cut out, with a dot cut out of its middle.
  Rectangle {
    y: root.ringTop
    anchors.horizontalCenter: parent.horizontalCenter
    width: root.ringSize
    height: root.ringSize
    radius: width / 2
    color: "transparent"
    border.width: root.stroke
    border.color: root.cut
    antialiasing: true

    Rectangle {
      anchors.centerIn: parent
      width: Math.max(2, Math.round(root.ringSize * 0.3))
      height: width
      radius: width / 2
      color: root.cut
      antialiasing: true
    }
  }
}
