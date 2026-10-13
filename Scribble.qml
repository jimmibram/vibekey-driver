import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui
import "Model.js" as Model

// A line of fake text: a rounded bar whose width looks like a sentence.
Rectangle {
  property color ink: "white"
  property int seed: 0
  property real maxWidth: 100
  property bool prompt: false
  height: Style.space(5)
  radius: height / 2
  width: Math.round(maxWidth * (0.25 + 0.7 * Model.noise(seed)))
  color: Qt.alpha(ink, prompt ? 0.5 : 0.28)
}
