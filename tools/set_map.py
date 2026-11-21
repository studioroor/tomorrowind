#!/usr/bin/env python3
"""Draws the map logged by the set_map scene (tests/ingame/.../set_map.lua):

    tools/set_map.py <take> [out.png] [--plan plan.json]

Land shaded by height (contours every 50 units, water blue, steep ground
darker), trees green, everything else grey, with a 500-unit grid labelled
relative to the centre. --plan draws planned spots on top: a JSON list of
{"name": .., "x": .., "y": .., "r": ..} relative to the centre. Needs Pillow.
"""
import json
import math
import os
import re
import sys

from PIL import Image, ImageDraw


def main():
    take = sys.argv[1]
    out = sys.argv[2] if len(sys.argv) > 2 and not sys.argv[2].startswith('--') else os.path.join(take, 'setmap.png')
    plan = []
    if '--plan' in sys.argv:
        plan = json.load(open(sys.argv[sys.argv.index('--plan') + 1]))
    log = open(os.path.join(take, 'stdout.log'), errors='replace').read()
    m = re.search(r'\[SM\] centre (-?\d+) (-?\d+) r (\d+) step (\d+)', log)
    cx, cy, R, step = (int(v) for v in m.groups())
    rows = {}
    for line in re.findall(r'\[SM\] row (-?\d+) ([-\d ]+)', log):
        rows[int(line[0])] = [float(v) for v in line[1].split()]
    objs = [(o[0], float(o[1]), float(o[2]), float(o[4])) for o in re.findall(r'\[SM\] obj (\S+) (-?[\d.]+) (-?[\d.]+) (-?[\d.]+) ([\d.]+)', log)]
    k = 13  # pixels per step
    n = 2 * R // step + 1
    size = n * k
    img = Image.new('RGB', (size, size))
    d = ImageDraw.Draw(img)
    ys = sorted(rows)
    hs = [h for r in rows.values() for h in r]
    lo, hi = max(0, min(hs)), max(hs)
    for j, yy in enumerate(ys):
        for i, h in enumerate(rows[yy]):
            px, py = i * k, (n - 1 - j) * k  # north up
            if h < 0:
                col = (40, 70, 130)
            else:
                v = (h - lo) / max(1, hi - lo)
                # steepness against the neighbours
                right = rows[yy][i + 1] if i + 1 < len(rows[yy]) else h
                up = rows[ys[j + 1]][i] if j + 1 < len(ys) else h
                slope = max(abs(right - h), abs(up - h)) / step
                base = (70 + int(110 * v), 100 + int(90 * v), 60 + int(50 * v))
                f = max(0.45, 1 - slope * 1.6)
                col = tuple(int(c * f) for c in base)
                if int(h // 50) != int(right // 50) or int(h // 50) != int(up // 50):
                    col = tuple(int(c * 0.8) for c in col)
            d.rectangle([px, py, px + k - 1, py + k - 1], fill=col)

    def to_px(x, y):
        return (x - cx + R) / step * k, (R - (y - cy)) / step * k

    for g in range(-R - R % 500, R + 1, 500):
        a = to_px(cx + g, cy - R)
        b = to_px(cx + g, cy + R)
        d.line([a, b], fill=(255, 255, 255), width=1)
        d.text((a[0] + 2, size - 12), str(g), fill=(255, 255, 255))
        a = to_px(cx - R, cy + g)
        b = to_px(cx + R, cy + g)
        d.line([a, b], fill=(255, 255, 255), width=1)
        d.text((2, a[1] + 2), str(g), fill=(255, 255, 255))
    for rid, x, y, r in objs:
        px, py = to_px(x, y)
        rr = max(2, r / step * k)
        low = rid.lower()
        tree = 'tree' in low and 'stump' not in low
        if 'parasol' in low or 'emp_' in low:
            col = (230, 200, 160)
        elif tree:
            col = (40, 230, 60)
        else:
            col = (200, 200, 200)
        if tree:
            d.ellipse([px - 4, py - 4, px + 4, py + 4], fill=col)
            d.ellipse([px - rr, py - rr, px + rr, py + rr], outline=col)
        else:
            d.rectangle([px - rr, py - rr, px + rr, py + rr], outline=col)
    for p in plan:
        px, py = to_px(cx + p['x'], cy + p['y'])
        rr = p.get('r', 100) / step * k
        d.ellipse([px - rr, py - rr, px + rr, py + rr], outline=(255, 80, 80), width=3)
        d.text((px + rr + 3, py - 6), p['name'], fill=(255, 120, 120))
    img.save(out)
    print('heights %.0f..%.0f, %d objects, wrote %s' % (lo, hi, len(objs), out))


if __name__ == '__main__':
    main()
