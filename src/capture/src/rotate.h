#ifndef RETASKER_ROTATE_H
#define RETASKER_ROTATE_H

#include <stdint.h>
#include <stdlib.h>

// Rotates a tight RGB buffer clockwise by rot degrees (90/180/270) into a fresh
// buffer; the caller frees the source. For 90/270 the width and height swap, so
// *w/*h are updated to the rotated dimensions. Used to undo xochitl's landscape
// canvas rotation, which otherwise leaves the crop turned 90 degrees.
//
// Lives in a header (not a .c) so the capture extension and its unit test share
// one definition; each side includes it from exactly one TU, so `static` is fine.
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

#endif // RETASKER_ROTATE_H
