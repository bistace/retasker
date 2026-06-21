import QtQuick
import Qt.labs.folderlistmodel
import Qt.labs.settings
import net.asivery.XoviMessageBroker 2.0
import "store.js" as Store

// reTasker viewer — a frontend-only AppLoad app.
//
// Todos ARE the PNG snippets the capture extension drops into capturesDir; the
// list is just that folder, newest-first. Done-state is the viewer's own
// concern and lives in Qt.labs.settings (a filename -> bool map). No SQLite:
// this Qt build ships neither QtQuick.LocalStorage nor a way to share a DB file
// with the C writer, and the folder already is the source of truth.
//
// Styled for e-ink: pure black on white, no animation, large tap targets.
Rectangle {
    id: root
    anchors.fill: parent
    color: "white"
    focus: true

    // AppLoad lifecycle contract: the root must expose these.
    signal close
    function unloading() {}

    readonly property string capturesDir: "file:///home/root/xovi/exthome/appload/retasker/captures"
    property string filter: "todo"          // "todo" | "done" | "all"
    property var doneMap: ({})
    property string pendingDelete: ""

    Settings {
        id: settings
        category: "retasker"
        property string doneJson: "{}"
    }

    // Native side (retasker-capture.so) handles the actual file removal.
    XoviMessageBroker { id: broker }

    FolderListModel {
        id: folder
        folder: root.capturesDir
        showDirs: false
        showFiles: true
        nameFilters: ["*.png"]
        onStatusChanged: if (folder.status === FolderListModel.Ready) root.refresh()
    }

    ListModel { id: rows }

    function refresh() {
        try {
            root.doneMap = JSON.parse(settings.doneJson);
        } catch (e) {
            root.doneMap = {};
        }
        var entries = Store.collect(folder);
        var visible = Store.view(entries, root.doneMap, root.filter);
        rows.clear();
        for (var i = 0; i < visible.length; i++) {
            rows.append({
                name: visible[i].name,
                url: visible[i].url,
                done: visible[i].done,
                dateText: Qt.formatDateTime(visible[i].mtime, "d MMM HH:mm")
            });
        }
    }

    function toggle(name) {
        root.doneMap[name] = !root.doneMap[name];
        settings.doneJson = JSON.stringify(root.doneMap);
        refresh();
    }

    function askDelete(name) {
        root.pendingDelete = name;
    }

    function confirmDelete() {
        var name = root.pendingDelete;
        root.pendingDelete = "";
        if (!name)
            return;
        broker.sendSimpleSignal("retasker.delete", name);
        if (root.doneMap[name] !== undefined) {
            delete root.doneMap[name];
            settings.doneJson = JSON.stringify(root.doneMap);
        }
        for (var i = 0; i < rows.count; i++) {
            if (rows.get(i).name === name) {
                rows.remove(i);
                break;
            }
        }
    }

    // --- Header: title, filter segments, close ---------------------------
    Rectangle {
        id: header
        anchors { top: parent.top; left: parent.left; right: parent.right }
        height: 240
        color: "white"

        Text {
            id: title
            anchors { left: parent.left; leftMargin: 32; top: parent.top; topMargin: 24 }
            text: "reTasker"
            font.pixelSize: 56
            font.bold: true
            color: "black"
        }

        Item {
            id: closeBtn
            width: 52
            height: 52
            anchors { right: parent.right; rightMargin: 40; verticalCenter: title.verticalCenter }
            Rectangle { anchors.centerIn: parent; width: parent.width; height: 6; radius: 3; color: "black"; rotation: 45 }
            Rectangle { anchors.centerIn: parent; width: parent.width; height: 6; radius: 3; color: "black"; rotation: -45 }
            MouseArea { anchors.fill: parent; anchors.margins: -24; onClicked: root.close() }
        }

        Row {
            anchors { left: parent.left; leftMargin: 32; top: title.bottom; topMargin: 28 }
            spacing: 0

            Repeater {
                model: [
                    { key: "todo", text: "To do" },
                    { key: "done", text: "Done" },
                    { key: "all", text: "All" }
                ]
                delegate: Rectangle {
                    required property var modelData
                    width: 200
                    height: 88
                    color: root.filter === modelData.key ? "black" : "white"
                    border.color: "black"
                    border.width: 2
                    Text {
                        anchors.centerIn: parent
                        text: modelData.text
                        font.pixelSize: 36
                        color: root.filter === modelData.key ? "white" : "black"
                    }
                    MouseArea {
                        anchors.fill: parent
                        onClicked: { root.filter = modelData.key; root.refresh(); }
                    }
                }
            }
        }

        Rectangle {
            anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
            height: 3
            color: "black"
        }
    }

    // --- List -------------------------------------------------------------
    ListView {
        id: list
        anchors { top: header.bottom; left: parent.left; right: parent.right; bottom: parent.bottom }
        model: rows
        clip: true
        cacheBuffer: 0
        highlightMoveDuration: 0
        boundsBehavior: Flickable.StopAtBounds

        delegate: TodoDelegate {
            width: list.width
            name: model.name
            imageUrl: model.url
            done: model.done
            dateText: model.dateText
            onToggleClicked: root.toggle(model.name)
            onLongPressed: root.askDelete(model.name)
        }
    }

    Text {
        anchors.centerIn: list
        visible: rows.count === 0
        text: root.filter === "done" ? "Nothing done yet" : "No todos"
        font.pixelSize: 40
        color: "black"
    }

    // --- Delete confirmation ---------------------------------------------
    // Opaque modal: long-pressing a row sets pendingDelete, which shows this.
    Rectangle {
        id: confirm
        anchors.fill: parent
        visible: root.pendingDelete !== ""
        color: "white"

        // Swallow taps so nothing behind the modal reacts.
        MouseArea { anchors.fill: parent }

        Rectangle {
            anchors.centerIn: parent
            width: 720
            height: 380
            color: "white"
            border.color: "black"
            border.width: 4

            Text {
                id: confirmTitle
                anchors { top: parent.top; topMargin: 56; horizontalCenter: parent.horizontalCenter }
                text: "Delete this todo?"
                font.pixelSize: 46
                font.bold: true
                color: "black"
            }

            Text {
                anchors { top: confirmTitle.bottom; topMargin: 20; horizontalCenter: parent.horizontalCenter }
                text: "This cannot be undone."
                font.pixelSize: 30
                color: "black"
            }

            Row {
                anchors { bottom: parent.bottom; bottomMargin: 48; horizontalCenter: parent.horizontalCenter }
                spacing: 40

                Rectangle {
                    width: 260
                    height: 100
                    color: "white"
                    border.color: "black"
                    border.width: 3
                    Text { anchors.centerIn: parent; text: "Cancel"; font.pixelSize: 40; color: "black" }
                    MouseArea { anchors.fill: parent; onClicked: root.pendingDelete = "" }
                }

                Rectangle {
                    width: 260
                    height: 100
                    color: "black"
                    border.color: "black"
                    border.width: 3
                    Text { anchors.centerIn: parent; text: "Delete"; font.pixelSize: 40; color: "white" }
                    MouseArea { anchors.fill: parent; onClicked: root.confirmDelete() }
                }
            }
        }
    }

    Component.onCompleted: refresh()
}
