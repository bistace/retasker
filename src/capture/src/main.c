// reTasker capture extension.
//
// Registers a "retasker.capture" signal handler on xovi-message-broker. When
// fired with a bbox JSON payload, it reads the live framebuffer address from
// framebuffer-spy, crops the bbox rectangle, and writes it out as a PNG.
//
// The selection-menu "Add to todos" button (added via a .qmd) sends the bbox;
// for the decision gate the same signal can be fired from a shell:
//   echo 'eretasker.capture:{"x":100,"y":200,"width":400,"height":300}' > /run/xovi-mb
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <ctype.h>
#include <time.h>
#include <fcntl.h>
#include <unistd.h>
#include <dirent.h>
#include <sys/stat.h>

#include "../xovi.h"

#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "../vendor/stb_image_write.h"

// The viewer (AppLoad app) treats this folder as the todo list, so capture
// writes here and delete removes from here — one shared source of truth.
#define CAPTURE_DIR "/home/root/xovi/exthome/appload/retasker/captures"
#define TEMPLATE_CONFIG "/home/root/xovi/exthome/appload/retasker/template.json"
#define FB_TYPE_RGBA 2 // FBSPY_TYPE_RGBA from framebuffer-spy.h (32-bit pixels)

struct fb_config {
    uintptr_t addr;
    int width, height, type, bpl;
};

struct rect {
    int x, y, w, h;
};

// Parses framebuffer-spy's "0xADDR,width,height,type,bpl,requiresReload" string.
static int parse_fb_config(const char *s, struct fb_config *c) {
    if (s == NULL) return -1;
    int reload;
    int n = sscanf(s, "%p,%d,%d,%d,%d,%d", (void **)&c->addr, &c->width, &c->height, &c->type,
                   &c->bpl, &reload);
    return (n == 6 && c->addr != 0) ? 0 : -1;
}

// JSON payload contract for the scrapers below (json_int, parse_bbox, json_str,
// json_bool): all incoming payloads are FLAT, single-level objects produced by
// first-party code (the selection .qmd and the QML viewer). Values are only
// strings, integers or booleans — no nesting, no arrays, no duplicated keys.
// Each scraper finds its key by substring search and reads the value right after,
// so these assumptions must hold; if a payload ever needs nesting or arrays,
// replace these with a real single-header JSON parser rather than extending them.

// Pulls the integer value following a quoted JSON key (e.g. "\"width\"").
static long json_int(const char *json, const char *key) {
    const char *p = strstr(json, key);
    if (p == NULL) return -1;
    p += strlen(key);
    while (*p && *p != '-' && !isdigit((unsigned char)*p))
        p++;
    if (*p == '\0') return -1;
    return strtol(p, NULL, 10);
}

static int parse_bbox(const char *json, struct rect *r) {
    if (json == NULL) return -1;
    r->x = (int)json_int(json, "\"x\"");
    r->y = (int)json_int(json, "\"y\"");
    r->w = (int)json_int(json, "\"width\"");
    r->h = (int)json_int(json, "\"height\"");
    if (r->x < 0 || r->y < 0 || r->w <= 0 || r->h <= 0) return -1;
    return 0;
}

static void clamp_rect(struct rect *r, const struct fb_config *c) {
    if (r->x + r->w > c->width) r->w = c->width - r->x;
    if (r->y + r->h > c->height) r->h = c->height - r->y;
}

// Crops the bbox out of the 4-byte-per-pixel framebuffer into a tight RGB buffer.
// Qt's Format_ARGB32 is stored little-endian as B,G,R,A in memory; alpha dropped.
static uint8_t *crop_rgb(const struct fb_config *c, const struct rect *r) {
    const int bpp = 4;
    uint8_t *out = malloc((size_t)r->w * r->h * 3);
    if (out == NULL) return NULL;
    const uint8_t *base = (const uint8_t *)c->addr;
    for (int row = 0; row < r->h; row++) {
        const uint8_t *src = base + (size_t)(r->y + row) * c->bpl + (size_t)r->x * bpp;
        uint8_t *dst = out + (size_t)row * r->w * 3;
        for (int col = 0; col < r->w; col++, src += bpp, dst += 3) {
            dst[0] = src[2]; // R
            dst[1] = src[1]; // G
            dst[2] = src[0]; // B
        }
    }
    return out;
}

// Rotates a tight RGB buffer clockwise by rot degrees (90/180/270) into a fresh
// buffer; the caller frees the source. For 90/270 the width and height swap, so
// *w/*h are updated to the rotated dimensions. Used to undo xochitl's landscape
// canvas rotation, which otherwise leaves the crop turned 90 degrees.
static uint8_t *rotate_rgb(const uint8_t *src, int *w, int *h, int rot) {
    const int W = *w, H = *h;
    const int ow = (rot == 180) ? W : H;
    const int oh = (rot == 180) ? H : W;
    uint8_t *out = malloc((size_t)ow * oh * 3);
    if (out == NULL) return NULL;
    for (int sy = 0; sy < H; sy++) {
        for (int sx = 0; sx < W; sx++) {
            int dx = rot == 90 ? H - 1 - sy : rot == 270 ? sy : W - 1 - sx;
            int dy = rot == 90 ? sx : rot == 270 ? W - 1 - sx : H - 1 - sy;
            const uint8_t *s = src + ((size_t)sy * W + sx) * 3;
            uint8_t *d = out + ((size_t)dy * ow + dx) * 3;
            d[0] = s[0];
            d[1] = s[1];
            d[2] = s[2];
        }
    }
    *w = ow;
    *h = oh;
    return out;
}

