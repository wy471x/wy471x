#!/usr/bin/env python3
"""Generate the CRT profile card that sits at the top of the profile README.

Takes the GitHub avatar, turns it into phosphor-green ASCII art, puts it next to
a fake terminal panel, and writes an animated GIF.

Usage:
    python3 .github/scripts/make-profile-card.py
    python3 .github/scripts/make-profile-card.py --preview /tmp/card.png

Requires Pillow + numpy only.
"""

import argparse
import math
import os

import numpy as np
from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

# ---------------------------------------------------------------- geometry ---
W, H = 800, 400
PANEL = (22, 20, 316, 382)          # ascii art area: left, top, right, bottom
DIVIDER_X = 344
TEXT_X, TEXT_Y = 372, 42
TEXT_SIZE = 15
LINE_GAP = 23

# ------------------------------------------------------------------ colors ---
BG = (4, 12, 7)
GREEN = (0x4A, 0xFF, 0x88)
GREEN_HOT = (0xD8, 0xFF, 0xE2)
GREEN_DIM = (0x27, 0x7E, 0x48)
GREEN_MID = (0x6C, 0xCE, 0x92)

FONT_CANDIDATES = [
    "/System/Library/Fonts/Menlo.ttc",
    "/System/Library/Fonts/Monaco.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
    "C:/Windows/Fonts/consola.ttf",
]

TERMINAL = [
    ("$ whoami", None),
    ("Yong Wan", "@wy471x", 10),
    (None, None),
    ("$ ls ~/open-source", None),
    ("apache/shenyu", "api gateway"),
    ("apache/hertzbeat", "observability"),
    ("apache/shenyu-website", "documentation"),
    ("ottertui/ottertui", "terminal ui"),
    ("GreptimeTeam/greptimedb", "time-series db"),
    (None, None),
    ("$ uptime", None),
    ("contributing since 2019", None),
]

PAIR_COLUMN = 25                   # monospace column for project descriptions

RAMP = " .:-=+*#%@"


def load_font(size):
    for path in FONT_CANDIDATES:
        if os.path.exists(path):
            try:
                return ImageFont.truetype(path, size)
            except OSError:
                continue
    return ImageFont.load_default()


def art_metrics():
    """Fixed cell grid so every frame renders identically."""
    font = load_font(int((PANEL[3] - PANEL[1]) / 34))
    cell_w = font.getlength("M")
    cell_h = cell_w * 1.55
    cols = int((PANEL[2] - PANEL[0]) / cell_w)
    rows = int((PANEL[3] - PANEL[1]) / cell_h)
    return font, cell_w, cell_h, cols, rows


# ------------------------------------------------------------- ascii art ----
def ascii_field(avatar, cols, rows):
    """Blend edges + highlights so the hazy sky drops out and the rocket reads."""
    src = avatar.convert("L")
    luma = np.asarray(src, dtype=np.float32) / 255.0
    broad = np.asarray(
        src.filter(ImageFilter.GaussianBlur(6)), dtype=np.float32
    ) / 255.0
    detail = np.clip((luma - broad) / 0.15, 0, 1)
    highlight = np.clip((luma - 0.72) / 0.28, 0, 1)

    field = np.maximum(detail * 0.85, highlight) ** 1.1
    img = Image.fromarray((field * 255).astype(np.uint8))
    return np.asarray(img.resize((cols, rows), Image.LANCZOS), dtype=np.float32) / 255.0


def art_layer(field, font, cell_w, cell_h):
    """RGBA layer with the ASCII glyphs drawn at their phosphor brightness."""
    layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    rows, cols = field.shape
    for r in range(rows):
        for c in range(cols):
            v = float(field[r, c])
            if v < 0.08:
                continue
            ch = RAMP[min(len(RAMP) - 1, int(v * len(RAMP)))]
            hot = min(1.0, max(0.0, (v - 0.40) / 0.60))
            color = tuple(int(a + (b - a) * hot) for a, b in zip(GREEN, GREEN_HOT))
            alpha = int(120 + 135 * v)
            draw.text(
                (PANEL[0] + c * cell_w, PANEL[1] + r * cell_h),
                ch,
                font=font,
                fill=color + (alpha,),
            )
    return layer


# ---------------------------------------------------------------- overlays ---
def make_vignette(size, strength=0.5):
    w, h = size
    yy, xx = np.mgrid[0:h, 0:w]
    cx, cy = w / 2.0, h / 2.0
    r = np.sqrt(((xx - cx) / cx) ** 2 + ((yy - cy) / cy) ** 2) / math.sqrt(2)
    mask = np.clip(1.0 - strength * r ** 2.2, 0, 1)
    return np.asarray((mask * 255).astype(np.uint8), dtype=np.float32) / 255.0


def make_scanlines(size, period=3, dark=0.60):
    w, h = size
    band = np.ones(h, dtype=np.float32)
    band[::period] = dark
    return np.repeat(band[:, None], w, axis=1)


