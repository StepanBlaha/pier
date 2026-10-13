#!/usr/bin/env python3
"""Render captured terminal output (ANSI SGR, truecolor) into a macOS-style terminal window PNG.

Usage: tools/render-terminal.py input.ansi output.png [--title "pier"] [--cols 96]
Capture input with e.g.:
  LANG=en_US.UTF-8 COLORTERM=truecolor script -q out.ansi pier hello
Half blocks (▀ ▄ █) are drawn as exact rectangles so pixel art stays crisp.
"""
import re
import sys
import argparse
from PIL import Image, ImageDraw, ImageFont

BG = (24, 26, 36)
FG = (220, 223, 230)
BAR = (40, 43, 56)
BASIC = {30: (40, 42, 54), 31: (239, 83, 80), 32: (102, 187, 106), 33: (255, 202, 40), 34: (66, 133, 244),
         35: (186, 104, 200), 36: (38, 198, 218), 37: (220, 223, 230), 90: (120, 124, 140), 91: (255, 110, 100),
         92: (130, 210, 130), 93: (255, 220, 90), 94: (100, 160, 255), 95: (210, 140, 220), 96: (90, 220, 235),
         97: (250, 250, 250)}


# box-drawing glyphs drawn as connected strokes: (up, down, left, right)
BOX = {"│": (1, 1, 0, 0), "─": (0, 0, 1, 1), "┌": (0, 1, 0, 1), "╭": (0, 1, 0, 1), "┐": (0, 1, 1, 0), "╮": (0, 1, 1, 0),
       "└": (1, 0, 0, 1), "╰": (1, 0, 0, 1), "┘": (1, 0, 1, 0), "╯": (1, 0, 1, 0), "├": (1, 1, 0, 1), "┤": (1, 1, 1, 0),
       "┬": (0, 1, 1, 1), "┴": (1, 0, 1, 1), "┼": (1, 1, 1, 1)}


def xterm256(n):
    if n < 16:
        return list(BASIC.values())[n % len(BASIC)]
    if n < 232:
        n -= 16
        steps = [0, 95, 135, 175, 215, 255]
        return steps[n // 36], steps[(n // 6) % 6], steps[n % 6]
    v = 8 + (n - 232) * 10
    return v, v, v


def parse(text, cols):
    """Return rows of cells: (char, fg, bg, bold)."""
    text = text.replace("\r\n", "\n").replace("\r", "")
    text = re.sub(r"\x1b\][^\x07]*(\x07|\x1b\\)", "", text)          # OSC
    rows, row = [], []
    fg, bg, bold = None, None, False
    i = 0
    while i < len(text):
        c = text[i]
        if c == "\x1b":
            m = re.match(r"\x1b\[([0-9;?]*)([A-Za-z])", text[i:])
            if m:
                if m.group(2) == "m":
                    params = [int(p) if p else 0 for p in m.group(1).split(";")] if m.group(1) else [0]
                    j = 0
                    while j < len(params):
                        p = params[j]
                        if p == 0: fg, bg, bold = None, None, False
                        elif p == 1: bold = True
                        elif p == 22: bold = False
                        elif p in (38, 48) and j + 1 < len(params):
                            if params[j + 1] == 2 and j + 4 < len(params):
                                col = tuple(params[j + 2:j + 5]); j += 4
                            elif params[j + 1] == 5 and j + 2 < len(params):
                                col = xterm256(params[j + 2]); j += 2
                            else:
                                col = None
                            if p == 38: fg = col
                            else: bg = col
                        elif p == 39: fg = None
                        elif p == 49: bg = None
                        elif 30 <= p <= 37 or 90 <= p <= 97: fg = BASIC.get(p)
                        elif 40 <= p <= 47: bg = BASIC.get(p - 10)
                        elif 100 <= p <= 107: bg = BASIC.get(p - 10)
                        j += 1
                i += len(m.group(0))
                continue
            i += 1
            continue
        if c == "\n":
            rows.append(row); row = []
        elif c >= " ":
            row.append((c, fg, bg, bold))
        i += 1
    if row:
        rows.append(row)
    while rows and not any(ch.strip() for ch, *_ in rows[-1]):
        rows.pop()
    return [r[:cols] for r in rows]


def render(rows, out, title, cols):
    font = ImageFont.truetype("/System/Library/Fonts/Menlo.ttc", 26)
    bold = ImageFont.truetype("/System/Library/Fonts/Menlo.ttc", 26, index=1)
    cw = round(font.getlength("M"))
    ch = 34
    pad, bar = 36, 56
    width = max(len(r) for r in rows) if rows else cols
    W, H = pad * 2 + width * cw, bar + pad * 2 + len(rows) * ch
    img = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(img)
    d.rectangle((0, 0, W, bar), fill=BAR)
    for k, col in enumerate([(255, 95, 87), (254, 188, 46), (40, 200, 64)]):
        d.ellipse((24 + k * 34, 18, 44 + k * 34, 38), fill=col)
    if title:
        tw = font.getlength(title)
        d.text(((W - tw) / 2, 13), title, font=font, fill=(160, 165, 180))
    for y, row in enumerate(rows):
        for x, (c, fg, bg, b) in enumerate(row):
            x0, y0 = pad + x * cw, bar + pad + y * ch
            if bg:
                d.rectangle((x0, y0, x0 + cw - 1, y0 + ch - 1), fill=bg)
            col = fg or FG
            if c == "█":
                d.rectangle((x0, y0, x0 + cw - 1, y0 + ch - 1), fill=col)
            elif c == "▀":
                d.rectangle((x0, y0, x0 + cw - 1, y0 + ch // 2 - 1), fill=col)
            elif c == "▄":
                d.rectangle((x0, y0 + ch // 2, x0 + cw - 1, y0 + ch - 1), fill=col)
            elif c in BOX:
                up, down, left, right = BOX[c]
                cx, cy, lw = x0 + cw // 2, y0 + ch // 2, 2
                if up: d.rectangle((cx - lw // 2, y0, cx + lw // 2 - 1, cy), fill=col)
                if down: d.rectangle((cx - lw // 2, cy, cx + lw // 2 - 1, y0 + ch - 1), fill=col)
                if left: d.rectangle((x0, cy - lw // 2, cx, cy + lw // 2 - 1), fill=col)
                if right: d.rectangle((cx, cy - lw // 2, x0 + cw - 1, cy + lw // 2 - 1), fill=col)
            elif c != " ":
                d.text((x0, y0 + 2), c, font=bold if b else font, fill=col)
    # rounded window corners on a transparent canvas
    mask = Image.new("L", (W, H), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, W - 1, H - 1), radius=22, fill=255)
    rgba = img.convert("RGBA")
    rgba.putalpha(mask)
    rgba.save(out, optimize=True)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("input")
    ap.add_argument("output")
    ap.add_argument("--title", default="pier")
    ap.add_argument("--cols", type=int, default=100)
    a = ap.parse_args()
    with open(a.input, encoding="utf-8", errors="replace") as f:
        rows = parse(f.read(), a.cols)
    render(rows, a.output, a.title, a.cols)
