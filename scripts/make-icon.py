#!/usr/bin/env python3
"""Turn a flat-background icon rendering into a macOS .icns.

The source art is a rounded square sitting on a solid off-white page. Two
things have to happen before macOS can use it:

  1. The page has to become transparent — including the anti-aliased ring
     around the shape, or the icon gets a pale halo on dark backgrounds.
  2. The shape has to be inset into Apple's icon grid: on a 1024pt canvas a
     square app icon is 824pt wide, centred. Skipping this makes the icon
     look oversized next to every other icon in the Dock.

Usage: make-icon.py <source.png> [output-dir]
"""

import subprocess
import sys
from pathlib import Path

from PIL import Image

# Apple's macOS icon grid (Big Sur onwards).
CANVAS = 1024
SHAPE = 824

ICONSET = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
]


def channel_distance(pixel, background):
    return max(abs(pixel[i] - background[i]) for i in range(3))


def find_bounds(pixels, width, height, background, threshold=120):
    """Bounding box of the solid artwork, ignoring the anti-aliased fringe."""
    xs = [x for x in range(width)
          if any(channel_distance(pixels[x, y], background) > threshold
                 for y in range(0, height, 2))]
    ys = [y for y in range(height)
          if any(channel_distance(pixels[x, y], background) > threshold
                 for x in range(0, width, 2))]
    if not xs or not ys:
        sys.exit("Found no artwork — is the background really a flat colour?")
    return xs[0], ys[0], xs[-1], ys[-1]


def cut_background(image, background, solid=150):
    """Replace the page with transparency, matting the edge properly.

    The shape is convex, so scanning each row inwards from both sides finds
    exactly the outside pixels — no flood fill, and interior light colours
    (the pale purple suckers) can never be mistaken for background.

    Edge pixels are a blend of the background and whatever colour the shape
    has at that point: px = a*F + (1-a)*bg. Solving for `a` gives real
    coverage instead of a hard cut, and un-premultiplying removes the
    background tint that would otherwise show as a halo.
    """
    width, height = image.size
    pixels = image.load()
    out = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    target = out.load()

    for y in range(height):
        row = [x for x in range(width)
               if channel_distance(pixels[x, y], background) > solid]
        if not row:
            continue  # entirely outside the shape
        left, right = row[0], row[-1]
        for x in range(left, right + 1):
            target[x, y] = pixels[x, y] + (255,)

        # Per-row edge colour: exact matting even where the green tentacle,
        # not the purple border, is what meets the page.
        for edge_x, colour in ((left, pixels[left, y]), (right, pixels[right, y])):
            span = channel_distance(colour, background)
            if span == 0:
                continue
            step = -1 if edge_x == left else 1
            x = edge_x + step
            while 0 <= x < width:
                distance = channel_distance(pixels[x, y], background)
                if distance == 0:
                    break
                alpha = min(1.0, distance / span)
                if alpha <= 0.004:
                    break
                # Un-premultiply: recover the shape's own colour.
                rgb = tuple(
                    max(0, min(255, round((pixels[x, y][i] - (1 - alpha) * background[i]) / alpha)))
                    for i in range(3)
                )
                target[x, y] = rgb + (round(alpha * 255),)
                x += step
    return out


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    source = Path(sys.argv[1])
    out_dir = Path(sys.argv[2]) if len(sys.argv) > 2 else source.parent

    image = Image.open(source).convert("RGB")
    width, height = image.size
    pixels = image.load()
    corners = [pixels[0, 0], pixels[width - 1, 0], pixels[0, height - 1], pixels[width - 1, height - 1]]
    background = tuple(sum(c[i] for c in corners) // 4 for i in range(3))

    x0, y0, x1, y1 = find_bounds(pixels, width, height, background)
    art_w, art_h = x1 - x0 + 1, y1 - y0 + 1
    print(f"background #{background[0]:02X}{background[1]:02X}{background[2]:02X}, "
          f"artwork {art_w}x{art_h} at ({x0},{y0})")

    # Square the crop around the artwork's centre rather than stretching it:
    # the render is a pixel or two off square and non-uniform scaling shows.
    side = max(art_w, art_h)
    cx, cy = (x0 + x1) // 2, (y0 + y1) // 2
    box = (cx - side // 2, cy - side // 2, cx - side // 2 + side, cy - side // 2 + side)
    cropped = image.crop(box)

    shape = cut_background(cropped, background).resize((SHAPE, SHAPE), Image.LANCZOS)
    master = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    offset = (CANVAS - SHAPE) // 2
    master.paste(shape, (offset, offset), shape)

    out_dir.mkdir(parents=True, exist_ok=True)
    master_path = out_dir / "AppIcon.png"
    master.save(master_path)
    print(f"wrote {master_path} ({CANVAS}x{CANVAS}, shape {SHAPE}px inset {offset}px)")

    iconset = out_dir / "AppIcon.iconset"
    iconset.mkdir(exist_ok=True)
    for size, name in ICONSET:
        master.resize((size, size), Image.LANCZOS).save(iconset / name)
    subprocess.run(["iconutil", "-c", "icns", str(iconset),
                    "-o", str(out_dir / "AppIcon.icns")], check=True)
    print(f"wrote {out_dir / 'AppIcon.icns'}")


if __name__ == "__main__":
    main()
