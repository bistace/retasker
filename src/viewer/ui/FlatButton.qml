import QtQuick

// A flat e-ink button. `primary` fills it black with white text; otherwise it is
// outlined with black text. When `enabled` is false it dims to grey and ignores
// taps (used for the not-yet-ready Save/Add/Create actions). Sized by the caller
// via width/height (defaults 260x100); emits clicked() only when enabled.
Rectangle {
    id: button

    property string text: ""
    property bool primary: false
    property int fontSize: 40
    signal clicked

    implicitWidth: 260
    implicitHeight: 100
    color: button.primary && button.enabled ? "black" : "white"
    border.color: button.enabled ? "black" : "#aaaaaa"
    border.width: 3

    Text {
        anchors.centerIn: parent
        text: button.text
        font.pixelSize: button.fontSize
        color: button.primary && button.enabled ? "white" : (button.enabled ? "black" : "#aaaaaa")
    }
    MouseArea {
        anchors.fill: parent
        enabled: button.enabled
        onClicked: button.clicked()
    }
}
