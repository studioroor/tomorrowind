#!/usr/bin/env python3
"""Makes the colony tent's meshes from the game's own Ashlander tent.

The outside: vanilla ex_ashl_tent_01/02.nif have an invisible collision plane
across its doorway (a loading door normally stands there). Detaching their
collision node makes the engine collide with the visible geometry instead,
which has a real gap at the door: settlers and the player can walk in.

The lining: the outside mesh is one-sided, so from inside you would see
straight through it. in_ashl_tent_01/02.nif line them, but have collision of their
own that blocks the doorway, so their collision node is emptied: no collision.

Usage: tools/make_tent_meshes.py <Morrowind.bsa> <output-dir>
"""
import os
import re
import struct
import sys


def read_from_bsa(path, wanted):
    data = open(path, 'rb').read()
    _, hash_offset, count = struct.unpack_from('<III', data, 0)
    records = [struct.unpack_from('<II', data, 12 + i * 8) for i in range(count)]
    name_offsets = struct.unpack_from('<%dI' % count, data, 12 + count * 8)
    names_at = 12 + count * 12
    data_at = 12 + hash_offset + count * 8
    for i in range(count):
        start = names_at + name_offsets[i]
        name = data[start:data.index(b'\0', start)].decode('latin1')
        if name.lower() == wanted.lower():
            size, offset = records[i]
            return data[data_at + offset:data_at + offset + size]
    raise SystemExit('%s is not in %s' % (wanted, path))


def find_blocks(nif):
    """Start of every block: each begins with its length-prefixed type name."""
    header_end = nif.index(b'\n') + 1
    num_blocks = struct.unpack_from('<I', nif, header_end + 4)[0]
    type_name = re.compile(rb'[\x04-\x20]\x00\x00\x00((?:Ni|BS|Root|Avoid)[A-Za-z]+)')
    blocks = list(type_name.finditer(nif, header_end + 8))
    if len(blocks) != num_blocks:
        raise SystemExit('expected %d blocks, found %d' % (num_blocks, len(blocks)))
    return blocks


def collision_index(blocks):
    found = [i for i, m in enumerate(blocks) if m.group(1) == b'RootCollisionNode']
    if len(found) != 1:
        raise SystemExit('expected one collision node, found %d' % len(found))
    return found[0]


def children_of(nif, start):
    """(offset, count) of the child references of the NiNode block at `start`."""
    at = start
    for _ in range(2):  # type name, node name
        at += 4 + struct.unpack_from('<I', nif, at)[0]
    at += 4 + 4 + 2           # extra data, controller, flags
    at += 12 + 36 + 4 + 12    # translation, rotation, scale, velocity
    at += 4 + 4 * struct.unpack_from('<I', nif, at)[0]  # properties
    if struct.unpack_from('<I', nif, at)[0]:
        raise SystemExit('bounding volumes are not handled')
    at += 4
    return at + 4, struct.unpack_from('<I', nif, at)[0]


def detach_collision(nif):
    nif = bytearray(nif)
    blocks = find_blocks(bytes(nif))
    index = collision_index(blocks)
    at, count = children_of(nif, blocks[0].start())
    for i in range(count):
        if struct.unpack_from('<i', nif, at + i * 4)[0] == index:
            struct.pack_into('<i', nif, at + i * 4, -1)
            return bytes(nif)
    raise SystemExit('the root node does not reference the collision node')


def empty_collision(nif):
    nif = bytearray(nif)
    blocks = find_blocks(bytes(nif))
    at, count = children_of(nif, blocks[collision_index(blocks)].start())
    for i in range(count):
        struct.pack_into('<i', nif, at + i * 4, -1)
    return bytes(nif)


if __name__ == '__main__':
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    bsa, out = sys.argv[1], sys.argv[2]
    os.makedirs(out, exist_ok=True)
    for name, source, patch in (
        ('tent.nif', 'meshes\\x\\ex_ashl_tent_02.nif', detach_collision),
        ('tent_lining.nif', 'meshes\\i\\in_ashl_tent_02.nif', empty_collision),
        ('tent_large.nif', 'meshes\\x\\ex_ashl_tent_01.nif', detach_collision),
        ('tent_large_lining.nif', 'meshes\\i\\in_ashl_tent_01.nif', empty_collision),
    ):
        path = os.path.join(out, name)
        with open(path, 'wb') as f:
            f.write(patch(read_from_bsa(bsa, source)))
        print('wrote', path)
