// reTasker backend — the todo database, as an AppLoad backend process.
//
// AppLoad launches this with argv[1] = a unix SOCK_SEQPACKET socket it created;
// we connect and speak its protocol: each message is an 8-byte header
// {int32 type; int32 length} datagram followed (if length>0) by a body datagram
// of UTF-8 JSON. The QML viewer talks to us via AppLoad.sendMessage(type, json)
// and we reply the same way (AppLoad.onMessageReceived).
//
// We own a SQLite database of todos so the viewer never scans a folder of
// thousands of files: reads are paginated, indexed queries. PNG snippets still
// live on disk (the capture extension writes them); we only delete a PNG once
// its text has been transcribed into the DB, so the captures dir stays small.
//
// Almost no JSON is parsed in C: the incoming message is bound as ?1 and
// SQLite's json_extract/json_each/json_object do the work.
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#include "../vendor/sqlite3.h"

#define APP_DIR "/home/root/xovi/exthome/appload/retasker"
#define DB_PATH APP_DIR "/retasker.db"
#define CAPTURE_DIR APP_DIR "/captures"
#define MAX_MESSAGE_LENGTH 10485760 // 10 MiB, from AppLoad's protocol.h

// Wire-protocol message types. KEEP IN SYNC with the msg* readonly properties in
// src/viewer/ui/main.qml — both sides hand-maintain this numbering.
// Request types (viewer -> backend).
#define MSG_QUERY 1
#define MSG_SET_DONE 2
#define MSG_SET_TEXT 3
#define MSG_DELETE 4
#define MSG_INGEST 5
#define MSG_CAL 6
#define MSG_ADD 7
#define MSG_SET_PARENT 8
#define MSG_CHILDREN 9
// Reply types (backend -> viewer).
#define MSG_READY 100
#define MSG_ROWS 101
#define MSG_INGESTED 102
#define MSG_CAL_ROWS 103
#define MSG_CHILD_ROWS 104
// System types (AppLoad -> backend). A new frontend attaching re-announces us so
// it can load even if it missed the first READY; terminate ends the process.
#define MSG_NEW_COORDINATOR -2
#define MSG_TERMINATE -1

struct PacketHeader {
    int32_t type;
    int32_t length;
};

static sqlite3 *db;

// Send one AppLoad message: the header as its own datagram, then the body as a
// second datagram (SEQPACKET keeps the boundaries; an empty body sends none).
static void send_msg(int fd, int32_t type, const char *body) {
    struct PacketHeader hdr = {type, body ? (int32_t)strlen(body) : 0};
    if (send(fd, &hdr, sizeof(hdr), 0) < 0) return;
    if (hdr.length > 0 && send(fd, body, (size_t)hdr.length, 0) < 0)
        fprintf(stderr, "[retasker-backend] body send failed (type %d)\n", type);
}

// Copy the string value of a top-level JSON "key":"value" into out. Minimal:
// quoted string values only, handles a backslash-escaped char. Returns 1 if
// found. Used solely to pull a todo's base name for file removal.
//
// Intentionally byte-identical to json_str() in src/capture/src/main.c: the two
// modules build in isolation (each Makefile is run on its own copied subtree), so
// there is no shared header to lift this into. Keep the two copies in sync.
static int json_str(const char *json, const char *key, char *out, size_t outsize) {
    char pat[64];
    snprintf(pat, sizeof(pat), "\"%s\"", key);
    const char *p = strstr(json, pat);
    if (p == NULL) return 0;
    p = strchr(p + strlen(pat), ':');
    if (p == NULL) return 0;
    p++;
    while (*p == ' ' || *p == '\t')
        p++;
    if (*p != '"') return 0;
    p++;
    size_t i = 0;
    while (*p != '\0' && *p != '"' && i + 1 < outsize) {
        if (*p == '\\' && p[1] != '\0') p++;
        out[i++] = *p++;
    }
    out[i] = '\0';
    return 1;
}

// Remove the PNG for a todo once its text lives in the DB. The base comes from
// our own DB, but reject a '/' anyway so a bad row can't escape the dir.
static void remove_png(const char *json) {
    char base[256];
    if (!json_str(json, "base", base, sizeof(base))) return;
    if (strchr(base, '/') != NULL) return;
    char path[512];
    snprintf(path, sizeof(path), "%s/%s.png", CAPTURE_DIR, base);
    remove(path);
}

