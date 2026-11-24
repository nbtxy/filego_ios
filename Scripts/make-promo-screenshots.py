#!/usr/bin/env python3
"""
Compose App Store promotional screenshots from raw simulator captures.

Each output is 1320 × 2868 (the 6.9-inch slot) or 2853 × 2007 (iPhone Duo
inner display in the landscape book pose): a warm paper background, a short
marketing headline, and the app screen in a rounded card below. The copy is deliberately kept in this file
so the screenshots and the store text cannot drift apart unnoticed.

Usage (Pillow lives in the harness runtime, not system Python):

  /Users/laienguang/.dsh/dsh-runtimes/dsh-primary-runtime/dependencies/python/bin/python3 \
    Scripts/make-promo-screenshots.py \
    --raw build/shots --out build/promo
    --raw build/shots --out build/promo-duo --device duo

The raw captures are named 01-drive.png … 06-plan.png for Chinese and
en-01-drive.png … for English. Duo landscape captures use
duo-land-zh-drive.png … and duo-land-en-drive.png …. Missing captures are
skipped, so a partial run still produces the slides that exist.
"""

from __future__ import annotations

import argparse
import math
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

W, H = 1320, 2868
MARGIN = 96
PHONE_W = 944
PHONE_TOP = 790
BRAND_SIZE = 44
BRAND_Y = 96
ACCENT_Y = 196
ACCENT_W = 72
HEADLINE_Y = 246
HEADLINE_ZH = 100
HEADLINE_EN = 94
SUB_ZH = 42
SUB_EN = 42
SUB_GAP = 18
RADIUS = 46
GLOW_W = 560

LAYOUTS = {
    "iphone": dict(
        W=1320, H=2868, MARGIN=96, PHONE_W=944, PHONE_TOP=790,
        BRAND_SIZE=44, BRAND_Y=96, ACCENT_Y=196, ACCENT_W=72,
        HEADLINE_Y=246, HEADLINE_ZH=100, HEADLINE_EN=94,
        SUB_ZH=42, SUB_EN=42, SUB_GAP=18, RADIUS=46, GLOW_W=560,
    ),
    "duo": dict(
        W=2007, H=2853, MARGIN=140, PHONE_W=1388, PHONE_TOP=820,
        BRAND_SIZE=60, BRAND_Y=110, ACCENT_Y=225, ACCENT_W=100,
        HEADLINE_Y=270, HEADLINE_ZH=130, HEADLINE_EN=122,
        SUB_ZH=56, SUB_EN=54, SUB_GAP=24, RADIUS=52, GLOW_W=760,
    ),
    # Duo unfolded and rotated to the landscape book pose. The inner display is
    # 2853 × 2007 and the app lays out wide, with the rail on the right.
    "duo-landscape": dict(
        W=2853, H=2007, MARGIN=150, PHONE_W=1700, PHONE_TOP=760,
        BRAND_SIZE=56, BRAND_Y=100, ACCENT_Y=205, ACCENT_W=100,
        HEADLINE_Y=250, HEADLINE_ZH=125, HEADLINE_EN=118,
        SUB_ZH=50, SUB_EN=48, SUB_GAP=22, RADIUS=50, GLOW_W=900,
    ),
}

PAPER_TOP = (248, 245, 237)
PAPER_BOTTOM = (239, 234, 221)
INK = (16, 32, 27)
SECONDARY = (88, 97, 91)
LIME = (199, 227, 107)
HAIRLINE = (222, 214, 195)

PINGFANG = (
    "/System/Library/AssetsV2/com_apple_MobileAsset_Font8/"
    "86ba2c91f017a3749571a82f2c6d890ac7ffb2fb.asset/AssetData/PingFang.ttc"
)
SF = "/System/Library/Fonts/SFNS.ttf"

