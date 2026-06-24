import QtQuick

// Edit-todo modal: modify a todo's text. Saving writes <base>.txt through the
// transcribe path; for an image todo that also drops the .png (a manual
// transcription). `app` is the viewer root, which seeds and reads the text via
// the `field` alias (app.editFromMenu/saveEdit/closeEdit drive it). Text entry
// relies on the device on-screen keyboard appearing on focus.
ModalSheet {
    id: editSheet

    property var app
    property alias field: editField

    open: app.editName !== ""
    cardWidth: 820
    cardHeight: 720

    Text {
        id: editTitle
        anchors {
            top: parent.top
            topMargin: 40
            left: parent.left
            leftMargin: 48
        }
        text: "Edit todo"
        font.pixelSize: 44
        font.bold: true
        color: "black"
    }

    Rectangle {
        id: editBox
        anchors {
            top: editTitle.bottom
            topMargin: 28
            left: parent.left
            leftMargin: 48
            right: parent.right
            rightMargin: 48
            bottom: editButtons.top
            bottomMargin: 40
        }
        color: "white"
        border.color: "black"
        border.width: 3

        Flickable {
            anchors {
                fill: parent
                margins: 20
            }
            contentWidth: width
            contentHeight: editField.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            TextEdit {
                id: editField
                width: parent.width
                font.pixelSize: 38
                color: "black"
                wrapMode: TextEdit.Wrap
                selectByMouse: false
            }
        }

        Text {
            anchors {
                left: parent.left
                leftMargin: 20
                top: parent.top
                topMargin: 20
            }
            visible: editField.text === ""
            text: "Type the todo text"
            font.pixelSize: 38
            color: "#888888"
        }
    }

    Row {
        id: editButtons
        anchors {
            bottom: parent.bottom
            bottomMargin: 40
            horizontalCenter: parent.horizontalCenter
        }
        spacing: 40

        FlatButton {
            text: "Cancel"
            onClicked: editSheet.app.closeEdit()
        }

        FlatButton {
            primary: true
            enabled: editField.text.trim() !== ""
            text: "Save"
            onClicked: editSheet.app.saveEdit()
        }
    }
}
