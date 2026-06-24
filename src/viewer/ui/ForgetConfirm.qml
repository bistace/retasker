import QtQuick

// Forget-note confirmation: removing a row only drops reTasker's local record;
// the notebook (if it still exists) is untouched. Stacks above the day-notes
// sheet. `app` is the viewer root, holding pendingForget* and confirmForget.
ModalSheet {
    id: forgetConfirm

    property var app

    open: app.pendingForgetKind !== ""
    cardWidth: 720
    cardHeight: 520

    Text {
        id: forgetTitle
        anchors {
            top: parent.top
            topMargin: 48
            horizontalCenter: parent.horizontalCenter
        }
        text: "Remove from list?"
        font.pixelSize: 46
        font.bold: true
        color: "black"
    }

    Text {
        id: forgetName
        anchors {
            top: forgetTitle.bottom
            topMargin: 36
            left: parent.left
            leftMargin: 48
            right: parent.right
            rightMargin: 48
        }
        text: forgetConfirm.app.pendingForgetLabel
        font.pixelSize: 40
        color: "black"
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
        maximumLineCount: 2
        elide: Text.ElideRight
    }

    Text {
        anchors {
            top: forgetName.bottom
            topMargin: 28
            left: parent.left
            leftMargin: 48
            right: parent.right
            rightMargin: 48
        }
        text: "This only removes it from reTasker. The notebook itself is not deleted."
        font.pixelSize: 28
        color: "black"
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
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
            onClicked: forgetConfirm.app.pendingForgetKind = ""
        }

        FlatButton {
            primary: true
            text: "Remove"
            onClicked: forgetConfirm.app.confirmForget()
        }
    }
}