static int db_open(void) {
    if (sqlite3_open(DB_PATH, &db) != SQLITE_OK) return -1;
    const char *schema = "CREATE TABLE IF NOT EXISTS todos("
                         "  base TEXT PRIMARY KEY,"
                         "  ts INTEGER NOT NULL,"
                         "  text TEXT,"
                         "  done INTEGER NOT NULL DEFAULT 0,"
                         "  has_image INTEGER NOT NULL DEFAULT 1,"
                         "  parent TEXT);"
                         "CREATE INDEX IF NOT EXISTS idx_todos_ts ON todos(ts);";
    if (sqlite3_exec(db, schema, NULL, NULL, NULL) != SQLITE_OK) return -1;
    // Pre-existing DBs predate the subtask column. ADD COLUMN errors once it's
    // there (SQLite has no IF NOT EXISTS for columns), so the result is ignored.
    sqlite3_exec(db, "ALTER TABLE todos ADD COLUMN parent TEXT", NULL, NULL, NULL);
    return 0;
}

// Run an UPDATE/DELETE/INSERT that binds the message JSON as ?1. Returns the
// number of rows changed (or -1 on prepare failure).
static int exec_with_json(const char *sql, const char *json) {
    sqlite3_stmt *stmt;
    if (sqlite3_prepare_v2(db, sql, -1, &stmt, NULL) != SQLITE_OK) return -1;
    sqlite3_bind_text(stmt, 1, json, -1, SQLITE_TRANSIENT);
    sqlite3_step(stmt);
    sqlite3_finalize(stmt);
    return sqlite3_changes(db);
}

// Run a SELECT that binds the message JSON as ?1 and returns a single JSON-text
// column, then send it back as `type`. The SQL builds the whole reply envelope.
static void reply_json_query(int fd, int32_t type, const char *sql, const char *json) {
    sqlite3_stmt *stmt;
    if (sqlite3_prepare_v2(db, sql, -1, &stmt, NULL) != SQLITE_OK) {
        send_msg(fd, type, "{}");
        return;
    }
    sqlite3_bind_text(stmt, 1, json, -1, SQLITE_TRANSIENT);
    const char *out = "{}";
    if (sqlite3_step(stmt) == SQLITE_ROW) {
        const unsigned char *col = sqlite3_column_text(stmt, 0);
        if (col != NULL) out = (const char *)col;
    }
    send_msg(fd, type, out);
    sqlite3_finalize(stmt);
}

// A page of todos, newest first, scoped by status filter and (optionally) a
// [rangeStart, rangeEnd) capture-time window for the calendar's day/month view.
static void handle_query(int fd, const char *json) {
    static const char *sql =
        "SELECT json_object('offset', json_extract(?1,'$.offset'), 'rows', json(coalesce(("
        "  SELECT json_group_array(json_object("
        "    'base',base,'ts',ts,'text',text,'done',done,'hasImage',has_image,"
        "    'childCount',(SELECT count(*) FROM todos c WHERE c.parent=t.base),"
        "    'childOpen',(SELECT count(*) FROM todos c WHERE c.parent=t.base AND c.done=0)))"
        "  FROM (SELECT base,ts,text,done,has_image FROM todos WHERE"
        "    parent IS NULL"
        "    AND (json_extract(?1,'$.filter')='all'"
        "     OR (json_extract(?1,'$.filter')='todo' AND done=0)"
        "     OR (json_extract(?1,'$.filter')='done' AND done=1))"
        "    AND (json_extract(?1,'$.rangeStart') IS NULL OR ts>=json_extract(?1,'$.rangeStart'))"
        "    AND (json_extract(?1,'$.rangeEnd') IS NULL OR ts<json_extract(?1,'$.rangeEnd'))"
        "    ORDER BY ts DESC"
        "    LIMIT json_extract(?1,'$.limit') OFFSET json_extract(?1,'$.offset')) t),'[]')))";
    reply_json_query(fd, MSG_ROWS, sql, json);
}

// All children of one parent, oldest-first (natural checklist order), regardless
// of done state — the viewer shows every child when a parent is expanded. The
// reply echoes the parent base so the viewer knows which row to splice under.
static void handle_children(int fd, const char *json) {
    static const char *sql =
        "SELECT json_object('base',json_extract(?1,'$.base'),'rows', json(coalesce(("
        "  SELECT json_group_array(json_object("
        "    'base',base,'ts',ts,'text',text,'done',done,'hasImage',has_image))"
        "  FROM todos WHERE parent=json_extract(?1,'$.base') ORDER BY ts),'[]')))";
    reply_json_query(fd, MSG_CHILD_ROWS, sql, json);
}

// {ts,done} for every todo in a window; the viewer buckets them into local days
// for the calendar (date math stays in JS, so no timezone logic lives here).
static void handle_cal(int fd, const char *json) {
    static const char *sql =
        "SELECT json_object('rows', json(coalesce(("
        "  SELECT json_group_array(json_object('ts',ts,'done',done)) FROM todos"
        "  WHERE ts>=json_extract(?1,'$.rangeStart') AND ts<json_extract(?1,'$.rangeEnd'))"
        ",'[]')))";
    reply_json_query(fd, MSG_CAL_ROWS, sql, json);
}

