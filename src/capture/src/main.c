// reTasker capture extension — framebuffer capture.
//
// Registers a "retasker.capture" signal handler on xovi-message-broker. When
// fired with a bbox JSON payload, it reads the live framebuffer address from
// framebuffer-spy, crops the bbox rectangle, and writes it out as a PNG.
//
// The selection-menu "Add to todos" button (added via a .qmd) sends the bbox;
// for the decision gate the same signal can be fired from a shell:
//   echo 'eretasker.capture:{"x":100,"y":200,"width":400,"height":300}' > /run/xovi-mb
//
// The same .so also exports the xochitl native-bridge handlers (newnote/template
// lookups); those live in bridge.c — an unrelated responsibility, kept in the
// same extension only because they share the broker entry point and build.
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <ctype.h>
#include <time.h>
#include <sys/stat.h>

#include "../xovi.h"

#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "../vendor/stb_image_write.h"

// The viewer (AppLoad app) treats this folder as the todo list, so capture
// writes here and delete removes from here — one shared source of truth.
#define CAPTURE_DIR "/home/root/xovi/exthome/appload/retasker/captures"
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
    // The returned path is handed straight back to xovi-message-broker, which
    // treats the handler result as a borrowed string (it does not free it). A
    // heap allocation here would leak per capture, so use a static buffer: the
    // broker marshals the string to its JS caller synchronously, before the next
    // capture can overwrite it.
    static char path[256];
    mkdir(CAPTURE_DIR, 0755);
    // Millisecond timestamp (not seconds): the counter resets to 0 when the
    // module reloads, so a second-resolution name could collide with a capture
    // from a previous load and silently overwrite that todo.
    struct timespec now;
    clock_gettime(CLOCK_REALTIME, &now);
    long long ms = (long long)now.tv_sec * 1000 + now.tv_nsec / 1000000;
    snprintf(path, sizeof(path), "%s/cap-%lld-%d.png", CAPTURE_DIR, ms, counter++);
    if (!stbi_write_png(path, r->w, r->h, 3, rgb, r->w * 3)) {
        fprintf(stderr, "[retasker] PNG write failed: %s\n", path);
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
