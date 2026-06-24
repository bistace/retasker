.pragma library

// The capture instant (epoch milliseconds) encoded in a todo's base name
// (cap-<ms>-<counter>). The capture extension names files with a millisecond
// timestamp; this is sent to the backend when ingesting a new capture so a
// todo's date survives later edits. Returns 0 if the name carries no timestamp.
function captureMs(base) {
    var m = /^cap-(\d+)-\d+$/.exec(base);
    return m ? parseInt(m[1], 10) : 0;
}
