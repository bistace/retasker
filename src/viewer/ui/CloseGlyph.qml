import QtQuick

// The close "X": two bars crossed at +/-45 degrees, with a generously padded tap
// target. `dim` sizes the glyph (default 52); callers anchor it and wire clicked().
Item {
    id: glyph

    property int dim: 52
    property int bar: 6
    signal clicked

    width: dim
    height: dim

    Rectangle {
        anchors.centerIn: parent
        width: parent.width
        height: glyph.bar
        radius: glyph.bar / 2
        color: "black"
        rotation: 45
    }
    Rectangle {
        anchors.centerIn: parent
        width: parent.width
        height: glyph.bar
        radius: glyph.bar / 2
        color: "black"
        rotation: -45
    }
    MouseArea {
        anchors.fill: parent
        anchors.margins: -24
        onClicked: glyph.clicked()
    }
}
