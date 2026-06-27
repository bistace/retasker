import QtQuick

// Full-screen opaque overlay for a modal: a tap-swallowing white backdrop plus a
// centered bordered card. `open` drives visibility; `cardWidth`/`cardHeight` size
// the card. Declared children land inside the card and anchor against it, so a
// modal body reads the same as before -- just without the hand-rolled scaffold.
Rectangle {
    id: sheet

    property bool open: false
    property int cardWidth: 720
    property int cardHeight: 560
    // -1 centers the card vertically; a value >= 0 is the preferred top margin.
    // Either way the card is kept above the on-screen keyboard (see below), so
    // this is just the resting position when the keyboard is down.
    property int topMargin: -1
    readonly property int minMargin: 16
    default property alias content: card.data

    // The on-screen keyboard docks at the bottom of the window, so the card must
    // fit in the band above it. keyboardRectangle is authoritative in both
    // orientations -- and unlike `visible` (which can stay stuck true on this
    // platform) its height drops to 0 when the keyboard is down. This matters most
    // in landscape, where the short window would otherwise let the keyboard cover
    // the card's action buttons.
    readonly property real availHeight: sheet.height - Qt.inputMethod.keyboardRectangle.height

    anchors.fill: parent
    visible: sheet.open
    color: "white"

    // Swallow taps so nothing behind the modal reacts.
    MouseArea {
        anchors.fill: parent
    }

    Rectangle {
        id: card
        anchors.horizontalCenter: parent.horizontalCenter
        width: sheet.cardWidth
        // Cap to the band above the keyboard; the body shrinks with it (its
        // buttons are anchored to the card bottom, so they stay reachable).
        height: Math.min(sheet.cardHeight, sheet.availHeight - 2 * sheet.minMargin)
        // Center in the band, or sit at topMargin -- but never so low that the
        // bottom slides behind the keyboard.
        y: sheet.topMargin < 0 ? Math.max(sheet.minMargin, (sheet.availHeight - height) / 2) : Math.min(sheet.topMargin, sheet.availHeight - height - sheet.minMargin)
        color: "white"
        border.color: "black"
        border.width: 4
    }
}
