// Unit tests for the capture extension's pure C helpers. We include the real
// sources directly so the static functions are visible in this translation unit:
//   - rotate.h  : rotate_rgb (framebuffer rotation)
//   - bridge.c  : json_escape (and the rest of the bridge, unused here)
//
// Build & run:  cc -D_GNU_SOURCE -Wall -o /tmp/retasker_ctest \
//                   test/c/test_helpers.c && /tmp/retasker_ctest
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../../src/capture/src/rotate.h"
#include "../../src/capture/src/bridge.c"

static void test_json_escape(void) {
    char out[64];

    assert(json_escape("plain", out, sizeof(out)) == 0);
    assert(strcmp(out, "plain") == 0);

    // Quote and backslash get backslash-escaped.
    assert(json_escape("a\"b\\c", out, sizeof(out)) == 0);
    assert(strcmp(out, "a\\\"b\\\\c") == 0);

    // Tab and newline use their short escapes.
    assert(json_escape("tab\tnl\n", out, sizeof(out)) == 0);
    assert(strcmp(out, "tab\\tnl\\n") == 0);

    // Other control chars become \u00XX.
    char ctrl[2] = {0x01, 0};
    assert(json_escape(ctrl, out, sizeof(out)) == 0);
    assert(strcmp(out, "\\u0001") == 0);

    // Overflowing the output buffer returns -1.
    char small[3];
    assert(json_escape("toolong", small, sizeof(small)) == -1);

    printf("  ok - json_escape\n");
}

static void test_rotate_rgb(void) {
    // A 2x1 RGB image: pixel (0,0) then pixel (1,0).
    uint8_t src[6] = {10, 11, 12, 20, 21, 22};

    // 90 deg CW: dims swap to 1x2, column becomes a top-to-bottom row.
    int w = 2, h = 1;
    uint8_t *r90 = rotate_rgb(src, &w, &h, 90);
    assert(r90 != NULL && w == 1 && h == 2);
    assert(r90[0] == 10 && r90[1] == 11 && r90[2] == 12);
    assert(r90[3] == 20 && r90[4] == 21 && r90[5] == 22);
    free(r90);

    // 180 deg: dims unchanged, pixel order reversed.
    w = 2;
    h = 1;
    uint8_t *r180 = rotate_rgb(src, &w, &h, 180);
    assert(r180 != NULL && w == 2 && h == 1);
    assert(r180[0] == 20 && r180[1] == 21 && r180[2] == 22);
    assert(r180[3] == 10 && r180[4] == 11 && r180[5] == 12);
    free(r180);

    // 270 deg CW: dims swap to 1x2, reversed relative to 90.
    w = 2;
    h = 1;
    uint8_t *r270 = rotate_rgb(src, &w, &h, 270);
    assert(r270 != NULL && w == 1 && h == 2);
    assert(r270[0] == 20 && r270[1] == 21 && r270[2] == 22);
    assert(r270[3] == 10 && r270[4] == 11 && r270[5] == 12);
    free(r270);

    printf("  ok - rotate_rgb\n");
}

int main(void) {
    test_json_escape();
    test_rotate_rgb();
    printf("\nC assertions passed\n");
    return 0;
}
