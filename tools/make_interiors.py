#!/usr/bin/env python3
"""Generates the colony's interiors from a Morrowind.esm.

    tools/make_interiors.py "<Data Files>/Morrowind.esm"

Writes two files:
  Tomorrowind.omwaddon              one empty interior cell: Lua can't create cells
  scripts/tomorrowind/interiors.lua the architecture of a few vanilla houses (ids
                                    and positions only), built in that cell at
                                    runtime, each house at its own spot

Only walls, floors, windows, stairs, inner doors and hanging lights are kept: what
stands in the rooms is up to the player.
"""
import math
import os
import re
import struct
import sys

CELL_NAME = 'Tomorrowind Interiors'
# key -> the vanilla interior whose architecture it copies
ROOMS = {
    'hlaalu_small': "Balmora, Hecerinde's House",
    'hlaalu_mid': "Balmora, Dralosa Athren's House",
    'hlaalu_large': "Balmora, Tsiya's House",
    'shack': "Seyda Neen, Fine-Mouth's Shack",
    'common': "Caldera, Odairan Ashummi-Ammus' House",
}
KEEP_LIGHT = re.compile(r'lamp|lantern|sconce|chandelier|paper')
# Where each room's floor is, below the point you arrive at: measured in game
# with tests/ingame rooms scene (there is no physics here to find it).
FLOOR = {'hlaalu_small': -92.8, 'hlaalu_mid': -123.0, 'hlaalu_large': -85.5, 'shack': -116.4, 'common': -88.8}
BED = re.compile(r'bed|hammock')
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')


def subrecords(body):
    at, out = 0, []
    while at < len(body):
        size = struct.unpack_from('<I', body, at + 4)[0]
        out.append((body[at:at + 4], body[at + 8:at + 8 + size]))
        at += 8 + size
    return out


def text(raw):
    return raw.rstrip(b'\0').decode('latin1')


def read_esm(path):
    data = open(path, 'rb').read()
    models, cells, at = {}, {}, 0
    outdoor_doors = {}
    while at < len(data):
        tag = data[at:at + 4]
        size = struct.unpack_from('<I', data, at + 4)[0]
        body = data[at + 16:at + 16 + size]
        at += 16 + size
        if tag in (b'STAT', b'LIGH', b'DOOR', b'ACTI'):
            fields = dict(subrecords(body))
            models[text(fields.get(b'NAME', b'')).lower()] = (tag, text(fields.get(b'MODL', b'')).lower())
        elif tag == b'CELL':
            subs = subrecords(body)
            first = {}
            for key, value in subs:
                first.setdefault(key, value)
            refs, cur = [], None
            for key, value in subs:
                if key == b'FRMR':
                    cur = {}
                    refs.append(cur)
                elif cur is None:
                    continue
                elif key == b'NAME':
                    cur['id'] = text(value).lower()
                elif key == b'DATA' and len(value) == 24:
                    cur['pos'] = struct.unpack('<6f', value)
                elif key == b'XSCL':
                    cur['scale'] = struct.unpack('<f', value)[0]
                elif key == b'DODT':
                    cur['dest'] = struct.unpack('<6f', value)
                elif key == b'DNAM':
                    cur['destCell'] = text(value)
            flags = struct.unpack_from('<i', first[b'DATA'], 0)[0]
            if flags & 1:
                cells[text(first[b'NAME'])] = refs
            else:
                for r in refs:
                    if r.get('destCell') and 'dest' in r:
                        outdoor_doors.setdefault(r['destCell'], r['dest'])
    return models, cells, outdoor_doors


def room_lua(key, name, models, refs, arrive):
    ox, oy, oz = arrive[0], arrive[1], arrive[2]
    pieces, exits, beds = [], [], []
    for r in refs:
        kind, model = models.get(r.get('id', ''), (None, ''))
        if 'pos' not in r or kind is None or r['id'] == 'northmarker':
            continue
        x, y, z, rx, ry, rz = r['pos']
        if kind == b'ACTI' and BED.search(model):
            # where the vanilla house had its bed: the house comes with one there
            beds.append('{ %r, %.1f, %.1f, %.4f }' % ('meshes/' + model.replace('\\', '/'), x - ox, y - oy, rz))
            continue
        item = '{ %r, %.1f, %.1f, %.1f, %.4f, %.4f, %.4f, %.3f }' % (r['id'], x - ox, y - oy, z - oz, rx, ry, rz, r.get('scale', 1))
        if kind == b'DOOR' and 'dest' in r:
            exits.append(item)
        elif kind == b'DOOR':
            pieces.append(item)
        elif kind == b'STAT' and model.startswith(('i\\', 'x\\')):
            pieces.append(item)
        elif kind == b'LIGH' and (not model or KEEP_LIGHT.search(model)):
            pieces.append(item)
    return ("    %s = {\n        arrive = { yaw = %.4f },\n        floor = %.1f,\n        beds = { %s },\n"
            "        exits = {\n            %s,\n        },\n        pieces = {\n            %s,\n        },\n    },\n") % (
        key, arrive[5], FLOOR[key], ', '.join(beds), ',\n            '.join(exits), ',\n            '.join(pieces))


def write_plugin(path):
    def record(tag, subs):
        body = b''.join(k + struct.pack('<I', len(v)) + v for k, v in subs)
        return tag + struct.pack('<I', len(body)) + b'\0' * 8 + body
    hedr = struct.pack('<fi', 1.3, 0) + b'Tomorrowind'.ljust(32, b'\0') \
        + b'One empty cell: the mod builds its interiors there with Lua.'.ljust(256, b'\0') + struct.pack('<i', 1)
    cell = record(b'CELL', [
        (b'NAME', CELL_NAME.encode() + b'\0'),
        (b'DATA', struct.pack('<iii', 1, 0, 0)),
        # warm ambient light, brighter than vanilla: the rooms have few lamps
        (b'AMBI', bytes((125, 110, 95, 0, 80, 60, 20, 0, 0, 0, 0, 0)) + struct.pack('<f', 0.3)),
    ])
    with open(path, 'wb') as f:
        f.write(record(b'TES3', [(b'HEDR', hedr)]) + cell)


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    models, cells, outdoor = read_esm(sys.argv[1])
    out = ["-- Generated by tools/make_interiors.py. The architecture of vanilla houses:\n"
           "-- pieces { id, x, y, z, rotX, rotY, rotZ, scale }, relative to where you\n"
           "-- arrive; floor: its height there; beds { model, x, y, yaw }: the house's own.\n"
           "return {\n    cell = %r,\n" % CELL_NAME]
    for key, name in ROOMS.items():
        arrive = outdoor[name]
        out.append(room_lua(key, name, models, cells[name], arrive))
    out.append("}\n")
    with open(os.path.join(ROOT, 'scripts/tomorrowind/interiors.lua'), 'w') as f:
        f.write(''.join(out))
    write_plugin(os.path.join(ROOT, 'Tomorrowind.omwaddon'))
    print('wrote', len(ROOMS), 'rooms and the plugin')


if __name__ == '__main__':
    main()
