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

    property bool isChild           // a subtask: indented, no disclosure of its own
    property int childCount         // subtasks hanging off this row (0 = leaf)
    property int childOpen          // of those, how many are still open
    property bool expanded          // children currently spliced in below

    // A parent (has children) gets a disclosure control on the left; subtasks are
    // indented under it.
    readonly property bool hasDisclosure: !row.isChild && row.childCount > 0
    readonly property int indent: row.isChild ? 64 : 0

    signal toggleClicked
    signal longPressed
    signal expandClicked

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

    // Disclosure control for a parent: a chevron plus an open/total badge, its own
    // tap target so it doesn't trip the row's toggle. Sits left of the circle. The
    // chevron is drawn (not a glyph) and rotates from "right" to "down" when open,
    // matching how the rest of the UI draws its symbols.
    Item {
        id: disclosure
        visible: row.hasDisclosure
        anchors {
            left: parent.left
            leftMargin: 24
            verticalCenter: parent.verticalCenter
        }
        width: 116
        height: 56

        Canvas {
            id: chevron
            anchors {
                left: parent.left
                verticalCenter: parent.verticalCenter
            }
            width: 26
            height: 26
            rotation: row.expanded ? 90 : 0
            onPaint: {
                var ctx = getContext("2d");
                ctx.reset();
                ctx.fillStyle = "black";
                ctx.beginPath();
                ctx.moveTo(5, 3);
                ctx.lineTo(5, height - 3);
                ctx.lineTo(width - 4, height / 2);
                ctx.closePath();
                ctx.fill();
            }
        }

        Text {
            anchors {
                left: chevron.right
                leftMargin: 14
                verticalCenter: parent.verticalCenter
            }
            text: (row.childCount - row.childOpen) + "/" + row.childCount
            font.pixelSize: 30
            color: "black"
        }

        MouseArea {
            anchors.fill: parent
            anchors.margins: -16
            onClicked: row.expandClicked()
        }
    }

    // Toggle circle (large tap target on the left).
    Rectangle {
        id: check
        anchors {
            left: parent.left
            leftMargin: 36 + row.indent + (row.hasDisclosure ? 120 : 0)
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
        font.pixelSize: row.isChild ? 34 : 40
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