SLIDES = [
    {
        "screen": "drive",
        "zh_file": "01-drive.png",
        "en_file": "en-drive.png",
        "zh_headline": "把 AI 的成果\n装进口袋",
        "en_headline": "Put AI output\nin your pocket",
        "zh_sub": "HTML、Markdown、图片和 PDF，\n都在手机里收好。",
        "en_sub": "HTML, Markdown, images and PDFs —\nall saved on your phone.",
    },
    {
        "screen": "html",
        "zh_file": "02-html.png",
        "en_file": "en-html.png",
        "zh_headline": "HTML 打开就能看",
        "en_headline": "HTML, rendered\nnot downloaded",
        "zh_sub": "AI 生成的报告和页面，\n不用下载，直接在手机上渲染。",
        "en_sub": "AI-generated reports and pages\nopen straight on your phone.",
    },
    {
        "screen": "markdown",
        "zh_file": "03-markdown.png",
        "en_file": "en-markdown.png",
        "zh_headline": "Markdown 也排版好",
        "en_headline": "Markdown that\nlooks finished",
        "zh_sub": "标题、表格、任务列表和代码块，\n读起来像一篇成品。",
        "en_sub": "Headings, tables, task lists and code,\ntypeset like a finished document.",
    },
    {
        "screen": "inbox",
        "zh_file": "04-inbox.png",
        "en_file": "en-inbox.png",
        "zh_headline": "电脑发，手机收",
        "en_headline": "Send from a browser.\nRead on your phone.",
        "zh_sub": "浏览器打开你的专属地址，\n文件几秒就到手机上。",
        "en_sub": "Open your own address, drop a file,\nand it lands in the app.",
    },
    {
        "screen": "qr",
        "zh_file": "05-qr.png",
        "en_file": "en-qr.png",
        "zh_headline": "扫个码\n文件就过来",
        "en_headline": "One scan,\nfile delivered",
        "zh_sub": "当面传文件，不用加好友，\n也不用对方装 App。",
        "en_sub": "Send in person. No friend request,\nand no app for the sender.",
    },
    {
        "screen": "plan",
        "zh_file": "06-plan.png",
        "en_file": "en-plan.png",
        "zh_headline": "US$9.99\n终身买断",
        "en_headline": "US$9.99.\nYours forever.",
        "zh_sub": "一次买断，永久使用。\n不是订阅，不会续费。",
        "en_sub": "One-time purchase.\nNo subscription, no renewal.",
    },
]


def font_chinese(size: int, weight: str = "semibold") -> ImageFont.FreeTypeFont:
    index = {"regular": 3, "medium": 7, "semibold": 11}[weight]
    return ImageFont.truetype(PINGFANG, size, index=index)


def font_latin(size: int, weight: str = "bold") -> ImageFont.FreeTypeFont:
    font = ImageFont.truetype(SF, size)
    try:
        font.set_variation_by_name(weight.capitalize())
    except Exception:
        pass
    return font


