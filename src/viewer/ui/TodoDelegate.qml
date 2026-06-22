import QtQuick

// One todo row: a toggle circle, the captured snippet, and its date.
// Pure black/white, no animation — meant for e-ink.
Item {
    id: row
    height: 320

    property string name
    property string kind            // "image" (PNG snippet) | "text" (OCR result)
    property string text
    property string imageUrl
    property bool done
    property string dateText

    signal toggleClicked
    signal longPressed

    // Long-press anywhere on the row opens the delete confirmation.
    // Declared first so it sits below the toggle (toggle taps still win);
    // it only handles press-and-hold, so list flicking is unaffected.
    MouseArea {
        anchors.fill: parent
        onPressAndHold: row.longPressed()
    }

    // Toggle circle (large tap target on the left).
    Rectangle {
        id: check
        anchors { left: parent.left; leftMargin: 36; verticalCenter: parent.verticalCenter }
        width: 88
        height: 88
        radius: width / 2
        color: row.done ? "black" : "white"
        border.color: "black"
        border.width: 4

        Canvas {
            id: checkmark
            anchors.centerIn: parent
            width: 50
            height: 50
            visible: row.done
            onPaint: {
                var ctx = getContext("2d");
                ctx.reset();
                ctx.strokeStyle = "white";
                ctx.lineWidth = 7;
                ctx.lineCap = "round";
                ctx.lineJoin = "round";
                ctx.beginPath();
                ctx.moveTo(width * 0.18, height * 0.52);
                ctx.lineTo(width * 0.42, height * 0.76);
                ctx.lineTo(width * 0.84, height * 0.24);
                ctx.stroke();
            }
            onVisibleChanged: if (visible) requestPaint()
            Component.onCompleted: requestPaint()
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
            left: check.right; leftMargin: 36
            right: date.left; rightMargin: 24
            top: parent.top; topMargin: 24
            bottom: parent.bottom; bottomMargin: 24
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
            left: check.right; leftMargin: 36
            right: date.left; rightMargin: 24
            verticalCenter: parent.verticalCenter
        }
        text: row.text
        font.pixelSize: 40
        color: "black"
        wrapMode: Text.WordWrap
        maximumLineCount: 4
        elide: Text.ElideRight
    }

    Text {
        id: date
        anchors { right: parent.right; rightMargin: 36; top: parent.top; topMargin: 28 }
        text: row.dateText
        font.pixelSize: 30
        color: "black"
    }

    Rectangle {
        anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
        height: 2
        color: "black"
    }
}
