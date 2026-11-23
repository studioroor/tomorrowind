"""Music for Tomorrowind's trailers and videos: synthesised pads and plucks,
and orchestral instruments played from a SoundFont through fluidsynth.

A song (a plain dict, saved as JSON in music/songs/) is sections (chords, a
melody, drums), an arrangement (which section plays when, who plays in it,
fades and slowing down), the tracks (the band) and the feel (rubato, human,
swing): see "a song" below. render(song) returns float32 stereo samples at
RATE. pad(total) is the trailers' own soundtrack, exactly as it always was.
"""
import math
import os
import shutil
import struct
import subprocess
import tempfile
import wave
import zlib

import numpy as np

RATE = 44100
HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, '..', '..'))
SOUNDFONT = os.path.join(REPO, 'music', 'soundfonts', 'MuseScore_General.sf2')

NOTE_NAMES = ['C', 'C#', 'D', 'Eb', 'E', 'F', 'F#', 'G', 'Ab', 'A', 'Bb', 'B']
QUALITIES = {
    '': [0, 4, 7], 'm': [0, 3, 7], '5': [0, 7, 12], 'sus2': [0, 2, 7], 'sus4': [0, 5, 7],
    'dim': [0, 3, 6], 'aug': [0, 4, 8], 'maj7': [0, 4, 7, 11], 'm7': [0, 3, 7, 10],
    '7': [0, 4, 7, 10], 'add9': [0, 4, 7, 14], 'madd9': [0, 3, 7, 14],
}
VOICINGS = ['close', 'open', 'spread']

# General MIDI programs that suit the game's sound: strings, choir, horns,
# harp, winds, timpani, and a few soft pads
INSTRUMENTS = {
    'Strings': 48, 'Slow strings': 49, 'Synth strings': 50, 'Violin': 40, 'Viola': 41, 'Cello': 42,
    'Contrabass': 43, 'Tremolo strings': 44, 'Pizzicato strings': 45, 'Harp': 46, 'Timpani': 47,
    'Choir aahs': 52, 'Voice oohs': 53, 'French horn': 60, 'Brass section': 61, 'Trombone': 57,
    'Tuba': 58, 'Flute': 73, 'Recorder': 74, 'Pan flute': 75, 'Ocarina': 79, 'Oboe': 68,
    'English horn': 69, 'Bassoon': 70, 'Clarinet': 71, 'Celesta': 8, 'Glockenspiel': 9,
    'Music box': 10, 'Nylon guitar': 24, 'Sitar': 104, 'Dulcimer': 15, 'Church organ': 19,
    'Warm pad': 89, 'Choir pad': 91, 'Bowed glass': 92, 'Halo pad': 94, 'Sweep pad': 95,
}

# the pad's sound: layers of each note (pitch ratio, loudness), and the
# waveforms (harmonic, loudness) each layer is made of
PAD_DEFAULTS = {
    'detune': 1.003, 'shimmer': 0.6, 'sub': 0.5, 'air': 0.14,
    'width': 1.0015, 'attack': 1.2, 'release': 1.6, 'overlap': 1.35, 'curve': 1.2,
    'wave': 'sine', 'vibrato': 0.0, 'vibratoRate': 4.5, 'tremolo': 0.0, 'tremoloRate': 3.0, 'level': 0.05,
}
WAVES = {
    'sine': [(1, 1.0)],
    'warm': [(1, 1.0), (2, 0.35), (3, 0.15), (4, 0.06)],
    'hollow': [(1, 1.0), (3, 0.33), (5, 0.2), (7, 0.14)],
    'bright': [(1, 1.0), (2, 0.5), (3, 0.33), (4, 0.25), (5, 0.2), (6, 0.16)],
    'bell': [(1, 1.0), (2.76, 0.35), (5.4, 0.18), (8.93, 0.08)],
}
PLUCK_DEFAULTS = {'decay': 2.5, 'brightness': 0.6, 'strum': 0.04, 'width': 1.002, 'level': 0.09}
INSTRUMENT_DEFAULTS = {'program': 48, 'velocity': 80, 'pan': 64, 'reverb': 60}


def hz(midi):
    return 440.0 * 2 ** ((midi - 69) / 12)


# ---------------------------------------------------------------------------
# the trailer's pad, as it always was

TRAILER_CHORDS = [(146.83, 174.61, 220.0), (116.54, 174.61, 233.08), (130.81, 196.0, 261.63), (110.0, 164.81, 220.0)]


