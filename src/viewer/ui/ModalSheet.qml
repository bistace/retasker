import QtQuick

// Full-screen opaque overlay for a modal: a tap-swallowing white backdrop plus a
// centered bordered card. `open` drives visibility; `cardWidth`/`cardHeight` size
// the card. Declared children land inside the card and anchor against it, so a
// modal body reads the same as before — just without the hand-rolled scaffold.
Rectangle {
    id: sheet

    property bool open: false
    property int cardWidth: 720
    property int cardHeight: 560
    default property alias content: card.data

    anchors.fill: parent
    visible: sheet.open
    color: "white"

    // Swallow taps so nothing behind the modal reacts.
    MouseArea {
        anchors.fill: parent
    }

    Rectangle {
        id: card
        anchors.centerIn: parent
        width: sheet.cardWidth
        height: sheet.cardHeight
        color: "white"
        border.color: "black"
        border.width: 4
    }
}
