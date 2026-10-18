"""Draws the VideoTool app icon (1024 px master) in the Theme colours.
Pink→violet squircle, white play glyph with speed ticks, yellow star. Run: python3 make_icon.py"""
from PIL import Image, ImageDraw, ImageFilter
import math

S = 1024
PINK, VIOLET, STAR = (0xFF, 0x2E, 0x63), (0x7B, 0x61, 0xFF), (0xFF, 0xD6, 0x0A)

def lerp(a, b, t): return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))

grad = Image.new("RGB", (S, S))
px = grad.load()
for y in range(S):
    for x in range(S):
        px[x, y] = lerp(PINK, VIOLET, min(1, max(0, (x + y) / (2 * S) * 1.15)))

mask = Image.new("L", (S, S), 0)
inset = (S - 824) // 2
ImageDraw.Draw(mask).rounded_rectangle([inset, inset, S - inset, S - inset], radius=185, fill=255)

icon = Image.new("RGBA", (S, S), (0, 0, 0, 0))
shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(shadow).rounded_rectangle([inset, inset + 14, S - inset, S - inset + 14], radius=185, fill=(0, 0, 0, 110))
icon.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(18)))
body = grad.convert("RGBA"); body.putalpha(mask)
icon.alpha_composite(body)


sheen = Image.new("L", (S, S), 0)
sp = sheen.load()
for y in range(inset, S // 2):
    a = int(34 * (1 - (y - inset) / (S // 2 - inset)) ** 2)
    for x in range(S): sp[x, y] = a
sheen = Image.composite(sheen, Image.new("L", (S, S), 0), mask)
wl = Image.new("RGBA", (S, S), (255, 255, 255, 255)); wl.putalpha(sheen)
icon.alpha_composite(wl)
d = ImageDraw.Draw(icon)
cx, cy, r = S * 0.50, S * 0.52, 200
tri = [(cx - r * 0.55, cy - r), (cx - r * 0.55, cy + r), (cx + r * 1.0, cy)]
tm = Image.new("L", (S, S), 0)
ImageDraw.Draw(tm).polygon(tri, fill=255)
tm = tm.filter(ImageFilter.GaussianBlur(26)).point(lambda v: 255 if v > 110 else 0).filter(ImageFilter.GaussianBlur(1.2))
white = Image.new("RGBA", (S, S), (255, 255, 255, 255)); white.putalpha(tm)
icon.alpha_composite(white)
for i, w in enumerate([110, 76]):
    y = cy - 70 + i * 140
    d.rounded_rectangle([cx - r * 0.55 - 64 - w, y - 16, cx - r * 0.55 - 64, y + 16], radius=16, fill=(255, 255, 255, 170))

def star(cx, cy, R, r):
    return [(cx + (R if k % 2 == 0 else r) * math.cos(-math.pi / 2 + k * math.pi / 5),
             cy + (R if k % 2 == 0 else r) * math.sin(-math.pi / 2 + k * math.pi / 5)) for k in range(10)]
sx, sy = S - inset - 190, inset + 185
glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(glow).polygon(star(sx, sy, 104, 46), fill=(0, 0, 0, 120))
icon.alpha_composite(glow.filter(ImageFilter.GaussianBlur(10)))
d.polygon(star(sx, sy, 96, 42), fill=STAR + (255,))
icon.save("AppIcon-1024.png")
print("saved AppIcon-1024.png")
