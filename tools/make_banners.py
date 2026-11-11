#!/usr/bin/env python3
"""Makes the README banner, the GitHub social preview and a square picture
from an in-game still (see tests/ingame/scripts/tomorrowind_test/poster.lua
and tools/shoot_poster.sh):

    tools/make_banners.py <still.png> [out-dir]      (default: art/)

The still is brightened (dawn shots come out dark), cropped, and the name is
set over the sky in MysticCards, the Morrowind-style font that ships with
OpenMW (SIL Open Font License). Needs Pillow and numpy, as make_trailer.py.
"""
import os
import sys

from PIL import Image, ImageDraw, ImageEnhance, ImageFilter, ImageFont

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from make_trailer import BRIGHT, FONT  # noqa: E402

SUBTITLE = 'A House Hlaalu colony builder for OpenMW'


def grade(img, gamma=1.45, contrast=1.04, saturation=1.2):
    """The same lift as the trailer's evening shots."""
    lut = [min(255, int(255 * (i / 255) ** (1 / gamma) + 0.5)) for i in range(256)]
    img = img.convert('RGB').point(lut * 3)
    img = ImageEnhance.Contrast(img).enhance(contrast)
    return ImageEnhance.Color(img).enhance(saturation)


def text_block(img, lines, x, y, anchor='left'):
    """Lines of (text, size, colour) with a soft dark halo, from (x, y) down."""
    layer = Image.new('RGBA', img.size, (0, 0, 0, 0))
    halo = Image.new('RGBA', img.size, (0, 0, 0, 0))
    draw, hdraw = ImageDraw.Draw(layer), ImageDraw.Draw(halo)
    for text, size, colour in lines:
        font = ImageFont.truetype(FONT, size)
        box = draw.textbbox((0, 0), text, font=font)
        w = box[2] - box[0]
        tx = x - box[0] if anchor == 'left' else x - w / 2 - box[0]
        hdraw.text((tx, y - box[1]), text, font=font, fill=(0, 0, 0, 200), stroke_width=max(3, size // 14), stroke_fill=(0, 0, 0, 200))
        draw.text((tx, y - box[1]), text, font=font, fill=colour, stroke_width=max(1, size // 60), stroke_fill=(70, 48, 20))
        y += (box[3] - box[1]) + size * 0.45
    halo = halo.filter(ImageFilter.GaussianBlur(max(6, lines[0][1] // 12)))
    out = img.convert('RGBA')
    out.alpha_composite(halo)
    out.alpha_composite(layer)
    return out.convert('RGB')


def main():
    still = sys.argv[1]
    out = sys.argv[2] if len(sys.argv) > 2 else 'art'
    os.makedirs(out, exist_ok=True)
    img = grade(Image.open(still))
    w, h = img.size
    s = w / 1920
    gold = (232, 194, 122)
    # README banner, 2.4:1: the sky on the left for the name, the walk below
    banner = img.crop((0, int(240 * s), w, int(1040 * s)))
    banner = text_block(banner, [('Tomorrowind', int(150 * s), gold), (SUBTITLE, int(46 * s), BRIGHT)], int(70 * s), int(40 * s))
    banner.resize((1600, int(1600 * banner.height / banner.width)), Image.LANCZOS).save(os.path.join(out, 'tomorrowind-banner.png'))
    # GitHub social preview, 1280 x 640, the name over the sky in the middle
    social = img.crop((0, int(60 * s), w, int(1020 * s))).resize((1280, 640), Image.LANCZOS)
    social = text_block(social, [('Tomorrowind', 118, gold), (SUBTITLE, 36, BRIGHT)], 640, 46, anchor='middle')
    social.save(os.path.join(out, 'tomorrowind-social.png'))
    # square: the settlers setting out, for an avatar or a thumbnail
    square = img.crop((int(330 * s), int(80 * s), int(1330 * s), int(1080 * s))).resize((1024, 1024), Image.LANCZOS)
    square.save(os.path.join(out, 'tomorrowind-square.png'))
    for name in ('banner', 'social', 'square'):
        print('wrote', os.path.join(out, 'tomorrowind-%s.png' % name))


if __name__ == '__main__':
    main()