def background() -> Image.Image:
    image = Image.new("RGB", (W, H), PAPER_TOP)
    draw = ImageDraw.Draw(image)
    for y in range(H):
        t = y / H
        rgb = tuple(
            round(PAPER_TOP[i] * (1 - t) + PAPER_BOTTOM[i] * t) for i in range(3)
        )
        draw.line([(0, y), (W, y)], fill=rgb)
    # A very soft lime wash behind the phone, so the card does not float on a
    # dead-flat field.
    glow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    glow_draw = ImageDraw.Draw(glow)
    glow_draw.ellipse(
        [W // 2 - GLOW_W, PHONE_TOP - 150, W // 2 + GLOW_W, H + 260],
        fill=(*LIME, 34),
    )
    glow = glow.filter(ImageFilter.GaussianBlur(110))
    return Image.alpha_composite(image.convert("RGBA"), glow)


def draw_wordmark(image: Image.Image) -> None:
    draw = ImageDraw.Draw(image)
    brand = font_latin(BRAND_SIZE, "semibold")
    draw.text((MARGIN, BRAND_Y), "Stolnk", font=brand, fill=INK)
    width = draw.textlength("Stolnk", font=brand)
    dot = round(BRAND_SIZE * 0.32)
    draw.rounded_rectangle(
        [MARGIN + width + 14, BRAND_Y + 13, MARGIN + width + 14 + dot, BRAND_Y + 13 + dot],
        radius=round(dot / 2),
        fill=LIME,
    )
    draw.rounded_rectangle(
        [MARGIN, ACCENT_Y, MARGIN + ACCENT_W, ACCENT_Y + 6], radius=3, fill=LIME
    )


def wrap(draw: ImageDraw.ImageDraw, text: str, font, max_width: int) -> list[str]:
    lines: list[str] = []
    for paragraph in text.split("\n"):
        if not paragraph:
            lines.append("")
            continue
        words = paragraph.split(" ")
        current = ""
        for word in words:
            trial = word if not current else f"{current} {word}"
            if draw.textlength(trial, font=font) <= max_width:
                current = trial
            else:
                if current:
                    lines.append(current)
                current = word
        lines.append(current)
    return lines


def frame_phone(screen: Image.Image) -> Image.Image:
    ratio = PHONE_W / screen.width
    height = round(screen.height * ratio)
    resized = screen.convert("RGB").resize((PHONE_W, height), Image.LANCZOS)

    radius = RADIUS
    mask = Image.new("L", (PHONE_W, height), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [0, 0, PHONE_W - 1, height - 1], radius=radius, fill=255
    )

    card = Image.new("RGBA", (PHONE_W, height), (0, 0, 0, 0))
    card.paste(resized, (0, 0), mask)

    border = ImageDraw.Draw(card)
    border.rounded_rectangle(
        [0, 0, PHONE_W - 1, height - 1],
        radius=radius,
        outline=(*HAIRLINE, 255),
        width=2,
    )
    return card


def raw_name(slide: dict, locale: str, device: str) -> str:
    if device == "duo-landscape":
        return f"duo-land-{'en' if locale == 'en' else 'zh'}-{slide['screen']}.png"
    if device == "duo":
        if locale == "en":
            return f"duo-en-inner-{slide['screen']}.png"
        return f"duo-inner-{slide['screen']}-nostatus.png"
    return slide["en_file"] if locale == "en" else slide["zh_file"]


def apply_layout(device: str) -> None:
    global W, H, MARGIN, PHONE_W, PHONE_TOP, BRAND_SIZE, BRAND_Y
    global ACCENT_Y, ACCENT_W, HEADLINE_Y, HEADLINE_ZH, HEADLINE_EN
    global SUB_ZH, SUB_EN, SUB_GAP, RADIUS, GLOW_W
    layout = LAYOUTS[device]
    W = layout["W"]
    H = layout["H"]
    MARGIN = layout["MARGIN"]
    PHONE_W = layout["PHONE_W"]
    PHONE_TOP = layout["PHONE_TOP"]
    BRAND_SIZE = layout["BRAND_SIZE"]
    BRAND_Y = layout["BRAND_Y"]
    ACCENT_Y = layout["ACCENT_Y"]
    ACCENT_W = layout["ACCENT_W"]
    HEADLINE_Y = layout["HEADLINE_Y"]
    HEADLINE_ZH = layout["HEADLINE_ZH"]
    HEADLINE_EN = layout["HEADLINE_EN"]
    SUB_ZH = layout["SUB_ZH"]
    SUB_EN = layout["SUB_EN"]
    SUB_GAP = layout["SUB_GAP"]
    RADIUS = layout["RADIUS"]
    GLOW_W = layout["GLOW_W"]


def compose(raw: Path, out: Path, slide: dict, locale: str, device: str) -> bool:
    file = raw_name(slide, locale, device)
    source = raw / file
    if not source.exists():
        print(f"skip {locale}: missing {source}")
        return False

    image = background()
    draw_wordmark(image)
    draw = ImageDraw.Draw(image)

    if locale == "en":
        headline_font = font_latin(HEADLINE_EN, "bold")
        sub_font = font_latin(SUB_EN, "regular")
        headline = slide["en_headline"]
        sub = slide["en_sub"]
    else:
        headline_font = font_chinese(HEADLINE_ZH, "semibold")
        sub_font = font_chinese(SUB_ZH, "medium")
        headline = slide["zh_headline"]
        sub = slide["zh_sub"]

    max_text = W - MARGIN * 2
    y = HEADLINE_Y
    for line in wrap(draw, headline, headline_font, max_text):
        draw.text((MARGIN, y), line, font=headline_font, fill=INK)
        y += round(headline_font.size * 1.16)
    y += SUB_GAP
    for line in wrap(draw, sub, sub_font, max_text):
        draw.text((MARGIN, y), line, font=sub_font, fill=SECONDARY)
        y += round(sub_font.size * 1.45)

    screen = Image.open(source)
    card = frame_phone(screen)
    x = (W - PHONE_W) // 2

    shadow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    shadow_draw = ImageDraw.Draw(shadow)
    shadow_draw.rounded_rectangle(
        [x + 6, PHONE_TOP + 26, x + PHONE_W - 6, PHONE_TOP + card.height + 10],
        radius=RADIUS,
        fill=(16, 32, 27, 70),
    )
    shadow = shadow.filter(ImageFilter.GaussianBlur(30))
    image = Image.alpha_composite(image, shadow)
    image.alpha_composite(card, (x, PHONE_TOP))

    out.parent.mkdir(parents=True, exist_ok=True)
    image.convert("RGB").save(out, "PNG", optimize=True)
    print(f"wrote {out}")
    return True


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--raw", default="build/shots")
    parser.add_argument("--out", default=None)
    parser.add_argument("--device", choices=sorted(LAYOUTS), default="iphone")
    parser.add_argument("--locale", choices=["zh", "en", "both"], default="both")
    args = parser.parse_args()

    apply_layout(args.device)
    raw = Path(args.raw)
    defaults = {
        "iphone": "build/promo",
        "duo": "build/promo-duo",
        "duo-landscape": "build/promo-duo-landscape",
    }
    out = Path(args.out or defaults[args.device])
    locales = ["zh", "en"] if args.locale == "both" else [args.locale]
    for locale in locales:
        for index, slide in enumerate(SLIDES, start=1):
            folder = out / ("en-US" if locale == "en" else "zh-Hans")
            compose(raw, folder / f"{index:02d}.png", slide, locale, args.device)


if __name__ == "__main__":
    main()