def pad(total):
    """An original slow pad in D minor: the trailers' soundtrack."""
    n = int(total * RATE)
    out = np.zeros((n, 2), dtype=np.float32)
    bar = total / (len(TRAILER_CHORDS) * 2)
    events = [(i * bar, None, TRAILER_CHORDS[i % len(TRAILER_CHORDS)], (i + 1.35) * bar) for i in range(len(TRAILER_CHORDS) * 2)]
    pad_events(out, events, PAD_DEFAULTS)
    return out


def hit(at, mix, gain=1.0):
    """A soft low drum: struck harder (gain over 1), more of a thump at the start."""
    length = int(1.4 * RATE)
    tt = np.arange(length) / RATE
    sweep = 30 * float(np.clip(gain, 0.05, 2.5)) ** 0.5
    wave_ = np.sin(2 * np.pi * (46 + sweep * np.exp(-tt * 18)) * tt) * np.exp(-tt * 3.2) * 0.42 * gain
    add(mix, np.stack([wave_, wave_], axis=1).astype(np.float32), at)


def add(mix, sound, at, gain=1.0):
    a = int(at * RATE)
    if a >= len(mix):
        return
    n = min(len(sound), len(mix) - a)
    mix[a:a + n] += sound[:n] * gain


# ---------------------------------------------------------------------------
# synths

def intensity(gain):
    """How hard a note is played, from its loudness (1: as set): the
    instruments play harder (velocity), and so do the synths: brighter and
    fuller when loud, softer and rounder when quiet."""
    return float(np.clip(gain, 0.05, 2.5))


def pad_events(out, events, p):
    """Pad notes into `out`: events are (start s, length s, frequencies Hz[, end s[, gain]])."""
    n = len(out)
    base_layers = ((1.0, 1.0), (p['detune'], p['shimmer']), (0.5, p['sub']), (2.0, p['air']))
    base_partials = WAVES.get(p.get('wave', 'sine'), WAVES['sine'])
    for ev in events:
        start, length_s, freqs = ev[:3]
        end = ev[3] if len(ev) > 3 and ev[3] is not None else start + length_s
        note_gain = ev[4] if len(ev) > 4 else None
        layers, partials = base_layers, base_partials
        if note_gain is not None and abs(note_gain - 1) > 1e-9:
            # played harder: the shimmer, the octave above and the overtones swell
            x = intensity(note_gain)
            layers = ((1.0, 1.0), (p['detune'], min(1.0, p['shimmer'] * x ** 0.5)), (0.5, p['sub']), (2.0, p['air'] * x))
            partials = [(h, hg if h == 1 else hg * x ** 0.7) for h, hg in base_partials]
        a, b = int(start * RATE), min(n, int(end * RATE))
        if b <= a:
            continue
        # time from the event's own start, as the trailer's pad always worked it out
        tt = np.arange(a, b) / RATE - a / RATE
        length = b - a
        env = np.minimum(np.minimum(tt / max(1e-3, p['attack']), 1.0), (length / RATE - tt) / max(1e-3, p['release'])).clip(0, 1) ** p['curve']
        if p.get('tremolo'):
            env = env * (1 - p['tremolo'] * 0.5 * (1 + np.sin(2 * np.pi * p['tremoloRate'] * tt)))
        vib = 0
        if p.get('vibrato'):
            # depth in cents, as a phase wobble
            vib = (2 ** (p['vibrato'] / 1200) - 1) * np.sin(2 * np.pi * p['vibratoRate'] * tt) / (2 * np.pi * p['vibratoRate'])
        tone = np.zeros(length)
        right = np.zeros(length)
        for f in freqs:
            for det, gain in layers:
                if gain == 0:
                    continue
                for h, hg in partials:
                    g = gain * hg
                    tone += g * np.sin(2 * np.pi * f * det * h * (tt + vib))
                    right += g * np.sin(2 * np.pi * f * det * h * p['width'] * (tt + vib) + 0.7)
        if note_gain is not None:
            env = env * note_gain
        out[a:b, 0] += (tone * env * p['level']).astype(np.float32)
        out[a:b, 1] += (right * env * p['level']).astype(np.float32)


