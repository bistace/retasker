import QtQuick
import "calendar.js" as Cal

// Month calendar. Each day cell carries a status marker derived from dayIndex:
//   every todo done -> filled disc + check; some pending -> a ring filled
//   proportional to done/total; none -> blank. Tapping a day that has todos
//   emits dayClicked(key). Pure black/white for e-ink.
Item {
    id: monthView

    property int year
    property int month                  // 0-based, matches JS Date
    property var dayIndex: ({})
    property var notesMap: ({})         // day key -> [titles] of extra notes
    property var dayNoteMap: ({})       // day key -> true if its main note exists
    property string todayKey
    property string selectedKey

    signal dayClicked(string key)
    signal prevMonth
    signal nextMonth
    signal goToday

    readonly property var monthNames: ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
    readonly property var weekdays: ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    readonly property var cells: Cal.monthGrid(monthView.year, monthView.month)
    readonly property var todayParts: monthView.todayKey.split("-")
    readonly property bool viewingToday: parseInt(monthView.todayParts[0], 10) === monthView.year && parseInt(monthView.todayParts[1], 10) - 1 === monthView.month

    // --- Month nav --------------------------------------------------------
    Item {
        id: nav
        anchors {
            top: parent.top
            left: parent.left
            right: parent.right
        }
        height: 104

        // Centered group: prev chevron, month label, next chevron.
        Row {
            anchors.centerIn: parent
            spacing: 28

            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "‹"
                font.pixelSize: 64
                color: "black"
                MouseArea {
                    anchors.fill: parent
                    anchors.margins: -24
                    onClicked: monthView.prevMonth()
                }
            }

            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: monthView.monthNames[monthView.month] + " " + monthView.year
                font.pixelSize: 46
                font.bold: true
                color: "black"
            }

            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "›"
                font.pixelSize: 64
                color: "black"
                MouseArea {
                    anchors.fill: parent
                    anchors.margins: -24
                    onClicked: monthView.nextMonth()
                }
            }
        }

        // Jump back to the current month; hidden when it's already shown.
        FlatButton {
            anchors {
                right: parent.right
                rightMargin: 32
                verticalCenter: parent.verticalCenter
            }
            width: 150
            height: 64
            fontSize: 28
            text: "Today"
            visible: !monthView.viewingToday
            onClicked: monthView.goToday()
        }
    }

    // --- Weekday header ---------------------------------------------------
    Row {
        id: weekHeader
        anchors {
            top: nav.bottom
            topMargin: 8
            left: parent.left
            right: parent.right
        }
        Repeater {
            model: monthView.weekdays
            delegate: Item {
                required property var modelData
                required property int index
                width: monthView.width / 7
                height: 60
                Text {
                    anchors.centerIn: parent
                    text: modelData
                    font.pixelSize: 30
                    font.bold: true
                    color: index >= 5 ? "#888888" : "black"
                }
            }
        }
    }

    // --- Day grid ---------------------------------------------------------
    Grid {
        id: grid
        anchors {
            top: weekHeader.bottom
            left: parent.left
            right: parent.right
            bottom: parent.bottom
        }
        columns: 7
        readonly property real cellW: width / 7
        readonly property real cellH: height / (monthView.cells.length / 7)

        Repeater {
            model: monthView.cells
            delegate: Item {
                id: cell
                required property var modelData
                required property int index
                width: grid.cellW
                height: grid.cellH

                readonly property var stat: modelData ? monthView.dayIndex[modelData.key] : undefined
                readonly property int total: stat ? stat.total : 0
                readonly property int done: stat ? stat.done : 0
                readonly property bool allDone: total > 0 && done === total
                readonly property bool isToday: modelData && modelData.key === monthView.todayKey
                readonly property bool isSelected: modelData && modelData.key === monthView.selectedKey
                readonly property bool isWeekend: (index % 7) >= 5
                readonly property int noteCount: modelData && monthView.notesMap[modelData.key] ? monthView.notesMap[modelData.key].length : 0
                readonly property bool hasDayNote: modelData && monthView.dayNoteMap[modelData.key] === true

                Rectangle {
                    anchors.fill: parent
                    anchors.margins: 10
                    radius: 8
                    visible: cell.modelData !== null
                    // Weekend gets a grey wash dark enough to read on e-ink; today
                    // and the selected day are marked with a black border (which
                    // stays crisp on e-ink) rather than a near-white fill.
                    color: cell.isWeekend ? "#cccccc" : "white"
                    border.color: "black"
                    border.width: cell.isToday ? 6 : (cell.isSelected ? 4 : 0)

                    // Day number — today reverses out of a solid black disc.
                    Item {
                        anchors {
                            top: parent.top
                            left: parent.left
                            topMargin: 10
                            leftMargin: 10
                        }
                        width: 50
                        height: 50

                        Rectangle {
                            anchors.centerIn: parent
                            width: 50
                            height: 50
                            radius: 25
                            visible: cell.isToday
                            color: "black"
                        }
                        Text {
                            anchors.centerIn: parent
                            text: cell.modelData ? cell.modelData.day : ""
                            font.pixelSize: 30
                            font.bold: cell.isToday
                            color: cell.isToday ? "white" : "black"
                        }
                    }

                    // Note markers in the top-right corner: an outline dot when the
                    // day's main note exists, a filled dot when it has titled notes.
                    Row {
                        anchors {
                            top: parent.top
                            right: parent.right
                            topMargin: 12
                            rightMargin: 14
                        }
                        spacing: 6
                        layoutDirection: Qt.RightToLeft

                        Rectangle {
                            width: 20
                            height: 20
                            radius: 10
                            visible: cell.noteCount > 0
                            color: "black"
                        }
                        Rectangle {
                            width: 20
                            height: 20
                            radius: 10
                            visible: cell.hasDayNote
                            color: "white"
                            border.color: "black"
                            border.width: 3
                        }
                    }

                    // Pending days: a track ring with an arc filled to done/total.
                    Canvas {
                        id: arc
                        anchors.centerIn: parent
                        width: 68
                        height: 68
                        visible: cell.total > 0 && !cell.allDone
                        property int aDone: cell.done
                        property int aTotal: cell.total
                        onADoneChanged: requestPaint()
                        onATotalChanged: requestPaint()
                        Component.onCompleted: requestPaint()
                        onPaint: {
                            var ctx = getContext("2d");
                            ctx.reset();
                            var cx = width / 2;
                            var cy = height / 2;
                            var r = width / 2 - 5;
                            ctx.strokeStyle = "#999999";
                            ctx.lineWidth = 6;
                            ctx.beginPath();
                            ctx.arc(cx, cy, r, 0, Math.PI * 2);
                            ctx.stroke();
                            if (aTotal <= 0 || aDone <= 0)
                                return;
                            ctx.strokeStyle = "black";
                            ctx.lineWidth = 8;
                            ctx.lineCap = "round";
                            ctx.beginPath();
                            ctx.arc(cx, cy, r, -Math.PI / 2, -Math.PI / 2 + (aDone / aTotal) * Math.PI * 2);
                            ctx.stroke();
                        }
                    }

                    // All done: filled disc + check.
                    Rectangle {
                        anchors.centerIn: parent
                        width: 64
                        height: 64
                        radius: 32
                        visible: cell.allDone
                        color: "black"

                        CheckMark {
                            anchors.centerIn: parent
                            dim: 36
                            stroke: 6
                        }
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    enabled: cell.modelData !== null
                    onClicked: monthView.dayClicked(cell.modelData.key)
                }
            }
        }
    }

    // Bold frame around the whole grid (sibling of Grid: a child of Grid would be
    // laid out as a cell).
    Rectangle {
        anchors.fill: grid
        color: "transparent"
        border.color: "black"
        border.width: 3
    }
}
