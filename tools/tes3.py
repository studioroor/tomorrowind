"""Minimal TES3 (Morrowind ESM/ESP) record reader/writer.

Records are kept as (type, flags, [(subtag, bytes), ...]).  Enough to inspect
vanilla records and to write the small plugins this mod needs.
"""
import struct


def read_records(path):
    data = open(path, 'rb').read()
    pos = 0
    while pos < len(data):
        rtype, size, _unused, flags = struct.unpack_from('<4sIII', data, pos)
        pos += 16
        body = data[pos:pos + size]
        pos += size
        subs, sp = [], 0
        while sp < len(body):
            stag, ssize = struct.unpack_from('<4sI', body, sp)
            sp += 8
            subs.append((stag.decode('latin1'), body[sp:sp + ssize]))
            sp += ssize
        yield rtype.decode('latin1'), flags, subs


def zstr(s):
    return s.encode('cp1252') + b'\0'


def fixed(s, n):
    b = s.encode('cp1252')
    assert len(b) < n, (s, n)
    return b + b'\0' * (n - len(b))


def pack_record(rtype, subs, flags=0):
    body = b''.join(struct.pack('<4sI', t.encode(), len(d)) + d for t, d in subs)
    return struct.pack('<4sIII', rtype.encode(), len(body), 0, flags) + body


def write_plugin(path, records, masters, author='', description=''):
    """records: list of (rtype, subs[, flags]); masters: list of (name, size)."""
    hedr = struct.pack('<fI', 1.3, 0) + fixed(author, 32) + fixed(description, 256) \
        + struct.pack('<I', len(records))
    head = [('HEDR', hedr)]
    for name, size in masters:
        head += [('MAST', zstr(name)), ('DATA', struct.pack('<Q', size))]
    out = [pack_record('TES3', head)]
    for rec in records:
        out.append(pack_record(*rec))
    with open(path, 'wb') as f:
        f.write(b''.join(out))
