.pragma library

// A todo's time is the capture instant encoded in its base name
// (cap-<unix-seconds>-<counter>), not the file's mtime: editing a todo rewrites
// its .txt and would otherwise bump it to "now". Fall back to mtime for any file
// that doesn't carry a timestamp.
function captureTime(base, mtime) {
    var m = /^cap-(\d+)-\d+$/.exec(base);
    if (m)
        return new Date(parseInt(m[1], 10) * 1000);
    return mtime;
}

// Group capture files into todos, keyed by base name (e.g. "cap-123-0").
// A todo is either an image (.png, freshly captured) or text (.txt, the OCR
// transcription). If both exist for a base, the transcription wins.
function collect(folderModel) {
    var byBase = {};
    for (var i = 0; i < folderModel.count; i++) {
        var name = "" + folderModel.get(i, "fileName");
        var m = /^(.*)\.(png|txt)$/i.exec(name);
        if (!m)
            continue;
        var base = m[1];
        var kind = m[2].toLowerCase() === "txt" ? "text" : "image";
        if (byBase[base] && byBase[base].kind === "text")
            continue;  // already have the transcription for this todo
        byBase[base] = {
            base: base,
            name: name,
            kind: kind,
            url: "" + folderModel.get(i, "fileURL"),
            mtime: captureTime(base, folderModel.get(i, "fileModified"))
        };
    }
    var out = [];
    for (var k in byBase)
        out.push(byBase[k]);
    return out;
}

// Tag with done-state (keyed by base), sort newest-first, keep the filter.
function view(entries, doneMap, filter) {
    var rows = entries.map(function (e) {
        return {
            base: e.base,
            name: e.name,
            kind: e.kind,
            url: e.url,
            mtime: e.mtime,
            done: doneMap[e.base] === true
        };
    });
    rows.sort(function (a, b) { return b.mtime - a.mtime; });
    if (filter === "done")
        return rows.filter(function (r) { return r.done; });
    if (filter === "todo")
        return rows.filter(function (r) { return !r.done; });
    return rows;
}
