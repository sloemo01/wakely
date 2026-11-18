#!/usr/bin/env python3
"""Render the Wakely drag-to-Applications disk-image background.

Dark editorial header, light install shelf so Finder's black item labels stay
readable, and a common 40px left margin for the mark, headline and subtitle.
Produces 720x420 @1x plus 1440x840 @2x in Resources/DMGBackground.tiff.
"""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
FONT = ROOT / "Resources/Fonts/Pixel"
OUT = ROOT / "Resources/DMGBackground.tiff"
W, H = 720, 420

BAYER = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5]
DARK = (9, 9, 11)
CREAM = (250, 250, 250)
SECONDARY = (196, 196, 204)
TERTIARY = (85, 85, 95)
GOLD = (234, 179, 8)
GOLD_DARK = (133, 96, 0)
SHELF = (244, 244, 245)
SHELF_STROKE = (208, 208, 217)
MARK = [
    ".....1.....",
    ".1...1...1.",
    "..1.....1..",
    "..1111111..",
    ".1.......1.",
    "1....1....1",
    ".1.......1.",
    "..1111111..",
    "..1.....1..",
    ".1...1...1.",
    ".....1.....",
]
SHELF_TOP = 226
LEFT = 40


def font(name: str, size: int) -> ImageFont.FreeTypeFont:
    return ImageFont.truetype(str(FONT / name), size)


def blend(base, overlay, alpha):
    return tuple(round(b * (1 - alpha) + o * alpha) for b, o in zip(base, overlay))


def dither(draw, scale: int):
    cell = 4 * scale
    height = 40 * scale
    for y in range(0, height, cell):
        coverage = 1 - (y / max(1, height - 1)) / 0.94
        for x in range(0, W * scale, cell):
            threshold = (BAYER[((y // cell) & 3) * 4 + ((x // cell) & 3)] + 0.5) / 16
            if coverage <= threshold:
                continue
            draw.rectangle([x, y, x + cell - 1, y + cell - 1],
                           fill=blend(DARK, SECONDARY, 0.14 * coverage))


def spaced(draw, xy, text, face, fill, tracking):
    x, y = xy
    for character in text:
        draw.text((x, y), character, font=face, fill=fill)
        x += draw.textlength(character, font=face) + tracking
    return x


def render(scale: int) -> Image.Image:
    S = scale
    image = Image.new("RGB", (W * S, H * S), DARK)
    draw = ImageDraw.Draw(image)
    dither(draw, S)

    # Light install shelf for Finder's black item labels.
    draw.rectangle([0, SHELF_TOP * S, W * S, H * S - 1], fill=SHELF)
    draw.rectangle([0, SHELF_TOP * S, W * S, SHELF_TOP * S + S - 1], fill=SHELF_STROKE)

    # Brand mark and wordmark share one optical centre.
    cell = 4 * S
    mark_y = 28 * S
    for row, line in enumerate(MARK):
        for column, ch in enumerate(line):
            if ch == "1":
                x = LEFT * S + column * cell
                y = mark_y + row * cell
                draw.rectangle([x, y, x + cell - 1, y + cell - 1], fill=GOLD)
    spaced(draw, ((LEFT + 56) * S, (mark_y + 16 * S)), "WAKELY",
           font("PixelOperator8-Bold.ttf", 10 * S), SECONDARY, 3 * S)

    label = "DRAG TO INSTALL"
    face = font("PixelOperator8-Bold.ttf", 9 * S)
    label_width = sum(draw.textlength(c, font=face) + 2 * S for c in label) - 2 * S
    spaced(draw, ((W - LEFT) * S - label_width, (mark_y + 17 * S)), label,
           face, TERTIARY, 2 * S)

    draw.text((LEFT * S, 94 * S), "Drag Wakely",
              font=font("PixelOperator-Bold.ttf", 30 * S), fill=CREAM)
    draw.text((LEFT * S, 129 * S), "into Applications",
              font=font("PixelOperator-Bold.ttf", 30 * S), fill=CREAM)
    draw.text((LEFT * S + 2 * S, 174 * S),
              "Menu-bar control for when your Mac stays awake.",
              font=font("PixelOperator.ttf", 11 * S), fill=SECONDARY)

    # Rule ends the dark header and starts the install shelf.
    draw.rectangle([LEFT * S, 204 * S, (W - LEFT) * S, 204 * S + S - 1],
                   fill=(39, 39, 42))
    draw.rectangle([LEFT * S, 204 * S, (LEFT + 64) * S, 204 * S + S - 1], fill=GOLD)

    # Icon centres are (180, 296) and (540, 296); the arrow joins them.
    y = 296 * S
    draw.rectangle([240 * S, y - S, 456 * S, y + S - 1], fill=GOLD_DARK)
    for index, half in enumerate((12, 9, 6, 3)):
        x = (454 + index * 4) * S
        draw.rectangle([x, y - half * S, x + 4 * S - 1, y + half * S], fill=GOLD_DARK)
    draw.rectangle([470 * S, y - 2 * S, 482 * S, y + 2 * S - 1], fill=GOLD_DARK)

    note = "Quit any running copy before replacing it."
    face = font("PixelOperator.ttf", 9 * S)
    note_width = draw.textlength(note, font=face)
    draw.text(((W * S - note_width) / 2, 390 * S), note, font=face, fill=TERTIARY)
    return image


def main():
    one = render(1)
    two = render(2)
    one_path = Path("/tmp/wakely-dmg-bg-1x.png")
    two_path = Path("/tmp/wakely-dmg-bg-2x.png")
    one.save(one_path)
    two.save(two_path)
    import subprocess
    one_tiff = Path("/tmp/wakely-dmg-bg-1x.tiff")
    two_tiff = Path("/tmp/wakely-dmg-bg-2x.tiff")
    subprocess.run(["sips", "-s", "format", "tiff", str(one_path), "--out", str(one_tiff)],
                   check=True, capture_output=True)
    subprocess.run(["sips", "-s", "format", "tiff", str(two_path), "--out", str(two_tiff)],
                   check=True, capture_output=True)
    subprocess.run(["tiffutil", "-cat", str(one_tiff), str(two_tiff), "-out", str(OUT)],
                   check=True, capture_output=True)
    print(f"Wrote {OUT} (720x420 @1x + 1440x840 @2x)")


if __name__ == "__main__":
    main()
