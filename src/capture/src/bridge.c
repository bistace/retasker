// reTasker xochitl native bridge.
//
// The other half of the retasker-capture extension (built into the same .so as
// the framebuffer capture in main.c, but a separate, unrelated responsibility).
// The AppLoad viewer (QML) can only reach native code via xovi-message-broker
// signals, never QML listeners, so these handlers do the filesystem and xochitl
// lookups the sandboxed viewer can't: creating/finding notebooks and persisting
// the default template. They re-emit to the MainView QML listener over the broker
// pipe (the 'u' route delivers to QML).
#include <dirent.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>

#include "broker.h"

#define XOCHITL_DIR "/home/root/.local/share/remarkable/xochitl"
#define TEMPLATE_CONFIG "/home/root/xovi/exthome/appload/retasker/template.json"

// Copy the string value of a top-level JSON "key":"value" into out. Minimal: only
// quoted string values, handles a backslash-escaped char. Returns 1 if found.
//
// Intentionally byte-identical to json_str() in src/backend/src/main.c: the two
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

static int json_escape(const char *src, char *out, size_t outsize) {
    size_t j = 0;
    for (size_t i = 0; src[i] != '\0'; i++) {
        unsigned char c = (unsigned char)src[i];
        const char *esc = NULL;
        char hex[7];
        switch (c) {
        case '"':
            esc = "\\\"";
            break;
        case '\\':
            esc = "\\\\";
            break;
        case '\b':
            esc = "\\b";
            break;
        case '\f':
            esc = "\\f";
            break;
        case '\n':
            esc = "\\n";
            break;
        case '\r':
            esc = "\\r";
            break;
        case '\t':
            esc = "\\t";
            break;
        default:
            if (c < 0x20) {
                snprintf(hex, sizeof(hex), "\\u%04x", c);
                esc = hex;
            }
            break;
        }
        if (esc != NULL) {
            size_t n = strlen(esc);
            if (j + n + 1 > outsize) return -1;
            memcpy(out + j, esc, n);
            j += n;
        } else {
            if (j + 2 > outsize) return -1;
            out[j++] = (char)c;
        }
    }
    out[j] = '\0';
    return 0;
}

static int json_bool(const char *json, const char *key) {
    char pat[64];
    snprintf(pat, sizeof(pat), "\"%s\"", key);
    const char *p = strstr(json, pat);
    if (p == NULL) return 0;
    p = strchr(p + strlen(pat), ':');
    if (p == NULL) return 0;
    p++;
    while (*p == ' ' || *p == '\t')
        p++;
    return strncmp(p, "true", 4) == 0;
}

// Reads up to bufsize-1 bytes and NUL-terminates. NOTE: a file larger than the
// caller's buffer is silently truncated, so match_entry then string-matches a
// partial buffer. Safe for xochitl's small .metadata files (a few hundred bytes
// into match_entry's 8 KiB buf); revisit if ever pointed at larger files.
static int read_file(const char *path, char *buf, size_t bufsize) {
    FILE *f = fopen(path, "r");
    if (f == NULL) return -1;
    size_t n = fread(buf, 1, bufsize - 1, f);
    fclose(f);
    buf[n] = '\0';
    return (int)n;
}

static int has_metadata_suffix(const char *name) {
    size_t n = strlen(name);
    return n > 9 && strcmp(name + n - 9, ".metadata") == 0;
}

// Reads a metadata file and, if it matches type/visibleName (and parent when
// given), copies its UUID (filename minus ".metadata") into uuid. Skips deleted.
static int match_entry(const char *fname, const char *wantType, const char *wantName,
                       const char *wantParent, char *uuid, size_t uuidSize) {
    char path[512], buf[8192], type[32], vn[256], parent[64];
    snprintf(path, sizeof(path), "%s/%s", XOCHITL_DIR, fname);
    if (read_file(path, buf, sizeof(buf)) < 0) return 0;
    if (strstr(buf, "\"deleted\": true") != NULL) return 0;
    type[0] = vn[0] = parent[0] = '\0';
    json_str(buf, "type", type, sizeof(type));
    if (strcmp(type, wantType) != 0) return 0;
    json_str(buf, "visibleName", vn, sizeof(vn));
    if (strcmp(vn, wantName) != 0) return 0;
    if (wantParent != NULL) {
        json_str(buf, "parent", parent, sizeof(parent));
        if (strcmp(parent, wantParent) != 0) return 0;
    }
    size_t len = strlen(fname) - 9;
    if (len + 1 > uuidSize) return 0;
    memcpy(uuid, fname, len);
    uuid[len] = '\0';
    return 1;
}