def pluck_events(out, events, p):
    """Plucked strings (harp, lute): each harmonic dies away, the high ones first.
    events are (start s, frequency Hz[, gain])."""
    n = len(out)
    for ev in events:
        start, f = ev[:2]
        note_gain = ev[2] if len(ev) > 2 else 1.0
        # plucked harder: brighter, the high harmonics ring longer
        x = intensity(note_gain)
        bright = float(np.clip(p['brightness'] * x ** 0.35, 0.05, 0.97))
        ring = x ** 0.25
        a = int(start * RATE)
        length = min(n - a, int((p['decay'] * 2.2) * RATE))
        if length <= 0:
            continue
        tt = np.arange(length) / RATE
        left = np.zeros(length)
        right = np.zeros(length)
        k = 1
        while k * f < 9000 and k <= 16:
            g = (bright ** (k - 1)) / k ** 0.5
            d = np.exp(-tt * k ** 0.8 / (ring ** (k > 1) * max(0.05, p['decay'])))
            left += g * d * np.sin(2 * np.pi * f * k * tt)
            right += g * d * np.sin(2 * np.pi * f * k * p['width'] * tt + 0.4)
            k += 1
        click = np.minimum(1, tt / 0.003)
        out[a:a + length, 0] += (left * click * p['level'] * note_gain).astype(np.float32)
        out[a:a + length, 1] += (right * click * p['level'] * note_gain).astype(np.float32)


# ---------------------------------------------------------------------------
# a song: sections, an arrangement, a band
#
#   {
#     "name": .., "bpm": 100, "beatsPerBar": 2,
#     "feel": {"rubato": 0..1, "human": 0..1, "swing": 0..1},
#     "sections": [ {"id": "A", "name": "A", "chords": [..], "melody": [..], "drums": [{"beat": 0, "kind": "low"}, ..],
#                    "parts": {"<track id>": "melody" | "chords" | "bass" | "arp" | "rest"}} ],
#                    "beatsPerBar": 3, "legato": {"<track id>": true},
#                    "volume": {"<track id>" | "drums" | "drum:<kind>": 0..1.5}, "bpm": 72} ],
#                    (parts: what a track plays in this section, if not what the band says;
#                    beatsPerBar: its own time signature; legato: per track, over the band's;
#                    volume: per track, times the band's and the block's; bpm: its own tempo)
# A block's mix can also say legato for a track ({"on":, "volume":, "legato":}),
# over the section and the band. A track's "hold" (default true): its bass or chords hold on when the next
# chord gives the same notes, rather than striking them again.
#     "arrangement": [ {"section": "A", "repeat": 1, "label": "harp only",
#                       "mix": {"<track id>": {"on": true, "volume": 1}, "drums": {..}},
#                       "fadeIn": 0, "fadeOut": 0, "slowTo": 1, "slowOver": 0, "bpm": 72} ],
#     "tracks": [ {"id": "t1", "type": .., ..} ],
#     "drumVolume": 1, "drumVolumes": {"<kind>": 1}       all the drums, and each drum
#   }
# (a block's mix and a section's volume take "drum:<kind>" too: one drum)
# (fades in bars; slowTo: the tempo at the block's end, as a share, reached
# over its last slowOver bars, or the whole block when 0; bpm: the block's own
# tempo, over its section's and the song's)
# A chord: {"root": "G", "octave": 3, "quality": "", "voicing": "close", "bars": 1, "bass": "B",
#           "rest": ["t2", "drums"]}
# (bass: a note under the chord other than its root: G/B; rest: tracks, or the
# drums, that stay silent while this chord plays). Songs from before
# sections (chords and melody at the top) open as section A, played `repeat` times.

DRUMS = {
    # id: (name, how it sounds, General MIDI percussion key)
    'low': ('Low drum', 'synth', None),
    'bass': ('Bass drum', 'kit', 35),
    'floor': ('Floor tom', 'kit', 41),
    'tom': ('Tom', 'kit', 45),
    'hand': ('Hand drum', 'kit', 64),
    'bongo': ('Bongo', 'kit', 61),
    'tamb': ('Tambourine', 'kit', 54),
    'shaker': ('Shaker', 'kit', 70),
    'triangle': ('Triangle', 'kit', 81),
    'cymbal': ('Cymbal', 'kit', 49),
    'block': ('Wood block', 'kit', 77),
    'timpani': ('Timpani on the root', 'timpani', None),
}
DRUM_ORDER = ['low', 'bass', 'floor', 'tom', 'hand', 'bongo', 'timpani', 'tamb', 'shaker', 'triangle', 'cymbal', 'block']
FEEL_DEFAULTS = {'rubato': 0.0, 'human': 0.0, 'swing': 0.0}


