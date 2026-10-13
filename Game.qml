import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The back of the mock window: a box-breaking game. The knob drives the paddle,
// the three keys fire balls carrying their own symbols.
Rectangle {
  id: game
  required property var host
  signal exit()
  radius: Style.space(10)
  color: Qt.alpha(host.foreground, 0.05)
  border.width: Math.max(1, Style.space(1))
  border.color: Qt.alpha(host.foreground, 0.22)
  clip: true

  readonly property real pad: Style.space(10)
  readonly property real titleH: Style.space(24)
  readonly property int cols: 7
  // Each level adds a row of boxes, up to six, and some speed.
  readonly property int rows: Math.min(6, 3 + level)
  readonly property real boxGap: Style.space(4)
  readonly property real boxH: Style.space(14)
  readonly property real boxTop: titleH + Style.space(12)
  readonly property real boxW: (width - pad * 2 - boxGap * (cols - 1)) / cols
  readonly property real paddleW: Style.space(60)
  readonly property real paddleH: Style.space(6)
  readonly property real paddleY: height - Style.space(18)
  readonly property real notch: Style.space(10)   // paddle travel per knob click
  readonly property real ballR: Style.space(6)
  readonly property real speed: Style.spaceReal(190) * (1 + 0.2 * (level - 1)) // per second, a fifth faster each level
  readonly property var icons: ({ key1: "\u{F036C}", key2: "\u{F012C}", key3: "\u{F0156}" })

  property var alive: []
  property int boxesLeft: 0
  property int shots: 0
  property int level: 1
  property int score: 0
  property int lastBonus: 0
  property bool over: false
  property int knobBase: 0
  property real lastTick: 0
  // The knob's running notch count, measured from where the game started.
  readonly property real paddleX: Math.max(0, Math.min(width - paddleW,
    (width - paddleW) / 2 + (host.knobPosition - knobBase) * notch))

  // A fresh game from level one.
  function reset() {
    level = 1
    score = 0
    newRound()
  }

  function newRound() {
    var a = []
    for (var i = 0; i < cols * rows; i++) a.push(true)
    alive = a
    boxesLeft = cols * rows
    shots = 0
    lastBonus = 0
    over = false
    balls.clear()
    knobBase = host.knobPosition
    lastTick = 0
  }

  // Points per box: the top row pays most, and every level pays more.
  function pointsFor(index) {
    return 10 * (rows - Math.floor(index / cols)) * level
  }

  // key1 fires up-left, key2 straight up, key3 up-right.
  function fire(key) {
    if (over) { reset(); return }
    if (boxesLeft === 0) { level++; newRound(); return }
    var a = (key === "key1" ? -30 : key === "key3" ? 30 : 0) * Math.PI / 180
    balls.append({
      x: paddleX + paddleW / 2, y: paddleY - ballR - 1,
      vx: speed * Math.sin(a), vy: -speed * Math.cos(a),
      icon: icons[key] || ""
    })
    shots++
  }

  function step() {
    var now = Date.now()
    var dt = lastTick > 0 ? Math.min(0.04, (now - lastTick) / 1000) : 0.016
    lastTick = now
    var r = ballR, hit = false
    var live = []
    var lost = false
    for (var i = 0; i < balls.count; i++) {
      var b = balls.get(i)
      var x = b.x + b.vx * dt, y = b.y + b.vy * dt, vx = b.vx, vy = b.vy
      if (x < r) { x = r; vx = Math.abs(vx) }
      if (x > width - r) { x = width - r; vx = -Math.abs(vx) }
      if (y < titleH + r) { y = titleH + r; vy = Math.abs(vy) }
      // Paddle: where the ball lands along it sets the bounce angle.
      if (vy > 0 && y + r >= paddleY && b.y + r <= paddleY + paddleH
          && x >= paddleX - r && x <= paddleX + paddleW + r) {
        var rel = Math.max(-1, Math.min(1, (x - (paddleX + paddleW / 2)) / (paddleW / 2)))
        var ang = rel * 60 * Math.PI / 180
        vx = speed * Math.sin(ang); vy = -speed * Math.cos(ang)
        y = paddleY - r
      }
      // Boxes: the shallower overlap tells which face was struck.
      if (y - r < boxTop + rows * (boxH + boxGap)) {
        for (var k = 0; k < alive.length; k++) {
          if (!alive[k]) continue
          var bx = pad + (k % cols) * (boxW + boxGap)
          var by = boxTop + Math.floor(k / cols) * (boxH + boxGap)
          if (x + r <= bx || x - r >= bx + boxW || y + r <= by || y - r >= by + boxH) continue
          alive[k] = false; boxesLeft--; hit = true
          score += pointsFor(k)
          if (boxesLeft === 0) {
            // Clearing pays a bonus that shrinks with every shot it took.
            lastBonus = Math.max(0, 100 * level - 10 * (shots - 1))
            score += lastBonus
          }
          var ox = Math.min(x + r - bx, bx + boxW - (x - r))
          var oy = Math.min(y + r - by, by + boxH - (y - r))
          if (ox < oy) { vx = -vx; x += vx > 0 ? ox : -ox }
          else { vy = -vy; y += vy > 0 ? oy : -oy }
          break
        }
      }
      if (y - r > height) { lost = true; break }  // missed by the bar: game over
      live.push({ x: x, y: y, vx: vx, vy: vy, icon: b.icon })
    }
    if (lost) {
      over = true
      balls.clear()
      if (hit) alive = alive.slice()
      return
    }
    // Balls bounce off each other: equal masses swap their speed
    // along the line between them, and are pushed apart so they
    // don't stick.
    for (var p = 0; p < live.length; p++) {
      for (var q = p + 1; q < live.length; q++) {
        var A = live[p], B = live[q]
        var dx = B.x - A.x, dy = B.y - A.y
        var d = Math.sqrt(dx * dx + dy * dy)
        if (d >= 2 * r || d === 0) continue
        var nx = dx / d, ny = dy / d
        var along = (B.vx - A.vx) * nx + (B.vy - A.vy) * ny
        if (along < 0) {  // closing in, not already parting
          A.vx += along * nx; A.vy += along * ny
          B.vx -= along * nx; B.vy -= along * ny
        }
        var push = (2 * r - d) / 2 + 0.5
        A.x -= nx * push; A.y -= ny * push
        B.x += nx * push; B.y += ny * push
      }
    }
    for (var m = 0; m < live.length; m++) {
      if (m < balls.count) balls.set(m, live[m])
      else balls.append(live[m])
    }
    while (balls.count > live.length) balls.remove(balls.count - 1)
    if (hit) alive = alive.slice()
  }

  ListModel { id: balls }

  Timer {
    interval: 16
    repeat: true
    running: host.gameOn && host.opened && host.editing === "" && balls.count > 0
    onTriggered: game.step()
  }

  Component.onCompleted: reset()

  // Title bar, same dots as the window it is the back of.
  Item {
    x: game.pad
    width: parent.width - game.pad * 2
    height: game.titleH

    Row {
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(5)
      Repeater {
        model: 3
        Rectangle { width: Style.space(7); height: width; radius: width / 2; color: Qt.alpha(host.foreground, 0.3) }
      }
    }

    Text {
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: "LEVEL " + game.level
      color: host.faint
      font.family: host.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
    }

    Text {
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: game.score + " pts"
      color: host.foreground
      font.family: host.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
    }
  }

  Rectangle {
    x: 0; y: game.titleH
    width: parent.width
    height: Math.max(1, Style.space(1))
    color: Qt.alpha(host.foreground, 0.15)
  }

  Repeater {
    model: game.cols * game.rows
    Rectangle {
      required property int index
      x: game.pad + (index % game.cols) * (game.boxW + game.boxGap)
      y: game.boxTop + Math.floor(index / game.cols) * (game.boxH + game.boxGap)
      width: game.boxW
      height: game.boxH
      radius: Style.space(3)
      // Like the window's scribbles: foreground, fading row by row.
      color: Qt.alpha(host.foreground, 0.5 - Math.floor(index / game.cols) * 0.06)
      opacity: game.alive[index] ? 1 : 0
      scale: game.alive[index] ? 1 : 1.6
      Behavior on opacity { NumberAnimation { duration: 180 } }
      Behavior on scale { NumberAnimation { duration: 180 } }
    }
  }

  Repeater {
    model: balls
    Rectangle {
      required property var model
      x: model.x - width / 2
      y: model.y - width / 2
      width: game.ballR * 2
      height: width
      radius: width / 2
      color: host.accent
      Text {
        anchors.centerIn: parent
        textFormat: Text.PlainText
        text: model.icon
        color: Color.popups.background
        font.family: host.fontFamily
        font.pixelSize: game.ballR * 1.5
      }
    }
  }

  Rectangle {
    x: game.paddleX
    y: game.paddleY
    width: game.paddleW
    height: game.paddleH
    radius: height / 2
    color: host.foreground
    Behavior on x { NumberAnimation { duration: 50 } }
  }

  Text {
    anchors.centerIn: parent
    width: parent.width - game.pad * 4
    visible: balls.count === 0 && !game.over
    textFormat: Text.PlainText
    text: game.boxesLeft === 0
      ? "Level " + game.level + " cleared in " + game.shots + (game.shots === 1 ? " shot" : " shots")
        + (game.lastBonus > 0 ? ", +" + game.lastBonus + " bonus" : "") + ". Press a key for level " + (game.level + 1) + "."
      : (game.score === 0 && game.level === 1
        ? "Turn the knob to move the bar, press a key to fire. The knob press starts over; a click turns the window back."
        : game.boxesLeft + " to go. Press a key to fire.")
    color: host.faint
    font.family: host.fontFamily
    font.pixelSize: Style.font.caption
    horizontalAlignment: Text.AlignHCenter
    wrapMode: Text.WordWrap
  }

  // Shown when a ball gets past the bar.
  Rectangle {
    anchors.fill: parent
    visible: game.over
    color: Qt.alpha(Color.popups.background, 0.75)

    Rectangle {
      anchors.centerIn: parent
      width: Math.min(parent.width - game.pad * 4, Style.space(220))
      height: dialogCol.implicitHeight + game.pad * 2
      radius: Style.space(10)
      color: Color.popups.background
      border.width: Math.max(1, Style.space(1))
      border.color: Qt.alpha(host.foreground, 0.35)

      Column {
        id: dialogCol
        anchors.centerIn: parent
        width: parent.width - game.pad * 2
        spacing: Style.space(6)

        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: "GAME OVER"
          color: host.foreground
          font.family: host.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
          horizontalAlignment: Text.AlignHCenter
        }
        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: game.score + " pts on level " + game.level
          color: host.foreground
          font.family: host.fontFamily
          font.pixelSize: Style.font.caption
          horizontalAlignment: Text.AlignHCenter
          wrapMode: Text.WordWrap
        }
        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: "A ball got past the bar. Press a key to play again."
          color: host.faint
          font.family: host.fontFamily
          font.pixelSize: Style.font.caption
          horizontalAlignment: Text.AlignHCenter
          wrapMode: Text.WordWrap
        }
      }
    }
  }

  MouseArea {
    anchors.fill: parent
    cursorShape: Qt.PointingHandCursor
    onClicked: game.exit()
  }
}
