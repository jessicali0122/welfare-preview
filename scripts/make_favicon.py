#!/usr/bin/env python3
"""Generate cream-filled, full-bleed favicon + OG share images from the TSA logo JPG."""
from PIL import Image, ImageDraw
import os

SRC = os.path.expanduser("~/welfare-preview/scripts/tsa-logo-src.jpg")
OUT = os.path.expanduser("~/welfare-preview/assets/icons")
CREAM = (254, 247, 237)

img = Image.open(SRC).convert("RGB")
w, h = img.size
px = img.load()

def is_dark(p):
    return p[0] + p[1] + p[2] < 60

cy = h // 2
xs = [x for x in range(w) if not is_dark(px[x, cy])]
cx = w // 2
ys = [y for y in range(h) if not is_dark(px[cx, y])]
ccx = (xs[0] + xs[-1]) / 2
ccy = (ys[0] + ys[-1]) / 2
radius = max(xs[-1] - xs[0], ys[-1] - ys[0]) / 2 + 2

# Crop tight to the logo circle
box = (int(ccx - radius), int(ccy - radius), int(ccx + radius), int(ccy + radius))
logo = img.crop(box)  # RGB, cream interior, thin dark outer ring

def render(size, scale=1.24, rounded=False, transparent_corners=False):
    """Cream square with the logo enlarged (scale>1 = bleed past edges a touch)."""
    canvas = Image.new("RGBA", (size, size), CREAM + (255,))
    d = int(size * scale)
    lg = logo.resize((d, d), Image.LANCZOS).convert("RGBA")
    off = (size - d) // 2
    # circular mask so the crop's black square corners are never pasted
    SS = 4
    dm = Image.new("L", (d * SS, d * SS), 0)
    ImageDraw.Draw(dm).ellipse([0, 0, d * SS - 1, d * SS - 1], fill=255)
    dm = dm.resize((d, d), Image.LANCZOS)
    canvas.paste(lg, (off, off), dm)
    if transparent_corners:
        # circular alpha so tab/home-screen shows a clean disc, corners clear
        SS = 4
        m = Image.new("L", (size * SS, size * SS), 0)
        ImageDraw.Draw(m).ellipse([0, 0, size * SS - 1, size * SS - 1], fill=255)
        canvas.putalpha(m.resize((size, size), Image.LANCZOS))
    return canvas

# 瀏覽器分頁 favicon（32）：透明圓角，深/淺色分頁列都好看
render(32, scale=1.24, transparent_corners=True).save(os.path.join(OUT, "app-icon-32.png"))
print("wrote app-icon-32.png")

# apple-touch-icon（180/512）：奶油底填滿（避免 iOS 主畫面黑角），logo 縮到 ~86% 留出奶油色邊框
for size, name in [(180, "app-icon-180.png"), (512, "app-icon-512.png")]:
    render(size, scale=0.86, transparent_corners=False).convert("RGB").save(os.path.join(OUT, name))
    print("wrote", name)

# OG share image: full-bleed cream square, no transparency (LINE/FB show a solid tile)
render(1200, scale=0.92, transparent_corners=False).convert("RGB").save(
    os.path.join(OUT, "app-og.png"), quality=92)
print("wrote app-og.png")

# SVG wrapper embeds the 512 disc
import base64
b64 = base64.b64encode(open(os.path.join(OUT, "app-icon-512.png"), "rb").read()).decode()
open(os.path.join(OUT, "app-icon.svg"), "w").write(
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512" '
    'role="img" aria-label="騰勢福委會">'
    f'<image href="data:image/png;base64,{b64}" width="512" height="512"/></svg>\n')
print("wrote app-icon.svg")
