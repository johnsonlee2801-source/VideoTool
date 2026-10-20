#!/usr/bin/env python3
"""README feature art: each card says what the feature does, then shows it.

Input:  <out>/<lang>/f-speed.png, f-subtitles.png, f-clip.png (+ .json: where the
        parts to point at are, in pixels), written by DocsScreenshotTests D2.
Output: <images>/<lang>/hero.jpg, speed.jpg, subtitles.jpg, clip.jpg

The film frames are from Tears of Steel (CC BY 3.0, Blender Foundation,
mango.blender.org). Usage: tools/compose_readme_art.py <out dir> <docs/images>
"""
import json
import os
import sys

import numpy as np

from PIL import Image, ImageDraw, ImageFilter, ImageFont

OUT, IMAGES = sys.argv[1], sys.argv[2]
ICON = os.path.join(os.path.dirname(__file__), "..", "design", "icon", "AppIcon-1024.png")

PINK, CYAN, VIOLET, STAR = (255, 46, 99), (8, 217, 214), (123, 97, 255), (255, 214, 10)
BG_TOP, BG_BOTTOM = (11, 11, 18), (22, 18, 34)
WHITE, GREY = (245, 245, 247), (169, 169, 188)


def find_pingfang():
    root = "/System/Library/AssetsV2"
    for dirpath, _, files in os.walk(root):
        if "PingFang.ttc" in files:
            return os.path.join(dirpath, "PingFang.ttc")
    return "/System/Library/Fonts/Hiragino Sans GB.ttc"


PINGFANG = find_pingfang()
SF = "/System/Library/Fonts/SFNS.ttf"


def font(size, weight="Semibold", cjk=True):
    if cjk and PINGFANG.endswith("PingFang.ttc"):
        index = {"Regular": 3, "Medium": 7, "Semibold": 11}[weight]
        return ImageFont.truetype(PINGFANG, size, index=index)
    if cjk:
        return ImageFont.truetype(PINGFANG, size)
    f = ImageFont.truetype(SF, size)
    f.set_variation_by_name({"Regular": "Regular", "Medium": "Medium", "Semibold": "Bold"}[weight])
    return f


# Words per language. "big" is the reader's language, "small" the other one.
TEXT = {
    "zh": dict(
        tagline=("看得快，看得懂，留得住。", "Watch faster. Understand any language. Keep the best parts."),
        pills=["按住加速 2–6×", "AI 双语字幕", "C … C 截片段"],
        speed=("按住加速", "Hold to speed up", "按住画面 2× 加速，按住往右拖最快 6×，松手恢复原速。", "按住 + 拖动  →  2.6×"),
        subtitles=("AI 双语字幕", "AI subtitles, made on your Mac",
                   "本机识别 + 翻译，免费、不上传。画面里是 VideoTool 为这部电影实际生成的字幕。", "边看边生成"),
        clip=("C … C 截片段", "Press C, then C, to cut a clip", "开头按 C，结尾按 C，一键导出 GIF、视频，或直接拷贝去粘贴。",
              "GIF · 视频 · 拷贝", "C 开头 · C 结尾"),
        credit="画面：Tears of Steel (CC BY 3.0) © Blender Foundation",
    ),
    "en": dict(
        tagline=("Watch faster. Understand any language. Keep the best parts.", "看得快，看得懂，留得住。"),
        pills=["Hold to speed up · 2–6×", "AI bilingual subtitles", "C … C to cut a clip"],
        speed=("Hold to speed up", "按住加速", "Hold the picture for 2×, drag right for up to 6×, let go to return.",
               "hold + drag  →  2.6×"),
        subtitles=("AI subtitles, made on your Mac", "AI 双语字幕",
                   "Recognised and translated on your Mac: free, nothing uploaded. These are the subtitles VideoTool made for this film.",
                   "made while you watch"),
        clip=("Press C, then C, to cut a clip", "C … C 截片段", "C at the start, C at the end: one click to a GIF, a video, or the clipboard.",
              "GIF · Video · Copy", "C start · C end"),
        credit="Film: Tears of Steel (CC BY 3.0) © Blender Foundation",
    ),
    "ja": dict(
        tagline=("速く見て、どの言語もわかって、いい場面を残す。", "Watch faster. Understand any language. Keep the best parts."),
        pills=["長押しで 2〜6 倍速", "AI 2 か国語字幕", "C … C でクリップ"],
        speed=("長押しで速く", "Hold to speed up", "長押しで 2 倍速、右へドラッグで最大 6 倍、離せば元の速度へ。", "長押し + ドラッグ  →  2.6×"),
        subtitles=("AI字幕を Mac の中で", "AI subtitles, made on your Mac",
                   "Mac の中で認識・翻訳。無料で、アップロードなし。画面は VideoTool がこの映画に実際に付けた字幕です。", "見ながら作成"),
        clip=("C … C でクリップ", "Press C, then C, to cut a clip", "始まりで C、終わりで C。ワンクリックで GIF、ビデオ、またはコピー。",
              "GIF · ビデオ · コピー", "C 始点 · C 終点"),
        credit="映像：Tears of Steel (CC BY 3.0) © Blender Foundation",
    ),
}