def chord_notes(c):
    root = 12 * (int(c.get('octave', 3)) + 1) + NOTE_NAMES.index(c.get('root', 'C'))
    iv = QUALITIES.get(c.get('quality', ''), QUALITIES[''])
    voicing = c.get('voicing', 'close')
    if voicing == 'open' and len(iv) >= 3 and iv[1] < 7:
        # the third up an octave: wide and hollow
        iv = [iv[0], iv[2], iv[1] + 12] + iv[3:]
    elif voicing == 'spread':
        iv = [iv[0] - 12] + iv + [iv[0] + 12]
    return [root + i for i in iv]


def bass_note(c):
    """The chord's lowest note, an octave under it: its root, or the note
    after the slash (G/B: the B just under the G)."""
    root = 12 * (int(c.get('octave', 3)) + 1) + NOTE_NAMES.index(c.get('root', 'C'))
    if c.get('bass') in NOTE_NAMES:
        b = 12 * (int(c.get('octave', 3)) + 1) + NOTE_NAMES.index(c['bass'])
        while b > root:
            b -= 12
        return b - 12 if root - b < 3 else b
    return root - 12


def normalize(song):
    """A song in today's shape (sections and an arrangement), whatever its age."""
    song = dict(song)
    if 'sections' not in song:
        bpb = int(song.get('beatsPerBar', 4))
        drums = [{'beat': b * bpb, 'kind': 'low'} for b in song.get('drums', [])]
        song['sections'] = [{'id': 'A', 'name': 'A', 'chords': song.get('chords', []), 'melody': song.get('melody', []), 'drums': drums}]
        song['arrangement'] = [{'section': 'A', 'repeat': int(song.get('repeat', 1))}]
        for k in ('chords', 'melody', 'drums', 'repeat'):
            song.pop(k, None)
    song['feel'] = dict(FEEL_DEFAULTS, **(song.get('feel') or {}))
    tracks, used = [], set()
    for i, t in enumerate(song.get('tracks', [])):
        t = dict(t)
        if not t.get('id') or t['id'] in used:
            n = i + 1
            while 't%d' % n in used:
                n += 1
            t['id'] = 't%d' % n
        used.add(t['id'])
        tracks.append(t)
    song['tracks'] = tracks
    if not song.get('arrangement') and song['sections']:
        song['arrangement'] = [{'section': song['sections'][0]['id'], 'repeat': 1}]
    return song


def section_bpb(song, section):
    """A section's beats a bar: its own time signature, or the song's."""
    return int(section.get('beatsPerBar') or song.get('beatsPerBar', 4))


def section_beats(section, bpb):
    return sum(float(c.get('bars', 1)) for c in section['chords']) * bpb


def legato_for(track, sec, block):
    """Does a track play legato here: the block says, else the section, else
    the track itself (in the band)."""
    m = ((block.get('mix') or {}).get(track['id']) or {}).get('legato')
    if m is not None:
        return bool(m)
    s = (sec.get('legato') or {}).get(track['id'])
    if s is not None:
        return bool(s)
    return bool(track.get('legato', False))


def legato(notes, gap=1.0, overlap=0.08):
    """Notes that run on into the next one (when it comes within `gap`
    beats; a longer rest stays a rest), overlapping it a little."""
    out = sorted(notes, key=lambda x: x[0])
    for i in range(len(out) - 1):
        s0, ln, ns = out[i]
        nxt = out[i + 1][0]
        if nxt > s0 and nxt - (s0 + ln) <= gap:
            out[i] = (s0, nxt - s0 + overlap, ns)
    return out


def layout(song):
    """Where everything falls, in beats from the start: the passes (each time a
    section plays: block, section, start, beats) and the blocks."""
    bpb = int(song.get('beatsPerBar', 4))
    secs = {s['id']: s for s in song['sections']}
    passes, blocks, g = [], [], 0.0
    for bi, bl in enumerate(song['arrangement']):
        sec = secs.get(bl.get('section'))
        if not sec or not sec['chords']:
            continue
        beats = section_beats(sec, section_bpb(song, sec))
        start = g
        for _ in range(max(1, int(bl.get('repeat', 1)))):
            passes.append((bi, sec, g, beats))
            g += beats
        blocks.append({'index': bi, 'section': sec['id'], 'start': start, 'beats': g - start})
    return passes, blocks, g


