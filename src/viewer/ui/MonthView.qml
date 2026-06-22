import QtQuick
import "calendar.js" as Cal

// Month calendar. Each day cell carries a status marker derived from dayIndex:
//   every todo done -> filled disc + check; some pending -> open ring; none -> blank.
// Tapping a day that has todos emits dayClicked(key). Pure black/white for e-ink.
Item {
    id: monthView

    property int year
    property int month                  // 0-based, matches JS Date
    property var dayIndex: ({})
    property string todayKey
    property string selectedKey

    signal dayClicked(string key)
    signal prevMonth
    signal nextMonth

    readonly property var monthNames: ["January", "February", "March", "April", "May", "June",
                                       "July", "August", "September", "October", "November", "December"]
    readonly property var weekdays: ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    readonly property var cells: Cal.monthGrid(monthView.year, monthView.month)

    // --- Month nav --------------------------------------------------------
    Item {
        id: nav
        anchors { top: parent.top; left: parent.left; right: parent.right }
        height: 104

        Rectangle {
            anchors { left: parent.left; leftMargin: 32; verticalCenter: parent.verticalCenter }
            width: 96; height: 76
            color: "white"; border.color: "black"; border.width: 2
            Text { anchors.centerIn: parent; text: "‹"; font.pixelSize: 48; color: "black" }
            MouseArea { anchors.fill: parent; onClicked: monthView.prevMonth() }
        }

        Text {
            anchors.centerIn: parent
            text: monthView.monthNames[monthView.month] + " " + monthView.year
            font.pixelSize: 44; font.bold: true; color: "black"
        }

        Rectangle {
            anchors { right: parent.right; rightMargin: 32; verticalCenter: parent.verticalCenter }
            width: 96; height: 76
            color: "white"; border.color: "black"; border.width: 2
            Text { anchors.centerIn: parent; text: "›"; font.pixelSize: 48; color: "black" }
            MouseArea { anchors.fill: parent; onClicked: monthView.nextMonth() }
        }
    }

    // --- Weekday header ---------------------------------------------------
    Row {
        id: weekHeader
        anchors { top: nav.bottom; topMargin: 8; left: parent.left; right: parent.right }
        Repeater {
            model: monthView.weekdays
            delegate: Item {
                required property var modelData
                width: monthView.width / 7
                height: 56
                Text { anchors.centerIn: parent; text: modelData; font.pixelSize: 28; color: "black" }
            }
        }
    }

    // --- Day grid ---------------------------------------------------------
    Grid {
        id: grid
        anchors { top: weekHeader.bottom; left: parent.left; right: parent.right; bottom: parent.bottom }
        columns: 7
        readonly property real cellW: width / 7
        readonly property real cellH: height / (monthView.cells.length / 7)

        Repeater {
            model: monthView.cells
            delegate: Item {
                id: cell
                required property var modelData
                width: grid.cellW
                height: grid.cellH

                readonly property var stat: modelData ? monthView.dayIndex[modelData.key] : undefined
                readonly property int total: stat ? stat.total : 0
                readonly property int done: stat ? stat.done : 0
                readonly property bool allDone: total > 0 && done === total
                readonly property bool isToday: modelData && modelData.key === monthView.todayKey
                readonly property bool isSelected: modelData && modelData.key === monthView.selectedKey

                Rectangle {
                    anchors.fill: parent
                    anchors.margins: 4
                    visible: cell.modelData !== null
                    color: cell.isSelected ? "#dddddd" : "white"
                    border.color: "black"
                    border.width: cell.isSelected ? 6 : (cell.isToday ? 4 : 1)

                    Text {
                        anchors { top: parent.top; left: parent.left; topMargin: 12; leftMargin: 14 }
                        text: cell.modelData ? cell.modelData.day : ""
                        font.pixelSize: 30
                        font.bold: cell.isToday
                        color: "black"
                    }

                    // Status marker: filled+check when all done, open ring when pending.
                    Rectangle {
                        anchors.centerIn: parent
                        width: 56; height: 56; radius: 28
                        visible: cell.total > 0
                        color: cell.allDone ? "black" : "white"
                        border.color: "black"; border.width: 4

                        Canvas {
                            anchors.centerIn: parent
                            width: 34; height: 34
                            visible: cell.allDone
                            onPaint: {
                                var ctx = getContext("2d");
                                ctx.reset();
                                ctx.strokeStyle = "white";
                                ctx.lineWidth = 6;
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
}
