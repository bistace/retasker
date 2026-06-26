#!/usr/bin/env python3
"""reTasker launcher icon: dark full-bleed rounded tile + tapered pen-stroke check.

Dependency-free (stdlib only). Analytic anti-aliasing via signed-distance fields,
so it renders crisp at any SIZE without supersampling. The check follows the app's
own CheckMark geometry (.18,.52)->(.42,.76)->(.84,.24) so the launcher mark and the
in-app "done" check are the same glyph; the stroke radius is varied along the path
to give the calligraphic thin->thick->fine-point pen feel.
"""
import zlib, struct, math, sys

SIZE   = 512
TILE   = (0x1a, 0x1a, 0x1a)   # near-black, softer than pure black on e-ink
INK    = (0xff, 0xff, 0xff)   # white check
CORNER = 0.20                 # rounded-rect corner radius (fraction of tile)

# Check control points (unit square), matching ui/CheckMark.qml.
A = (0.18, 0.52)
B = (0.42, 0.76)
C = (0.84, 0.24)

# Stroke half-width (fraction of tile) along the path: touchdown -> elbow -> lift-off.
R_A, R_B, R_C = 0.050, 0.088, 0.006

L1 = math.dist(A, B)
L2 = math.dist(B, C)
SB = L1 / (L1 + L2)           # normalized arc position of the elbow


def radius_at(s):
    """Variable half-width as a function of normalized arc position s in [0,1]."""
    if s <= SB:
        u = s / SB
        return R_A + (R_B - R_A) * (u ** 0.7)          # swell into the elbow
    u = (s - SB) / (1 - SB)
    return R_B + (R_C - R_B) * (u ** 1.5)              # hold, then taper to a point


def seg_project(p, a, b):
    """Return (distance, t) of p's projection onto segment a-b, t clamped to [0,1]."""
    ax, ay = a; bx, by = b; px, py = p
    dx, dy = bx - ax, by - ay
    dd = dx * dx + dy * dy
    t = 0.0 if dd == 0 else max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / dd))
    fx, fy = ax + t * dx, ay + t * dy
    return math.hypot(px - fx, py - fy), t


def check_coverage(p, feather):
    """Coverage [0,1] of the tapered stroke at point p (unit coords)."""
    d1, t1 = seg_project(p, A, B)
    s1 = t1 * SB
    c1 = (radius_at(s1) - d1) / feather + 0.5
    d2, t2 = seg_project(p, B, C)
    s2 = SB + t2 * (1 - SB)
    c2 = (radius_at(s2) - d2) / feather + 0.5
    return max(0.0, min(1.0, max(c1, c2)))


def tile_coverage(p, feather):
    """Coverage [0,1] of the full-bleed rounded square at point p (unit coords)."""
    qx = abs(p[0] - 0.5) - (0.5 - CORNER)
    qy = abs(p[1] - 0.5) - (0.5 - CORNER)
    outside = math.hypot(max(qx, 0.0), max(qy, 0.0))
    d = outside + min(max(qx, qy), 0.0) - CORNER       # signed distance to rounded rect
    return max(0.0, min(1.0, 0.5 - d / feather))


def render(size):
    feather = 1.0 / size                               # ~1px AA band in unit coords
    buf = bytearray(size * size * 4)
    i = 0
    for y in range(size):
        py = (y + 0.5) / size
        for x in range(size):
            px = (x + 0.5) / size
            a = tile_coverage((px, py), feather)
            if a <= 0.0:
                i += 4
                continue
            k = check_coverage((px, py), feather)
            r = round(TILE[0] + (INK[0] - TILE[0]) * k)
            g = round(TILE[1] + (INK[1] - TILE[1]) * k)
            b = round(TILE[2] + (INK[2] - TILE[2]) * k)
            buf[i] = r; buf[i+1] = g; buf[i+2] = b; buf[i+3] = round(a * 255)
            i += 4
    return buf


def write_png(path, size, rgba):
    def chunk(typ, data):
        return (struct.pack(">I", len(data)) + typ + data +
                struct.pack(">I", zlib.crc32(typ + data) & 0xffffffff))
    raw = bytearray()
    row = size * 4
    for y in range(size):
        raw.append(0)
        raw.extend(rgba[y * row:(y + 1) * row])
    ihdr = struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0)
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(chunk(b"IHDR", ihdr))
        f.write(chunk(b"IDAT", zlib.compress(bytes(raw), 9)))
        f.write(chunk(b"IEND", b""))


if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else "icon.png"
    write_png(out, SIZE, render(SIZE))
    print("wrote", out, f"({SIZE}x{SIZE})")
