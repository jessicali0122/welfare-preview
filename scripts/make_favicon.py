#!/usr/bin/env python3
"""Generate transparent-corner favicon PNGs + SVG wrapper from the TSA logo JPG."""
from PIL import Image, ImageDraw
import os, base64

SRC = os.path.expanduser("~/welfare-preview/S__129761284.jpg")
OUT = os.path.expanduser("~/welfare-preview/assets/icons")

img = Image.open(SRC).convert("RGBA")
w, h = img.size
px = img.load()

# Detect logo circle bounds on the center row/col (background is near-black)
def is_dark(p):
    return p[0] + p[1] + p[2] < 60

cy = h // 2
xs = [x for x in range(w) if not is_dark(px[x, cy])]
cx = w // 2
ys = [y for y in range(h) if not is_dark(px[cx, y])]
left, right = xs[0], xs[-1]
top, bottom = ys[0], ys[-1]
ccx = (left + right) / 2
ccy = (top + bottom) / 2
radius = (max(right - left, bottom - top) / 2) + 2  # tiny pad to keep edge
print(f"circle center=({ccx:.0f},{ccy:.0f}) radius={radius:.0f}")

# High-res circular alpha mask (supersampled for smooth edge)
SS = 4
mask = Image.new("L", (w * SS, h * SS), 0)
d = ImageDraw.Draw(mask)
d.ellipse(
    [(ccx - radius) * SS, (ccy - radius) * SS,
     (ccx + radius) * SS, (ccy + radius) * SS],
    fill=255,
)
mask = mask.resize((w, h), Image.LANCZOS)

logo = img.copy()
logo.putalpha(mask)

# Crop tight to the circle so the icon fills the frame
box = (int(ccx - radius), int(ccy - radius), int(ccx + radius), int(ccy + radius))
logo = logo.crop(box)

for size, name in [(32, "app-icon-32.png"), (180, "app-icon-180.png"), (512, "app-icon-512.png")]:
    logo.resize((size, size), Image.LANCZOS).save(os.path.join(OUT, name))
    print("wrote", name)

# SVG wrapper embedding the 512 PNG so the vector <link> shows the new logo too
png512 = os.path.join(OUT, "app-icon-512.png")
b64 = base64.b64encode(open(png512, "rb").read()).decode()
svg = (
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512" '
    'role="img" aria-label="騰勢福委會">'
    f'<image href="data:image/png;base64,{b64}" width="512" height="512"/>'
    '</svg>\n'
)
open(os.path.join(OUT, "app-icon.svg"), "w").write(svg)
print("wrote app-icon.svg")
