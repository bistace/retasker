import QtQuick
import Qt.labs.folderlistmodel
import Qt.labs.settings
import net.asivery.XoviMessageBroker 2.0
import net.asivery.AppLoad 1.0
import "store.js" as Store
import "ocr.js" as Ocr
import "calendar.js" as Cal

// reTasker viewer -- an AppLoad app backed by retasker-backend.
//
// Todos live in a SQLite database owned by the backend process (this Qt build
// ships no SQLite, so the viewer can't open one itself -- it talks to the backend
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
    property int menuChildCount: 0   // gates "Make subtask of..." (only childless rows)

    // Parent picker: nestChildBase (a row's base) drives visibility; the picker
    // lists top-level todos to nest it under. nestChildText previews the subtask.
    property string nestChildBase: ""
    property string nestChildText: ""

    // Edit sheet: editName (a row filename) drives visibility; editBase keys the
    // write. The field starts from the current transcription (empty for an image).
    property string editName: ""
    property string editBase: ""

    // Add-todo sheet: a todo typed in the viewer instead of captured. addTodoOpen
    // drives visibility; addTodoDay ("y-m-d") is the day it's filed under. Calendar
    // view fixes that to the active day; list view picks it with the embedded month
    // grid (addPickYear/Month drive which month it shows). addSeq disambiguates the
    // base when several todos are added within the same millisecond.
    property bool addTodoOpen: false
    property string addTodoDay: ""
    property int addPickYear: 0
    property int addPickMonth: 0
    property int addSeq: 0

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
    // Transcriptions run through a bounded queue so a burst of captures can't
    // fire hundreds of concurrent requests at the provider.
    property var ocrConfig: null
    property var ocrTried: ({})
    property var ocrQueue: []     // {base, url} jobs waiting for a slot
    property int ocrInFlight: 0
    readonly property int ocrMax: 3

    // Backend (retasker-backend, an AppLoad process owning the SQLite DB). The
    // viewer only loads once the backend signals READY -- messages sent before its
    // socket is registered are dropped. Todos are fetched one page at a time.
    property bool backendReady: false
    property int pageSize: 200
    property int loadedOffset: 0
    property bool moreAvailable: false
    property var ingested: ({})          // PNG bases ingested this session
    // Wire-protocol message types. KEEP IN SYNC with the MSG_* defines in
    // src/backend/src/main.c -- both sides hand-maintain this numbering.
    readonly property int msgQuery: 1
    readonly property int msgSetDone: 2
    readonly property int msgSetText: 3
    readonly property int msgDelete: 4
    readonly property int msgIngest: 5
    readonly property int msgCal: 6
    readonly property int msgAdd: 7
    readonly property int msgSetParent: 8
    readonly property int msgChildren: 9
    readonly property int msgReady: 100
    readonly property int msgRows: 101
    readonly property int msgIngested: 102
    readonly property int msgCalRows: 103
    readonly property int msgChildRows: 104

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

    // Broker for native newnote/chooseTemplate signals.
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
        var data;
        try {
            data = JSON.parse(contents);
        } catch (e) {
            return;  // malformed reply: drop it, matching the other parses
        }
        if (type === root.msgRows) {
            if (data.offset === 0)
                rows.clear();
            var list = data.rows || [];
            for (var i = 0; i < list.length; i++)
                root.appendRow(list[i]);
            root.loadedOffset = data.offset + list.length;
            root.moreAvailable = list.length === root.pageSize;
        } else if (type === root.msgChildRows) {
            root.insertChildren(data.base, data.rows || []);
        } else if (type === root.msgCalRows) {
            root.dayIndex = Cal.buildIndex(data.rows || []);
        } else if (type === root.msgIngested) {
            if ((data.new || 0) > 0)
                root.refresh();  // new todos landed: re-query the current view
        }
    }

    // Turn a backend todo row into a list-model entry. An image row (awaiting
    // OCR) points at its PNG; a text row carries its transcription. `parentBase`
    // is "" for a top-level row, or the parent's base for a spliced-in subtask.
    function rowEntry(r, parentBase) {
        var image = r.hasImage === 1 || r.hasImage === true;
        return {
            base: r.base,
            name: r.base + (image ? ".png" : ".txt"),
            kind: image ? "image" : "text",
            text: r.text ? r.text : "",
            url: root.capturesDir + "/" + r.base + ".png",
            done: r.done === 1 || r.done === true,
            dateText: Qt.formatDateTime(new Date(r.ts), "d MMM HH:mm"),
            parent: parentBase,
            isChild: parentBase !== "",
            childCount: r.childCount || 0,
            childOpen: r.childOpen || 0,
            expanded: false
        };
    }

    function appendRow(r) {
        rows.append(root.rowEntry(r, ""));
    }

    // Splice a parent's children into the flat model right after it, marking it
    // expanded. The reply can arrive for a parent that's since been collapsed or
    // dropped, so re-check before inserting; ignore a second reply once expanded.
    function insertChildren(parentBase, list) {
        for (var i = 0; i < rows.count; i++) {
            if (rows.get(i).base === parentBase && !rows.get(i).isChild) {
                if (rows.get(i).expanded)
                    return;
                rows.setProperty(i, "expanded", true);
                for (var j = 0; j < list.length; j++)
                    rows.insert(i + 1 + j, root.rowEntry(list[j], parentBase));
                return;
            }
        }
    }

    // Expand a collapsed parent (fetch its children lazily) or collapse an
    // expanded one (drop the contiguous run of child rows that follow it).
    function toggleExpand(base) {
        for (var i = 0; i < rows.count; i++) {
            if (rows.get(i).base !== base || rows.get(i).isChild)
                continue;
            if (rows.get(i).expanded) {
                rows.setProperty(i, "expanded", false);
                var k = i + 1;
                while (k < rows.count && rows.get(k).isChild)
                    rows.remove(k);
            } else {
                backend.sendMessage(root.msgChildren, JSON.stringify({
                    base: base
                }));
            }
            return;
        }
    }

    // Keep a parent's open-count badge in step when one of its children toggles,
    // without re-querying (which would collapse the whole list).
    function adjustParentOpen(parentBase, delta) {
        for (var i = 0; i < rows.count; i++) {
            if (rows.get(i).base === parentBase && !rows.get(i).isChild) {
                var n = rows.get(i).childOpen + delta;
                rows.setProperty(i, "childOpen", n < 0 ? 0 : n);
                return;
            }
        }
    }

    // Ingest every capture the folder lists into the DB (the backend ignores
    // ones it already has) and OCR any not transcribed yet. This is the only use
    // of the folder model -- the displayed list comes from the backend.
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

    // Queue a capture for transcription (deduped per session by ocrTried) and
    // start it if a slot is free.
    function maybeTranscribe(base, url) {
        if (!root.ocrConfig || root.ocrTried[base])
            return;
        root.ocrTried[base] = true;
        root.ocrQueue.push({
            base: base,
            url: url
        });
        root.pumpOcr();
    }

    // Keep up to ocrMax transcriptions in flight; each completion frees a slot
    // and pulls the next job.
    function pumpOcr() {
        while (root.ocrInFlight < root.ocrMax && root.ocrQueue.length > 0) {
            var job = root.ocrQueue.shift();
            root.ocrInFlight += 1;
            root.transcribeJob(job.base, job.url);
        }
    }

    function transcribeJob(base, url) {
        Ocr.transcribe(url, root.ocrConfig, function (text) {
            root.ocrInFlight -= 1;
            if (text) {
                // offline/unreadable returns null: keep the image and move on
                backend.sendMessage(root.msgSetText, JSON.stringify({
                    base: base,
                    text: text
                }));
                root.applyTranscription(base, text);
            }
            root.pumpOcr();
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

    // GET a local JSON file and hand the parsed object to onParsed; passes null
    // when the file is missing/empty or doesn't parse, so callers decide.
    function loadJson(path, onParsed) {
        var xhr = new XMLHttpRequest();
        xhr.open("GET", path);
        xhr.onreadystatechange = function () {
            if (xhr.readyState !== XMLHttpRequest.DONE)
                return;
            var data = null;
            try {
                data = JSON.parse(xhr.responseText);
            } catch (e) {
                data = null;
            }
            onParsed(data);
        };
        xhr.send();
    }

    function loadOcrConfig() {
        root.loadJson(root.appDir + "/config.json", function (data) {
            root.ocrConfig = data;
            if (root.ocrConfig)
                root.syncFolder();
        });
    }

    function toggle(base) {
        var isChild = false;
        for (var i = 0; i < rows.count; i++) {
            if (rows.get(i).base === base) {
                var done = !rows.get(i).done;
                isChild = rows.get(i).isChild;
                var parentBase = rows.get(i).parent;
                rows.setProperty(i, "done", done);
                backend.sendMessage(root.msgSetDone, JSON.stringify({
                    base: base,
                    done: done
                }));
                if (isChild)
                    root.adjustParentOpen(parentBase, done ? -1 : 1);
                break;
            }
        }
        // Re-scope the view to match: a status-filtered list drops a top-level
        // row, and the calendar's per-day counts change. A child stays put -- an
        // expanded parent always shows all its children -- so it never re-queries.
        if (root.viewMode === "calendar")
            root.requestCal();
        else if (!isChild && root.filter !== "all")
            root.refresh();
    }

    // Find a loaded list row by its filename, or null if it's no longer present.
    function rowByName(name) {
        for (var i = 0; i < rows.count; i++) {
            if (rows.get(i).name === name)
                return rows.get(i);
        }
        return null;
    }

    function askDelete(name) {
        var r = root.rowByName(name);
        if (r) {
            root.pendingKind = r.kind;
            root.pendingText = r.text;
            root.pendingUrl = r.url;
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
        var r = root.rowByName(name);
        if (r) {
            root.menuBase = r.base;
            root.menuKind = r.kind;
            root.menuText = r.text;
            root.menuUrl = r.url;
            root.menuChildCount = r.childCount;
        }
        root.menuName = name;
    }

    function editFromMenu() {
        root.editBase = root.menuBase;
        root.editName = root.menuName;
        editSheet.field.text = root.menuText;
        root.menuName = "";
        editSheet.field.forceActiveFocus();
    }

    function deleteFromMenu() {
        var name = root.menuName;
        root.menuName = "";
        root.askDelete(name);
    }

    // Close the menu and open the parent picker for the selected todo.
    function nestFromMenu() {
        root.nestChildBase = root.menuBase;
        root.nestChildText = root.menuKind === "image" ? "(handwritten todo)" : root.menuText;
        root.menuName = "";
    }

    // Loaded top-level todos that can be a parent: everything not itself a subtask
    // and not the todo being nested. One level deep, so a candidate may already
    // have children -- it just gains another.
    function parentCandidates() {
        var out = [];
        for (var i = 0; i < rows.count; i++) {
            var r = rows.get(i);
            if (r.isChild || r.base === root.nestChildBase)
                continue;
            out.push({
                base: r.base,
                label: r.kind === "image" ? "(handwritten todo)" : r.text,
                dateText: r.dateText
            });
        }
        return out;
    }

    // Nest the picked todo under a chosen parent. Re-query so it leaves the top
    // level and the parent's child counts refresh (this collapses any expansions).
    function chooseParent(parentBase) {
        backend.sendMessage(root.msgSetParent, JSON.stringify({
            base: root.nestChildBase,
            parent: parentBase
        }));
        root.nestChildBase = "";
        root.refresh();
    }

    // Save an edited todo: store the text in the DB. The backend drops the .png
    // if it was still an image, so editing an untranscribed capture doubles as a
    // manual transcription.
    function saveEdit() {
        var text = editSheet.field.text.trim();
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
        editSheet.field.focus = false;
        root.editName = "";
        Qt.inputMethod.hide();
    }

    // Open the add-todo sheet. Calendar view files the new todo under the active
    // day; list view starts on today and lets the user pick another via the grid.
    function openAddTodo() {
        root.addTodoDay = root.viewMode === "calendar" ? root.activeDay() : root.todayKey;
        var p = root.addTodoDay.split("-");
        root.addPickYear = parseInt(p[0], 10);
        root.addPickMonth = parseInt(p[1], 10) - 1;
        addTodoSheet.field.text = "";
        root.addTodoOpen = true;
        addTodoSheet.field.forceActiveFocus();
    }

    // Capture-time for a day picked in the add sheet: the day at the current
    // time-of-day, so a todo dated today reads "now" and one for another day still
    // falls inside that day's [midnight, next-midnight) calendar window.
    function dayTs(key) {
        var p = key.split("-");
        var now = new Date();
        return new Date(p[0], p[1] - 1, p[2], now.getHours(), now.getMinutes(), now.getSeconds()).getTime();
    }

    // Save typed-in todos: one text row per non-empty line, all dated to the chosen
    // day. addSeq keeps the bases unique even though the lines share a timestamp.
    // The backend processes these before the re-query that follows, so refresh()
    // shows them.
    function saveAddTodo() {
        var lines = addTodoSheet.field.text.split("\n");
        var ts = root.dayTs(root.addTodoDay);
        var now = (new Date()).getTime();
        for (var i = 0; i < lines.length; i++) {
            var text = lines[i].trim();
            if (text === "")
                continue;
            root.addSeq += 1;
            backend.sendMessage(root.msgAdd, JSON.stringify({
                base: "man-" + now + "-" + root.addSeq,
                ts: ts,
                text: text
            }));
        }
        root.closeAddTodo();
        root.refresh();
    }

    function closeAddTodo() {
        addTodoSheet.field.focus = false;
        root.addTodoOpen = false;
        Qt.inputMethod.hide();
    }

    // Move the add sheet's date picker forward/back by whole months.
    function shiftAddMonth(delta) {
        var r = Cal.addMonths(root.addPickYear, root.addPickMonth, delta);
        root.addPickYear = r.year;
        root.addPickMonth = r.month;
    }

    // Jump the calendar back to the current month and select today.
    function jumpToToday() {
        var p = root.todayKey.split("-");
        root.shownYear = parseInt(p[0], 10);
        root.shownMonth = parseInt(p[1], 10) - 1;
        root.selectedDay = root.todayKey;
        root.refresh();
    }

    // Move the calendar forward/back by whole months, rolling the year over.
    function shiftMonth(delta) {
        var r = Cal.addMonths(root.shownYear, root.shownMonth, delta);
        root.shownYear = r.year;
        root.shownMonth = r.month;
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

    // Ask the native bridge to open (creating if needed) the named notebook with
    // the current default template, then close the viewer so the user lands in it.
    // The single place the "retasker.newnote" wire shape is built.
    function openNote(name) {
        broker.sendSimpleSignal("retasker.newnote", JSON.stringify({
            name: name,
            template: settings.noteTemplateFilename
        }));
        root.close();
    }

    // Open (or create) the day's primary note, named just by its date. Remember
    // it locally so the calendar and sheet can show that the day has a main note.
    function openDayNote(key) {
        var next = Object.assign({}, root.dayNoteMap);
        next[key] = true;
        root.dayNoteMap = next;
        settings.dayNotesJson = JSON.stringify(next);
        root.openNote(root.dayLabel(key));
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
        var next = Object.assign({}, root.dayNoteMap);
        delete next[key];
        root.dayNoteMap = next;
        settings.dayNotesJson = JSON.stringify(next);
    }

    function forgetExtraNote(key, title) {
        var list = (root.notesMap[key] ? root.notesMap[key] : []).filter(function (t) {
            return t !== title;
        });
        var next = Object.assign({}, root.notesMap);
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
        root.openNote(root.dayNoteName(key, title));
    }

    // Create a titled note for the day, remember it locally, and open it.
    function createExtraNote(key, title) {
        var t = title.trim();
        if (t === "")
            return;
        var list = root.notesMap[key] ? root.notesMap[key].slice() : [];
        if (list.indexOf(t) === -1)
            list.push(t);
        var next = Object.assign({}, root.notesMap);
        next[key] = list;
        root.notesMap = next;
        settings.notesJson = JSON.stringify(next);
        root.openNote(root.dayNoteName(key, t));
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
        root.loadJson(root.appDir + "/template.json", function (data) {
            // Missing/empty/unreadable: keep the saved template defaults.
            if (data !== null)
                root.applyTemplateConfig(data);
        });
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

        CloseGlyph {
            id: closeBtn
            anchors {
                right: parent.right
                rightMargin: 40
                verticalCenter: title.verticalCenter
            }
            onClicked: root.close()
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

            // Status filter -- only meaningful for the flat list.
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
        onGoToday: root.jumpToToday()
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

                CheckMark {
                    anchors.centerIn: parent
                    dim: 30
                    stroke: 5
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
        FlatButton {
            id: notesBtn
            anchors {
                right: parent.right
                rightMargin: 32
                verticalCenter: parent.verticalCenter
            }
            width: 240
            height: 60
            fontSize: 30
            primary: true
            text: "Notes"
            onClicked: {
                root.addNoteDay = root.activeDay();
                root.addSheetMode = "list";
                root.addNoteOpen = true;
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
            isChild: model.isChild
            childCount: model.childCount
            childOpen: model.childOpen
            expanded: model.expanded
            onToggleClicked: root.toggle(model.base)
            onLongPressed: root.openRowMenu(model.name)
            onExpandClicked: root.toggleExpand(model.base)
        }
    }

    Text {
        anchors.centerIn: list
        visible: !root.settingsOpen && rows.count === 0
        text: root.filter === "done" && root.viewMode === "list" ? "Nothing done yet" : "No todos"
        font.pixelSize: 40
        color: "black"
    }

    // Add a typed-in todo. The modals declared after this are opaque and cover it
    // while open, so it only needs to step aside for the settings page.
    Rectangle {
        id: addFab
        visible: !root.settingsOpen
        width: 120
        height: 120
        radius: 60
        color: "black"
        anchors {
            right: parent.right
            rightMargin: 48
            bottom: parent.bottom
            bottomMargin: 48
        }
        Text {
            anchors.centerIn: parent
            text: "+"
            font.pixelSize: 80
            color: "white"
        }
        MouseArea {
            anchors.fill: parent
            onClicked: root.openAddTodo()
        }
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

                    FlatButton {
                        width: 170
                        height: 76
                        fontSize: 32
                        text: "Reset"
                        onClicked: root.resetDefaultTemplate()
                    }

                    FlatButton {
                        width: 190
                        height: 76
                        fontSize: 32
                        primary: true
                        text: "Choose"
                        onClicked: root.chooseDefaultTemplate()
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
    DeleteConfirm {
        app: root
    }

    // --- Row action menu (long-press) ------------------------------------
    RowMenu {
        app: root
    }

    // --- Edit sheet -------------------------------------------------------
    EditSheet {
        id: editSheet
        app: root
    }

    // --- Parent picker (Make subtask of...) --------------------------------
    ParentPicker {
        app: root
    }

    // --- Add-todo sheet ---------------------------------------------------
    AddTodoSheet {
        id: addTodoSheet
        app: root
    }

    // --- Day-notes sheet --------------------------------------------------
    DayNotesSheet {
        id: addSheet
        app: root
    }

    // --- Forget-note confirmation ----------------------------------------
    ForgetConfirm {
        app: root
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