def sweep_gain(h, center, thickness=140, peak=0.30):
    """Bright horizontal refresh band; wraps at the edges for a seamless loop."""
    yy = np.arange(h, dtype=np.float32)
    d = np.abs(yy - center)
    d = np.minimum(d, h - d)
    return np.exp(-(d ** 2) / (2 * (thickness / 2.0) ** 2)) * peak


def build_frame(art, terminal_font, prompt_font, t, frames, vignette, scanlines,
                grain, corner_mask):
    """t in [0, 1) is the loop position."""
    bloom = art.filter(ImageFilter.GaussianBlur(3.0))

    frame = Image.new("RGB", (W, H), BG)
    frame = ImageChops.add(frame, bloom.convert("RGB"), scale=1.0)
    frame = Image.alpha_composite(frame.convert("RGBA"), art).convert("RGB")

    draw = ImageDraw.Draw(frame)
    draw.line([(DIVIDER_X, PANEL[1]), (DIVIDER_X, PANEL[3])], fill=GREEN_DIM, width=1)

    y = TEXT_Y
    for row in TERMINAL:
        text = row[0]
        extra = row[1] if len(row) > 1 else None
        column = row[2] if len(row) > 2 else PAIR_COLUMN
        if text is None:
            y += LINE_GAP // 2
            continue
        if text.startswith("$"):
            draw.text((TEXT_X, y), text, font=prompt_font, fill=GREEN)
        else:
            draw.text((TEXT_X, y), text, font=terminal_font, fill=GREEN_MID)
        if extra:
            col = TEXT_X + draw.textlength("M" * column, font=terminal_font)
            draw.text((col, y), extra, font=terminal_font, fill=GREEN_DIM)
        y += LINE_GAP

    if (int(t * frames) // 3) % 2 == 0:
        cw = draw.textlength("$ ", font=prompt_font)
        draw.rectangle([(TEXT_X, y + 2), (TEXT_X + cw - 5, y + TEXT_SIZE + 1)], fill=GREEN)

    arr = np.asarray(frame, dtype=np.float32)
    # refresh band sweeps the art panel only; the terminal stays stable and
    # compresses much better in the GIF
    band = sweep_gain(H, (t * H) % H)[:, None]
    band = np.repeat(band, W, axis=1)
    band[:, DIVIDER_X:] = 0.0
    arr += band[:, :, None] * np.array([110, 255, 160], np.float32)
    arr *= scanlines[:, :, None]
    arr *= vignette[:, :, None]
    arr += grain
    arr = np.clip(arr * (1.0 + 0.02 * math.sin(2 * math.pi * 3 * t)), 0, 255)
    arr *= corner_mask[:, :, None]
    return Image.fromarray(arr.astype(np.uint8), "RGB")


def crop_avatar(avatar):
    """Crop to the panel aspect, framing the rocket rather than the empty sky."""
    w, h = avatar.size
    return avatar.crop((int(w * 0.24), int(h * 0.07), int(w * 0.87), h))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--avatar", default="assets/avatar-source.jpg")
    ap.add_argument("--out", default="assets/profile-card.gif")
    ap.add_argument("--preview", default=None, help="also write one frame as PNG")
    ap.add_argument("--frames", type=int, default=12)
    ap.add_argument("--fps", type=int, default=12)
    ap.add_argument("--colors", type=int, default=32)
    args = ap.parse_args()

    font, cell_w, cell_h, cols, rows = art_metrics()
    avatar = crop_avatar(Image.open(args.avatar))
    art = art_layer(ascii_field(avatar, cols, rows), font, cell_w, cell_h)

    terminal_font = load_font(TEXT_SIZE)
    prompt_font = load_font(TEXT_SIZE)
    vignette = make_vignette((W, H))
    scanlines = make_scanlines((W, H))
    grain = np.random.default_rng(7).normal(0, 3.0, (H, W, 1)).astype(np.float32)
    mask = Image.new("L", (W, H), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, W - 1, H - 1], radius=14, fill=255)
    corner_mask = np.asarray(mask.filter(ImageFilter.GaussianBlur(1.2)), dtype=np.float32) / 255.0

    frames = [
        build_frame(art, terminal_font, prompt_font, i / args.frames, args.frames,
                    vignette, scanlines, grain, corner_mask)
        for i in range(args.frames)
    ]

    if args.preview:
        frames[len(frames) // 2].save(args.preview)
        print(f"preview -> {args.preview}")

    os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
    palette = frames[0].quantize(colors=args.colors, method=Image.MEDIANCUT, dither=Image.NONE)
    quantized = [f.quantize(palette=palette, dither=Image.NONE) for f in frames]
    quantized[0].save(
        args.out,
        save_all=True,
        append_images=quantized[1:],
        duration=int(1000 / args.fps),
        loop=0,
        optimize=True,
        disposal=1,
    )
    print(f"wrote {args.out}: {len(quantized)} frames, {W}x{H}, "
          f"{os.path.getsize(args.out) / 1024:.0f} KB")


if __name__ == "__main__":
    main()
