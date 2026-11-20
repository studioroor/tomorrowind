#!/usr/bin/env python3
"""Shows what the ambient scout run found (tests/ingame/.../ambient_scene.lua):

    tools/ambient_scout.py <take> [out-dir]      (default: the take)

walkmap.png   where everybody walked (a dot a second per settler), on a map
              of the village with the road, the buildings and the cameras
cameras.jpg   the still from every candidate camera, with its name
Needs Pillow.
"""
import os
import re
import sys

from PIL import Image, ImageDraw

LANE_Y, JUNCTION_X = -56680, -2250


def main():
    take = sys.argv[1]
    out = sys.argv[2] if len(sys.argv) > 2 else take
    log = open(os.path.join(take, 'stdout.log'), errors='replace').read()
    walks = [tuple(map(float, p.split(','))) for line in re.findall(r'\[AMBIENT\]\s+walk (.*)', log) for p in line.split()]
    places = [(m[0], float(m[1]), float(m[2])) for m in re.findall(r'\[AMBIENT\]\s+place (\S+) (-?\d+) (-?\d+)', log)]
    stills = re.findall(r'\[AMBIENT\]\s+still\s+(\S+)', log)
    # the map: x from -4500 to 2000, y the lane +-2000; 1 px = 5 units
    x0, x1, y0, y1, k = -4500, 2000, LANE_Y - 2000, LANE_Y + 2000, 5.0
    w, h = int((x1 - x0) / k), int((y1 - y0) / k)
    img = Image.new('RGB', (w, h), (34, 44, 30))
    d = ImageDraw.Draw(img)

    def px(x, y):
        return (x - x0) / k, (y1 - y) / k  # north up

    # the roads: the branch along the lane, the main road north-south
    d.line([px(JUNCTION_X, LANE_Y), px(x1, LANE_Y)], fill=(120, 110, 90), width=int(300 / k))
    d.line([px(JUNCTION_X, y0), px(JUNCTION_X, y1)], fill=(120, 110, 90), width=int(300 / k))
    for x, y in walks:
        cx, cy = px(x, y)
        d.ellipse([cx - 2, cy - 2, cx + 2, cy + 2], fill=(255, 200, 60))
    colours = {'storehouse': (230, 80, 80), 'house': (200, 140, 90), 'tree': (60, 200, 60), 'lumber': (140, 220, 120),
               'farm': (180, 220, 80), 'mine': (160, 160, 200)}
    for kind, x, y in places:
        cx, cy = px(x, y)
        r = 70 / k if kind in ('house', 'storehouse') else 30 / k
        d.rectangle([cx - r, cy - r, cx + r, cy + r], outline=colours.get(kind, (220, 220, 220)), width=2)
        d.text((cx + r + 2, cy - 6), kind, fill=colours.get(kind, (220, 220, 220)))
    # the cameras (as in ambient_scene.lua: from, to)
    src = open(os.path.join(os.path.dirname(__file__), '..', 'tests', 'ingame', 'scripts', 'tomorrowind_test', 'ambient_scene.lua')).read()
    for name, fx, fy, tx, ty in re.findall(r'(\w+) = \{ \{ (-?\d+), Y ([-+] \d+), \d+ \}, \{ (-?\d+), Y ([-+] \d+), \d+ \} \}', src):
        a = px(float(fx), LANE_Y + float(fy.replace(' ', '')))
        b = px(float(tx), LANE_Y + float(ty.replace(' ', '')))
        d.line([a, b], fill=(120, 170, 255), width=1)
        d.ellipse([a[0] - 4, a[1] - 4, a[0] + 4, a[1] + 4], fill=(120, 170, 255))
        d.text((a[0] + 5, a[1] + 2), name, fill=(170, 200, 255))
    img.save(os.path.join(out, 'walkmap.png'))
    # the stills, in the order they were taken
    shots = sorted(os.listdir(os.path.join(take, 'userdata', 'screenshots')), key=lambda x: int(re.findall(r'\d+', x)[0]))
    tiles = []
    for name, f in zip(stills, shots):
        im = Image.open(os.path.join(take, 'userdata', 'screenshots', f)).convert('RGB').resize((480, 270))
        ImageDraw.Draw(im).text((8, 8), name, fill=(255, 255, 0))
        tiles.append(im)
    cols = 4
    sheet = Image.new('RGB', (480 * cols, 270 * ((len(tiles) + cols - 1) // cols)))
    for i, im in enumerate(tiles):
        sheet.paste(im, ((i % cols) * 480, (i // cols) * 270))
    sheet.save(os.path.join(out, 'cameras.jpg'))
    print('%d walk samples, %d places, %d stills' % (len(walks), len(places), len(tiles)))


if __name__ == '__main__':
    main()
