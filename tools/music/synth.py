"""Music for Tomorrowind's trailers and videos: synthesised pads and plucks,
and orchestral instruments played from a SoundFont through fluidsynth.

A song (a plain dict, saved as JSON in music/songs/):

    {
      "name": "trailer", "bpm": 44, "repeat": 2,
      "chords": [ {"root": "D", "octave": 3, "quality": "m", "voicing": "close", "bars": 1}, ... ],
      "melody": [ {"beat": 0, "len": 2, "pitch": 62}, ... ],      beats from the start of one pass
      "drums": [0, 4],                                             bars (in one pass) with a low drum
      "tracks": [ {"type": "pad" | "pluck" | "instrument", "part": "chords" | "bass" | "melody" | "arp",
                   "volume": 1, "octave": 0, "mute": false, ...the type's own settings} ]
    }

The chords play `repeat` times; the melody and the drums go round with them.
render(song) returns float32 stereo samples at RATE. pad(total) is the
trailer's own soundtrack, exactly as it always was.
"""
import math
import os
import shutil
import struct
import subprocess
import tempfile
import wave

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
    """A soft low drum."""
    length = int(1.4 * RATE)
    tt = np.arange(length) / RATE
    wave_ = np.sin(2 * np.pi * (46 + 30 * np.exp(-tt * 18)) * tt) * np.exp(-tt * 3.2) * 0.42 * gain
    add(mix, np.stack([wave_, wave_], axis=1).astype(np.float32), at)


def add(mix, sound, at, gain=1.0):
    a = int(at * RATE)
    if a >= len(mix):
        return
    n = min(len(sound), len(mix) - a)
    mix[a:a + n] += sound[:n] * gain


# ---------------------------------------------------------------------------
# synths

def pad_events(out, events, p):
    """Pad notes into `out`: events are (start s, length s, frequencies Hz[, end s])."""
    n = len(out)
    layers = ((1.0, 1.0), (p['detune'], p['shimmer']), (0.5, p['sub']), (2.0, p['air']))
    partials = WAVES.get(p.get('wave', 'sine'), WAVES['sine'])
    for ev in events:
        start, length_s, freqs = ev[:3]
        end = ev[3] if len(ev) > 3 else start + length_s
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
        out[a:b, 0] += (tone * env * p['level']).astype(np.float32)
        out[a:b, 1] += (right * env * p['level']).astype(np.float32)


def pluck_events(out, events, p):
    """Plucked strings (harp, lute): each harmonic dies away, the high ones first.
    events are (start s, frequency Hz)."""
    n = len(out)
    for start, f in events:
        a = int(start * RATE)
        length = min(n - a, int((p['decay'] * 2.2) * RATE))
        if length <= 0:
            continue
        tt = np.arange(length) / RATE
        left = np.zeros(length)
        right = np.zeros(length)
        k = 1
        while k * f < 9000 and k <= 16:
            g = (p['brightness'] ** (k - 1)) / k ** 0.5
            d = np.exp(-tt * k ** 0.8 / max(0.05, p['decay']))
            left += g * d * np.sin(2 * np.pi * f * k * tt)
            right += g * d * np.sin(2 * np.pi * f * k * p['width'] * tt + 0.4)
            k += 1
        click = np.minimum(1, tt / 0.003)
        out[a:a + length, 0] += (left * click * p['level']).astype(np.float32)
        out[a:a + length, 1] += (right * click * p['level']).astype(np.float32)


# ---------------------------------------------------------------------------
# a song

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


def timeline(song):
    """Chord events (start beat, beats, notes) for the whole song, the melody's
    notes, the drum bars, and the length in beats."""
    per_bar = int(song.get('beatsPerBar', 4))
    chords, beat = [], 0.0
    one = sum(float(c.get('bars', 1)) for c in song['chords']) * per_bar
    for r in range(int(song.get('repeat', 1))):
        for c in song['chords']:
            beats = float(c.get('bars', 1)) * per_bar
            chords.append((beat, beats, chord_notes(c)))
            beat += beats
    melody = []
    drums = []
    for r in range(int(song.get('repeat', 1))):
        for m in song.get('melody', []):
            if float(m['beat']) < one:
                melody.append((r * one + float(m['beat']), float(m.get('len', 1)), int(m['pitch'])))
        for bar in song.get('drums', []):
            if bar * per_bar < one:
                drums.append(r * one + bar * per_bar)
    return chords, melody, drums, beat


def part_notes(track, chords, melody, beat_s):
    """What a track plays: (start s, length s, [midi notes])."""
    part, shift = track.get('part', 'chords'), 12 * int(track.get('octave', 0))
    out = []
    if part == 'chords':
        for b, beats, notes in chords:
            out.append((b * beat_s, beats * beat_s, [x + shift for x in notes]))
    elif part == 'bass':
        for b, beats, notes in chords:
            out.append((b * beat_s, beats * beat_s, [notes[0] - 12 + shift]))
    elif part == 'melody':
        for b, beats, pitch in melody:
            out.append((b * beat_s, beats * beat_s, [pitch + shift]))
    elif part == 'arp':
        step = float(track.get('step', 0.5))  # beats between notes
        pattern = track.get('pattern', 'up')
        for b, beats, notes in chords:
            seq = notes + [notes[0] + 12]
            if pattern == 'updown':
                seq = seq + seq[-2:0:-1]
            elif pattern == 'down':
                seq = seq[::-1]
            k, t = 0, 0.0
            while t < beats - 1e-6:
                out.append(((b + t) * beat_s, step * beat_s, [seq[k % len(seq)] + shift]))
                k, t = k + 1, t + step
    return out


