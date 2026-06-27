import QtQuick

// Delete-confirmation modal: long-pressing a row sets app.pendingDelete, which
// opens this. `app` is the viewer root, holding the pending* preview state and
// the confirmDelete action.
ModalSheet {
    id: confirm

    property var app

    open: app.pendingDelete !== ""
    cardWidth: 720
    cardHeight: 560

    Text {
        id: confirmTitle
        anchors {
            top: parent.top
            topMargin: 48
            horizontalCenter: parent.horizontalCenter
        }
        text: "Delete this todo?"
        font.pixelSize: 46
        font.bold: true
        color: "black"
    }

    // Preview of the todo being deleted -- the text, or the snippet image.
    Rectangle {
        id: preview
        anchors {
            top: confirmTitle.bottom
            topMargin: 32
            left: parent.left
            leftMargin: 48
            right: parent.right
            rightMargin: 48
        }
        height: 180
        color: "white"
        border.color: "black"
        border.width: 2

        Text {
            anchors {
                fill: parent
                margins: 20
            }
            visible: confirm.app.pendingKind === "text"
            text: confirm.app.pendingText
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
            visible: confirm.app.pendingKind === "image"
            source: confirm.app.pendingKind === "image" ? confirm.app.pendingUrl : ""
            fillMode: Image.PreserveAspectFit
            smooth: true
            asynchronous: true
        }
    }

    Text {
        anchors {
            top: preview.bottom
            topMargin: 24
            horizontalCenter: parent.horizontalCenter
        }
        text: "This cannot be undone."
        font.pixelSize: 30
        color: "black"
    }

    Row {
        anchors {
            bottom: parent.bottom
            bottomMargin: 48
            horizontalCenter: parent.horizontalCenter
        }
        spacing: 40

        FlatButton {
            text: "Cancel"
            onClicked: confirm.app.pendingDelete = ""
        }

        FlatButton {
            primary: true
            text: "Delete"
            onClicked: confirm.app.confirmDelete()
        }
    }
}
