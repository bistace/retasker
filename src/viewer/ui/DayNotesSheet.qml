import QtQuick

// Day-notes modal. List mode browses/opens the selected day's notes (its main
// note plus any titled extras); new mode takes a title for a new one. `app` is
// the viewer root, holding addNoteDay/addSheetMode and the open/create/forget
// actions. Title entry relies on the device on-screen keyboard appearing on focus.
ModalSheet {
    id: addSheet

    property var app

    open: app.addNoteOpen
    cardWidth: 760
    cardHeight: 820

    // Leaving title entry (Back or close) has to drop the field's focus and hide
    // the input method explicitly; dropping focus alone leaves the on-screen
    // keyboard lingering over the calendar, same as the edit/add-todo sheets.
    function dismissKeyboard() {
        titleField.focus = false;
        Qt.inputMethod.hide();
    }

    Text {
        id: addTitle
        anchors {
            top: parent.top
            topMargin: 40
            left: parent.left
            leftMargin: 48
            right: parent.right
            rightMargin: 120
        }
        text: "Notes for " + addSheet.app.dayLabel(addSheet.app.addNoteDay)
        font.pixelSize: 44
        font.bold: true
        color: "black"
        elide: Text.ElideRight
    }

    // Dismiss the whole sheet.
    CloseGlyph {
        anchors {
            top: parent.top
            topMargin: 40
            right: parent.right
            rightMargin: 44
        }
        onClicked: {
            addSheet.dismissKeyboard();
            addSheet.app.addNoteOpen = false;
        }
    }

    // ---- List mode: the day's notes -----------------------------
    Item {
        visible: addSheet.app.addSheetMode === "list"
        anchors {
            top: addTitle.bottom
            topMargin: 24
            left: parent.left
            leftMargin: 48
            right: parent.right
            rightMargin: 48
            bottom: parent.bottom
            bottomMargin: 180
        }

        Text {
            id: listHint
            anchors {
                top: parent.top
                left: parent.left
            }
            text: existingList.count > 0 ? "Tap a note to open it" : "No notes for this day yet."
            font.pixelSize: 28
            color: "black"
        }

        ListView {
            id: existingList
            anchors {
                top: listHint.bottom
                topMargin: 16
                left: parent.left
                right: parent.right
                bottom: parent.bottom
            }
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            spacing: 12
            model: addSheet.app.dayNotes(addSheet.app.addNoteDay)
            delegate: Rectangle {
                id: noteRow
                required property var modelData
                width: existingList.width
                height: 76
                color: "white"
                border.color: "black"
                border.width: 2

                Text {
                    anchors {
                        left: parent.left
                        leftMargin: 20
                        right: removeBtn.left
                        rightMargin: 12
                        verticalCenter: parent.verticalCenter
                    }
                    text: noteRow.modelData.label
                    font.pixelSize: 32
                    font.bold: noteRow.modelData.kind === "day"
                    color: "black"
                    elide: Text.ElideRight
                }

                // Open the note (whole row except the remove button).
                MouseArea {
                    anchors {
                        left: parent.left
                        top: parent.top
                        bottom: parent.bottom
                        right: removeBtn.left
                    }
                    onClicked: {
                        if (noteRow.modelData.kind === "day")
                            addSheet.app.openDayNote(addSheet.app.addNoteDay);
                        else
                            addSheet.app.openExtraNote(addSheet.app.addNoteDay, noteRow.modelData.title);
                    }
                }

                // Forget a hand-deleted note (local record only).
                Item {
                    id: removeBtn
                    width: 76
                    anchors {
                        top: parent.top
                        bottom: parent.bottom
                        right: parent.right
                    }
                    Rectangle {
                        anchors {
                            left: parent.left
                            top: parent.top
                            topMargin: 14
                            bottomMargin: 14
                        }
                        width: 2
                        height: parent.height - 28
                        color: "black"
                    }
                    Rectangle {
                        anchors.centerIn: parent
                        width: 30
                        height: 5
                        radius: 2
                        color: "black"
                        rotation: 45
                    }
                    Rectangle {
                        anchors.centerIn: parent
                        width: 30
                        height: 5
                        radius: 2
                        color: "black"
                        rotation: -45
                    }
                    MouseArea {
                        anchors.fill: parent
                        onClicked: {
                            if (noteRow.modelData.kind === "day")
                                addSheet.app.askForget("day", "", noteRow.modelData.label);
                            else
                                addSheet.app.askForget("extra", noteRow.modelData.title, noteRow.modelData.label);
                        }
                    }
                }
            }
        }
    }

    // List-mode actions: start a new titled note, or open the day's main note.
    Row {
        visible: addSheet.app.addSheetMode === "list"
        anchors {
            bottom: parent.bottom
            bottomMargin: 40
            horizontalCenter: parent.horizontalCenter
        }
        spacing: 40

        FlatButton {
            width: 300
            fontSize: 38
            text: "+ New note"
            onClicked: {
                addSheet.app.addSheetMode = "new";
                titleField.text = "";
                titleField.forceActiveFocus();
            }
        }

        FlatButton {
            width: 300
            fontSize: 38
            primary: true
            text: addSheet.app.addNoteDay === addSheet.app.todayKey ? "Today's note" : "Day's note"
            onClicked: addSheet.app.openDayNote(addSheet.app.addNoteDay)
        }
    }

    // ---- New mode: title entry ----------------------------------
    Item {
        visible: addSheet.app.addSheetMode === "new"
        anchors {
            top: addTitle.bottom
            topMargin: 24
            left: parent.left
            leftMargin: 48
            right: parent.right
            rightMargin: 48
            bottom: parent.bottom
            bottomMargin: 180
        }

        Text {
            id: inputLabel
            anchors {
                top: parent.top
                left: parent.left
            }
            text: "New note title"
            font.pixelSize: 28
            color: "black"
        }

        Rectangle {
            id: inputBox
            anchors {
                top: inputLabel.bottom
                topMargin: 16
                left: parent.left
                right: parent.right
            }
            height: 92
            color: "white"
            border.color: "black"
            border.width: 3

            TextInput {
                id: titleField
                anchors {
                    fill: parent
                    leftMargin: 20
                    rightMargin: 20
                }
                font.pixelSize: 38
                color: "black"
                clip: true
                verticalAlignment: TextInput.AlignVCenter
                onAccepted: addSheet.app.createExtraNote(addSheet.app.addNoteDay, titleField.text)
            }

            Text {
                anchors {
                    left: parent.left
                    leftMargin: 20
                    verticalCenter: parent.verticalCenter
                }
                visible: titleField.text === ""
                text: "e.g. Standup, 1:1 with Alex"
                font.pixelSize: 38
                color: "#888888"
            }
        }
    }

    // New-mode actions: back to the list, or create the titled note.
    Row {
        visible: addSheet.app.addSheetMode === "new"
        anchors {
            bottom: parent.bottom
            bottomMargin: 40
            horizontalCenter: parent.horizontalCenter
        }
        spacing: 40

        FlatButton {
            text: "Back"
            onClicked: {
                addSheet.dismissKeyboard();
                addSheet.app.addSheetMode = "list";
            }
        }

        FlatButton {
            primary: true
            enabled: titleField.text.trim() !== ""
            text: "Create"
            onClicked: addSheet.app.createExtraNote(addSheet.app.addNoteDay, titleField.text)
        }
    }
}