def background(w, h, glow, glow_xy):
    """Dark vertical gradient, brightened by a soft glow of the card's colour."""
    t = np.linspace(0, 1, h)[:, None, None]
    base = np.asarray(BG_TOP, "float32") + (np.asarray(BG_BOTTOM, "float32") - np.asarray(BG_TOP, "float32")) * t
    base = np.repeat(base, w, axis=1)
    layer = Image.new("RGB", (w, h), (0, 0, 0))
    gx, gy = glow_xy
    r = w * 0.45
    ImageDraw.Draw(layer).ellipse((gx - r, gy - r * 0.6, gx + r, gy + r * 0.6), fill=tuple(int(v * 0.55) for v in glow))
    glow_px = np.asarray(layer.filter(ImageFilter.GaussianBlur(220)), "float32")
    screen = 255 - (255 - base) * (255 - glow_px) / 255           # screen blend: only brightens
    return Image.fromarray(np.clip(screen, 0, 255).astype("uint8"))


def rounded(img, radius):
    mask = Image.new("L", img.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, img.size[0] - 1, img.size[1] - 1), radius, fill=255)
    out = img.convert("RGBA")
    out.putalpha(mask)
    return out


def paste_shot(canvas, shot, box_w, xy, radius=22):
    s = box_w / shot.size[0]
    shot = shot.resize((box_w, int(shot.size[1] * s)), Image.LANCZOS)
    shadow = Image.new("RGBA", (shot.size[0] + 160, shot.size[1] + 160), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle((80, 100, 80 + shot.size[0], 100 + shot.size[1]), radius, fill=(0, 0, 0, 190))
    shadow = shadow.filter(ImageFilter.GaussianBlur(36))
    canvas.paste(shadow, (xy[0] - 80, xy[1] - 80), shadow)
    shot = rounded(shot, radius)
    canvas.paste(shot, xy, shot)
    ImageDraw.Draw(canvas).rounded_rectangle((xy[0], xy[1], xy[0] + shot.size[0] - 1, xy[1] + shot.size[1] - 1), radius,
                                            outline=(255, 255, 255, 40), width=2)
    return s


def callout(canvas, rect, color, label, cjk, above=True, pad=10):
    """A glowing frame around rect (canvas pixels) and a label pill next to it."""
    x, y, w, h = rect
    x0, y0, x1, y1 = x - pad, y - pad, x + w + pad, y + h + pad
    glow = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    ImageDraw.Draw(glow).rounded_rectangle((x0, y0, x1, y1), 16, outline=color + (255,), width=10)
    canvas.alpha_composite(glow.filter(ImageFilter.GaussianBlur(10)))
    d = ImageDraw.Draw(canvas)
    d.rounded_rectangle((x0, y0, x1, y1), 16, outline=color + (255,), width=4)
    f = font(30, "Semibold", cjk)
    tw = d.textlength(label, font=f)
    lw, lh = int(tw + 44), 56
    lx = int(min(max(x0, 40), canvas.size[0] - lw - 40))
    ly = int(y0 - lh - 18) if above else int(y1 + 18)
    d.rounded_rectangle((lx, ly, lx + lw, ly + lh), 28, fill=color + (255,))
    d.text((lx + 22, ly + lh / 2), label, font=f, fill=(255, 255, 255), anchor="lm")


def heading(d, x, y, big, small, desc, cjk_big, cjk_small, cjk_desc, accent, number=None, width=1440):
    if number:
        d.text((x, y), number, font=font(30, "Semibold", False), fill=accent)
        y += 50
    d.text((x, y), big, font=font(68, "Semibold", cjk_big), fill=WHITE)
    y += 92
    d.text((x, y), small, font=font(32, "Medium", cjk_small), fill=accent)
    y += 56
    # Wrap the description to the width.
    f = font(30, "Regular", cjk_desc)
    line, lines = "", []
    for ch in (desc.split(" ") if not cjk_desc else list(desc)):
        test = (line + (" " if line and not cjk_desc else "") + ch) if not cjk_desc else line + ch
        if d.textlength(test, font=f) > width and line:
            lines.append(line)
            line = ch
        else:
            line = test
    lines.append(line)
    for l in lines:
        d.text((x, y), l, font=f, fill=GREY)
        y += 46
    return y


def load(lang, name):
    shot = Image.open(os.path.join(OUT, lang, name + ".png")).convert("RGB")
    with open(os.path.join(OUT, lang, name + ".json")) as fh:
        marks = json.load(fh)
    return shot, marks


def place(rect, s, origin):
    return (origin[0] + rect["x"] * s, origin[1] + rect["y"] * s, rect["w"] * s, rect["h"] * s)


def card(lang, kind):
    t = TEXT[lang]
    cjk_big = lang != "en"
    cjk_small = lang == "en"
    W, H = 1600, 1180
    accent = {"speed": PINK, "subtitles": CYAN, "clip": VIOLET}[kind]
    canvas = background(W, H, accent, (W * 0.78, H * 0.18)).convert("RGBA")
    d = ImageDraw.Draw(canvas)
    number = {"speed": "01", "subtitles": "02", "clip": "03"}[kind]
    words = t[kind]
    y = heading(d, 80, 64, words[0], words[1], words[2], cjk_big, cjk_small, cjk_big, accent, number)
    shot, marks = load(lang, "f-" + kind)
    origin = (80, max(int(y) + 60, 420))
    s = paste_shot(canvas, shot, W - 160, origin)
    if kind == "speed":
        callout(canvas, place(marks["hud"], s, origin), PINK, words[3], cjk_big)
    elif kind == "subtitles":
        pic = marks["picture"]
        band = {"x": pic["x"] + pic["w"] * 0.12, "y": pic["y"] + pic["h"] * 0.70, "w": pic["w"] * 0.76, "h": pic["h"] * 0.25}
        callout(canvas, place(band, s, origin), CYAN, words[3], cjk_big, above=True)
    else:
        callout(canvas, place(marks["bar"], s, origin), VIOLET, words[3], cjk_big, above=True)
        # The two C marks on the timeline (398–405 s of 734, as staged by DocsScreenshotTests D2).
        m = marks["markers"]
        x0 = m["x"] + m["w"] * 398 / 734
        x1 = m["x"] + m["w"] * 405 / 734
        mid = m["y"] + m["h"] / 2
        ticks = {"x": x0 - 14, "y": mid - 22, "w": max(x1 - x0, 1) + 28, "h": 44}
        callout(canvas, place(ticks, s, origin), CYAN, words[4], cjk_big, above=False, pad=6)
    d = ImageDraw.Draw(canvas)
    d.text((80, H - 40), t["credit"], font=font(20, "Regular", lang != "en"), fill=(120, 120, 140), anchor="ls")
    return canvas.convert("RGB")


def hero(lang):
    t = TEXT[lang]
    W, H = 1600, 1120
    canvas = background(W, H, PINK, (W * 0.15, H * 0.05)).convert("RGBA")
    glow2 = background(W, H, CYAN, (W * 0.95, H * 0.95))
    canvas = Image.fromarray(np.maximum(np.asarray(canvas.convert("RGB")), np.asarray(glow2))).convert("RGBA")
    icon = Image.open(ICON).convert("RGBA").resize((120, 120), Image.LANCZOS)
    canvas.paste(icon, (80, 64), icon)
    d = ImageDraw.Draw(canvas)
    d.text((222, 72), "VideoTool", font=font(76, "Semibold", False), fill=WHITE)
    name_w = d.textlength("VideoTool", font=font(76, "Semibold", False))
    d.text((222 + name_w + 22, 140), "by ChengNuo", font=font(30, "Medium", False), fill=GREY, anchor="ls")
    big, small = t["tagline"]
    d.text((222, 166), big, font=font(34, "Medium", lang != "en"), fill=WHITE)
    d.text((80, 224), small, font=font(26, "Regular", lang == "en"), fill=GREY)
    x = 80
    for label, color in zip(t["pills"], [PINK, CYAN, VIOLET]):
        f = font(28, "Semibold", lang != "en")
        w = d.textlength(label, font=f) + 48
        d.rounded_rectangle((x, 282, x + w, 336), 27, fill=color + (230,))
        d.text((x + 24, 309), label, font=f, fill=(255, 255, 255), anchor="lm")
        x += w + 16
    shot, marks = load(lang, "f-speed")
    origin = (80, 390)
    s = paste_shot(canvas, shot, W - 160, origin)
    callout(canvas, place(marks["hud"], s, origin), PINK, t["speed"][3], lang != "en")
    d = ImageDraw.Draw(canvas)
    d.text((W - 80, H - 22), t["credit"], font=font(20, "Regular", lang != "en"), fill=(120, 120, 140), anchor="rs")
    return canvas.convert("RGB")


for lang in TEXT:
    if not os.path.isdir(os.path.join(OUT, lang)):
        continue
    dest = os.path.join(IMAGES, lang)
    os.makedirs(dest, exist_ok=True)
    hero(lang).save(os.path.join(dest, "hero.jpg"), quality=86, optimize=True, progressive=True)
    for kind in ("speed", "subtitles", "clip"):
        card(lang, kind).save(os.path.join(dest, kind + ".jpg"), quality=86, optimize=True, progressive=True)
    print(lang, "ok")
