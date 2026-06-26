import QtQuick

// Long-press row action menu: Modify (or Transcribe, for an image) / Delete /
// Cancel. `app` is the viewer root, holding the menu* preview state and the
// editFromMenu/deleteFromMenu actions.
ModalSheet {
    id: rowMenu

    property var app

    open: app.menuName !== ""
    cardWidth: 720
    // The "Make subtask of…" action only applies to a childless todo, so the card
    // grows to fit it only then.
    cardHeight: app.menuChildCount === 0 ? 880 : 740

    // Preview of the todo being acted on — its text, or the snippet image.
    Rectangle {
        id: menuPreview
        anchors {
            top: parent.top
            topMargin: 48
            left: parent.left
            leftMargin: 48
            right: parent.right
            rightMargin: 48
        }
        height: 200
        color: "white"
        border.color: "black"
        border.width: 2

        Text {
            anchors {
                fill: parent
                margins: 20
            }
            visible: rowMenu.app.menuKind === "text"
            text: rowMenu.app.menuText
            font.pixelSize: 36
            color: "black"
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            wrapMode: Text.WordWrap
            maximumLineCount: 3
            elide: Text.ElideRight
        }

        Image {
            anchors {
                fill: parent
                margins: 16
            }
            visible: rowMenu.app.menuKind === "image"
            source: rowMenu.app.menuKind === "image" ? rowMenu.app.menuUrl : ""
            fillMode: Image.PreserveAspectFit
            smooth: true
            asynchronous: true
        }
    }

    Column {
        anchors {
            top: menuPreview.bottom
            topMargin: 40
            horizontalCenter: parent.horizontalCenter
        }
        spacing: 28

        // Modify a text todo; for an image, the same action is a manual
        // transcription, so it reads "Transcribe".
        FlatButton {
            width: 560
            primary: true
            text: rowMenu.app.menuKind === "image" ? "Transcribe" : "Modify"
            onClicked: rowMenu.app.editFromMenu()
        }

        // Nest this todo under another. Hidden once it has children of its own —
        // subtasks are one level deep, so a parent can't itself become a subtask.
        FlatButton {
            width: 560
            visible: rowMenu.app.menuChildCount === 0
            text: "Make subtask of…"
            onClicked: rowMenu.app.nestFromMenu()
        }

        FlatButton {
            width: 560
            text: "Delete"
            onClicked: rowMenu.app.deleteFromMenu()
        }

        FlatButton {
            width: 560
            text: "Cancel"
            onClicked: rowMenu.app.menuName = ""
        }
    }
}