class Clock:
    """Beats to seconds, with the tempo breathing (rubato), and slowing down
    where a block asks for it."""
    STEP = 1 / 32

    def __init__(self, song, blocks, passes, total, rng):
        bpm = np.full(int(math.ceil(total / self.STEP)) + 2, float(song.get('bpm', 60)))
        rubato = float(song['feel'].get('rubato', 0))
        n = len(bpm)
        b = np.arange(n) * self.STEP
        # a tempo of its own: the block's, else its section's, else the song's
        secs = {s['id']: s for s in song['sections']}
        for x in blocks:
            bl = song['arrangement'][x['index']]
            own = float(bl.get('bpm') or secs[x['section']].get('bpm') or 0)
            if own > 0:
                bpm[(b >= x['start']) & (b < x['start'] + x['beats'])] = own
                if x is blocks[-1]:
                    bpm[b >= x['start'] + x['beats']] = own
        factor = np.ones(n)
        if rubato > 0:
            ph = rng.uniform(0, 2 * math.pi, 3)
            drift = 0.55 * np.sin(2 * np.pi * b / 7.3 + ph[0]) + 0.3 * np.sin(2 * np.pi * b / 3.1 + ph[1]) + 0.15 * np.sin(2 * np.pi * b / 13.7 + ph[2])
            factor *= 1 + rubato * 0.09 * drift
            # a phrase breathes out at its end: the last beat of each pass broadens
            for _, _, start, beats in passes:
                end = start + beats
                near = np.clip(1 - np.abs(b - (end - 0.5)) / 1.2, 0, 1)
                factor *= 1 - rubato * 0.14 * near ** 2
        for x in blocks:
            bl = song['arrangement'][x['index']]
            slow = float(bl.get('slowTo', 1) or 1)
            if slow < 1:
                # over the block's last `slowOver` bars (0: the whole block)
                over = float(bl.get('slowOver', 0) or 0)
                sec = next(s for s in song['sections'] if s['id'] == x['section'])
                span = min(x['beats'], over * section_bpb(song, sec)) if over > 0 else x['beats']
                s0 = x['start'] + x['beats'] - span
                inside = (b >= s0) & (b < x['start'] + x['beats'])
                prog = (b - s0) / max(1e-6, span)
                factor = np.where(inside, factor * (1 - (1 - slow) * prog ** 2), factor)
                # after the slow-down: the last tempo holds for the tail
                after = b >= x['start'] + x['beats']
                if x is blocks[-1]:
                    factor = np.where(after, factor * slow, factor)
        sec_per_step = 60.0 / (bpm * factor) * self.STEP
        self.beats = b
        self.times = np.concatenate([[0.0], np.cumsum(sec_per_step)[:-1]])
        self.last_spb = 60.0 / (bpm[-1] * factor[-1])

    def t(self, beat):
        if beat >= self.beats[-1]:
            return self.times[-1] + (beat - self.beats[-1]) * self.last_spb
        return float(np.interp(beat, self.beats, self.times))


def part_beats(track, chords, melody):
    """What a track plays in one pass of a section, in beats from its start:
    (start, length, [midi notes])."""
    part, shift = track.get('part', 'chords'), 12 * int(track.get('octave', 0))
    out = []
    if part == 'chords':
        for b, beats, c in chords:
            out.append((b, beats, [x + shift for x in chord_notes(c)]))
    elif part == 'bass':
        for b, beats, c in chords:
            out.append((b, beats, [bass_note(c) + shift]))
    elif part == 'melody':
        for m in melody:
            out.append((float(m['beat']), float(m.get('len', 1)), [int(m['pitch']) + shift]))
    elif part == 'arp':
        step = float(track.get('step', 0.5))
        pattern = track.get('pattern', 'up')
        for b, beats, c in chords:
            notes = chord_notes(c)
            seq = notes + [notes[0] + 12]
            if pattern == 'updown':
                seq = seq + seq[-2:0:-1]
            elif pattern == 'down':
                seq = seq[::-1]
            k, t = 0, 0.0
            while t < beats - 1e-6:
                out.append((b + t, step, [seq[k % len(seq)] + shift]))
                k, t = k + 1, t + step
    return out


def resting(chords, key, beat):
    """Does `key` (a track id, or 'drums') rest at this beat: the chord
    playing then says so."""
    for b, ln, c in chords:
        if b <= beat + 1e-6 < b + ln:
            return key in (c.get('rest') or ())
    return False


def swung(beat, swing):
    """Off-beats (halfway through a beat) come a little late: up to a triplet feel."""
    if swing and abs((beat % 1) - 0.5) < 1e-6:
        return beat + swing / 6
    return beat


