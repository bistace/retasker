import QtQuick

// The reTasker "done" check: three strokes (.18,.52 -> .42,.76 -> .84,.24) drawn
// on a transparent square. `dim` sizes it; `stroke`/`strokeColor` are tunable so
// the same glyph serves the list row, the calendar cell and the month badge.
// Callers anchor it and drive its `visible` flag; it repaints when shown (a Canvas
// won't paint while hidden).
Canvas {
    id: mark

    property int dim: 34
    property int stroke: 5
    property color strokeColor: "white"

    width: dim
    height: dim

    onPaint: {
        var ctx = getContext("2d");
        ctx.reset();
        ctx.strokeStyle = mark.strokeColor;
        ctx.lineWidth = mark.stroke;
        ctx.lineCap = "round";
        ctx.lineJoin = "round";
        ctx.beginPath();
        ctx.moveTo(width * 0.18, height * 0.52);
        ctx.lineTo(width * 0.42, height * 0.76);
        ctx.lineTo(width * 0.84, height * 0.24);
        ctx.stroke();
    }
    onVisibleChanged: if (visible)
        requestPaint()
    Component.onCompleted: requestPaint()
}
