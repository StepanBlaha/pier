#!/usr/bin/env python3
"""Generate Sources/PierCore/Mascot/MascotArt.swift from the full-res mascot PNGs.

Usage:
    python3 tools/gen-mascot.py [--src DIR] [--preview DIR]

Needs Python 3 + Pillow. Sources are the 1254px originals (read-only); `*-transparent.png` have alpha,
`*-cream.png` get their cream background removed by flood fill from the borders. Each pose is cropped to
the bird's bounding box, fitted into a small pixel grid and quantized to the fixed mascot palette so it
stays crisp (navy outline, blue hat band, white body, grey wing, yellow beak/feet).

--preview DIR writes upscaled PNGs of every generated grid so the result can be judged by eye.
"""
import argparse, os, sys
from collections import deque
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_SRC = "/Users/stepanblaha/Developer/Pier Mascot Export"
OUT = os.path.join(ROOT, "Sources/PierCore/Mascot/MascotArt.swift")

# index -> (char, name, rgb). Index 0 is transparent (the terminal's own background).
PALETTE = [
    (".", "clear",  None),
    ("n", "navy",   (0x0d, 0x1b, 0x4c)),
    ("b", "blue",   (0x23, 0x50, 0xa8)),
    ("w", "white",  (0xfb, 0xfb, 0xf7)),
    ("l", "shade",  (0xc9, 0xcc, 0xd6)),
    ("g", "grey",   (0x9a, 0xa0, 0xb4)),
    ("y", "yellow", (0xf5, 0xb8, 0x2e)),
    ("p", "pink",   (0xe8, 0x70, 0x7a)),
]

# pose -> (file, size spec). Poses cut off by the image border ("bust") are used as they are.
POSES = {
    "standing":    "standing-fullbody-transparent.png",
    "sleeping":    "sleeping-fullbody-transparent.png",
    "celebrating": "celebrating-fullbody-transparent.png",
    "saluting":    "saluting-fullbody-transparent.png",
    "waving":      "waving-fullbody-transparent.png",
    "thinking":    "thinking-fullbody-transparent.png",
    "coffee":      "coffee-fullbody-transparent.png",
    "surprised":   "surprised-corner-transparent.png",
}
# name -> (cols, pixel rows). Pixel rows are even (two per text row, half blocks).
SIZES = {"small": (16, 16), "medium": (30, 30)}

# Per-class vote weights when a cell covers many source pixels: thin dark / colorful details (outline,
# eye, beak) must win over the large white areas around them or the bird turns to mush.
COLOR_MIN = {6: 0.30, 7: 0.20, 2: 0.35}  # yellow, pink, blue: share of a cell that makes it that color, checked in order
NAVY_MIN = {"small": 0.30, "medium": 0.20}  # navy share of a cell that makes it outline (thin lines survive)
EDGE_NAVY_MIN = 0.0
WEIGHT = {1: 3.2, 2: 1.6, 3: 1.0, 4: 1.0, 5: 1.3, 6: 1.9, 7: 2.0}


def load(path):
    im = Image.open(path).convert("RGBA")
    px = im.load()
    w, h = im.size
    if px[0, 0][3] == 255:  # opaque (cream) background: flood from the border
        bg = px[0, 0][:3]
        def near(c):
            return max(abs(c[0] - bg[0]), abs(c[1] - bg[1]), abs(c[2] - bg[2])) < 14
        seen = bytearray(w * h)
        q = deque()
        for x in range(w):
            q.append((x, 0)); q.append((x, h - 1))
        for y in range(h):
            q.append((0, y)); q.append((w - 1, y))
        while q:
            x, y = q.popleft()
            if x < 0 or y < 0 or x >= w or y >= h or seen[y * w + x]:
                continue
            if not near(px[x, y]):
                continue
            seen[y * w + x] = 1
            px[x, y] = (0, 0, 0, 0)
            q.extend(((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)))
    return im


_CACHE = {}


def classify(rgb):
    hit = _CACHE.get(rgb)
    if hit is not None:
        return hit
    best = _classify(rgb)
    _CACHE[rgb] = best
    return best


def _classify(rgb):
    best, bd = 3, 1e18
    for i, (_, _, c) in enumerate(PALETTE):
        if c is None:
            continue
        d = sum((a - b) ** 2 for a, b in zip(rgb, c))
        if d < bd:
            best, bd = i, d
    return best