def render(song, loop=False, soundfont=SOUNDFONT, info=None):
    """The whole song as float32 stereo. loop: the tail (release, reverb)
    wraps round into the start, so it repeats without a seam. info: a dict
    that gets the timeline (for following along while it plays)."""
    song = normalize(song)
    bpb = int(song.get('beatsPerBar', 4))
    feel = song['feel']
    swing, human = float(feel.get('swing', 0)), float(feel.get('human', 0))
    seed = zlib.crc32((song.get('name') or 'song').encode())
    rng = np.random.default_rng(seed)
    passes, blocks, total = layout(song)
    clock = Clock(song, blocks, passes, total, rng)
    tail = 8.0
    end_s = clock.t(total)
    n = int((end_s + tail) * RATE) + 1
    mix = np.zeros((n, 2), dtype=np.float32)
    solo = any(t.get('solo') for t in song['tracks'])

    def when(beat):
        """A beat to seconds: swung, and a little off the grid if human."""
        t = clock.t(swung(beat, swing))
        if human:
            t += float(np.clip(rng.normal(0, human * 0.018), -0.045, 0.045))
        return max(0.0, t)

    def loud():
        return float(np.clip(1 + rng.normal(0, human * 0.12), 0.6, 1.3)) if human else 1.0

    def mixed(bl, key):
        m = (bl.get('mix') or {}).get(key) or {}
        return (m.get('on', True), float(m.get('volume', 1)))

    pad_ev, pluck_ev, midi_ev = {}, {}, {}
    last = {}  # track id -> the notes it's holding: the same again straight after are held on
    for bi, sec, start, beats in passes:
        bl = song['arrangement'][bi]
        chords, b = [], 0.0
        sbpb = section_bpb(song, sec)
        for c in sec['chords']:
            length = float(c.get('bars', 1)) * sbpb
            chords.append((b, length, c))
            b += length
        melody = [m for m in sec.get('melody', []) if float(m['beat']) < beats]
        roles = sec.get('parts') or {}
        for tr in song['tracks']:
            if tr.get('mute') or (solo and not tr.get('solo')):
                continue
            # what it plays in this section: its own part, unless the section says otherwise
            part = roles.get(tr['id']) or tr.get('part', 'chords')
            if part == 'rest':
                continue
            tr = dict(tr, part=part)
            on, gain = mixed(bl, tr['id'])
            if not on or gain <= 0:
                continue
            gain *= float(tr.get('volume', 1.0)) * float((sec.get('volume') or {}).get(tr['id'], 1.0))
            # the same notes again, straight after: held on, not struck again
            # (bass and chords; plucks always strike, there's nothing to hold)
            holds = part in ('bass', 'chords') and tr['type'] != 'pluck' and tr.get('hold', True)
            # less what falls on a chord this track sits out
            played = [p for p in part_beats(tr, chords, melody) if not resting(chords, tr['id'], p[0])]
            if tr['type'] != 'pluck' and legato_for(tr, sec, bl):
                played = legato(played)
            for s0, ln, notes in played:
                a = start + s0
                held = last.get(tr['id']) if holds else None
                if held and held['block'] == bi and held['notes'] == notes and abs(held['until'] - a) < 1e-6:
                    held['until'] = a + ln
                    held['extend'](a + ln)
                    continue
                t0 = when(a)
                if tr['type'] == 'pad':
                    over = float(tr.get('overlap', PAD_DEFAULTS['overlap'])) if part in ('chords', 'bass') else 1.0
                    rel = 0 if over > 1 else float(tr.get('release', PAD_DEFAULTS['release']))
                    lst = pad_ev.setdefault(tr['id'], [])
                    t1 = clock.t(swung(a + ln * over, swing)) + rel
                    lst.append((t0, t1 - t0, [hz(x) for x in notes], None, gain * loud()))
                    k = len(lst) - 1

                    def extend(until, lst=lst, k=k, over=over, rel=rel, ln=ln):
                        # the overlap past the last chord stays as it was
                        e = lst[k]
                        t1 = clock.t(swung(until + ln * (over - 1), swing)) + rel
                        lst[k] = (e[0], t1 - e[0]) + e[2:]
                elif tr['type'] == 'pluck':
                    strum = float(tr.get('strum', PLUCK_DEFAULTS['strum']))
                    for i, x in enumerate(notes):
                        pluck_ev.setdefault(tr['id'], []).append((t0 + i * strum, hz(x), gain * loud()))
                    extend = None
                elif tr['type'] == 'instrument':
                    t1 = clock.t(swung(a + ln, swing))
                    spread = human * 0.022 if len(notes) > 1 else 0
                    lst = midi_ev.setdefault(tr['id'], [])
                    first = len(lst)
                    for i, x in enumerate(notes):
                        lst.append((t0 + i * spread, max(t0 + i * spread + 0.02, t1), x, gain * loud()))

                    def extend(until, lst=lst, first=first):
                        t1 = clock.t(swung(until, swing))
                        for k in range(first, len(lst)):
                            e = lst[k]
                            lst[k] = (e[0], max(e[1], t1)) + e[2:]
                else:
                    extend = None
                if holds and extend:
                    last[tr['id']] = {'block': bi, 'notes': notes, 'until': a + ln, 'extend': extend}
        # the drums
        on, dgain = mixed(bl, 'drums')
        if on and dgain > 0:
            vols = sec.get('volume') or {}
            dgain *= float(song.get('drumVolume', 1.0)) * float(vols.get('drums', 1.0))
            for h in sec.get('drums', []):
                hb = float(h.get('beat', 0))
                if hb >= beats or resting(chords, 'drums', hb):
                    continue
                # each drum: in the song (the band), in the section, in the block
                kid = h.get('kind', 'low')
                kon, kgain = mixed(bl, 'drum:' + kid)
                kgain *= float((song.get('drumVolumes') or {}).get(kid, 1.0)) * float(vols.get('drum:' + kid, 1.0))
                if not kon or kgain <= 0:
                    continue
                kind = DRUMS.get(kid, DRUMS['low'])
                t = when(start + hb)
                g = dgain * kgain * float(h.get('volume', 1)) * loud()
                if kind[1] == 'synth':
                    hit(t, mix, g)
                elif kind[1] == 'kit':
                    midi_ev.setdefault('__kit', []).append((t, t + 0.2, kind[2], g))
                else:
                    # timpani: the root of the chord playing then, low
                    root = next((c for cb, cl, c in chords if cb <= hb < cb + cl), sec['chords'][0])
                    note = 36 + NOTE_NAMES.index(root.get('root', 'C'))
                    midi_ev.setdefault('__timpani', []).append((t, t + 1.5, note, g))
    for tr in song['tracks']:
        if tr['id'] in pad_ev:
            p = dict(PAD_DEFAULTS, **{k: v for k, v in tr.items() if k in PAD_DEFAULTS})
            pad_events(mix, pad_ev[tr['id']], p)
        if tr['id'] in pluck_ev:
            p = dict(PLUCK_DEFAULTS, **{k: v for k, v in tr.items() if k in PLUCK_DEFAULTS})
            pluck_events(mix, pluck_ev[tr['id']], p)
    if midi_ev:
        channels = []
        for tr in song['tracks']:
            if tr['id'] in midi_ev:
                channels.append((dict(INSTRUMENT_DEFAULTS, **{k: v for k, v in tr.items() if k in INSTRUMENT_DEFAULTS}), midi_ev[tr['id']], False))
        if '__timpani' in midi_ev:
            channels.append((dict(INSTRUMENT_DEFAULTS, program=47, reverb=70), midi_ev['__timpani'], False))
        if '__kit' in midi_ev:
            channels.append((dict(INSTRUMENT_DEFAULTS, program=0, reverb=50), midi_ev['__kit'], True))
        mix += fluid(channels, end_s + tail, n, soundfont)
    # fades, by block
    env = np.ones(n, dtype=np.float32)
    for x in blocks:
        bl = song['arrangement'][x['index']]
        sbpb = section_bpb(song, next(s for s in song['sections'] if s['id'] == x['section']))
        fi, fo = float(bl.get('fadeIn', 0) or 0) * sbpb, float(bl.get('fadeOut', 0) or 0) * sbpb
        if fi > 0:
            a, b = int(clock.t(x['start']) * RATE), int(clock.t(x['start'] + min(fi, x['beats'])) * RATE)
            env[a:b] *= np.linspace(0, 1, max(1, b - a), dtype=np.float32)
        if fo > 0:
            stop = x['start'] + x['beats']
            a, b = int(clock.t(stop - min(fo, x['beats'])) * RATE), int(clock.t(stop) * RATE)
            env[a:b] *= np.linspace(1, 0, max(1, b - a), dtype=np.float32)
            if x is blocks[-1]:
                env[b:] = 0
    mix *= env[:, None]
    end = int(end_s * RATE)
    if loop:
        rest = mix[end:]
        mix = mix[:end].copy()
        k = min(len(rest), end)
        mix[:k] += rest[:k]
    if info is not None:
        info['blocks'] = [dict(x, time=clock.t(x['start']), end=clock.t(x['start'] + x['beats'])) for x in blocks]
        info['beatTimes'] = [round(clock.t(i), 4) for i in range(int(math.ceil(total)) + 1)]
        info['length'] = len(mix) / RATE
    return mix

