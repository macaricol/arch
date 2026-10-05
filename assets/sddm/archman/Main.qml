// ARCHMAN login screen: the installer's unlock screen (lib/prompt.sh's
// unlock_screen) as an SDDM theme. logo.png, lock.png and dot.png are renders
// of the console font (tools/make-sddm-theme.py), shown at a whole-number
// scale with smoothing off, so they keep the console's pixels; the layout is
// the unlock screen's, measured in console cells (8 x 16 at scale 1).
// Colours and tagline: theme.conf.
import QtQuick 2.15

Rectangle {
  id: root
  width: 1280
  height: 800
  color: config.background

  // The logo at about half the screen's width, as on the console.
  property int s: Math.max(1, Math.round(width * 0.5 / Math.max(1, logo.sourceSize.width)))
  property int cellW: 8 * s
  property int cellH: 16 * s
  property bool failed: false
  // The last user, or on the very first login (nobody yet) the only one.
  property string user: userModel.lastUser !== "" ? userModel.lastUser
                                                  : userModel.data(userModel.index(0, 0), Qt.UserRole + 1)

  function login() {
    sddm.login(root.user, password.text, sessionModel.lastIndex)
  }

  Connections {
    target: sddm
    function onLoginFailed() {
      root.failed = true
      password.text = ""
      password.forceActiveFocus()
    }
  }

  Column {
    anchors.centerIn: parent

    Image {
      id: logo
      source: "logo.png"
      smooth: false
      width: sourceSize.width * root.s
      height: sourceSize.height * root.s
      anchors.horizontalCenter: parent.horizontalCenter
    }
    Item { width: 1; height: root.cellH }
    Text {
      text: config.tagline
      color: config.taglineColor
      font.family: "monospace"
      font.pixelSize: root.cellH * 0.8
      anchors.horizontalCenter: parent.horizontalCenter
    }
    Item { width: 1; height: root.cellH * 2 }

    // The padlock (5 x 3 cells), a cell's gap, the box (38 x 3 cells).
    Row {
      spacing: root.cellW
      anchors.horizontalCenter: parent.horizontalCenter

      Image {
        source: "lock.png"
        smooth: false
        width: sourceSize.width * root.s
        height: sourceSize.height * root.s
      }

      Rectangle {
        width: root.cellW * 38
        height: root.cellH * 3
        color: "transparent"
        border.color: config.border
        border.width: root.s

        // A dot per character typed, a cell each, from the box's second cell.
        Row {
          x: root.cellW * 2
          anchors.verticalCenter: parent.verticalCenter
          Repeater {
            model: Math.min(password.text.length, 34)
            Image {
              source: "dot.png"
              smooth: false
              width: root.cellW
              height: root.cellH
            }
          }
        }

        TextInput {
          id: password
          anchors.fill: parent
          echoMode: TextInput.Password
          color: "transparent"
          selectionColor: "transparent"
          selectedTextColor: "transparent"
          cursorDelegate: Item {}
          focus: true
          onTextChanged: if (text.length > 0) root.failed = false
          Keys.onReturnPressed: root.login()
          Keys.onEnterPressed: root.login()
        }
      }
    }

    Item { width: 1; height: root.cellH }
    Text {
      text: root.failed ? "Wrong password, try again" : "Enter your password to log in"
      color: root.failed ? config.error : config.hint
      font.family: "monospace"
      font.pixelSize: root.cellH * 0.8
      anchors.horizontalCenter: parent.horizontalCenter
    }
  }

  Component.onCompleted: password.forceActiveFocus()
}
