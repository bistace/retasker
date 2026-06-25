import QtQuick

// One todo row: a toggle circle, the captured snippet, and its date.
// Pure black/white, no animation — meant for e-ink.
//
// Height adapts to the content: image snippets get a fixed tall box, while
// transcribed text shrinks to fit its line(s) so a one-line todo isn't a
// wall of whitespace.
Item {
    id: row
    height: row.kind === "text" ? Math.max(transcription.implicitHeight + 2 * vpad, minHeight) : imageHeight

    readonly property int vpad: 28
    readonly property int minHeight: 124
    readonly property int imageHeight: 320

    property string name
    property string kind            // "image" (PNG snippet) | "text" (OCR result)
    property string text
    property string imageUrl
    property bool done
    property string dateText

    signal toggleClicked
    signal longPressed

    // The whole row is the completion target: a tap toggles done, a press-and-hold
    // opens the action menu (Modify / Delete). Declared first so it sits below the
    // toggle circle, whose own MouseArea consumes taps on it. Qt suppresses the tap
    // after a long press, so the two gestures don't collide, and a list flick steals
    // the grab before either fires.
    MouseArea {
        anchors.fill: parent
        onClicked: row.toggleClicked()
        onPressAndHold: row.longPressed()
    }

    // Toggle circle (large tap target on the left).
    Rectangle {
        id: check
        anchors {
            left: parent.left
            leftMargin: 36
            verticalCenter: parent.verticalCenter
        }
        width: 56
        height: 56
        radius: width / 2
        color: row.done ? "black" : "white"
        border.color: "black"
        border.width: 4

        CheckMark {
            anchors.centerIn: parent
            dim: 34
            stroke: 5
            visible: row.done
        }

        MouseArea {
            anchors.fill: parent
            anchors.margins: -24
            onClicked: row.toggleClicked()
        }
    }

    // Captured handwriting snippet (kept when OCR is unavailable or unsure).
    Image {
        id: snippet
        visible: row.kind === "image"
        anchors {
            left: check.right
            leftMargin: 36
            right: date.left
            rightMargin: 24
            top: parent.top
            topMargin: 24
            bottom: parent.bottom
            bottomMargin: 24
        }
        source: row.kind === "image" ? row.imageUrl : ""
        fillMode: Image.PreserveAspectFit
        horizontalAlignment: Image.AlignLeft
        smooth: true
        asynchronous: true
    }

    // Transcribed text (replaces the snippet once OCR succeeds).
    Text {
        id: transcription
        visible: row.kind === "text"
        anchors {
            left: check.right
            leftMargin: 36
            right: date.left
            rightMargin: 24
            verticalCenter: parent.verticalCenter
        }
        text: row.text
        font.pixelSize: 40
        font.strikeout: row.done
        color: "black"
        wrapMode: Text.WordWrap
        maximumLineCount: 4
        elide: Text.ElideRight
    }

    Text {
        id: date
        anchors {
            right: parent.right
            rightMargin: 36
            verticalCenter: parent.verticalCenter
        }
        text: row.dateText
        font.pixelSize: 30
        color: "black"
    }

    Rectangle {
        anchors {
            left: parent.left
            right: parent.right
            bottom: parent.bottom
        }
        height: 2
        color: "black"
    }
}
