import QtQuick
import Qt.labs.folderlistmodel
import Qt.labs.settings
import net.asivery.XoviMessageBroker 2.0
import "store.js" as Store
import "ocr.js" as Ocr

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

    readonly property string appDir: "file:///home/root/xovi/exthome/appload/retasker"
    readonly property string capturesDir: appDir + "/captures"
    property string filter: "todo"          // "todo" | "done" | "all"
    property var doneMap: ({})

    // Delete confirmation: pendingDelete holds the filename; the rest mirror the
    // row's content so the modal can preview exactly which todo is going away.
    property string pendingDelete: ""
    property string pendingKind: ""
    property string pendingText: ""
    property string pendingUrl: ""

    // OCR (config loaded from appDir/config.json; null disables transcription).
    // ocrTried guards against re-submitting the same capture within a session;
    // reopening the app retries anything still left as an image (e.g. offline).
    property var ocrConfig: null
    property var ocrTried: ({})

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
        nameFilters: ["*.png", "*.txt"]
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
            var v = visible[i];
            rows.append({
                base: v.base,
                name: v.name,
                kind: v.kind,
                url: v.url,
                text: "",
                done: v.done,
                dateText: Qt.formatDateTime(v.mtime, "d MMM HH:mm")
            });
            if (v.kind === "text")
                root.loadText(v.base, v.url);
        }
        root.runOcr(entries);
    }

    // Transcribe every not-yet-tried image capture in the background. On
    // success the native side writes the .txt and drops the .png.
    function runOcr(entries) {
        if (!root.ocrConfig)
            return;
        for (var i = 0; i < entries.length; i++)
            maybeTranscribe(entries[i]);
    }

    function maybeTranscribe(entry) {
        if (entry.kind !== "image" || root.ocrTried[entry.base])
            return;
        root.ocrTried[entry.base] = true;
        var base = entry.base;
        var png = entry.name;
        Ocr.transcribe(entry.url, root.ocrConfig, function (text) {
            if (!text)
                return;  // offline or unreadable: keep the image
            // "<file> <percent-encoded text>": keeps the payload single-line so
            // it survives the broker, and round-trips newlines/accents as UTF-8.
            broker.sendSimpleSignal("retasker.transcribe", png + " " + encodeURIComponent(text));
            root.applyTranscription(base, text);
        });
    }

    // Swap a row from image to text in place. The native side has just written
    // the .txt and removed the .png; updating the row directly avoids waiting on
    // the folder model to notice (the file count is unchanged, so it may not).
    function applyTranscription(base, text) {
        for (var i = 0; i < rows.count; i++) {
            if (rows.get(i).base === base) {
                rows.setProperty(i, "kind", "text");
                rows.setProperty(i, "text", text);
                rows.setProperty(i, "name", base + ".txt");
                rows.setProperty(i, "url", root.capturesDir + "/" + base + ".txt");
                return;
            }
        }
    }

    function loadOcrConfig() {
        var xhr = new XMLHttpRequest();
        xhr.open("GET", root.appDir + "/config.json");
        xhr.onreadystatechange = function () {
            if (xhr.readyState !== XMLHttpRequest.DONE)
                return;
            try {
                root.ocrConfig = JSON.parse(xhr.responseText);
            } catch (e) {
                root.ocrConfig = null;
            }
            if (root.ocrConfig)
                root.runOcr(Store.collect(folder));
        };
        xhr.send();
    }

    // Read a transcription file and drop it into its row (async; tiny file).
    function loadText(base, url) {
        var xhr = new XMLHttpRequest();
        xhr.open("GET", url);
        xhr.onreadystatechange = function () {
            if (xhr.readyState === XMLHttpRequest.DONE)
                root.setRowText(base, (xhr.responseText || "").trim());
        };
        xhr.send();
    }

    function setRowText(base, text) {
        for (var i = 0; i < rows.count; i++) {
            if (rows.get(i).base === base) {
                rows.setProperty(i, "text", text);
                return;
            }
        }
    }

    function toggle(base) {
        root.doneMap[base] = !root.doneMap[base];
        settings.doneJson = JSON.stringify(root.doneMap);
        refresh();
    }

    function askDelete(name) {
        for (var i = 0; i < rows.count; i++) {
            var r = rows.get(i);
            if (r.name === name) {
                root.pendingKind = r.kind;
                root.pendingText = r.text;
                root.pendingUrl = r.url;
                break;
            }
        }
        root.pendingDelete = name;
    }

    function confirmDelete() {
        var name = root.pendingDelete;
        root.pendingDelete = "";
        if (!name)
            return;
        broker.sendSimpleSignal("retasker.delete", name);
        var base = name.replace(/\.(png|txt)$/i, "");
        if (root.doneMap[base] !== undefined) {
            delete root.doneMap[base];
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
            kind: model.kind
            text: model.text
            imageUrl: model.url
            done: model.done
            dateText: model.dateText
            onToggleClicked: root.toggle(model.base)
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
            height: 560
            color: "white"
            border.color: "black"
            border.width: 4

            Text {
                id: confirmTitle
                anchors { top: parent.top; topMargin: 48; horizontalCenter: parent.horizontalCenter }
                text: "Delete this todo?"
                font.pixelSize: 46
                font.bold: true
                color: "black"
            }

            // Preview of the todo being deleted — the text, or the snippet image.
            Rectangle {
                id: preview
                anchors {
                    top: confirmTitle.bottom; topMargin: 32
                    left: parent.left; leftMargin: 48
                    right: parent.right; rightMargin: 48
                }
                height: 180
                color: "white"
                border.color: "black"
                border.width: 2

                Text {
                    anchors { fill: parent; margins: 20 }
                    visible: root.pendingKind === "text"
                    text: root.pendingText
                    font.pixelSize: 36
                    color: "black"
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                    wrapMode: Text.WordWrap
                    maximumLineCount: 3
                    elide: Text.ElideRight
                }

                Image {
                    anchors { fill: parent; margins: 16 }
                    visible: root.pendingKind === "image"
                    source: root.pendingKind === "image" ? root.pendingUrl : ""
                    fillMode: Image.PreserveAspectFit
                    smooth: true
                    asynchronous: true
                }
            }

            Text {
                anchors { top: preview.bottom; topMargin: 24; horizontalCenter: parent.horizontalCenter }
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

    Component.onCompleted: {
        loadOcrConfig();
        refresh();
    }
}