def master(mix, peak=0.89):
    m = float(np.abs(mix).max()) if len(mix) else 0
    return mix * (peak / m) if m > peak else mix


# ---------------------------------------------------------------------------
# the SoundFont instruments: a MIDI file, played by fluidsynth

def _varlen(v):
    out = [v & 0x7F]
    v >>= 7
    while v:
        out.insert(0, (v & 0x7F) | 0x80)
        v >>= 7
    return bytes(out)


def write_midi(path, channels, length_s):
    """channels: (settings, notes, is the drum kit); notes are (on s, off s,
    key, loudness 0..). Written at 60 bpm, 1000 ticks a beat: a tick is a
    millisecond, so tempo changes are already in the times."""
    events = [(0, 0, b'\xff\x51\x03' + struct.pack('>I', 1_000_000)[1:])]
    melodic = [c for c in range(16) if c != 9]
    k = 0
    for p, notes, kit in channels:
        if kit:
            ch = 9
        else:
            if k >= len(melodic):
                raise RuntimeError('Too many instrument tracks: at most %d' % len(melodic))
            ch = melodic[k]
            k += 1
            events.append((0, 1, bytes([0xC0 | ch, int(p['program']) & 0x7F])))
        events.append((0, 1, bytes([0xB0 | ch, 10, int(p['pan']) & 0x7F])))
        events.append((0, 1, bytes([0xB0 | ch, 91, int(p['reverb']) & 0x7F])))
        events.append((0, 1, bytes([0xB0 | ch, 7, 110])))
        # A note that starts again while it's still sounding (timing a little
        # off with "human", or the same note in the next chord): the earlier
        # one stops right there. Otherwise its stop, coming after the new
        # start, would silence the new note too.
        played = sorted((int(on * 1000), int(off * 1000), key, gain) for on, off, key, gain in notes if 0 <= key <= 127)
        nxt = {}
        for i in range(len(played) - 1, -1, -1):
            a, b, key, gain = played[i]
            later = nxt.get(key)
            if later is not None and later < b:
                b = later
            nxt[key] = a
            vel = max(1, min(127, int(round(p['velocity'] * gain))))
            events.append((a, 3, bytes([0x90 | ch, key, vel])))
            events.append((max(a + 1, b), 2, bytes([0x80 | ch, key, 0])))
    # silence to the end, so the release and the reverb are kept
    events.append((int(length_s * 1000), 4, b'\xff\x01\x00'))
    events.sort(key=lambda e: (e[0], e[1]))
    body, last = b'', 0
    for tick, _, data in events:
        body += _varlen(tick - last) + data
        last = tick
    body += b'\x00\xff\x2f\x00'
    with open(path, 'wb') as f:
        f.write(b'MThd' + struct.pack('>IHHH', 6, 0, 1, 1000))
        f.write(b'MTrk' + struct.pack('>I', len(body)) + body)


