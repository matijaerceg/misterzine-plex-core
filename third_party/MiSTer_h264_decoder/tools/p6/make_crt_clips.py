#!/usr/bin/env python3
"""make_crt_clips.py -- a twitter test set for a 15 kHz interlaced CRT (P6 part 2's
Anti-Twitter, docs/analog.md §9): synthetic High-profile clips, generated here, never
committed. Every picture is built line-exact in numpy and piped to x264, so a "one-line"
detail is exactly one frame line. Play them with Video Output = Interlaced and Analog
Aspect = Fit (720 wide pictures are then shown 1:1, one picture line per frame line), and
flip Anti-Twitter in the OSD while one plays: it takes effect at the next field.

    python3 tools/p6/make_crt_clips.py OUTDIR     (needs ffmpeg with libx264, numpy, Pillow)

Each clip at 720x480 (59.94) and 720x576 (50: twitter is 25 Hz there, easier to see):
  chart   still bands of white lines on black -- 1-line lines 6 lines apart (flicker with
          Anti-Twitter Off, steady On); 1-on / 1-off alternating lines (the worst case: the
          whole block pulses); 2-line lines (the CONTROL: steady either way -- if these
          flicker, it is the set, not twitter)
  zone    a vertical frequency sweep: horizontal stripes from coarse at the top to 1-on /
          1-off at the bottom -- Off, the bottom shimmers; On, the finest stripes fade to grey
  text    a HUD-like page: 1-line-stroke bitmap text, thin boxes and underlines (left), the
          same at 2x (right: the control) -- the case players notice
  scroll  the text page scrolling up 1 line a frame and (lower half) 1 line every 2 frames:
          moving one-line detail crawls differently from still detail
"""
import os
import subprocess
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFont

W = 720
WHITE, BLACK, GREY = 235, 16, 126        # video levels (limited range, as the decoder shows them)


def label(img, x, y, s):
    d = ImageDraw.Draw(img)
    d.text((x, y), s, fill=WHITE, font=ImageFont.load_default())


def chart(h):
    a = np.full((h, W), BLACK, np.uint8)
    img = Image.fromarray(a)
    band = h // 4
    rows = []
    for i, (name, period, thick) in enumerate([("1-LINE LINES", 6, 1), ("ALTERNATE 1-ON 1-OFF", 2, 1),
                                               ("2-LINE LINES (CONTROL)", 8, 2)]):
        y0 = 30 + i * (band + 20)
        label(img, 8, y0 - 16, name)
        for y in range(y0, y0 + band - 10, period):
            rows.append((y, thick))
    a = np.asarray(img).copy()
    for y, t in rows:
        a[y:y + t, 200:W - 20] = WHITE
    return a


def zone(h):
    y = np.arange(h, dtype=float)
    # instantaneous frequency 0 -> 0.5 cycles a line down the picture: phase = pi y^2 / (2 h)
    v = 0.5 + 0.5 * np.cos(np.pi * y * y / (2 * h))
    col = (BLACK + (WHITE - BLACK) * v).astype(np.uint8)
    a = np.repeat(col[:, None], W, axis=1)
    img = Image.fromarray(a)
    d = ImageDraw.Draw(img)
    d.rectangle((0, 0, 170, 14), fill=BLACK)
    label(img, 4, 2, "ZONE: coarse -> 1-on/1-off")
    return np.asarray(img)


def text_page(h, extra=0):
    """the HUD page; `extra` lines taller (for scrolling)"""
    # a 1-bit canvas: no anti-aliasing, every stroke exactly white or black
    small = Image.new("1", (W // 2, h + extra), 0)
    d = ImageDraw.Draw(small)
    f = ImageFont.load_default()
    lines = ["SCORE 0012340   LIVES 3   STAGE 1-4", "THE QUICK BROWN FOX JUMPS OVER", "THE LAZY DOG 0123456789",
             "EEEE TTTT HHHH ==== ---- ____", "PRESS START", "Continue?  YES / NO", "Options  Audio  Video  Controls"]
    y = 6
    while y < h + extra - 20:
        for s in lines:
            d.text((6, y), s, fill=1, font=f)
            d.line((6, y + 13, 6 + 8 * len(s) // 1.4, y + 13), fill=1)          # an underline, 1 line
            y += 18
        d.rectangle((4, y, W // 2 - 8, y + 30), outline=1)                        # a 1-line box
        d.text((12, y + 10), "HP [##########------]", fill=1, font=f)
        y += 40
    left = np.where(np.asarray(small), WHITE, BLACK).astype(np.uint8)
    # the right half: the left half's top at 2x (strokes 2 lines: the control)
    big = np.asarray(Image.fromarray(left[:(h + extra) // 2, :W // 4]).resize((W // 2, ((h + extra) // 2) * 2),
                                                                          Image.NEAREST))
    right = np.full((h + extra, W // 2), BLACK, np.uint8)
    right[:big.shape[0]] = big
    a = np.concatenate([left, right], axis=1)
    a[:, W // 2 - 1] = GREY                                                        # a 1-dot divider
    return a


def enc(out, frames, h, rate, n):
    """frames: a function frame_index -> (h, W) uint8 luma; chroma neutral"""
    p = subprocess.Popen(["ffmpeg", "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "gray", "-s", "%dx%d" % (W, h),
                          "-r", rate, "-i", "-", "-vf", "format=yuv420p", "-c:v", "libx264", "-profile:v", "high",
                          "-level", "31", "-x264-params", "bframes=0:keyint=60:crf=4", out], stdin=subprocess.PIPE)
    for i in range(n):
        p.stdin.write(np.ascontiguousarray(frames(i)).tobytes())
    p.stdin.close()
    if p.wait() != 0:
        sys.exit("ffmpeg failed on " + out)
    print("  %s: %d bytes" % (os.path.basename(out), os.path.getsize(out)))


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else ".sim/crtclips"
    os.makedirs(out, exist_ok=True)
    for h, rate, fps in ((480, "60000/1001", 60), (576, "50", 50)):
        c, z, t = chart(h), zone(h), text_page(h)
        enc(os.path.join(out, "chart%d.264" % h), lambda i: c, h, rate, fps * 10)
        enc(os.path.join(out, "zone%d.264" % h), lambda i: z, h, rate, fps * 10)
        enc(os.path.join(out, "text%d.264" % h), lambda i: t, h, rate, fps * 10)
        tall = text_page(h, extra=4 * h)
        half = h // 2

        def scroll(i, tall=tall, h=h, half=half):
            a = np.empty((h, W), np.uint8)
            y1 = i % (tall.shape[0] - h)                  # 1 line a frame (top half)
            y2 = (i // 2) % (tall.shape[0] - h)           # 1 line every 2 frames (bottom half)
            a[:half] = tall[y1:y1 + half]
            a[half:] = tall[y2 + half:y2 + h]
            a[half - 1] = GREY
            return a
        enc(os.path.join(out, "scroll%d.264" % h), scroll, h, rate, fps * 20)


if __name__ == "__main__":
    main()