def render(song, loop=False, soundfont=SOUNDFONT):
    """The whole song as float32 stereo. loop: the tail (release, reverb)
    wraps round into the start, so it repeats without a seam."""
    bpm = float(song.get('bpm', 60))
    beat_s = 60.0 / bpm
    chords, melody, drums, beats = timeline(song)
    total = beats * beat_s
    tail = 8.0
    n = int((total + tail) * RATE)
    mix = np.zeros((n, 2), dtype=np.float32)
    solo = any(t.get('solo') for t in song['tracks'])
    midi_tracks = []
    for tr in song['tracks']:
        if tr.get('mute') or (solo and not tr.get('solo')):
            continue
        vol = float(tr.get('volume', 1.0))
        notes = part_notes(tr, chords, melody, beat_s)
        layer = np.zeros_like(mix)
        if tr['type'] == 'pad':
            p = dict(PAD_DEFAULTS, **{k: v for k, v in tr.items() if k in PAD_DEFAULTS})
            over = p['overlap'] if tr.get('part', 'chords') in ('chords', 'bass') else 1.0
            pad_events(layer, [(s, d * over + (0 if over > 1 else p['release']), [hz(x) for x in ns]) for s, d, ns in notes], p)
        elif tr['type'] == 'pluck':
            p = dict(PLUCK_DEFAULTS, **{k: v for k, v in tr.items() if k in PLUCK_DEFAULTS})
            ev = []
            for s, d, ns in notes:
                for i, x in enumerate(ns):
                    ev.append((s + i * p['strum'], hz(x)))
            pluck_events(layer, ev, p)
        elif tr['type'] == 'instrument':
            midi_tracks.append((tr, notes))
            continue
        mix += layer * vol
    if midi_tracks:
        mix += fluid(midi_tracks, bpm, total + tail, n, soundfont)
    for b in drums:
        hit(b * beat_s, mix, float(song.get('drumVolume', 1.0)))
    end = int(total * RATE)
    if loop:
        rest = mix[end:]
        mix = mix[:end].copy()
        k = min(len(rest), end)
        mix[:k] += rest[:k]
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


def write_midi(path, midi_tracks, bpm, length_s):
    tpb = 480
    sec_tick = 60.0 / bpm / tpb
    events = []  # (tick, order, bytes)
    events.append((0, 0, b'\xff\x51\x03' + struct.pack('>I', int(60_000_000 / bpm))[1:]))
    channels = [c for c in range(16) if c != 9]
    for (tr, notes), ch in zip(midi_tracks, channels):
        p = dict(INSTRUMENT_DEFAULTS, **{k: v for k, v in tr.items() if k in INSTRUMENT_DEFAULTS})
        vel = max(1, min(127, int(p['velocity'] * float(tr.get('volume', 1.0)))))
        events.append((0, 1, bytes([0xC0 | ch, int(p['program']) & 0x7F])))
        events.append((0, 1, bytes([0xB0 | ch, 10, int(p['pan']) & 0x7F])))
        events.append((0, 1, bytes([0xB0 | ch, 91, int(p['reverb']) & 0x7F])))
        events.append((0, 1, bytes([0xB0 | ch, 7, 110])))
        for s, d, ns in notes:
            on, off = int(s / sec_tick), int((s + d) / sec_tick)
            for x in ns:
                if 0 <= x <= 127:
                    events.append((on, 3, bytes([0x90 | ch, x, vel])))
                    events.append((max(on + 1, off), 2, bytes([0x80 | ch, x, 0])))
    # silence to the end, so the release and the reverb are kept
    events.append((int(length_s / sec_tick), 4, b'\xff\x01\x00'))
    events.sort(key=lambda e: (e[0], e[1]))
    body, last = b'', 0
    for tick, _, data in events:
        body += _varlen(tick - last) + data
        last = tick
    body += b'\x00\xff\x2f\x00'
    with open(path, 'wb') as f:
        f.write(b'MThd' + struct.pack('>IHHH', 6, 0, 1, tpb))
        f.write(b'MTrk' + struct.pack('>I', len(body)) + body)


def fluid(midi_tracks, bpm, length_s, n, soundfont=SOUNDFONT):
    if not shutil.which('fluidsynth'):
        raise RuntimeError('fluidsynth is not installed (brew install fluid-synth)')
    if not os.path.exists(soundfont):
        raise RuntimeError('no SoundFont at %s (see music/README.md)' % soundfont)
    with tempfile.TemporaryDirectory() as tmp:
        mid, out = os.path.join(tmp, 'song.mid'), os.path.join(tmp, 'song.wav')
        write_midi(mid, midi_tracks, bpm, length_s)
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
