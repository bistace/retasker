.pragma library

// Pull every PNG out of a FolderListModel into plain JS objects.
function collect(folderModel) {
    var out = [];
    for (var i = 0; i < folderModel.count; i++) {
        var name = "" + folderModel.get(i, "fileName");
        if (!/\.png$/i.test(name))
            continue;
        out.push({
            name: name,
            url: "" + folderModel.get(i, "fileURL"),
            mtime: folderModel.get(i, "fileModified")
        });
    }
    return out;
}

// Tag with done-state, sort newest-first, then keep only the active filter.
function view(entries, doneMap, filter) {
    var rows = entries.map(function (e) {
        return {
            name: e.name,
            url: e.url,
            mtime: e.mtime,
            done: doneMap[e.name] === true
        };
    });
    rows.sort(function (a, b) { return b.mtime - a.mtime; });
    if (filter === "done")
        return rows.filter(function (r) { return r.done; });
    if (filter === "todo")
        return rows.filter(function (r) { return !r.done; });
    return rows;
}