def fluid(channels, length_s, n, soundfont=SOUNDFONT):
    if not shutil.which('fluidsynth'):
        raise RuntimeError('fluidsynth is not installed (brew install fluid-synth)')
    if not os.path.exists(soundfont):
        raise RuntimeError('No SoundFont at %s (see music/README.md)' % soundfont)
    with tempfile.TemporaryDirectory() as tmp:
        mid, out = os.path.join(tmp, 'song.mid'), os.path.join(tmp, 'song.wav')
        write_midi(mid, channels, length_s)
        subprocess.run(['fluidsynth', '-ni', '-q', '-g', '0.5', '-r', str(RATE), '-O', 's16', '-T', 'wav', '-F', out, soundfont, mid],
                       check=True, capture_output=True)
        audio = read_wav(out)
    res = np.zeros((n, 2), dtype=np.float32)
    k = min(n, len(audio))
    res[:k] = audio[:k]
    return res

def read_wav(path):
    with wave.open(path, 'rb') as w:
        ch, frames = w.getnchannels(), w.readframes(w.getnframes())
    data = np.frombuffer(frames, dtype='<i2').astype(np.float32) / 32768.0
    data = data.reshape(-1, ch)
    return data if ch == 2 else np.repeat(data, 2, axis=1)


def write_wav(path, mix):
    pcm = (np.clip(mix, -1, 1) * 32767).astype('<i2')
    with wave.open(path, 'wb') as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(pcm.tobytes())


def wav_bytes(mix):
    import io
    buf = io.BytesIO()
    pcm = (np.clip(mix, -1, 1) * 32767).astype('<i2')
    with wave.open(buf, 'wb') as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(pcm.tobytes())
    return buf.getvalue()
