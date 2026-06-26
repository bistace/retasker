import QtQuick

// Parent picker: choose which top-level todo to nest the selected one under.
// `app` is the viewer root, holding nestChildBase/nestChildText and the
// parentCandidates/chooseParent actions. Opening is driven by nestChildBase.
ModalSheet {
    id: picker

    property var app

    open: app.nestChildBase !== ""
    // Near-fullscreen: the candidate list can be long, so use the whole screen
    // (a thin margin keeps the card border visible). ModalSheet caps the height.
    cardWidth: picker.width - 24
    cardHeight: picker.height

    Text {
        id: title
        anchors {
            top: parent.top
            topMargin: 40
            left: parent.left
            leftMargin: 48
            right: parent.right
            rightMargin: 120
        }
        text: "Make a subtask of…"
        font.pixelSize: 44
        font.bold: true
        color: "black"
        elide: Text.ElideRight
    }

    CloseGlyph {
        anchors {
            top: parent.top
            topMargin: 40
            right: parent.right
            rightMargin: 44
        }
        onClicked: picker.app.nestChildBase = ""
    }

    // The todo being nested, for context.
    Text {
        id: subtask
        anchors {
            top: title.bottom
            topMargin: 16
            left: parent.left
            leftMargin: 48
            right: parent.right
            rightMargin: 48
        }
        text: "“" + picker.app.nestChildText + "”"
        font.pixelSize: 30
        font.italic: true
        color: "black"
        wrapMode: Text.WordWrap
        maximumLineCount: 2
        elide: Text.ElideRight
    }

    ListView {
        id: candidates
        anchors {
            top: subtask.bottom
            topMargin: 28
            left: parent.left
            leftMargin: 48
            right: parent.right
            rightMargin: 48
            bottom: cancel.top
            bottomMargin: 28
        }
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        spacing: 12
        // Rebuilt each time the picker opens (a fresh open swaps the child base).
        model: picker.app.nestChildBase !== "" ? picker.app.parentCandidates() : []

        delegate: Rectangle {
            id: cand
            required property var modelData
            width: candidates.width
            height: 96
            color: "white"
            border.color: "black"
            border.width: 2

            Text {
                anchors {
                    left: parent.left
                    leftMargin: 24
                    right: when.left
                    rightMargin: 16
                    verticalCenter: parent.verticalCenter
                }
                text: cand.modelData.label
                font.pixelSize: 34
                color: "black"
                elide: Text.ElideRight
            }

            Text {
                id: when
                anchors {
                    right: parent.right
                    rightMargin: 24
                    verticalCenter: parent.verticalCenter
                }
                text: cand.modelData.dateText
                font.pixelSize: 26
                color: "black"
            }

            MouseArea {
                anchors.fill: parent
                onClicked: picker.app.chooseParent(cand.modelData.base)
            }
        }
    }

    Text {
        anchors.centerIn: candidates
        visible: candidates.count === 0
        text: "No other todos to nest under"
        font.pixelSize: 32
        color: "black"
    }

    FlatButton {
        id: cancel
        anchors {
            bottom: parent.bottom
            bottomMargin: 40
            horizontalCenter: parent.horizontalCenter
        }
        width: 300
        text: "Cancel"
        onClicked: picker.app.nestChildBase = ""
    }
}
