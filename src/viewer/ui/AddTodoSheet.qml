import QtQuick

// Add-todo modal: type a todo instead of capturing it. The date is fixed to the
// active day in calendar view; in list view the embedded month grid picks it.
// `app` is the viewer root, which reads the text via the `field` alias
// (app.openAddTodo/saveAddTodo/closeAddTodo drive it). Text entry relies on the
// device on-screen keyboard appearing when the field gains focus.
ModalSheet {
    id: addTodoSheet

    property var app
    property alias field: addField

    open: app.addTodoOpen
    cardWidth: 840
    // Top-anchored so the card and its buttons stay above the on-screen
    // keyboard. While typing (field focused) the month picker is hidden and the
    // card collapses to the compact height — only the calendar view ever needs
    // the taller card, and only when the keyboard is down.
    topMargin: 80
    cardHeight: (app.viewMode === "calendar" || addField.activeFocus) ? 720 : 1180

    Text {
        id: addTodoTitle
        anchors {
            top: parent.top
            topMargin: 40
            left: parent.left
            leftMargin: 48
        }
        text: "Add todo"
        font.pixelSize: 44
        font.bold: true
        color: "black"
    }

    Rectangle {
        id: addBox
        anchors {
            top: addTodoTitle.bottom
            topMargin: 28
            left: parent.left
            leftMargin: 48
            right: parent.right
            rightMargin: 48
        }
        height: 240
        color: "white"
        border.color: "black"
        border.width: 3

        Flickable {
            anchors {
                fill: parent
                margins: 20
            }
            contentWidth: width
            contentHeight: addField.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            TextEdit {
                id: addField
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
            visible: addField.text === ""
            text: "Type the todo text"
            font.pixelSize: 38
            color: "#888888"
        }
    }

    Text {
        id: addDateLabel
        anchors {
            top: addBox.bottom
            topMargin: 28
            left: parent.left
            leftMargin: 48
            right: parent.right
            rightMargin: 48
        }
        text: {
            var base = "For " + addTodoSheet.app.dayLabel(addTodoSheet.app.addTodoDay);
            return (addTodoSheet.app.viewMode !== "calendar" && addField.activeFocus) ? base + "  (tap to change)" : base;
        }
        font.pixelSize: 34
        font.bold: true
        color: "black"
        elide: Text.ElideRight

        // While typing, the picker is hidden to keep the card compact. Tapping
        // the date dismisses the keyboard so the picker reappears.
        MouseArea {
            anchors.fill: parent
            enabled: addTodoSheet.app.viewMode !== "calendar" && addField.activeFocus
            onClicked: {
                addField.focus = false;
                Qt.inputMethod.hide();
            }
        }
    }

    // List view: pick the date. Calendar view keeps the active day, so the
    // grid is hidden there; it's also hidden while typing so the card can
    // collapse clear of the keyboard.
    MonthView {
        id: addPicker
        visible: addTodoSheet.app.viewMode !== "calendar" && !addField.activeFocus
        anchors {
            top: addDateLabel.bottom
            topMargin: 16
            left: parent.left
            leftMargin: 24
            right: parent.right
            rightMargin: 24
            bottom: addTodoButtons.top
            bottomMargin: 24
        }
        year: addTodoSheet.app.addPickYear
        month: addTodoSheet.app.addPickMonth
        todayKey: addTodoSheet.app.todayKey
        selectedKey: addTodoSheet.app.addTodoDay
        onDayClicked: key => addTodoSheet.app.addTodoDay = key
        onPrevMonth: addTodoSheet.app.shiftAddMonth(-1)
        onNextMonth: addTodoSheet.app.shiftAddMonth(1)
    }

    Row {
        id: addTodoButtons
        anchors {
            bottom: parent.bottom
            bottomMargin: 40
            horizontalCenter: parent.horizontalCenter
        }
        spacing: 40

        FlatButton {
            text: "Cancel"
            onClicked: addTodoSheet.app.closeAddTodo()
        }

        FlatButton {
            primary: true
            enabled: addField.text.trim() !== ""
            text: "Add"
            onClicked: addTodoSheet.app.saveAddTodo()
        }
    }
}
