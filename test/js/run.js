"use strict";
// Unit tests for the viewer's pure JS helpers. These functions are plain
// ECMAScript (no Qt, no file IO), so we load each .js into a fresh vm context
// (stripping the QML `.pragma library` line) and assert against it with node.
//
//   node test/js/run.js
//
// Exits non-zero on the first failed assertion.
const fs = require("fs");
const vm = require("vm");
const path = require("path");
const assert = require("assert");

const UI = path.join(__dirname, "..", "..", "src", "viewer", "ui");

// Load a QML .js library and return its top-level functions as a context object.
function load(file) {
    const src = fs
        .readFileSync(path.join(UI, file), "utf8")
        .replace(/^\s*\.pragma\s+library\s*$/m, "");
    const ctx = {};
    vm.createContext(ctx);
    vm.runInContext(src, ctx, { filename: file });
    return ctx;
}

let passed = 0;
function check(name, fn) {
    fn();
    passed += 1;
    console.log("  ok - " + name);
}

// --- calendar.js ---------------------------------------------------------
const cal = load("calendar.js");

check("dateKey formats y-m-d with no zero padding", () => {
    assert.strictEqual(cal.dateKey(new Date(2026, 5, 4)), "2026-6-4");
});

// addMonths/buildIndex/monthCounts return objects from the vm realm, whose
// prototype differs from this realm's — so compare fields, not deepStrictEqual.
function eqMonth(r, year, month) {
    assert.strictEqual(r.year, year);
    assert.strictEqual(r.month, month);
}
function eqCount(r, total, done) {
    assert.strictEqual(r.total, total);
    assert.strictEqual(r.done, done);
}

check("addMonths rolls the year backward", () => {
    eqMonth(cal.addMonths(2026, 0, -1), 2025, 11);
});

check("addMonths rolls the year forward", () => {
    eqMonth(cal.addMonths(2026, 11, 1), 2027, 0);
});

check("addMonths handles multi-year deltas", () => {
    eqMonth(cal.addMonths(2026, 5, 21), 2028, 2);
    eqMonth(cal.addMonths(2026, 5, -18), 2024, 11);
});

check("monthGrid pads to whole weeks, Monday-first", () => {
    const cells = cal.monthGrid(2026, 5); // June 2026
    assert.strictEqual(cells.length % 7, 0);
    const days = cells.filter((c) => c !== null).map((c) => c.day);
    assert.strictEqual(days.length, 30);
    assert.strictEqual(days[0], 1);
    assert.strictEqual(days[29], 30);
    const lead = (new Date(2026, 5, 1).getDay() + 6) % 7;
    for (let i = 0; i < lead; i++) assert.strictEqual(cells[i], null);
    assert.strictEqual(cells[lead].day, 1);
});

check("buildIndex + monthCounts bucket by local day", () => {
    const idx = cal.buildIndex([
        { ts: new Date(2026, 5, 4, 10, 0).getTime(), done: 1 },
        { ts: new Date(2026, 5, 4, 11, 0).getTime(), done: 0 },
        { ts: new Date(2026, 5, 5, 9, 0).getTime(), done: true },
    ]);
    eqCount(idx["2026-6-4"], 2, 1);
    eqCount(idx["2026-6-5"], 1, 1);
    eqCount(cal.monthCounts(idx, 2026, 5), 3, 2);
    eqCount(cal.monthCounts(idx, 2026, 4), 0, 0);
});

// --- store.js ------------------------------------------------------------
const store = load("store.js");

check("captureMs extracts the ms timestamp from a cap- name", () => {
    assert.strictEqual(store.captureMs("cap-1718900000000-3"), 1718900000000);
});

check("captureMs returns 0 for manual / malformed names", () => {
    assert.strictEqual(store.captureMs("man-123-1"), 0);
    assert.strictEqual(store.captureMs("nope"), 0);
    assert.strictEqual(store.captureMs("cap-12-"), 0);
});

// --- ocr.js --------------------------------------------------------------
const ocr = load("ocr.js");

check("toBase64 matches known vectors (incl. padding)", () => {
    assert.strictEqual(ocr.toBase64([]), "");
    assert.strictEqual(ocr.toBase64([0x4d]), "TQ==");
    assert.strictEqual(ocr.toBase64([0x4d, 0x61]), "TWE=");
    assert.strictEqual(ocr.toBase64([0x4d, 0x61, 0x6e]), "TWFu");
});

check("toBase64 matches the reference encoder across lengths", () => {
    for (const len of [1, 2, 3, 4, 5, 6, 255, 256, 257, 1000]) {
        const bytes = [];
        for (let j = 0; j < len; j++) bytes.push((j * 37 + 11) & 255);
        const ref = Buffer.from(bytes).toString("base64");
        assert.strictEqual(ocr.toBase64(bytes), ref, "length " + len);
    }
});

console.log("\n" + passed + " JS assertions passed");
