import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The fake herdr window: scribbled output that the knob scrolls, a sidebar of
// agents, and a status line showing what the last key did. Pure decoration
// driven by the panel's simulation state.
Rectangle {
  id: sim
  required property var host
  signal clicked()
  radius: Style.space(10)
  color: Qt.alpha(host.foreground, 0.05)
  border.width: Math.max(1, Style.space(1))
  border.color: Qt.alpha(host.foreground, 0.22)
  clip: true

  readonly property real pad: Style.space(10)
  readonly property real lineStep: Style.space(11)

  // Title bar: window dots, a scribbled title, a recording light.
  Item {
    id: simTitle
    x: sim.pad
    y: 0
    width: parent.width - sim.pad * 2
    height: Style.space(24)

    Row {
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(5)
      Repeater {
        model: 3
        Rectangle { width: Style.space(7); height: width; radius: width / 2; color: Qt.alpha(host.foreground, 0.3) }
      }
    }

    Scribble { ink: host.foreground; anchors.centerIn: parent; seed: 99; maxWidth: parent.width * 0.4 }

    Rectangle {
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(8)
      height: width
      radius: width / 2
      color: host.urgent
      opacity: host.simControl === "key1" ? 1 : 0
      Behavior on opacity { NumberAnimation { duration: 150 } }
    }
  }

  Rectangle {
    x: 0; y: simTitle.height
    width: parent.width
    height: Math.max(1, Style.space(1))
    color: Qt.alpha(host.foreground, 0.15)
  }

  // Sidebar: the agents, one of them selected.
  Column {
    id: simSidebar
    x: sim.pad
    y: simTitle.height + Style.space(10)
    width: Style.space(66)
    spacing: Style.space(8)

    Repeater {
      model: host.simAgents
      Rectangle {
        required property int index
        width: simSidebar.width
        height: Style.space(16)
        radius: Style.space(4)
        color: index === host.simAgent ? Qt.alpha(host.accent, 0.25) : "transparent"
        Behavior on color { ColorAnimation { duration: 150 } }
        Scribble { ink: host.foreground;
          anchors.verticalCenter: parent.verticalCenter
          x: Style.space(6)
          seed: 300 + index
          maxWidth: parent.width - Style.space(12)
          prompt: index === host.simAgent
        }
      }
    }
  }

  Rectangle {
    x: simSidebar.x + simSidebar.width + sim.pad
    y: simTitle.height
    width: Math.max(1, Style.space(1))
    height: parent.height - simTitle.height - simStatusBar.height
    color: Qt.alpha(host.foreground, 0.15)
  }

  // Main pane: scribbled output that the knob scrolls.
  Item {
    id: simMain
    x: simSidebar.x + simSidebar.width + sim.pad * 2
    y: simTitle.height + Style.space(8)
    width: parent.width - x - sim.pad
    height: parent.height - y - simStatusBar.height - Style.space(6)
    clip: true

    readonly property int lineCount: 48
    readonly property real total: lineCount * sim.lineStep
    // Knob right scrolls up: earlier lines come down into view.
    readonly property real wrapped: ((host.knobPosition * sim.lineStep) % total + total) % total

    Item {
      y: -simMain.total + simMain.wrapped
      width: parent.width
      height: simMain.total * 2

      Repeater {
        model: simMain.lineCount * 2
        Item {
          required property int index
          readonly property int line: index % simMain.lineCount
          readonly property bool prompt: line % 9 === 0
          y: index * sim.lineStep
          width: parent.width
          height: sim.lineStep

          Rectangle {
            visible: parent.prompt
            x: 0
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(5)
            height: width
            radius: Style.space(1)
            color: host.accent
          }

          Scribble { ink: host.foreground;
            x: parent.prompt ? Style.space(9) : (parent.line % 4 === 2 ? Style.space(12) : 0)
            anchors.verticalCenter: parent.verticalCenter
            seed: parent.line
            maxWidth: parent.width - x
            prompt: parent.prompt
          }
        }
      }
    }
  }

  // Status line: what the last key did, or scribbles when idle.
  Rectangle {
    id: simStatusBar
    x: 0
    y: parent.height - height
    width: parent.width
    height: Style.space(22)
    color: Qt.alpha(host.foreground, 0.07)

    Row {
      anchors.verticalCenter: parent.verticalCenter
      x: sim.pad
      spacing: Style.space(8)
      visible: host.simStatus === ""
      Scribble { ink: host.foreground; anchors.verticalCenter: parent.verticalCenter; seed: 501; maxWidth: Style.space(70) }
      Scribble { ink: host.foreground; anchors.verticalCenter: parent.verticalCenter; seed: 502; maxWidth: Style.space(50) }
    }

    Text {
      anchors.verticalCenter: parent.verticalCenter
      x: sim.pad
      width: parent.width - sim.pad * 2
      visible: host.simStatus !== ""
      textFormat: Text.PlainText
      text: host.simStatus
      color: host.accent
      font.family: host.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      elide: Text.ElideRight
    }
  }

  MouseArea {
    anchors.fill: parent
    cursorShape: Qt.PointingHandCursor
    onClicked: sim.clicked()
  }
}
