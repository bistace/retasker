.pragma library

// Calendar helpers for the month view. Pure functions: no Qt, no file IO.
// Days are keyed "year-month-day" (1-based month/day, no zero padding) — the
// key is only ever used as a map lookup, so its exact form doesn't matter as
// long as dateKey() and monthGrid() agree.

function dateKey(d) {
    return d.getFullYear() + "-" + (d.getMonth() + 1) + "-" + d.getDate();
}

// Count todos and how many are done, per day, from the backend's calendar rows
// ({ts, done} for the shown month). Bucketing happens here, in local time, so
// the backend stays timezone-agnostic.
function buildIndex(rows) {
    var idx = {};
    for (var i = 0; i < rows.length; i++) {
        var k = dateKey(new Date(rows[i].ts));
        if (!idx[k])
            idx[k] = { total: 0, done: 0 };
        idx[k].total += 1;
        if (rows[i].done === 1 || rows[i].done === true)
            idx[k].done += 1;
    }
    return idx;
}

// Sum a month's todos from the day index (built by buildIndex). Keys are
// "year-month-day", so a "year-month-" prefix picks out exactly that month.
function monthCounts(index, year, month) {
    var prefix = year + "-" + (month + 1) + "-";
    var total = 0, done = 0;
    for (var k in index) {
        if (k.indexOf(prefix) === 0) {
            total += index[k].total;
            done += index[k].done;
        }
    }
    return { total: total, done: done };
}

// Add `delta` whole months to a (year, month) pair, rolling the year over.
// month is 0-based; returns the rolled {year, month}.
function addMonths(year, month, delta) {
    var m = month + delta;
    while (m < 0) {
        m += 12;
        year -= 1;
    }
    while (m > 11) {
        m -= 12;
        year += 1;
    }
    return { year: year, month: m };
}

// Cells for the given month, Monday-first, padded to whole weeks. Leading and
// trailing pad cells are null so the grid can render them blank.
function monthGrid(year, month) {
    var first = new Date(year, month, 1);
    var lead = (first.getDay() + 6) % 7;            // JS Sun=0..Sat=6 -> Mon=0
    var daysInMonth = new Date(year, month + 1, 0).getDate();
    var cells = [];
    var i;
    for (i = 0; i < lead; i++)
        cells.push(null);
    for (i = 1; i <= daysInMonth; i++)
        cells.push({ day: i, key: year + "-" + (month + 1) + "-" + i });
    while (cells.length % 7 !== 0)
        cells.push(null);
    return cells;
}