static char *write_png(const uint8_t *rgb, const struct rect *r) {
    static int counter = 0;
    mkdir(CAPTURE_DIR, 0755);
    char *path = malloc(256);
    if (path == NULL) return NULL;
    // Millisecond timestamp (not seconds): the counter resets to 0 when the
    // module reloads, so a second-resolution name could collide with a capture
    // from a previous load and silently overwrite that todo.
    struct timespec now;
    clock_gettime(CLOCK_REALTIME, &now);
    long long ms = (long long)now.tv_sec * 1000 + now.tv_nsec / 1000000;
    snprintf(path, 256, "%s/cap-%lld-%d.png", CAPTURE_DIR, ms, counter++);
    if (!stbi_write_png(path, r->w, r->h, 3, rgb, r->w * 3)) {
        fprintf(stderr, "[retasker] PNG write failed: %s\n", path);
        free(path);
        return NULL;
    }
    fprintf(stderr, "[retasker] wrote %s (%dx%d)\n", path, r->w, r->h);
    return path;
}

// export: invoked by xovi-message-broker for the "retasker.capture" signal.
char *captureHandler(const char *value) {
    fprintf(stderr, "[retasker] capture signal: %s\n", value ? value : "(null)");

    struct rect r;
    if (parse_bbox(value, &r) != 0) {
        fprintf(stderr, "[retasker] bad bbox payload\n");
        return NULL;
    }

    char *cfg = (char *)(uintptr_t)framebuffer_spy$getConfigString();
    struct fb_config c;
    int ok = parse_fb_config(cfg, &c);
    free(cfg);
    if (ok != 0) {
        fprintf(stderr, "[retasker] no framebuffer config (is framebuffer-spy loaded?)\n");
        return NULL;
    }
    if (c.type != FB_TYPE_RGBA) {
        fprintf(stderr, "[retasker] unsupported framebuffer type %d\n", c.type);
        return NULL;
    }

    clamp_rect(&r, &c);
    if (r.w <= 0 || r.h <= 0) return NULL;

    uint8_t *rgb = crop_rgb(&c, &r);
    if (rgb == NULL) return NULL;

    // Landscape pages render rotated inside the portrait framebuffer; the QML
    // sends the rotation needed to bring the crop back upright (0 in portrait).
    int rot = (int)json_int(value, "\"rotation\"");
    if (rot == 90 || rot == 180 || rot == 270) {
        uint8_t *rotated = rotate_rgb(rgb, &r.w, &r.h, rot);
        free(rgb);
        if (rotated == NULL) return NULL;
        rgb = rotated;
    }

    char *path = write_png(rgb, &r);
    free(rgb);
    return path;
}

#define XOCHITL_DIR "/home/root/.local/share/remarkable/xochitl"

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

    int fd = open("/run/xovi-mb", O_WRONLY);
    if (fd < 0) {
        fprintf(stderr, "[retasker] newnote: cannot open broker pipe\n");
        return NULL;
    }
    char encName[1536], encFolder[512], encExisting[512], encTemplate[1536];
    if (json_escape(name, encName, sizeof(encName)) != 0 ||
        json_escape(folderId, encFolder, sizeof(encFolder)) != 0 ||
        json_escape(existing, encExisting, sizeof(encExisting)) != 0 ||
        json_escape(templateFilename, encTemplate, sizeof(encTemplate)) != 0) {
        fprintf(stderr, "[retasker] newnote: JSON escape failed\n");
        close(fd);
        return NULL;
    }

    char out[4096];
    int n = snprintf(out, sizeof(out),
                     "uretasker.newnote:{\"name\":\"%s\",\"folder\":\"%s\",\"existing\":\"%s\","
                     "\"template\":\"%s\"}\n",
                     encName, encFolder, encExisting, encTemplate);
    if (n > 0 && n < (int)sizeof(out)) {
        if (write(fd, out, (size_t)n) < 0)
            fprintf(stderr, "[retasker] newnote: pipe write failed\n");
    }
    close(fd);
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

    int fd = open("/run/xovi-mb", O_WRONLY);
    if (fd < 0) {
        fprintf(stderr, "[retasker] chooseTemplate: cannot open broker pipe\n");
        return NULL;
    }
    char out[2048];
    int n =
        snprintf(out, sizeof(out), "uretasker.chooseTemplate:{\"template\":\"%s\"}\n", encTemplate);
    if (n > 0 && n < (int)sizeof(out)) {
        if (write(fd, out, (size_t)n) < 0)
            fprintf(stderr, "[retasker] chooseTemplate: pipe write failed\n");
    }
    close(fd);
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
