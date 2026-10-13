#!/usr/bin/env python3
"""Generates the app's raster assets from the full-res mascot originals. Needs Pillow (`pip3 install pillow`).

  packaging/make-assets.py mascot    Sources/PierApp/Resources/Mascot/<pose>.png + <pose>@2x.png (trimmed, transparent)
  packaging/make-assets.py menubar   Sources/PierApp/Resources/Mascot/menubar-gull.png + @2x (18pt template image)
  packaging/make-assets.py icon      packaging/AppIcon-1024.png (rounded-rect icon; make-icon.sh turns it into the .icns)

The mascot originals live outside the repo ("Pier Mascot Export"); set MASCOT_SRC to that folder. The icon source is
checked in as packaging/icon-source.png so `icon` works from a clean checkout.
"""
import os, sys
from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
RES = os.path.join(ROOT, "Sources/PierApp/Resources/Mascot")
SRC = os.environ.get("MASCOT_SRC", "/Users/stepanblaha/Developer/Pier Mascot Export")

# pose name -> source file (transparent originals)
POSES = {
    "sleeping": "sleeping-fullbody-transparent.png",
    "thinking": "thinking-fullbody-transparent.png",
    "walking": "walking-fullbody-transparent.png",
    "standing": "standing-fullbody-transparent.png",
    "waving": "waving-fullbody-transparent.png",
    "saluting": "saluting-fullbody-transparent.png",
    "surprised": "surprised-corner-transparent.png",
}
SIZES = {"": 160, "@2x": 320}   # max dimension in px


def trim(im, pad=0.02):
    box = im.getchannel("A").point(lambda v: 255 if v > 8 else 0).getbbox()
    im = im.crop(box)
    p = int(max(im.size) * pad)
    out = Image.new("RGBA", (im.width + 2 * p, im.height + 2 * p), (0, 0, 0, 0))
    out.paste(im, (p, p))
    return out


def fit(im, maxdim):
    s = maxdim / max(im.size)
    return im.resize((max(1, round(im.width * s)), max(1, round(im.height * s))), Image.LANCZOS)


def mascot():
    os.makedirs(RES, exist_ok=True)
    for name, f in POSES.items():
        im = trim(Image.open(os.path.join(SRC, f)).convert("RGBA"))
        for suffix, px in SIZES.items():
            out = os.path.join(RES, f"{name}{suffix}.png")
            fit(im, px).save(out, optimize=True)
            print("wrote", os.path.relpath(out, ROOT))


# --- menu bar template: hand-drawn gull head (hat, band, eyes, beak) so it reads at 18px --------------------------

OX, OY, W, H, SS = 262, 70, 708, 640, 2


def _smooth(pts, n=3, closed=False):
    for _ in range(n):
        out, N = [], len(pts)
        if not closed:
            out.append(pts[0])
        for i in (range(N) if closed else range(N - 1)):
            p, q = pts[i], pts[(i + 1) % N]
            out.append((0.75 * p[0] + 0.25 * q[0], 0.75 * p[1] + 0.25 * q[1]))
            out.append((0.25 * p[0] + 0.75 * q[0], 0.25 * p[1] + 0.75 * q[1]))
        if not closed:
            out.append(pts[-1])
        pts = out
    return pts


def _head_mask(lw=84):
    im = Image.new("L", (W * SS, H * SS), 0)
    d = ImageDraw.Draw(im)
    P = lambda pts: [((x - OX) * SS, (y - OY) * SS) for x, y in pts]

    def line(pts, w=lw, closed=False):
        pts = _smooth(pts, 3, closed)
        if closed:
            pts = pts + [pts[0]]
        p = P(pts)
        d.line(p, fill=255, width=int(w * SS), joint="curve")
        r = w * SS / 2
        for x, y in p:
            d.ellipse((x - r, y - r, x + r, y + r), fill=255)

    box = lambda x0, y0, x1, y1: [(x0 - OX) * SS, (y0 - OY) * SS, (x1 - OX) * SS, (y1 - OY) * SS]
    line([(285, 365), (400, 240), (520, 150), (640, 105), (730, 100), (775, 140), (745, 225), (600, 290),
          (480, 345), (382, 400), (320, 420), (285, 395)], closed=True)                       # hat dome (ring)
    d.polygon(P(_smooth([(385, 385), (745, 232), (762, 320), (418, 475)], 2, True)), fill=255)   # band
    line([(418, 450), (385, 510), (385, 580), (450, 650), (580, 690), (740, 690), (880, 650), (935, 580),
          (925, 480), (880, 390), (800, 330), (758, 300)])                                      # head
    line([(770, 270), (815, 225), (850, 215), (850, 265), (825, 320)], w=56)                    # crest
    d.ellipse(box(530, 450, 612, 556), fill=255)                                                # eyes
    d.ellipse(box(738, 398, 818, 500), fill=255)
    d.polygon(P(_smooth([(640, 590), (705, 515), (760, 490), (830, 520), (850, 585), (790, 610), (700, 610)], 3, True)),
              fill=255)                                                                         # beak
    return im


