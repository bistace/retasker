import QtQuick
import Qt.labs.folderlistmodel
import Qt.labs.settings
import net.asivery.XoviMessageBroker 2.0
import net.asivery.AppLoad 1.0
import "store.js" as Store
import "ocr.js" as Ocr
import "calendar.js" as Cal

// reTasker viewer — an AppLoad app backed by retasker-backend.
//
// Todos live in a SQLite database owned by the backend process (this Qt build
// ships no SQLite, so the viewer can't open one itself — it talks to the backend
// over AppLoad). The viewer asks for a page of todos and renders it; the backend
// does the sorting, filtering and calendar bucketing. The PNG snippets the
// capture extension drops into capturesDir are the only files left on disk: the
// viewer ingests each new one into the DB and, once OCR transcribes it, the
// backend stores the text and deletes the PNG, so the folder stays small.
//
// Styled for e-ink: pure black on white, no animation, large tap targets.
Rectangle {
    id: root
    anchors.fill: parent
    color: "white"
    focus: true

    // AppLoad lifecycle contract: the root must expose these.
    signal close
    function unloading() {
    }

    readonly property string appDir: "file:///home/root/xovi/exthome/appload/retasker"
    readonly property string capturesDir: appDir + "/captures"
    property string filter: "todo"          // "todo" | "done" | "all"

    // Calendar: viewMode switches the body between the flat list and the month
    // grid. selectedDay (a "y-m-d" key) is set when a day is tapped in the grid,
    // which filters the list to that day. dayIndex maps each day to its
    // {total, done} counts so the grid can mark it. shown* drive which month is
    // displayed; todayKey highlights today's cell.
    property string viewMode: "list"        // "list" | "calendar"
    property string selectedDay: ""
    property var dayIndex: ({})
    // Notes the viewer has created, tracked locally (same as the done-map) so the
    // calendar can mark days and the sheet can list/reopen them. notesMap holds
    // the titled extras per day ("y-m-d" -> [titles]); dayNoteMap records whether
    // a day's main (date-named) note has been created ("y-m-d" -> true).
    property var notesMap: ({})
    property var dayNoteMap: ({})
    property int shownYear: 0
    property int shownMonth: 0               // 0-based
    property string todayKey: ""
    property bool settingsOpen: false
    readonly property string monthLabel: Qt.formatDate(new Date(root.shownYear, root.shownMonth, 1), "MMMM yyyy")
    readonly property var monthCounts: Cal.monthCounts(root.dayIndex, root.shownYear, root.shownMonth)
    readonly property bool monthAllDone: monthCounts.total > 0 && monthCounts.done === monthCounts.total

    // Delete confirmation: pendingDelete holds the filename; the rest mirror the
    // row's content so the modal can preview exactly which todo is going away.
    property string pendingDelete: ""
    property string pendingKind: ""
    property string pendingText: ""
    property string pendingUrl: ""

    // Row action menu (long-press): pick Modify or Delete for a todo. menuName is
    // the row's filename and drives visibility; the rest preview the todo and seed
    // the editor.
    property string menuName: ""
    property string menuBase: ""
    property string menuKind: ""
    property string menuText: ""
    property string menuUrl: ""

    // Edit sheet: editName (a row filename) drives visibility; editBase keys the
    // write. The field starts from the current transcription (empty for an image).
    property string editName: ""
    property string editBase: ""

    // Day-notes sheet: addNoteDay is the day it acts on (set when opened);
    // addSheetMode is "list" (browse/open the day's notes) or "new" (title entry).
    property bool addNoteOpen: false
    property string addNoteDay: ""
    property string addSheetMode: "list"

    // Forget-note confirmation: pendingForgetKind ("day"|"extra") drives the
    // modal; it acts on addNoteDay (the open sheet's day). title is the extra's
    // raw title; label is what the modal shows.
    property string pendingForgetKind: ""
    property string pendingForgetTitle: ""
    property string pendingForgetLabel: ""

    // OCR (config loaded from appDir/config.json; null disables transcription).
    // ocrTried guards against re-submitting the same capture within a session;
    // reopening the app retries anything still left as an image (e.g. offline).
    property var ocrConfig: null
    property var ocrTried: ({})

    // Backend (retasker-backend, an AppLoad process owning the SQLite DB). The
    // viewer only loads once the backend signals READY — messages sent before its
    // socket is registered are dropped. Todos are fetched one page at a time.
    property bool backendReady: false
    property int pageSize: 200
    property int loadedOffset: 0
    property bool moreAvailable: false
    property var ingested: ({})          // PNG bases ingested this session
    readonly property int msgQuery: 1
    readonly property int msgSetDone: 2
    readonly property int msgSetText: 3
    readonly property int msgDelete: 4
    readonly property int msgIngest: 5
    readonly property int msgCal: 6
    readonly property int msgReady: 100
    readonly property int msgRows: 101
    readonly property int msgIngested: 102
    readonly property int msgCalRows: 103

    Settings {
        id: settings
        category: "retasker"
        property string notesJson: "{}"     // day -> [titles] of extra notes
        property string dayNotesJson: "{}"  // day -> true if its main note exists
        property string viewMode: "list"    // remembered across sessions
        property string noteTemplateFilename: ""
        property string noteTemplateName: "Blank"
        property bool noteTemplateLandscape: false
        property bool openSettingsOnStart: false
    }

    // Native side (retasker-capture.so) handles the actual file removal.
    XoviMessageBroker {
        id: broker
    }

    // Todo database, owned by retasker-backend over AppLoad.
    AppLoad {
        id: backend
        applicationID: "retasker"
        onMessageReceived: (type, contents) => root.onBackendMessage(type, contents)
    }

    // Only un-transcribed PNGs live on disk now; this drives ingestion + OCR of
    // new captures. The displayed list comes from the backend, not this folder.
    FolderListModel {
        id: folder
        folder: root.capturesDir
        showDirs: false
        showFiles: true
        nameFilters: ["*.png"]
        onStatusChanged: if (folder.status === FolderListModel.Ready)
            root.syncFolder()
    }

    ListModel {
        id: rows
    }

    function refresh() {
        try {
            root.notesMap = JSON.parse(settings.notesJson);
        } catch (e) {
            root.notesMap = {};
        }
        try {
            root.dayNoteMap = JSON.parse(settings.dayNotesJson);
        } catch (e) {
            root.dayNoteMap = {};
        }
        if (!root.backendReady)
            return;  // the first load is driven by the backend's READY signal
        root.queryPage(0);
        if (root.viewMode === "calendar")
            root.requestCal();
    }

    // Request a page of todos: the status filter (list view) and, in calendar
    // view, the [start, end) capture-time window of the selected day or the shown
    // month. Newest-first ordering and paging happen in the backend.
    function queryPage(offset) {
        var req = {
            filter: root.viewMode === "calendar" ? "all" : root.filter,
            offset: offset,
            limit: root.pageSize
        };
        var range = root.viewRange();
        if (range) {
            req.rangeStart = range.start;
            req.rangeEnd = range.end;
        }
        backend.sendMessage(root.msgQuery, JSON.stringify(req));
    }

    // The capture-time window the calendar is scoped to: one day if selected,
    // otherwise the whole shown month. null in list view (no window).
    function viewRange() {
        if (root.viewMode !== "calendar")
            return null;
        if (root.selectedDay !== "") {
            var p = root.selectedDay.split("-");
            var d0 = new Date(p[0], p[1] - 1, p[2]);
            var d1 = new Date(p[0], p[1] - 1, parseInt(p[2], 10) + 1);
            return {
                start: d0.getTime(),
                end: d1.getTime()
            };
        }
        return {
            start: new Date(root.shownYear, root.shownMonth, 1).getTime(),
            end: new Date(root.shownYear, root.shownMonth + 1, 1).getTime()
        };
    }

    // Ask for the shown month's {ts,done} rows so the grid can mark each day
    // (the whole month, regardless of which day is selected).
    function requestCal() {
        backend.sendMessage(root.msgCal, JSON.stringify({
            rangeStart: new Date(root.shownYear, root.shownMonth, 1).getTime(),
            rangeEnd: new Date(root.shownYear, root.shownMonth + 1, 1).getTime()
        }));
    }

    // Load the next page once the list is scrolled near its end.
    function loadMore() {
        if (!root.moreAvailable)
            return;
        root.moreAvailable = false;  // guard until the page arrives
        root.queryPage(root.loadedOffset);
    }

    function onBackendMessage(type, contents) {
        if (type === root.msgReady) {
            root.backendReady = true;
            root.syncFolder();  // ingest captures the folder already listed
            root.refresh();
            return;
        }
        var data = JSON.parse(contents);
        if (type === root.msgRows) {
            if (data.offset === 0)
                rows.clear();
            var list = data.rows || [];
            for (var i = 0; i < list.length; i++)
                root.appendRow(list[i]);
            root.loadedOffset = data.offset + list.length;
            root.moreAvailable = list.length === root.pageSize;
        } else if (type === root.msgCalRows) {
            root.dayIndex = Cal.buildIndex(data.rows || []);
        } else if (type === root.msgIngested) {
            if ((data.new || 0) > 0)
                root.refresh();  // new todos landed: re-query the current view
        }
    }

    // Turn a backend todo row into a list-model entry. An image row (awaiting
    // OCR) points at its PNG; a text row carries its transcription.
    function appendRow(r) {
        var image = r.hasImage === 1 || r.hasImage === true;
        rows.append({
            base: r.base,
            name: r.base + (image ? ".png" : ".txt"),
            kind: image ? "image" : "text",
            text: r.text ? r.text : "",
            url: root.capturesDir + "/" + r.base + ".png",
            done: r.done === 1 || r.done === true,
            dateText: Qt.formatDateTime(new Date(r.ts), "d MMM HH:mm")
        });
    }

    // Ingest every capture the folder lists into the DB (the backend ignores
    // ones it already has) and OCR any not transcribed yet. This is the only use
    // of the folder model — the displayed list comes from the backend.
    function syncFolder() {
        if (!root.backendReady)
            return;  // re-run on READY; sending now would be dropped, and an OCR
        // result returning before then would be lost with it
        var items = [];
        for (var i = 0; i < folder.count; i++) {
            var fn = "" + folder.get(i, "fileName");
            var m = /^(cap-\d+-\d+)\.png$/i.exec(fn);
            if (!m)
                continue;
            var base = m[1];
            if (!root.ingested[base]) {
                root.ingested[base] = true;
                items.push({
                    base: base,
                    ts: Store.captureMs(base)
                });
            }
            root.maybeTranscribe(base, "" + folder.get(i, "fileURL"));
        }
        if (items.length > 0)
            backend.sendMessage(root.msgIngest, JSON.stringify({
                items: items
            }));
    }

    function maybeTranscribe(base, url) {
        if (!root.ocrConfig || root.ocrTried[base])
            return;
        root.ocrTried[base] = true;
        Ocr.transcribe(url, root.ocrConfig, function (text) {
            if (!text)
                return;  // offline or unreadable: keep the image
            backend.sendMessage(root.msgSetText, JSON.stringify({
                base: base,
                text: text
            }));
            root.applyTranscription(base, text);
        });
    }

    // Swap a row from image to text in place once its transcription is stored,
    // so the change shows without waiting on a re-query.
    function applyTranscription(base, text) {
        for (var i = 0; i < rows.count; i++) {
            if (rows.get(i).base === base) {
                rows.setProperty(i, "kind", "text");
                rows.setProperty(i, "text", text);
                rows.setProperty(i, "name", base + ".txt");
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
                root.syncFolder();
        };
        xhr.send();
    }

    function toggle(base) {
        for (var i = 0; i < rows.count; i++) {
            if (rows.get(i).base === base) {
                var done = !rows.get(i).done;
                rows.setProperty(i, "done", done);
                backend.sendMessage(root.msgSetDone, JSON.stringify({
                    base: base,
                    done: done
                }));
                break;
            }
        }
        // Re-scope the view to match: a status-filtered list drops the row, and
        // the calendar's per-day counts change.
        if (root.viewMode === "calendar")
            root.requestCal();
        else if (root.filter !== "all")
            root.refresh();
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
        for (var i = 0; i < rows.count; i++) {
            if (rows.get(i).name === name) {
                var base = rows.get(i).base;
                rows.remove(i);
                backend.sendMessage(root.msgDelete, JSON.stringify({
                    base: base
                }));
                if (root.viewMode === "calendar")
                    root.requestCal();
                break;
            }
        }
    }

    // Long-press menu: mirror the row's content so the menu can preview it and
    // the editor can start from it, then show the menu.
    function openRowMenu(name) {
        for (var i = 0; i < rows.count; i++) {
            var r = rows.get(i);
            if (r.name === name) {
                root.menuBase = r.base;
                root.menuKind = r.kind;
                root.menuText = r.text;
                root.menuUrl = r.url;
                break;
            }
        }
        root.menuName = name;
    }

    function editFromMenu() {
        root.editBase = root.menuBase;
        root.editName = root.menuName;
        editField.text = root.menuText;
        root.menuName = "";
        editField.forceActiveFocus();
    }

    function deleteFromMenu() {
        var name = root.menuName;
        root.menuName = "";
        root.askDelete(name);
    }

    // Save an edited todo: store the text in the DB. The backend drops the .png
    // if it was still an image, so editing an untranscribed capture doubles as a
    // manual transcription.
    function saveEdit() {
        var text = editField.text.trim();
        if (text === "")
            return;
        backend.sendMessage(root.msgSetText, JSON.stringify({
            base: root.editBase,
            text: text
        }));
        root.applyTranscription(root.editBase, text);
        root.closeEdit();
    }

    // Close the edit sheet and dismiss the on-screen keyboard. Dropping the
    // field's focus alone isn't enough on the device; the input method has to be
    // hidden explicitly or the keyboard lingers over the list.
    function closeEdit() {
        editField.focus = false;
        root.editName = "";
        Qt.inputMethod.hide();
    }

    // Move the calendar forward/back by whole months, rolling the year over.
    function shiftMonth(delta) {
        var m = root.shownMonth + delta;
        var y = root.shownYear;
        while (m < 0) {
            m += 12;
            y -= 1;
        }
        while (m > 11) {
            m -= 12;
            y += 1;
        }
        root.shownMonth = m;
        root.shownYear = y;
        root.selectedDay = "";
        root.refresh();
    }

    function dayLabel(key) {
        if (!key)
            return "";
        var p = key.split("-");
        return Qt.formatDate(new Date(p[0], p[1] - 1, p[2]), "d MMMM yyyy");
    }

    // Library name for a day's extra note: "<date> — <title>". The date prefix
    // groups a day's notes together and keeps titles from colliding across days;
    // both create and reopen go through the same name so the bridge dedupes.
    function dayNoteName(key, title) {
        return root.dayLabel(key) + " — " + title;
    }

    // Open (or create) the day's primary note, named just by its date. Remember
    // it locally so the calendar and sheet can show that the day has a main note.
    function openDayNote(key) {
        var next = {};
        for (var k in root.dayNoteMap)
            next[k] = root.dayNoteMap[k];
        next[key] = true;
        root.dayNoteMap = next;
        settings.dayNotesJson = JSON.stringify(next);
        broker.sendSimpleSignal("retasker.newnote", JSON.stringify({
            name: root.dayLabel(key),
            template: settings.noteTemplateFilename
        }));
        root.close();
    }

    // The day's notes as list rows: the main note first (if created), then the
    // titled extras. kind drives open/remove; title is the extra's raw title.
    function dayNotes(key) {
        var out = [];
        if (root.dayNoteMap[key] === true)
            out.push({
                kind: "day",
                label: root.dayLabel(key),
                title: ""
            });
        var extras = root.notesMap[key] ? root.notesMap[key] : [];
        for (var i = 0; i < extras.length; i++)
            out.push({
                kind: "extra",
                label: extras[i],
                title: extras[i]
            });
        return out;
    }

    // Forget a hand-deleted note (drops the local record only; the notebook, if
    // it still exists, is untouched). Reopening/recreating re-adds it.
    function forgetDayNote(key) {
        var next = {};
        for (var k in root.dayNoteMap)
            if (k !== key)
                next[k] = root.dayNoteMap[k];
        root.dayNoteMap = next;
        settings.dayNotesJson = JSON.stringify(next);
    }

    function forgetExtraNote(key, title) {
        var list = (root.notesMap[key] ? root.notesMap[key] : []).filter(function (t) {
            return t !== title;
        });
        var next = {};
        for (var k in root.notesMap)
            next[k] = root.notesMap[k];
        if (list.length > 0)
            next[key] = list;
        else
            delete next[key];
        root.notesMap = next;
        settings.notesJson = JSON.stringify(next);
    }

    function askForget(kind, title, label) {
        root.pendingForgetTitle = title;
        root.pendingForgetLabel = label;
        root.pendingForgetKind = kind;
    }

    function confirmForget() {
        if (root.pendingForgetKind === "day")
            root.forgetDayNote(root.addNoteDay);
        else if (root.pendingForgetKind === "extra")
            root.forgetExtraNote(root.addNoteDay, root.pendingForgetTitle);
        root.pendingForgetKind = "";
    }

    // Open an existing extra note for a day (the bridge matches by name).
    function openExtraNote(key, title) {
        broker.sendSimpleSignal("retasker.newnote", JSON.stringify({
            name: root.dayNoteName(key, title),
            template: settings.noteTemplateFilename
        }));
        root.close();
    }

    // Create a titled note for the day, remember it locally, and open it.
    function createExtraNote(key, title) {
        var t = title.trim();
        if (t === "")
            return;
        var list = root.notesMap[key] ? root.notesMap[key].slice() : [];
        if (list.indexOf(t) === -1)
            list.push(t);
        var next = {};
        for (var k in root.notesMap)
            next[k] = root.notesMap[k];
        next[key] = list;
        root.notesMap = next;
        settings.notesJson = JSON.stringify(next);
        broker.sendSimpleSignal("retasker.newnote", JSON.stringify({
            name: root.dayNoteName(key, t),
            template: settings.noteTemplateFilename
        }));
        root.close();
    }

    function activeDay() {
        return root.selectedDay !== "" ? root.selectedDay : root.todayKey;
    }

    function templateLabel() {
        return settings.noteTemplateName ? settings.noteTemplateName : "Blank";
    }

    function chooseDefaultTemplate() {
        settings.openSettingsOnStart = true;
        broker.sendSimpleSignal("retasker.chooseTemplate", JSON.stringify({
            template: settings.noteTemplateFilename
        }));
        root.close();
    }

    function resetDefaultTemplate() {
        settings.noteTemplateFilename = "";
        settings.noteTemplateName = "Blank";
        settings.noteTemplateLandscape = false;
        broker.sendSimpleSignal("retasker.template", JSON.stringify({
            filename: "",
            name: "Blank",
            landscape: false
        }));
    }

    function applyTemplateConfig(cfg) {
        settings.noteTemplateFilename = cfg && cfg.filename ? cfg.filename : "";
        settings.noteTemplateName = cfg && cfg.name ? cfg.name : "Blank";
        settings.noteTemplateLandscape = cfg && cfg.landscape === true;
    }

    function loadTemplateConfig() {
        var xhr = new XMLHttpRequest();
        xhr.open("GET", root.appDir + "/template.json");
        xhr.onreadystatechange = function () {
            if (xhr.readyState !== XMLHttpRequest.DONE)
                return;
            if (!xhr.responseText)
                return;
            try {
                root.applyTemplateConfig(JSON.parse(xhr.responseText));
            } catch (e) {
                root.applyTemplateConfig({});
            }
        };
        xhr.send();
    }

    // --- Header: title, filter segments, close ---------------------------
    Rectangle {
        id: header
        anchors {
            top: parent.top
            left: parent.left
            right: parent.right
        }
        height: 240
        color: "white"

        Text {
            id: title
            anchors {
                left: parent.left
                leftMargin: root.settingsOpen ? 112 : 32
                top: parent.top
                topMargin: 24
            }
            text: root.settingsOpen ? "Settings" : "reTasker"
            font.pixelSize: 56
            font.bold: true
            color: "black"
        }

        Item {
            id: backBtn
            width: 56
            height: 56
            visible: root.settingsOpen
            anchors {
                left: parent.left
                leftMargin: 32
                verticalCenter: title.verticalCenter
            }
            Canvas {
                anchors.fill: parent
                onPaint: {
                    var ctx = getContext("2d");
                    ctx.reset();
                    ctx.strokeStyle = "black";
                    ctx.lineWidth = 7;
                    ctx.lineCap = "round";
                    ctx.lineJoin = "round";
                    ctx.beginPath();
                    ctx.moveTo(width * 0.68, height * 0.18);
                    ctx.lineTo(width * 0.28, height * 0.50);
                    ctx.lineTo(width * 0.68, height * 0.82);
                    ctx.stroke();
                }
                Component.onCompleted: requestPaint()
            }
            MouseArea {
                anchors.fill: parent
                anchors.margins: -24
                onClicked: root.settingsOpen = false
            }
        }

        Item {
            id: closeBtn
            width: 52
            height: 52
            anchors {
                right: parent.right
                rightMargin: 40
                verticalCenter: title.verticalCenter
            }
            Rectangle {
                anchors.centerIn: parent
                width: parent.width
                height: 6
                radius: 3
                color: "black"
                rotation: 45
            }
            Rectangle {
                anchors.centerIn: parent
                width: parent.width
                height: 6
                radius: 3
                color: "black"
                rotation: -45
            }
            MouseArea {
                anchors.fill: parent
                anchors.margins: -24
                onClicked: root.close()
            }
        }

        Item {
            id: settingsBtn
            width: 56
            height: 56
            visible: !root.settingsOpen
            anchors {
                right: closeBtn.left
                rightMargin: 44
                verticalCenter: title.verticalCenter
            }
            Canvas {
                anchors.fill: parent
                onPaint: {
                    var ctx = getContext("2d");
                    ctx.reset();
                    ctx.strokeStyle = "black";
                    ctx.lineWidth = 5;
                    ctx.lineCap = "round";
                    ctx.lineJoin = "round";
                    ctx.beginPath();
                    for (var i = 0; i < 8; i++) {
                        var a = i * Math.PI / 4;
                        var x1 = width * 0.50 + Math.cos(a) * width * 0.31;
                        var y1 = height * 0.50 + Math.sin(a) * height * 0.31;
                        var x2 = width * 0.50 + Math.cos(a) * width * 0.42;
                        var y2 = height * 0.50 + Math.sin(a) * height * 0.42;
                        ctx.moveTo(x1, y1);
                        ctx.lineTo(x2, y2);
                    }
                    ctx.stroke();
                    ctx.beginPath();
                    ctx.arc(width * 0.50, height * 0.50, width * 0.24, 0, Math.PI * 2);
                    ctx.stroke();
                    ctx.beginPath();
                    ctx.arc(width * 0.50, height * 0.50, width * 0.09, 0, Math.PI * 2);
                    ctx.stroke();
                }
                Component.onCompleted: requestPaint()
            }
            MouseArea {
                anchors.fill: parent
                anchors.margins: -24
                onClicked: root.settingsOpen = true
            }
        }

        Row {
            anchors {
                left: parent.left
                leftMargin: 32
                top: title.bottom
                topMargin: 28
            }
            spacing: 24
            visible: !root.settingsOpen

            // Primary view switch: flat list vs month calendar.
            Row {
                spacing: 0
                Repeater {
                    model: [
                        {
                            key: "list",
                            text: "List"
                        },
                        {
                            key: "calendar",
                            text: "Calendar"
                        }
                    ]
                    delegate: Rectangle {
                        required property var modelData
                        width: 200
                        height: 88
                        color: root.viewMode === modelData.key ? "black" : "white"
                        border.color: "black"
                        border.width: 2
                        Text {
                            anchors.centerIn: parent
                            text: modelData.text
                            font.pixelSize: 36
                            color: root.viewMode === modelData.key ? "white" : "black"
                        }
                        MouseArea {
                            anchors.fill: parent
                            onClicked: {
                                root.viewMode = modelData.key;
                                settings.viewMode = modelData.key;
                                root.selectedDay = modelData.key === "calendar" ? root.todayKey : "";
                                root.refresh();
                            }
                        }
                    }
                }
            }

            // Status filter — only meaningful for the flat list.
            Row {
                spacing: 0
                visible: root.viewMode === "list"
                Repeater {
                    model: [
                        {
                            key: "todo",
                            text: "To do"
                        },
                        {
                            key: "done",
                            text: "Done"
                        },
                        {
                            key: "all",
                            text: "All"
                        }
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
                            onClicked: {
                                root.filter = modelData.key;
                                root.refresh();
                            }
                        }
                    }
                }
            }
        }

        Rectangle {
            anchors {
                left: parent.left
                right: parent.right
                bottom: parent.bottom
            }
            height: 3
            color: "black"
        }
    }

    // --- Month calendar (upper pane in calendar view) ---------------------
    MonthView {
        id: monthPane
        anchors {
            top: header.bottom
            left: parent.left
            right: parent.right
        }
        height: (root.height - header.height) * 0.58
        visible: !root.settingsOpen && root.viewMode === "calendar"
        year: root.shownYear
        month: root.shownMonth
        dayIndex: root.dayIndex
        notesMap: root.notesMap
        dayNoteMap: root.dayNoteMap
        todayKey: root.todayKey
        selectedKey: root.selectedDay
        onDayClicked: function (key) {
            root.selectedDay = (key === root.selectedDay) ? "" : key;
            root.refresh();
        }
        onPrevMonth: root.shiftMonth(-1)
        onNextMonth: root.shiftMonth(1)
    }

    // Context strip above the todo list while in calendar view: the shown month,
    // or the selected day with a tap-to-clear back to the whole month.
    Rectangle {
        id: listBar
        anchors {
            top: monthPane.bottom
            left: parent.left
            right: parent.right
        }
        height: 72
        visible: !root.settingsOpen && root.viewMode === "calendar"
        color: "white"

        Row {
            anchors {
                left: parent.left
                leftMargin: 32
                verticalCenter: parent.verticalCenter
            }
            spacing: 20

            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: root.selectedDay !== "" ? ("‹ " + root.dayLabel(root.selectedDay)) : root.monthLabel
                font.pixelSize: 34
                font.bold: true
                color: "black"
            }

            // Whole-month-done badge (only on the month label, not a day view).
            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: 48
                height: 48
                radius: 24
                visible: root.selectedDay === "" && root.monthAllDone
                color: "black"

                Canvas {
                    anchors.centerIn: parent
                    width: 30
                    height: 30
                    onPaint: {
                        var ctx = getContext("2d");
                        ctx.reset();
                        ctx.strokeStyle = "white";
                        ctx.lineWidth = 5;
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
            }
        }
        MouseArea {
            anchors.fill: parent
            enabled: root.selectedDay !== ""
            onClicked: {
                root.selectedDay = "";
                root.refresh();
            }
        }

        // Single entry point to the selected day's notes: opens a sheet listing
        // the day's notes (tap to open) with actions to add a titled note or open
        // the day's main note. The sheet's actions go through the native bridge,
        // which creates/opens the real notebook; closing the viewer drops the
        // user into it.
        Rectangle {
            id: notesBtn
            anchors {
                right: parent.right
                rightMargin: 32
                verticalCenter: parent.verticalCenter
            }
            width: 240
            height: 60
            color: "black"
            Text {
                anchors.centerIn: parent
                text: "Notes"
                font.pixelSize: 30
                color: "white"
            }
            MouseArea {
                anchors.fill: parent
                onClicked: {
                    root.addNoteDay = root.activeDay();
                    root.addSheetMode = "list";
                    root.addNoteOpen = true;
                }
            }
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

    // --- Todo list --------------------------------------------------------
    // The flat list in list view; the month's (or selected day's) todos below
    // the grid in calendar view.
    ListView {
        id: list
        anchors {
            top: root.viewMode === "calendar" ? listBar.bottom : header.bottom
            left: parent.left
            right: parent.right
            bottom: parent.bottom
        }
        visible: !root.settingsOpen
        model: rows
        clip: true
        cacheBuffer: 0
        highlightMoveDuration: 0
        boundsBehavior: Flickable.StopAtBounds

        // Pull the next page from the backend as the end comes into view.
        onContentYChanged: if (root.moreAvailable && contentY + height >= contentHeight - 400)
            root.loadMore()

        delegate: TodoDelegate {
            width: list.width
            name: model.name
            kind: model.kind
            text: model.text
            imageUrl: model.url
            done: model.done
            dateText: model.dateText
            onToggleClicked: root.toggle(model.base)
            onLongPressed: root.openRowMenu(model.name)
        }
    }

    Text {
        anchors.centerIn: list
        visible: !root.settingsOpen && rows.count === 0
        text: root.filter === "done" && root.viewMode === "list" ? "Nothing done yet" : "No todos"
        font.pixelSize: 40
        color: "black"
    }

    // --- Settings ---------------------------------------------------------
    Rectangle {
        id: settingsPage
        anchors {
            top: header.bottom
            left: parent.left
            right: parent.right
            bottom: parent.bottom
        }
        visible: root.settingsOpen
        color: "white"

        Column {
            anchors {
                top: parent.top
                left: parent.left
                right: parent.right
            }

            Rectangle {
                width: parent.width
                height: 150
                color: "white"

                Column {
                    anchors {
                        left: parent.left
                        leftMargin: 32
                        verticalCenter: parent.verticalCenter
                    }
                    width: parent.width - 420
                    spacing: 10
                    Text {
                        text: "Default template"
                        font.pixelSize: 38
                        font.bold: true
                        color: "black"
                    }
                    Text {
                        width: parent.width
                        text: root.templateLabel()
                        font.pixelSize: 30
                        color: "black"
                        elide: Text.ElideRight
                    }
                }

                Row {
                    anchors {
                        right: parent.right
                        rightMargin: 32
                        verticalCenter: parent.verticalCenter
                    }
                    spacing: 20

                    Rectangle {
                        width: 170
                        height: 76
                        color: "white"
                        border.color: "black"
                        border.width: 3
                        Text {
                            anchors.centerIn: parent
                            text: "Reset"
                            font.pixelSize: 32
                            color: "black"
                        }
                        MouseArea {
                            anchors.fill: parent
                            onClicked: root.resetDefaultTemplate()
                        }
                    }

                    Rectangle {
                        width: 190
                        height: 76
                        color: "black"
                        border.color: "black"
                        border.width: 3
                        Text {
                            anchors.centerIn: parent
                            text: "Choose"
                            font.pixelSize: 32
                            color: "white"
                        }
                        MouseArea {
                            anchors.fill: parent
                            onClicked: root.chooseDefaultTemplate()
                        }
                    }
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
        }
    }

    // --- Delete confirmation ---------------------------------------------
    // Opaque modal: long-pressing a row sets pendingDelete, which shows this.
    Rectangle {
        id: confirm
        anchors.fill: parent
        visible: root.pendingDelete !== ""
        color: "white"

        // Swallow taps so nothing behind the modal reacts.
        MouseArea {
            anchors.fill: parent
        }

        Rectangle {
            anchors.centerIn: parent
            width: 720
            height: 560
            color: "white"
            border.color: "black"
            border.width: 4

            Text {
                id: confirmTitle
                anchors {
                    top: parent.top
                    topMargin: 48
                    horizontalCenter: parent.horizontalCenter
                }
                text: "Delete this todo?"
                font.pixelSize: 46
                font.bold: true
                color: "black"
            }

            // Preview of the todo being deleted — the text, or the snippet image.
            Rectangle {
                id: preview
                anchors {
                    top: confirmTitle.bottom
                    topMargin: 32
                    left: parent.left
                    leftMargin: 48
                    right: parent.right
                    rightMargin: 48
                }
                height: 180
                color: "white"
                border.color: "black"
                border.width: 2

                Text {
                    anchors {
                        fill: parent
                        margins: 20
                    }
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
                    anchors {
                        fill: parent
                        margins: 16
                    }
                    visible: root.pendingKind === "image"
                    source: root.pendingKind === "image" ? root.pendingUrl : ""
                    fillMode: Image.PreserveAspectFit
                    smooth: true
                    asynchronous: true
                }
            }

            Text {
                anchors {
                    top: preview.bottom
                    topMargin: 24
                    horizontalCenter: parent.horizontalCenter
                }
                text: "This cannot be undone."
                font.pixelSize: 30
                color: "black"
            }

            Row {
                anchors {
                    bottom: parent.bottom
                    bottomMargin: 48
                    horizontalCenter: parent.horizontalCenter
                }
                spacing: 40

                Rectangle {
                    width: 260
                    height: 100
                    color: "white"
                    border.color: "black"
                    border.width: 3
                    Text {
                        anchors.centerIn: parent
                        text: "Cancel"
                        font.pixelSize: 40
                        color: "black"
                    }
                    MouseArea {
                        anchors.fill: parent
                        onClicked: root.pendingDelete = ""
                    }
                }

                Rectangle {
                    width: 260
                    height: 100
                    color: "black"
                    border.color: "black"
                    border.width: 3
                    Text {
                        anchors.centerIn: parent
                        text: "Delete"
                        font.pixelSize: 40
                        color: "white"
                    }
                    MouseArea {
                        anchors.fill: parent
                        onClicked: root.confirmDelete()
                    }
                }
            }
        }
    }

    // --- Row action menu (long-press) ------------------------------------
    // Opaque modal: long-pressing a row sets menuName, which shows this. Modify
    // opens the edit sheet; Delete drops to the existing delete confirmation.
    Rectangle {
        id: rowMenu
        anchors.fill: parent
        visible: root.menuName !== ""
        color: "white"

        // Swallow taps so nothing behind the modal reacts.
        MouseArea {
            anchors.fill: parent
        }

        Rectangle {
            anchors.centerIn: parent
            width: 720
            height: 740
            color: "white"
            border.color: "black"
            border.width: 4

            // Preview of the todo being acted on — its text, or the snippet image.
            Rectangle {
                id: menuPreview
                anchors {
                    top: parent.top
                    topMargin: 48
                    left: parent.left
                    leftMargin: 48
                    right: parent.right
                    rightMargin: 48
                }
                height: 200
                color: "white"
                border.color: "black"
                border.width: 2

                Text {
                    anchors {
                        fill: parent
                        margins: 20
                    }
                    visible: root.menuKind === "text"
                    text: root.menuText
                    font.pixelSize: 36
                    color: "black"
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                    wrapMode: Text.WordWrap
                    maximumLineCount: 3
                    elide: Text.ElideRight
                }

                Image {
                    anchors {
                        fill: parent
                        margins: 16
                    }
                    visible: root.menuKind === "image"
                    source: root.menuKind === "image" ? root.menuUrl : ""
                    fillMode: Image.PreserveAspectFit
                    smooth: true
                    asynchronous: true
                }
            }

            Column {
                anchors {
                    top: menuPreview.bottom
                    topMargin: 40
                    horizontalCenter: parent.horizontalCenter
                }
                spacing: 28

                // Modify a text todo; for an image, the same action is a manual
                // transcription, so it reads "Transcribe".
                Rectangle {
                    width: 560
                    height: 100
                    color: "black"
                    border.color: "black"
                    border.width: 3
                    Text {
                        anchors.centerIn: parent
                        text: root.menuKind === "image" ? "Transcribe" : "Modify"
                        font.pixelSize: 40
                        color: "white"
                    }
                    MouseArea {
                        anchors.fill: parent
                        onClicked: root.editFromMenu()
                    }
                }

                Rectangle {
                    width: 560
                    height: 100
                    color: "white"
                    border.color: "black"
                    border.width: 3
                    Text {
                        anchors.centerIn: parent
                        text: "Delete"
                        font.pixelSize: 40
                        color: "black"
                    }
                    MouseArea {
                        anchors.fill: parent
                        onClicked: root.deleteFromMenu()
                    }
                }

                Rectangle {
                    width: 560
                    height: 100
                    color: "white"
                    border.color: "#aaaaaa"
                    border.width: 3
                    Text {
                        anchors.centerIn: parent
                        text: "Cancel"
                        font.pixelSize: 40
                        color: "black"
                    }
                    MouseArea {
                        anchors.fill: parent
                        onClicked: root.menuName = ""
                    }
                }
            }
        }
    }

    // --- Edit sheet -------------------------------------------------------
    // Modify a todo's text. Saving writes <base>.txt through the transcribe
    // path; for an image todo that also drops the .png (a manual transcription).
    // Text entry relies on the device on-screen keyboard appearing on focus.
    Rectangle {
        id: editSheet
        anchors.fill: parent
        visible: root.editName !== ""
        color: "white"

        // Swallow taps so nothing behind the modal reacts.
        MouseArea {
            anchors.fill: parent
        }

        Rectangle {
            anchors.centerIn: parent
            width: 820
            height: 720
            color: "white"
            border.color: "black"
            border.width: 4

            Text {
                id: editTitle
                anchors {
                    top: parent.top
                    topMargin: 40
                    left: parent.left
                    leftMargin: 48
                }
                text: "Edit todo"
                font.pixelSize: 44
                font.bold: true
                color: "black"
            }

            Rectangle {
                id: editBox
                anchors {
                    top: editTitle.bottom
                    topMargin: 28
                    left: parent.left
                    leftMargin: 48
                    right: parent.right
                    rightMargin: 48
                    bottom: editButtons.top
                    bottomMargin: 40
                }
                color: "white"
                border.color: "black"
                border.width: 3

                Flickable {
                    anchors {
                        fill: parent
                        margins: 20
                    }
                    contentWidth: width
                    contentHeight: editField.implicitHeight
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds

                    TextEdit {
                        id: editField
                        width: parent.width
                        font.pixelSize: 38
                        color: "black"
                        wrapMode: TextEdit.Wrap
                        selectByMouse: false
                    }
                }

                Text {
                    anchors {
                        left: parent.left
                        leftMargin: 20
                        top: parent.top
                        topMargin: 20
                    }
                    visible: editField.text === ""
                    text: "Type the todo text"
                    font.pixelSize: 38
                    color: "#888888"
                }
            }

            Row {
                id: editButtons
                anchors {
                    bottom: parent.bottom
                    bottomMargin: 40
                    horizontalCenter: parent.horizontalCenter
                }
                spacing: 40

                Rectangle {
                    width: 260
                    height: 100
                    color: "white"
                    border.color: "black"
                    border.width: 3
                    Text {
                        anchors.centerIn: parent
                        text: "Cancel"
                        font.pixelSize: 40
                        color: "black"
                    }
                    MouseArea {
                        anchors.fill: parent
                        onClicked: root.closeEdit()
                    }
                }

                Rectangle {
                    readonly property bool ready: editField.text.trim() !== ""
                    width: 260
                    height: 100
                    color: ready ? "black" : "white"
                    border.color: ready ? "black" : "#aaaaaa"
                    border.width: 3
                    Text {
                        anchors.centerIn: parent
                        text: "Save"
                        font.pixelSize: 40
                        color: parent.ready ? "white" : "#aaaaaa"
                    }
                    MouseArea {
                        anchors.fill: parent
                        enabled: editField.text.trim() !== ""
                        onClicked: root.saveEdit()
                    }
                }
            }
        }
    }

    // --- Day-notes sheet --------------------------------------------------
    // List mode browses/opens the selected day's notes (its main note plus any
    // titled extras); new mode takes a title for a new one. Title entry relies on
    // the device on-screen keyboard appearing when the field gains focus.
    Rectangle {
        id: addSheet
        anchors.fill: parent
        visible: root.addNoteOpen
        color: "white"

        // Swallow taps so nothing behind reacts.
        MouseArea {
            anchors.fill: parent
        }

        Rectangle {
            anchors.centerIn: parent
            width: 760
            height: 820
            color: "white"
            border.color: "black"
            border.width: 4

            Text {
                id: addTitle
                anchors {
                    top: parent.top
                    topMargin: 40
                    left: parent.left
                    leftMargin: 48
                    right: parent.right
                    rightMargin: 120
                }
                text: "Notes for " + root.dayLabel(root.addNoteDay)
                font.pixelSize: 44
                font.bold: true
                color: "black"
                elide: Text.ElideRight
            }

            // Dismiss the whole sheet.
            Item {
                width: 52
                height: 52
                anchors {
                    top: parent.top
                    topMargin: 40
                    right: parent.right
                    rightMargin: 44
                }
                Rectangle {
                    anchors.centerIn: parent
                    width: parent.width
                    height: 6
                    radius: 3
                    color: "black"
                    rotation: 45
                }
                Rectangle {
                    anchors.centerIn: parent
                    width: parent.width
                    height: 6
                    radius: 3
                    color: "black"
                    rotation: -45
                }
                MouseArea {
                    anchors.fill: parent
                    anchors.margins: -24
                    onClicked: root.addNoteOpen = false
                }
            }

            // ---- List mode: the day's notes -----------------------------
            Item {
                visible: root.addSheetMode === "list"
                anchors {
                    top: addTitle.bottom
                    topMargin: 24
                    left: parent.left
                    leftMargin: 48
                    right: parent.right
                    rightMargin: 48
                    bottom: parent.bottom
                    bottomMargin: 180
                }

                Text {
                    id: listHint
                    anchors {
                        top: parent.top
                        left: parent.left
                    }
                    text: existingList.count > 0 ? "Tap a note to open it" : "No notes for this day yet."
                    font.pixelSize: 28
                    color: "black"
                }

                ListView {
                    id: existingList
                    anchors {
                        top: listHint.bottom
                        topMargin: 16
                        left: parent.left
                        right: parent.right
                        bottom: parent.bottom
                    }
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    spacing: 12
                    model: root.dayNotes(root.addNoteDay)
                    delegate: Rectangle {
                        id: noteRow
                        required property var modelData
                        width: existingList.width
                        height: 76
                        color: "white"
                        border.color: "black"
                        border.width: 2

                        Text {
                            anchors {
                                left: parent.left
                                leftMargin: 20
                                right: removeBtn.left
                                rightMargin: 12
                                verticalCenter: parent.verticalCenter
                            }
                            text: noteRow.modelData.label
                            font.pixelSize: 32
                            font.bold: noteRow.modelData.kind === "day"
                            color: "black"
                            elide: Text.ElideRight
                        }

                        // Open the note (whole row except the remove button).
                        MouseArea {
                            anchors {
                                left: parent.left
                                top: parent.top
                                bottom: parent.bottom
                                right: removeBtn.left
                            }
                            onClicked: {
                                if (noteRow.modelData.kind === "day")
                                    root.openDayNote(root.addNoteDay);
                                else
                                    root.openExtraNote(root.addNoteDay, noteRow.modelData.title);
                            }
                        }

                        // Forget a hand-deleted note (local record only).
                        Item {
                            id: removeBtn
                            width: 76
                            anchors {
                                top: parent.top
                                bottom: parent.bottom
                                right: parent.right
                            }
                            Rectangle {
                                anchors {
                                    left: parent.left
                                    top: parent.top
                                    topMargin: 14
                                    bottomMargin: 14
                                }
                                width: 2
                                height: parent.height - 28
                                color: "black"
                            }
                            Rectangle {
                                anchors.centerIn: parent
                                width: 30
                                height: 5
                                radius: 2
                                color: "black"
                                rotation: 45
                            }
                            Rectangle {
                                anchors.centerIn: parent
                                width: 30
                                height: 5
                                radius: 2
                                color: "black"
                                rotation: -45
                            }
                            MouseArea {
                                anchors.fill: parent
                                onClicked: {
                                    if (noteRow.modelData.kind === "day")
                                        root.askForget("day", "", noteRow.modelData.label);
                                    else
                                        root.askForget("extra", noteRow.modelData.title, noteRow.modelData.label);
                                }
                            }
                        }
                    }
                }
            }

            // List-mode actions: start a new titled note, or open the day's main note.
            Row {
                visible: root.addSheetMode === "list"
                anchors {
                    bottom: parent.bottom
                    bottomMargin: 40
                    horizontalCenter: parent.horizontalCenter
                }
                spacing: 40

                Rectangle {
                    width: 300
                    height: 100
                    color: "white"
                    border.color: "black"
                    border.width: 3
                    Text {
                        anchors.centerIn: parent
                        text: "+ New note"
                        font.pixelSize: 38
                        color: "black"
                    }
                    MouseArea {
                        anchors.fill: parent
                        onClicked: {
                            root.addSheetMode = "new";
                            titleField.text = "";
                            titleField.forceActiveFocus();
                        }
                    }
                }

                Rectangle {
                    width: 300
                    height: 100
                    color: "black"
                    border.color: "black"
                    border.width: 3
                    Text {
                        anchors.centerIn: parent
                        text: root.addNoteDay === root.todayKey ? "Today's note" : "Day's note"
                        font.pixelSize: 38
                        color: "white"
                    }
                    MouseArea {
                        anchors.fill: parent
                        onClicked: root.openDayNote(root.addNoteDay)
                    }
                }
            }

            // ---- New mode: title entry ----------------------------------
            Item {
                visible: root.addSheetMode === "new"
                anchors {
                    top: addTitle.bottom
                    topMargin: 24
                    left: parent.left
                    leftMargin: 48
                    right: parent.right
                    rightMargin: 48
                    bottom: parent.bottom
                    bottomMargin: 180
                }

                Text {
                    id: inputLabel
                    anchors {
                        top: parent.top
                        left: parent.left
                    }
                    text: "New note title"
                    font.pixelSize: 28
                    color: "black"
                }

                Rectangle {
                    id: inputBox
                    anchors {
                        top: inputLabel.bottom
                        topMargin: 16
                        left: parent.left
                        right: parent.right
                    }
                    height: 92
                    color: "white"
                    border.color: "black"
                    border.width: 3

                    TextInput {
                        id: titleField
                        anchors {
                            fill: parent
                            leftMargin: 20
                            rightMargin: 20
                        }
                        font.pixelSize: 38
                        color: "black"
                        clip: true
                        verticalAlignment: TextInput.AlignVCenter
                        onAccepted: root.createExtraNote(root.addNoteDay, titleField.text)
                    }

                    Text {
                        anchors {
                            left: parent.left
                            leftMargin: 20
                            verticalCenter: parent.verticalCenter
                        }
                        visible: titleField.text === ""
                        text: "e.g. Standup, 1:1 with Alex"
                        font.pixelSize: 38
                        color: "#888888"
                    }
                }
            }

            // New-mode actions: back to the list, or create the titled note.
            Row {
                visible: root.addSheetMode === "new"
                anchors {
                    bottom: parent.bottom
                    bottomMargin: 40
                    horizontalCenter: parent.horizontalCenter
                }
                spacing: 40

                Rectangle {
                    width: 260
                    height: 100
                    color: "white"
                    border.color: "black"
                    border.width: 3
                    Text {
                        anchors.centerIn: parent
                        text: "Back"
                        font.pixelSize: 40
                        color: "black"
                    }
                    MouseArea {
                        anchors.fill: parent
                        onClicked: root.addSheetMode = "list"
                    }
                }

                Rectangle {
                    readonly property bool ready: titleField.text.trim() !== ""
                    width: 260
                    height: 100
                    color: ready ? "black" : "white"
                    border.color: ready ? "black" : "#aaaaaa"
                    border.width: 3
                    Text {
                        anchors.centerIn: parent
                        text: "Create"
                        font.pixelSize: 40
                        color: parent.ready ? "white" : "#aaaaaa"
                    }
                    MouseArea {
                        anchors.fill: parent
                        enabled: titleField.text.trim() !== ""
                        onClicked: root.createExtraNote(root.addNoteDay, titleField.text)
                    }
                }
            }
        }
    }

    // --- Forget-note confirmation ----------------------------------------
    // Removing a row only drops reTasker's local record; the notebook (if it
    // still exists) is untouched. Stacks above the day-notes sheet.
    Rectangle {
        id: forgetConfirm
        anchors.fill: parent
        visible: root.pendingForgetKind !== ""
        color: "white"

        // Swallow taps so nothing behind the modal reacts.
        MouseArea {
            anchors.fill: parent
        }

        Rectangle {
            anchors.centerIn: parent
            width: 720
            height: 520
            color: "white"
            border.color: "black"
            border.width: 4

            Text {
                id: forgetTitle
                anchors {
                    top: parent.top
                    topMargin: 48
                    horizontalCenter: parent.horizontalCenter
                }
                text: "Remove from list?"
                font.pixelSize: 46
                font.bold: true
                color: "black"
            }

            Text {
                id: forgetName
                anchors {
                    top: forgetTitle.bottom
                    topMargin: 36
                    left: parent.left
                    leftMargin: 48
                    right: parent.right
                    rightMargin: 48
                }
                text: root.pendingForgetLabel
                font.pixelSize: 40
                color: "black"
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                maximumLineCount: 2
                elide: Text.ElideRight
            }

            Text {
                anchors {
                    top: forgetName.bottom
                    topMargin: 28
                    left: parent.left
                    leftMargin: 48
                    right: parent.right
                    rightMargin: 48
                }
                text: "This only removes it from reTasker. The notebook itself is not deleted."
                font.pixelSize: 28
                color: "black"
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
            }

            Row {
                anchors {
                    bottom: parent.bottom
                    bottomMargin: 48
                    horizontalCenter: parent.horizontalCenter
                }
                spacing: 40

                Rectangle {
                    width: 260
                    height: 100
                    color: "white"
                    border.color: "black"
                    border.width: 3
                    Text {
                        anchors.centerIn: parent
                        text: "Cancel"
                        font.pixelSize: 40
                        color: "black"
                    }
                    MouseArea {
                        anchors.fill: parent
                        onClicked: root.pendingForgetKind = ""
                    }
                }

                Rectangle {
                    width: 260
                    height: 100
                    color: "black"
                    border.color: "black"
                    border.width: 3
                    Text {
                        anchors.centerIn: parent
                        text: "Remove"
                        font.pixelSize: 40
                        color: "white"
                    }
                    MouseArea {
                        anchors.fill: parent
                        onClicked: root.confirmForget()
                    }
                }
            }
        }
    }

    Component.onCompleted: {
        var now = new Date();
        root.shownYear = now.getFullYear();
        root.shownMonth = now.getMonth();
        root.todayKey = Cal.dateKey(now);
        root.viewMode = settings.viewMode;
        // Calendar view opens scoped to today; the list shows everything.
        if (root.viewMode === "calendar")
            root.selectedDay = root.todayKey;
        if (settings.openSettingsOnStart) {
            root.settingsOpen = true;
            settings.openSettingsOnStart = false;
        }
        loadTemplateConfig();
        loadOcrConfig();
        refresh();
    }
}