// Insert any captures the viewer found that we don't have yet (base is the key,
// so re-ingesting is a no-op). Reply with how many were new so the viewer only
// re-queries when something actually changed.
static void handle_ingest(int fd, const char *json) {
    static const char *sql =
        "INSERT OR IGNORE INTO todos(base,ts,has_image,done,text)"
        "  SELECT json_extract(value,'$.base'), json_extract(value,'$.ts'), 1, 0, NULL"
        "  FROM json_each(?1,'$.items')";
    int n = exec_with_json(sql, json);
    char body[64];
    snprintf(body, sizeof(body), "{\"new\":%d}", n < 0 ? 0 : n);
    send_msg(fd, MSG_INGESTED, body);
}

static void dispatch(int fd, int32_t type, const char *json) {
    switch (type) {
    case MSG_QUERY:
        handle_query(fd, json);
        break;
    case MSG_SET_DONE:
        exec_with_json("UPDATE todos SET done=json_extract(?1,'$.done') "
                       "WHERE base=json_extract(?1,'$.base')",
                       json);
        break;
    case MSG_SET_TEXT:
        exec_with_json("UPDATE todos SET text=json_extract(?1,'$.text'), has_image=0 "
                       "WHERE base=json_extract(?1,'$.base')",
                       json);
        remove_png(json);
        break;
    case MSG_DELETE:
        // Orphaned children are promoted to top-level, not deleted with the parent.
        exec_with_json("UPDATE todos SET parent=NULL "
                       "WHERE parent=json_extract(?1,'$.base')",
                       json);
        exec_with_json("DELETE FROM todos WHERE base=json_extract(?1,'$.base')", json);
        remove_png(json);
        break;
    case MSG_SET_PARENT:
        // Nest a todo under another (parent), or un-nest it (parent: null).
        exec_with_json("UPDATE todos SET parent=json_extract(?1,'$.parent') "
                       "WHERE base=json_extract(?1,'$.base')",
                       json);
        break;
    case MSG_CHILDREN:
        handle_children(fd, json);
        break;
    case MSG_INGEST:
        handle_ingest(fd, json);
        break;
    case MSG_CAL:
        handle_cal(fd, json);
        break;
    case MSG_ADD:
        // A todo typed in the viewer (no capture): a text row, dated to the day
        // the user chose. base is the viewer's unique key, so OR IGNORE makes a
        // stray resend a no-op.
        exec_with_json("INSERT OR IGNORE INTO todos(base,ts,text,has_image,done) "
                       "VALUES(json_extract(?1,'$.base'),json_extract(?1,'$.ts'),"
                       "json_extract(?1,'$.text'),0,0)",
                       json);
        break;
    }
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "[retasker-backend] missing socket path\n");
        return 1;
    }
    int fd = socket(AF_UNIX, SOCK_SEQPACKET, 0);
    if (fd < 0) {
        perror("[retasker-backend] socket");
        return 1;
    }
    struct sockaddr_un addr = {0};
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, argv[1], sizeof(addr.sun_path) - 1);
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        perror("[retasker-backend] connect");
        return 1;
    }
    if (db_open() != 0) {
        fprintf(stderr, "[retasker-backend] cannot open %s\n", DB_PATH);
        return 1;
    }

    // Announce we're connected: messages the viewer sends before our socket is
    // registered are dropped, so it waits for this before its first query.
    send_msg(fd, MSG_READY, "{}");

    struct PacketHeader hdr;
    char *body = malloc(MAX_MESSAGE_LENGTH + 1);
    if (body == NULL) return 1;
    for (;;) {
        ssize_t n = recv(fd, &hdr, sizeof(hdr), 0);
        if (n < (ssize_t)sizeof(hdr)) break;
        // Always drain the body datagram first (even for system messages that
        // carry one, e.g. NEW_COORDINATOR) or the next header read desyncs.
        size_t len = 0;
        if (hdr.length > 0) {
            if (hdr.length > MAX_MESSAGE_LENGTH) break;
            ssize_t bn = recv(fd, body, (size_t)hdr.length, 0);
            if (bn < 1) break;
            len = (size_t)bn;
        }
        body[len] = '\0';
        if (hdr.type == MSG_TERMINATE) break;
        if (hdr.type == MSG_NEW_COORDINATOR)
            send_msg(fd, MSG_READY, "{}");
        else
            dispatch(fd, hdr.type, body);
    }

    free(body);
    sqlite3_close(db);
    return 0;
}
