import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The keypad drawn as the device itself, with each control's assignment beside it.
Item {
  id: device
  required property var host
  implicitHeight: deviceBody.height + Style.space(8)
  height: implicitHeight

  readonly property real bodyWidth: Style.space(104)
  readonly property real bodyHeight: Style.space(334)
  readonly property real knobSize: Style.space(80)
  readonly property real knobCenterY: Style.space(92)
  readonly property real keySize: Style.space(40)
  readonly property real keyGap: Style.space(12)
  readonly property real keysTop: Style.space(150)
  readonly property real labelX: bodyWidth + Style.space(26)
  readonly property real knobRowStep: Style.space(22)
  readonly property real knobEdge: deviceBody.x + bodyWidth / 2 + knobSize / 2
  readonly property real keyEdge: deviceBody.x + bodyWidth / 2 + keySize / 2

  function keyCenterY(index) {
    return keysTop + Style.space(10) + keySize / 2 + index * (keySize + keyGap)
  }

  Rectangle {
    id: deviceBody
    x: Style.space(2)
    y: Style.space(4)
    width: device.bodyWidth
    height: device.bodyHeight
    radius: Style.space(20)
    color: Qt.alpha(host.foreground, 0.06)
    border.width: Math.max(1, Style.space(1))
    border.color: Qt.alpha(host.foreground, 0.28)

    Text {
      anchors.top: parent.top
      anchors.topMargin: Style.space(8)
      anchors.horizontalCenter: parent.horizontalCenter
      textFormat: Text.PlainText
      text: "VibeKey"
      color: host.faint
      font.family: host.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
    }

    Row {
      anchors.top: parent.top
      anchors.topMargin: Style.space(26)
      anchors.horizontalCenter: parent.horizontalCenter
      spacing: Style.space(5)
      Repeater {
        model: 6
        Rectangle { width: Style.space(4); height: Style.space(14); radius: width / 2; color: Qt.alpha(host.foreground, 0.3) }
      }
    }

    Rectangle {
      id: knob
      readonly property bool lit: host.isKnobTurn(host.flashing) || host.flashing === "knob"
      readonly property bool editingThis: host.isKnobTurn(host.editing) || host.editing === "knob"
      x: (parent.width - width) / 2
      y: device.knobCenterY - height / 2
      width: device.knobSize
      height: width
      radius: width / 2
      color: Qt.alpha(host.foreground, editingThis ? 0.2 : 0.1)
      border.width: Math.max(2, Style.space(3))
      border.color: lit ? host.accent : (editingThis ? Qt.alpha(host.accent, 0.8) : Qt.alpha(host.foreground, 0.4))
      rotation: host.knobAngle
      Behavior on rotation { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
      Behavior on border.color { ColorAnimation { duration: 120 } }

      Rectangle {
        anchors.horizontalCenter: parent.horizontalCenter
        y: Style.space(8)
        width: Math.max(2, Style.space(3))
        height: Style.space(12)
        radius: width / 2
        color: knob.lit ? host.accent : Qt.alpha(host.foreground, 0.6)
      }

      Repeater {
        model: 12
        Rectangle {
          required property int index
          width: Math.max(1, Style.space(1))
          height: Style.space(4)
          x: knob.width / 2 - width / 2
          y: Style.space(5)
          transform: Rotation { origin.x: width / 2; origin.y: knob.height / 2 - Style.space(5); angle: index * 30 }
          color: Qt.alpha(host.foreground, 0.18)
          visible: index !== 0
        }
      }

      MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: host.toggleEditor("knob")
      }
    }

    Rectangle {
      x: (parent.width - width) / 2
      y: device.knobCenterY - height / 2
      width: Style.space(10)
      height: width
      radius: width / 2
      color: host.flashing === "knob" ? host.accent : Qt.alpha(host.foreground, host.editing === "knob" ? 0.5 : 0.2)
      Behavior on color { ColorAnimation { duration: 120 } }
    }

    Rectangle {
      x: parent.width - width / 2
      y: device.knobCenterY - height / 2
      width: Style.space(5)
      height: Style.space(18)
      radius: width / 2
      color: Qt.alpha(host.foreground, 0.35)
    }

    Rectangle {
      x: (parent.width - width) / 2
      y: device.keysTop
      width: device.keySize + Style.space(20)
      height: device.keySize * 3 + device.keyGap * 2 + Style.space(20)
      radius: Style.space(10)
      color: "transparent"
      border.width: Math.max(1, Style.space(1))
      border.color: Qt.alpha(host.accent, 0.45)
    }

    KeyCap { host: device.host; controlKey: "key1"; icon: "󰍬"; x: (parent.width - width) / 2; y: device.keyCenterY(0) - height / 2 }
    KeyCap { host: device.host; controlKey: "key2"; icon: "󰄬"; x: (parent.width - width) / 2; y: device.keyCenterY(1) - height / 2 }
    KeyCap { host: device.host; controlKey: "key3"; icon: "󰅖"; x: (parent.width - width) / 2; y: device.keyCenterY(2) - height / 2 }
  }

  Repeater {
    model: [
      { key: "knob_turn", y: deviceBody.y + device.knobCenterY - device.knobRowStep, from: device.knobEdge },
      { key: "knob", y: deviceBody.y + device.knobCenterY + device.knobRowStep, from: device.knobEdge },
      { key: "key1", y: deviceBody.y + device.keyCenterY(0), from: device.keyEdge },
      { key: "key2", y: deviceBody.y + device.keyCenterY(1), from: device.keyEdge },
      { key: "key3", y: deviceBody.y + device.keyCenterY(2), from: device.keyEdge }
    ]
    delegate: Rectangle {
      required property var modelData
      readonly property bool hot: host.editing === modelData.key
        || host.flashing === modelData.key
        || (modelData.key === "knob_turn" && host.isKnobTurn(host.flashing))
      x: modelData.from + Style.space(6)
      y: modelData.y
      width: device.labelX - x - Style.space(4)
      height: Math.max(1, Style.space(1))
      color: hot ? host.accent : Qt.alpha(host.foreground, 0.22)
      Rectangle {
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(5)
        height: width
        radius: width / 2
        color: parent.color
      }
    }
  }

  ControlLabel { host: device.host; controlKey: "knob_turn"; x: device.labelX; y: deviceBody.y + device.knobCenterY - device.knobRowStep - height / 2; width: device.width - device.labelX }
  ControlLabel { host: device.host; controlKey: "knob";      x: device.labelX; y: deviceBody.y + device.knobCenterY + device.knobRowStep - height / 2; width: device.width - device.labelX }
  ControlLabel { host: device.host; controlKey: "key1"; x: device.labelX; y: deviceBody.y + device.keyCenterY(0) - height / 2; width: device.width - device.labelX }
  ControlLabel { host: device.host; controlKey: "key2"; x: device.labelX; y: deviceBody.y + device.keyCenterY(1) - height / 2; width: device.width - device.labelX }
  ControlLabel { host: device.host; controlKey: "key3"; x: device.labelX; y: deviceBody.y + device.keyCenterY(2) - height / 2; width: device.width - device.labelX }
}
