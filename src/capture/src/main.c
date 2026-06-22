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
#include <sys/stat.h>

#include "../xovi.h"

#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "../vendor/stb_image_write.h"

// The viewer (AppLoad app) treats this folder as the todo list, so capture
// writes here and delete removes from here — one shared source of truth.
#define CAPTURE_DIR "/home/root/xovi/exthome/appload/retasker/captures"
#define FB_TYPE_RGBA 2  // FBSPY_TYPE_RGBA from framebuffer-spy.h (32-bit pixels)

struct fb_config {
    uintptr_t addr;
    int width, height, type, bpl;
};

struct rect { int x, y, w, h; };

// Parses framebuffer-spy's "0xADDR,width,height,type,bpl,requiresReload" string.
static int parse_fb_config(const char *s, struct fb_config *c) {
    if (s == NULL) return -1;
    int reload;
    int n = sscanf(s, "%p,%d,%d,%d,%d,%d", (void **)&c->addr,
                   &c->width, &c->height, &c->type, &c->bpl, &reload);
    return (n == 6 && c->addr != 0) ? 0 : -1;
}

// Pulls the integer value following a quoted JSON key (e.g. "\"width\"").
static long json_int(const char *json, const char *key) {
    const char *p = strstr(json, key);
    if (p == NULL) return -1;
    p += strlen(key);
    while (*p && *p != '-' && !isdigit((unsigned char)*p)) p++;
    if (*p == '\0') return -1;
    return strtol(p, NULL, 10);
}

static int parse_bbox(const char *json, struct rect *r) {
    if (json == NULL) return -1;
    r->x = (int) json_int(json, "\"x\"");
    r->y = (int) json_int(json, "\"y\"");
    r->w = (int) json_int(json, "\"width\"");
    r->h = (int) json_int(json, "\"height\"");
    if (r->x < 0 || r->y < 0 || r->w <= 0 || r->h <= 0) return -1;
    return 0;
}

static void clamp_rect(struct rect *r, const struct fb_config *c) {
    if (r->x + r->w > c->width)  r->w = c->width  - r->x;
    if (r->y + r->h > c->height) r->h = c->height - r->y;
}

// Crops the bbox out of the 4-byte-per-pixel framebuffer into a tight RGB buffer.
// Qt's Format_ARGB32 is stored little-endian as B,G,R,A in memory; alpha dropped.
static uint8_t *crop_rgb(const struct fb_config *c, const struct rect *r) {
    const int bpp = 4;
    uint8_t *out = malloc((size_t) r->w * r->h * 3);
    if (out == NULL) return NULL;
    const uint8_t *base = (const uint8_t *) c->addr;
    for (int row = 0; row < r->h; row++) {
        const uint8_t *src = base + (size_t)(r->y + row) * c->bpl + (size_t) r->x * bpp;
        uint8_t *dst = out + (size_t) row * r->w * 3;
        for (int col = 0; col < r->w; col++, src += bpp, dst += 3) {
            dst[0] = src[2];  // R
            dst[1] = src[1];  // G
            dst[2] = src[0];  // B
        }
    }
    return out;
}

static char *write_png(const uint8_t *rgb, const struct rect *r) {
    static int counter = 0;
    mkdir(CAPTURE_DIR, 0755);
    char *path = malloc(256);
    if (path == NULL) return NULL;
    snprintf(path, 256, "%s/cap-%ld-%d.png", CAPTURE_DIR, (long) time(NULL), counter++);
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

    char *cfg = (char *)(uintptr_t) framebuffer_spy$getConfigString();
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
    char *path = write_png(rgb, &r);
    free(rgb);
    return path;
}

static int has_png_suffix(const char *name) {
    size_t n = strlen(name);
    return n > 4 && strcmp(name + n - 4, ".png") == 0;
}

static int write_text(const char *path, const char *text, size_t len) {
    FILE *f = fopen(path, "w");
    if (f == NULL) {
        fprintf(stderr, "[retasker] txt open failed: %s\n", path);
        return -1;
    }
    fwrite(text, 1, len, f);
    fclose(f);
    return 0;
}

static int hexval(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return 0;
}

// Percent-decode src into dst (dst must be >= strlen(src)+1). Turns %XX into a
// raw byte; everything else copies through. Returns the decoded byte count.
static size_t percent_decode(const char *src, char *dst) {
    size_t j = 0;
    for (size_t i = 0; src[i] != '\0'; i++) {
        if (src[i] == '%' && isxdigit((unsigned char) src[i + 1])
                          && isxdigit((unsigned char) src[i + 2])) {
            dst[j++] = (char) ((hexval(src[i + 1]) << 4) | hexval(src[i + 2]));
            i += 2;
        } else {
            dst[j++] = src[i];
        }
    }
    return j;
}

// export: invoked by xovi-message-broker for the "retasker.transcribe" signal.
// Payload is "<pngfilename> <percent-encoded utf-8 text>": writes <base>.txt
// with the decoded text and removes the original <base>.png, turning an image
// todo into a text todo. Percent-encoding keeps the payload single-line and
// ASCII so it survives the broker transport and round-trips accents/newlines.
char *transcribeHandler(const char *value) {
    if (value == NULL) return NULL;
    const char *sp = strchr(value, ' ');
    if (sp == NULL) {
        fprintf(stderr, "[retasker] bad transcribe payload\n");
        return NULL;
    }

    size_t name_len = (size_t)(sp - value);
    const char *encoded = sp + 1;
    if (name_len == 0 || name_len > 200 || *encoded == '\0') return NULL;

    char name[208];
    memcpy(name, value, name_len);
    name[name_len] = '\0';
    if (strchr(name, '/') != NULL || !has_png_suffix(name)) {
        fprintf(stderr, "[retasker] bad transcribe filename: %s\n", name);
        return NULL;
    }

    char *text = malloc(strlen(encoded) + 1);
    if (text == NULL) return NULL;
    size_t text_len = percent_decode(encoded, text);

    char png_path[256], txt_path[256];
    snprintf(png_path, sizeof(png_path), "%s/%s", CAPTURE_DIR, name);
    name[name_len - 4] = '\0';  // strip ".png" to derive the base
    snprintf(txt_path, sizeof(txt_path), "%s/%s.txt", CAPTURE_DIR, name);

    int ok = (write_text(txt_path, text, text_len) == 0);
    free(text);
    if (!ok) return NULL;
    remove(png_path);
    fprintf(stderr, "[retasker] transcribed %s.png -> %s.txt\n", name, name);
    return NULL;
}

// export: invoked by xovi-message-broker for the "retasker.delete" signal.
// Payload is a bare PNG filename; the file is removed from the viewer's
// captures dir. A '/' in the name is rejected so the payload can't escape it.
char *deleteHandler(const char *value) {
    fprintf(stderr, "[retasker] delete signal: %s\n", value ? value : "(null)");

    if (value == NULL || value[0] == '\0' || strchr(value, '/') != NULL) {
        fprintf(stderr, "[retasker] bad delete payload\n");
        return NULL;
    }

    char path[256];
    snprintf(path, sizeof(path), "%s/%s", CAPTURE_DIR, value);
    if (remove(path) != 0) {
        fprintf(stderr, "[retasker] delete failed: %s\n", path);
        return NULL;
    }
    fprintf(stderr, "[retasker] deleted %s\n", path);
    return NULL;
}
