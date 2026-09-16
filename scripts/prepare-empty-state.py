#!/usr/bin/env python3
"""Usage: python3 scripts/prepare-empty-state.py SOURCE.png [OUTPUT.png]

Requires Pillow (image preparation only, not an application dependency).
"""
import sys
from pathlib import Path
from PIL import Image, ImageChops, ImageDraw, ImageFilter

source = Path(sys.argv[1])
target = Path(sys.argv[2]) if len(sys.argv) > 2 else Path(__file__).resolve().parents[1] / "Resources/EmptyState.png"
assert source.resolve() != target.resolve(), "Do not overwrite the original"
image = Image.open(source).convert("RGB")
assert image.size == (1254, 1254), "This mask is calibrated for the supplied illustration"

# ponytail: calibrated to this artwork; inspect the outline again for a replacement.
# Flood only the near-white background connected to the canvas, not interior whites.
r, g, b = image.split()
background = ImageChops.darker(ImageChops.darker(r, g), b).point(lambda v: 255 if v >= 250 else 0)
ImageDraw.floodfill(background, (0, 0), 128)
outline = background.point(lambda v: 0 if v == 128 else 255)
assert outline.getbbox() == (100, 118, 1148, 1131)
# Remove the one-pixel white matte at the perimeter, then antialias inward only.
alpha = ImageChops.darker(outline, outline.filter(ImageFilter.MinFilter(3)).filter(ImageFilter.GaussianBlur(0.5)))
result = image.convert("RGBA")
result.putalpha(alpha)
bounds = alpha.getbbox()
result = result.crop(bounds)
target.parent.mkdir(parents=True, exist_ok=True)
result.save(target)

# Round-trip check: every pixel safely inside the outline is unchanged and opaque.
saved = Image.open(target).convert("RGBA")
restored = Image.new("RGBA", image.size)
restored.paste(saved, bounds[:2])
interior = outline.filter(ImageFilter.MinFilter(9))
assert ImageChops.multiply(ImageChops.difference(restored.convert("RGB"), image), interior.convert("RGB")).getbbox() is None
assert ImageChops.multiply(ImageChops.invert(restored.getchannel("A")), interior).getbbox() is None
assert ImageChops.multiply(restored.getchannel("A"), ImageChops.invert(outline)).getbbox() is None
for point in [(380, 550), (850, 330), (440, 760), (880, 900)]:
    assert restored.getpixel(point) == (*image.getpixel(point), 255), point
assert saved.getchannel("A").getextrema() == (0, 255)
print(f"PASS: {target}, {saved.size}, crop={bounds}; interior RGB/white/alpha preserved, exterior transparent")