def menubar():
    os.makedirs(RES, exist_ok=True)
    mask = _head_mask()
    for suffix, h in (("", 18), ("@2x", 36)):
        w = round(mask.width * h / mask.height)
        a = mask.resize((w, h), Image.LANCZOS)
        out = Image.new("RGBA", (w, h), (0, 0, 0, 0))
        out.putalpha(a)
        path = os.path.join(RES, f"menubar-gull{suffix}.png")
        out.save(path, optimize=True)
        print("wrote", os.path.relpath(path, ROOT), out.size)


# --- app icon ---------------------------------------------------------------------------------------------------

def icon(size=1024):
    src = Image.open(os.path.join(ROOT, "packaging/icon-source.png")).convert("RGBA")
    # head + hat + shoulders; the bust bleeds off the bottom of the tile (clipped by the rounded rect), so there is
    # no visible cut line. Hat top and sides keep ~10% padding.
    head = trim(src.crop((150, 60, 1100, 1210)), pad=0)
    # macOS icon grid: the artwork sits in an 824px rounded rect inside the 1024 canvas (100px transparent margin)
    body, radius = round(size * 0.806), round(size * 0.806 * 0.225)
    k = 4
    mask = Image.new("L", (body * k, body * k), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, body * k - 1, body * k - 1), radius=radius * k, fill=255)
    mask = mask.resize((body, body), Image.LANCZOS)
    # cream with a faint vertical gradient
    tile = Image.new("RGBA", (body, body))
    top, bot = (255, 251, 238), (246, 238, 214)
    px = ImageDraw.Draw(tile)
    for y in range(body):
        t = y / (body - 1)
        px.line([(0, y), (body, y)], fill=tuple(round(a + (b - a) * t) for a, b in zip(top, bot)) + (255,))
    s = body * 0.86 / head.width
    h2 = head.resize((round(head.width * s), round(head.height * s)), Image.LANCZOS)
    # soft contact shadow under the artwork
    sh = Image.new("RGBA", tile.size, (0, 0, 0, 0))
    ox, oy = (body - h2.width) // 2, round(body * 0.10)
    shadow = Image.new("RGBA", h2.size, (40, 50, 80, 0)); shadow.putalpha(h2.getchannel("A").point(lambda v: int(v * 0.16)))
    sh.alpha_composite(shadow, (ox, oy + round(body * 0.012)))
    tile.alpha_composite(sh.filter(ImageFilter.GaussianBlur(body * 0.012)))
    tile.alpha_composite(h2, (ox, oy))
    tile.putalpha(mask)
    # canvas shadow like system icons
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    off = (size - body) // 2
    drop = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    blk = Image.new("RGBA", tile.size, (0, 0, 0, 0)); blk.putalpha(mask.point(lambda v: int(v * 0.28)))
    drop.alpha_composite(blk, (off, off + round(size * 0.01)))
    canvas.alpha_composite(drop.filter(ImageFilter.GaussianBlur(size * 0.010)))
    canvas.alpha_composite(tile, (off, off))
    out = os.path.join(ROOT, "packaging/AppIcon-1024.png")
    canvas.save(out)
    print("wrote", os.path.relpath(out, ROOT))


if __name__ == "__main__":
    cmds = {"mascot": mascot, "menubar": menubar, "icon": icon}
    if len(sys.argv) != 2 or sys.argv[1] not in cmds:
        sys.exit(__doc__)
    cmds[sys.argv[1]]()