def to_grid(im, cols, rows, navy_min):
    bbox = im.split()[-1].point(lambda a: 255 if a > 100 else 0).getbbox()
    im = im.crop(bbox)
    w, h = im.size
    # Fit into the grid, keep aspect, bottom-center aligned (feet on the same baseline).
    scale = min(cols / w, rows / h)
    gw, gh = max(1, round(w * scale)), max(1, round(h * scale))
    ox, oy = (cols - gw) // 2, rows - gh
    # classify at reduced resolution first (cheap, and the box filter smooths JPEG-ish noise)
    px = im.load()
    classes = [[0] * w for _ in range(h)]
    for y in range(h):
        for x in range(w):
            r, g, b, a = px[x, y]
            classes[y][x] = 0 if a < 128 else classify((r, g, b))
    grid = [[0] * cols for _ in range(rows)]
    navy_share = {}
    for gy in range(gh):
        y0, y1 = int(gy * h / gh), max(int((gy + 1) * h / gh), int(gy * h / gh) + 1)
        for gx in range(gw):
            x0, x1 = int(gx * w / gw), max(int((gx + 1) * w / gw), int(gx * w / gw) + 1)
            votes = {}
            n = 0
            for y in range(y0, y1):
                row = classes[y]
                for x in range(x0, x1):
                    c = row[x]
                    votes[c] = votes.get(c, 0) + 1
                    n += 1
            clear = votes.get(0, 0) / n
            if clear > 0.5:
                continue
            # colored features first (beak, band, tongue, wing), then the outline, then the big fills
            best = 0
            for c, need in COLOR_MIN.items():
                if votes.get(c, 0) / n >= need:
                    best = c
                    break
            if best == 0 and votes.get(1, 0) / n >= navy_min:
                best = 1
            if best == 0:
                bs = -1
                for c, v in votes.items():
                    if c in (0, 1):
                        continue
                    if v > bs:
                        best, bs = c, v
                if best == 0:
                    best = 1
            grid[oy + gy][ox + gx] = best
            navy_share[(oy + gy, ox + gx)] = votes.get(1, 0) / n
    # Close gaps in the silhouette outline: a white / shade cell on the edge of the bird that has any
    # outline ink in it becomes outline, so the white hat and belly stay readable on light terminals.
    for (y, x), share in navy_share.items():
        if grid[y][x] in (3, 4) and share >= EDGE_NAVY_MIN:
            for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                yy, xx = y + dy, x + dx
                if 0 <= yy < rows and 0 <= xx < cols and grid[yy][xx] == 0:
                    grid[y][x] = 1
                    break
    return grid


def preview(grids, outdir):
    os.makedirs(outdir, exist_ok=True)
    k = 12
    for (pose, size), g in grids.items():
        rows, cols = len(g), len(g[0])
        for tag, bgc in (("dark", (24, 24, 28)), ("light", (245, 245, 240))):
            im = Image.new("RGB", (cols * k, rows * k), bgc)
            p = im.load()
            for y in range(rows):
                for x in range(cols):
                    c = PALETTE[g[y][x]][2]
                    if c:
                        for dy in range(k):
                            for dx in range(k):
                                p[x * k + dx, y * k + dy] = c
            im.save(os.path.join(outdir, f"{pose}-{size}-{tag}.png"))


def swift(grids):
    out = []
    out.append("// GENERATED FILE - do not edit by hand.")
    out.append("// Regenerate with: python3 tools/gen-mascot.py   (needs Python 3 + Pillow and the full-res mascot PNGs)")
    out.append("// Source: tools/gen-mascot.py. Each row is one string, one character per pixel:")
    out.append("//   " + "  ".join(f"{c}={n}" for c, n, _ in PALETTE))
    out.append("")
    out.append("enum MascotArt {")
    out.append("    /// Palette RGB by index (index 0 = transparent, rgb unused).")
    out.append("    static let paletteRGB: [(UInt8, UInt8, UInt8)] = [")
    for c, n, rgb in PALETTE:
        r, g, b = rgb or (0, 0, 0)
        out.append(f"        ({r}, {g}, {b}),  // {c} {n}")
    out.append("    ]")
    out.append("    /// Characters used in `grids`, by palette index.")
    out.append("    static let paletteChars: [Character] = Array(\"" + "".join(c for c, _, _ in PALETTE) + "\")")
    out.append("")
    out.append("    static let grids: [String: [String: [String]]] = [")
    poses = list(POSES)
    for pose in poses:
        out.append(f"        \"{pose}\": [")
        for size in SIZES:
            g = grids[(pose, size)]
            out.append(f"            \"{size}\": [")
            for row in g:
                out.append("                \"" + "".join(PALETTE[i][0] for i in row) + "\",")
            out.append("            ],")
        out.append("        ],")
    out.append("    ]")
    out.append("}")
    return "\n".join(out) + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", default=DEFAULT_SRC)
    ap.add_argument("--preview", default=None)
    ap.add_argument("--out", default=OUT)
    a = ap.parse_args()
    grids = {}
    for pose, fn in POSES.items():
        im = load(os.path.join(a.src, fn))
        for size, (c, r) in SIZES.items():
            grids[(pose, size)] = to_grid(im, c, r, NAVY_MIN[size])
            print(f"{pose} {size}", file=sys.stderr)
    if a.preview:
        preview(grids, a.preview)
    os.makedirs(os.path.dirname(a.out), exist_ok=True)
    with open(a.out, "w") as f:
        f.write(swift(grids))


if __name__ == "__main__":
    main()