// export: invoked by xovi-message-broker for the "retasker.newnote" signal.
// The AppLoad viewer (QML) can only reach native extensions via sendSimpleSignal,
// never QML listeners. This bridges the gap. It also does the filesystem lookups
// the QML side can't: finds the "reTasker" collection and, if a note with the
// requested name already lives there, its UUID -- so the QML handler can open the
// existing note instead of making a duplicate. Re-emits to the MainView handler
// over the broker pipe (the 'u' route delivers to QML) as
// {"name","folder","existing","template"}.
char *newNoteHandler(const char *value) {
    char name[256] = "", templateFilename[256] = "";
    if (value != NULL) json_str(value, "name", name, sizeof(name));
    if (value != NULL) json_str(value, "template", templateFilename, sizeof(templateFilename));
    if (name[0] == '\0') strcpy(name, "reTasker note");

    char folderId[64] = "", existing[64] = "";
    DIR *d = opendir(XOCHITL_DIR);
    if (d != NULL) {
        struct dirent *e;
        while ((e = readdir(d)) != NULL) {
            if (!has_metadata_suffix(e->d_name)) continue;
            if (match_entry(e->d_name, "CollectionType", "reTasker", NULL, folderId,
                            sizeof(folderId)))
                break;
        }
        if (folderId[0] != '\0') {
            rewinddir(d);
            while ((e = readdir(d)) != NULL) {
                if (!has_metadata_suffix(e->d_name)) continue;
                if (match_entry(e->d_name, "DocumentType", name, folderId, existing,
                                sizeof(existing)))
                    break;
            }
        }
        closedir(d);
    }

    char encName[1536], encFolder[512], encExisting[512], encTemplate[1536];
    if (json_escape(name, encName, sizeof(encName)) != 0 ||
        json_escape(folderId, encFolder, sizeof(encFolder)) != 0 ||
        json_escape(existing, encExisting, sizeof(encExisting)) != 0 ||
        json_escape(templateFilename, encTemplate, sizeof(encTemplate)) != 0) {
        fprintf(stderr, "[retasker] newnote: JSON escape failed\n");
        return NULL;
    }

    char out[4096];
    int n = snprintf(out, sizeof(out),
                     "uretasker.newnote:{\"name\":\"%s\",\"folder\":\"%s\",\"existing\":\"%s\","
                     "\"template\":\"%s\"}\n",
                     encName, encFolder, encExisting, encTemplate);
    if (n > 0 && n < (int)sizeof(out)) emit_broker_signal("newnote", out);
    return NULL;
}

// export: invoked by xovi-message-broker for the "retasker.chooseTemplate"
// signal. The AppLoad viewer asks here, and this forwards the request to the
// MainView QML listener, where xochitl's native template selector is reachable.
char *chooseTemplateHandler(const char *value) {
    char templateFilename[256] = "", encTemplate[1536];
    if (value != NULL) json_str(value, "template", templateFilename, sizeof(templateFilename));
    if (json_escape(templateFilename, encTemplate, sizeof(encTemplate)) != 0) {
        fprintf(stderr, "[retasker] chooseTemplate: JSON escape failed\n");
        return NULL;
    }

    char out[2048];
    int n =
        snprintf(out, sizeof(out), "uretasker.chooseTemplate:{\"template\":\"%s\"}\n", encTemplate);
    if (n > 0 && n < (int)sizeof(out)) emit_broker_signal("chooseTemplate", out);
    return NULL;
}

// export: invoked by xovi-message-broker for the "retasker.template" signal.
// Persists the selected default notebook template for the AppLoad viewer.
char *templateHandler(const char *value) {
    char filename[256] = "", name[256] = "", encFilename[1536], encName[1536];
    int landscape = 0;
    if (value != NULL) {
        json_str(value, "filename", filename, sizeof(filename));
        json_str(value, "name", name, sizeof(name));
        landscape = json_bool(value, "landscape");
    }
    if (name[0] == '\0') strcpy(name, "Blank");
    if (json_escape(filename, encFilename, sizeof(encFilename)) != 0 ||
        json_escape(name, encName, sizeof(encName)) != 0) {
        fprintf(stderr, "[retasker] template: JSON escape failed\n");
        return NULL;
    }

    mkdir("/home/root/xovi/exthome/appload/retasker", 0755);
    FILE *f = fopen(TEMPLATE_CONFIG, "w");
    if (f == NULL) {
        fprintf(stderr, "[retasker] template: cannot open %s\n", TEMPLATE_CONFIG);
        return NULL;
    }
    fprintf(f, "{\"filename\":\"%s\",\"name\":\"%s\",\"landscape\":%s}\n", encFilename, encName,
            landscape ? "true" : "false");
    fclose(f);
    fprintf(stderr, "[retasker] saved template filename='%s' name='%s'\n", filename, name);
    return NULL;
}
