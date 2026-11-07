#!/usr/bin/env python3
"""Cuts the trailer from the frames filmed by tools/film_trailer.sh.

    tools/film_trailer.sh .playtest/take
    tools/make_trailer.py .playtest/take trailer/ [--music file]

    tools/film_trailer.sh .playtest/take2 trailer2
    tools/make_trailer.py .playtest/take2 trailer/ --cut 0.2

Writes trailer/tomorrowind-trailer-16x9.mp4 (YouTube) and -4x5.mp4 (Instagram);
the 0.2 cut (what's new in that version) writes tomorrowind-0.2-trailer-*.mp4.
Needs ffmpeg, Pillow and numpy (the sound is mixed from the game's own effects
and an original pad generated here; --music replaces the pad).

Captions use MysticCards, the Morrowind-style font that ships with OpenMW under
the SIL Open Font License.
"""
import argparse
import math
import os
import re
import subprocess
import sys
import tempfile

import numpy as np
from PIL import Image, ImageDraw, ImageFont

FPS = 30
RATE = 44100
OPENMW_FONTS = '/Applications/OpenMW 0.52 RC1/OpenMW.app/Contents/Resources/resources/vfs/fonts'
FONT = os.path.join(OPENMW_FONTS, 'MysticCards.ttf')
SOUNDS = os.path.expanduser('~/Downloads/Morrowind/Data Files/Sound')
GOLD = (223, 201, 159)
BRIGHT = (255, 232, 184)
PANEL = (0, 0, 0, 205)
EDGE = (172, 141, 92)
REPO = 'github.com/studioroor/tomorrowind'

# The edit. shot: name in the scene, start: seconds into that shot, dur: seconds
# on screen, grade: extra ffmpeg filter (evening shots need lifting).
BASE = 'eq=gamma=1.12:contrast=1.05:saturation=1.18'
EVENING = 'eq=gamma=1.55:contrast=1.03:saturation=1.15'
NIGHT = 'eq=gamma=1.95:saturation=1.05'
EDIT_01 = [
    dict(shot='dawn', start=0.5, dur=3.6, title=True, hit=True),
    dict(shot='growth1', start=0.0, dur=4.6, rate=1.8, caption='Found a House Hlaalu colony anywhere in Morrowind'),
    dict(shot='rise', start=0.0, dur=3.6, rate=1.55, caption='Watch every building rise from the ground'),
    dict(shot='miner', start=1.5, dur=2.0, caption='Give your settlers jobs: mine, farm, chop, smelt'),
    dict(shot='smelter', start=1.5, dur=2.0, caption='Give your settlers jobs: mine, farm, chop, smelt'),
    dict(shot='carry', start=0.3, dur=2.3, caption='They haul everything themselves'),
    dict(shot='growth2', start=0.0, dur=3.7, rate=2.0, hit=True, caption='Your village grows: houses, tents, curving walls'),
    dict(shot='campfire', start=1.0, dur=2.8, grade=EVENING, caption='Everyone keeps their own day: work, eat, rest, sleep'),
    dict(shot='dusk', start=1.0, dur=2.4, grade=EVENING, caption='Everyone keeps their own day: work, eat, rest, sleep'),
    dict(shot='sleep', start=1.0, dur=2.3, grade=NIGHT, caption='Everyone keeps their own day: work, eat, rest, sleep'),
    dict(shot='attack', start=10.0, dur=3.6, hit=True, caption='Guards defend the colony and take attackers prisoner'),
    dict(shot='ending', start=0.5, dur=6.0, ending=True, hit=True),
]
# what's new in 0.2, filmed by the trailer2 scene
HOME = 'Walk into any house: your settlers live there'
EDIT_02 = [
    dict(shot='open', start=0.5, dur=3.6, title=True, hit=True),
    dict(shot='caravan', start=3.5, dur=3.4, caption='Caravans come to trade at your market'),
    dict(shot='stairs', start=1.5, dur=3.0, caption='Build stairs, walkways and rope bridges'),
    dict(shot='bridge', start=0.5, dur=3.5, caption='Build stairs, walkways and rope bridges'),
    dict(shot='move', start=0.5, dur=4.0, rate=2.0, caption='Move a building: up go the scaffolds, over it slides'),
    dict(shot='home', start=0.5, dur=3.2, grade=EVENING, hit=True, caption=HOME),
    dict(shot='shrine', start=1.0, dur=2.6, grade=EVENING, fire=True, caption='Furnish them: rugs, tapestries, candles, shrines'),
    dict(shot='reader', start=1.0, dur=2.6, grade=EVENING, fire=True, caption='Furnish them: rugs, tapestries, candles, shrines'),
    dict(shot='ending', start=0.5, dur=6.0, ending=True, hit=True),
]
CUTS = {
    '0.1': dict(edit=EDIT_01, subtitle='A House Hlaalu colony builder for OpenMW', name='tomorrowind-trailer'),
    '0.2': dict(edit=EDIT_02, subtitle="What's new in version 0.2", name='tomorrowind-0.2-trailer'),
}
EDIT = EDIT_01
SUBTITLE = CUTS['0.1']['subtitle']
CROSSFADE = 0.25


def shots_from_log(path):
    start, shots = {}, {}
    for line in open(path, errors='ignore'):
        m = re.search(r'\[TRAILER\]\s+shot\s+(\w+)\s+from\s+(\d+)\s+at\s+([\d.]+)', line)
        if m:
            start[m[1]] = (int(m[2]), float(m[3]))
        m = re.search(r'\[TRAILER\]\s+shot\s+(\w+)\s+to\s+(\d+)', line)
        if m:
            shots[m[1]] = (start[m[1]][0], int(m[2]))
    return shots


def text_size(draw, text, font):
    box = draw.textbbox((0, 0), text, font=font)
    return box[2] - box[0], box[3] - box[1], box[1]


def wrap(draw, text, font, width):
    lines, line = [], ''
    for word in text.split():
        trial = (line + ' ' + word).strip()
        if text_size(draw, trial, font)[0] <= width:
            line = trial
        else:
            lines.append(line)
            line = word
    lines.append(line)
    return lines


def panel_text(img, lines, font, centre_y, color=GOLD, pad=(34, 18), gap=10):
    """Text in a Morrowind-style panel: black, with a thin gold edge."""
    draw = ImageDraw.Draw(img, 'RGBA')
    sizes = [text_size(draw, l, font) for l in lines]
    w = max(s[0] for s in sizes) + pad[0] * 2
    h = sum(s[1] for s in sizes) + gap * (len(lines) - 1) + pad[1] * 2
    x0, y0 = (img.width - w) // 2, int(centre_y - h / 2)
    draw.rectangle((x0, y0, x0 + w, y0 + h), fill=PANEL, outline=EDGE, width=3)
    y = y0 + pad[1]
    for line, s in zip(lines, sizes):
        draw.text(((img.width - s[0]) // 2, y - s[2]), line, font=font, fill=color)
        y += s[1] + gap


def glow_text(img, text, font, centre_y, color=BRIGHT):
    """Large text with a soft dark halo, for the title."""
    from PIL import ImageFilter
    draw = ImageDraw.Draw(img)
    w, h, top = text_size(draw, text, font)
    x, y = (img.width - w) // 2, int(centre_y - h / 2 - top)
    halo = Image.new('RGBA', img.size, (0, 0, 0, 0))
    ImageDraw.Draw(halo).text((x, y), text, font=font, fill=(0, 0, 0, 255), stroke_width=6, stroke_fill=(0, 0, 0, 255))
    halo = halo.filter(ImageFilter.GaussianBlur(14))
    img.alpha_composite(halo)
    img.alpha_composite(halo)
    ImageDraw.Draw(img).text((x, y), text, font=font, fill=color, stroke_width=2, stroke_fill=(70, 48, 20))


def card(kind, value, size, path):
    """A transparent overlay: a caption, the title or the end card."""
    w, h = size
    img = Image.new('RGBA', size, (0, 0, 0, 0))
    wide = w > h
    scale = w / 1920 if wide else w / 1080
    if kind == 'caption':
        font = ImageFont.truetype(FONT, int((54 if wide else 62) * scale))
        lines = wrap(ImageDraw.Draw(img), value, font, w * 0.86)
        panel_text(img, lines, font, h * (0.86 if wide else 0.84))
    elif kind == 'title':
        glow_text(img, 'Tomorrowind', ImageFont.truetype(FONT, int((190 if wide else 142) * scale)), h * 0.42)
        font = ImageFont.truetype(FONT, int((54 if wide else 60) * scale))
        lines = wrap(ImageDraw.Draw(img), SUBTITLE, font, w * 0.86)
        panel_text(img, lines, font, h * 0.60)
    elif kind == 'ending':
        glow_text(img, 'Tomorrowind', ImageFont.truetype(FONT, int((170 if wide else 142) * scale)), h * 0.34)
        small = ImageFont.truetype(FONT, int((46 if wide else 52) * scale))
        panel_text(img, wrap(ImageDraw.Draw(img), 'Free mod for OpenMW 0.52 and later', small, w * 0.86), small, h * 0.50)
        link = ImageFont.truetype(FONT, int((60 if wide else 56) * scale))
        panel_text(img, wrap(ImageDraw.Draw(img), REPO, link, w * 0.92), link, h * 0.63, color=BRIGHT)
        invite = ['Got an idea or found a bug? Open an issue on GitHub'] if wide \
            else ['Got an idea or found a bug?', 'Open an issue on GitHub']
        panel_text(img, invite, small, h * 0.76)
    img.save(path)


def run(cmd):
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode:
        sys.exit('command failed: ' + ' '.join(cmd[:8]) + '\n' + r.stderr[-1500:])


def render_clip(i, clip, frames_dir, names, shots, size, tmp):
    """One shot: frames, grade, framing, overlay with fades."""
    w, h = size
    first, last = shots[clip['shot']]
    a = first - 1 + int(clip['start'] * FPS)
    n = int(round((clip['dur'] + CROSSFADE) * FPS))
    rate = clip.get('rate', 1)  # how many filmed frames go by per frame shown
    if a + int(n * rate) > last + 1:
        sys.exit('shot %s has only %d frames, needs %d' % (clip['shot'], last - a, int(n * rate)))
    listing = os.path.join(tmp, 'c%d.txt' % i)
    with open(listing, 'w') as f:
        for k in range(n):
            f.write("file '%s'\nduration %f\n" % (os.path.join(frames_dir, names[a + int(k * rate)]), 1 / FPS))
    # 16:9 as filmed; 4:5 takes the middle of the picture, enlarged
    # (the frames are JPEGs: full-range colour, converted to the standard range)
    frame = 'scale=%d:%d:in_range=full:out_range=tv,crop=%d:%d' % (int(h * 16 / 9) + 1 if w < h else w, h, w, h)
    grade = clip.get('grade', BASE)
    filters = ','.join(x for x in (grade, frame, 'fps=%d' % FPS, 'format=yuv420p') if x)

    overlay = None
    if clip.get('title'):
        overlay = ('title', '')
    elif clip.get('ending'):
        overlay = ('ending', '')
    elif clip.get('caption'):
        overlay = ('caption', clip['caption'])
    out = os.path.join(tmp, 'c%d.mp4' % i)
    cmd = ['ffmpeg', '-y', '-hide_banner', '-f', 'concat', '-safe', '0', '-i', listing]
    if overlay:
        png = os.path.join(tmp, 'o%d.png' % i)
        card(overlay[0], overlay[1], size, png)
        d = n / FPS
        # a caption carried over from the previous clip doesn't fade in again
        same_prev = i > 0 and EDIT[i - 1].get('caption') == clip.get('caption') and clip.get('caption')
        same_next = i + 1 < len(EDIT) and EDIT[i + 1].get('caption') == clip.get('caption') and clip.get('caption')
        fades = []
        if not same_prev:
            fades.append('fade=t=in:st=%f:d=0.35:alpha=1' % (0.15 if overlay[0] == 'caption' else 0.6))
        if not same_next and overlay[0] != 'ending':
            fades.append('fade=t=out:st=%f:d=0.3:alpha=1' % max(0, d - CROSSFADE - 0.35))
        chain = 'format=rgba' + ''.join(',' + x for x in fades)
        cmd += ['-loop', '1', '-t', '%f' % d, '-i', png, '-filter_complex',
                '[0:v]%s[v];[1:v]%s[o];[v][o]overlay=shortest=1:format=auto,format=yuv420p[out]' % (filters, chain),
                '-map', '[out]']
    else:
        cmd += ['-vf', filters]
    cmd += ['-frames:v', str(n), '-c:v', 'libx264', '-crf', '14', '-preset', 'medium', '-r', str(FPS), out]
    run(cmd)
    return out


def join_clips(clips, size, out_video, tmp):
    """Crossfades all clips together, fading in from and out to black."""
    cmd = ['ffmpeg', '-y', '-hide_banner']
    for c in clips:
        cmd += ['-i', c]
    parts, label, offset = [], '0:v', 0.0
    for i in range(1, len(clips)):
        offset += EDIT[i - 1]['dur']
        parts.append('[%s][%d:v]xfade=transition=fade:duration=%f:offset=%f[x%d]' % (label, i, CROSSFADE, offset, i))
        label = 'x%d' % i
    total = sum(c['dur'] for c in EDIT) + CROSSFADE
    parts.append('[%s]fade=t=in:st=0:d=0.8,fade=t=out:st=%f:d=0.6,format=yuv420p[out]' % (label, total - 0.6))
    cmd += ['-filter_complex', ';'.join(parts), '-map', '[out]', '-c:v', 'libx264', '-crf', '18', '-preset', 'slow',
            '-r', str(FPS), '-pix_fmt', 'yuv420p', '-color_range', 'tv', out_video]
    run(cmd)
    return total


def clip_starts():
    starts, t = [], 0.0
    for c in EDIT:
        starts.append(t)
        t += c['dur']
    return starts


def load_sound(path):
    r = subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-i', path, '-f', 'f32le', '-ac', '2', '-ar', str(RATE), '-'],
                       capture_output=True)
    if r.returncode or not r.stdout:
        sys.exit('cannot read sound ' + path)
    return np.frombuffer(r.stdout, dtype=np.float32).reshape(-1, 2).copy()


def add(mix, sound, at, gain=1.0):
    a = int(at * RATE)
    if a >= len(mix):
        return
    n = min(len(sound), len(mix) - a)
    mix[a:a + n] += sound[:n] * gain


def pad(total):
    """An original slow pad in D minor, with a low hit on the big moments."""
    n = int(total * RATE)
    t = np.arange(n) / RATE
    chords = [(146.83, 174.61, 220.0), (116.54, 174.61, 233.08), (130.81, 196.0, 261.63), (110.0, 164.81, 220.0)]
    out = np.zeros((n, 2), dtype=np.float32)
    bar = total / (len(chords) * 2)
    for i in range(len(chords) * 2):
        chord = chords[i % len(chords)]
        a, b = int(i * bar * RATE), min(n, int((i + 1.35) * bar * RATE))
        tt = t[a:b] - t[a]
        length = b - a
        env = np.minimum(np.minimum(tt / 1.2, 1.0), (length / RATE - tt) / 1.6).clip(0, 1) ** 1.2
        tone = np.zeros(length)
        right = np.zeros(length)
        for f in chord:
            for det, gain in ((1.0, 1.0), (1.003, 0.6), (0.5, 0.5), (2.0, 0.14)):
                tone += gain * np.sin(2 * np.pi * f * det * tt)
                right += gain * np.sin(2 * np.pi * f * det * 1.0015 * tt + 0.7)
        out[a:b, 0] += (tone * env * 0.05).astype(np.float32)
        out[a:b, 1] += (right * env * 0.05).astype(np.float32)
    return out


def hit(at, mix):
    """A soft low drum."""
    length = int(1.4 * RATE)
    tt = np.arange(length) / RATE
    wave = np.sin(2 * np.pi * (46 + 30 * np.exp(-tt * 18)) * tt) * np.exp(-tt * 3.2) * 0.42
    add(mix, np.stack([wave, wave], axis=1).astype(np.float32), at)


def impacts(log, shots_at):
    """When tool strikes happened during each filmed shot, from the game's log."""
    out = {}
    def seconds(stamp):
        h, m, s = stamp.split(':')
        return int(h) * 3600 + int(m) * 60 + float(s)
    starts = {}
    for line in open(log, errors='ignore'):
        stamp = re.match(r'\[(\d+:\d+:[\d.]+)', line)
        if not stamp:
            continue
        m = re.search(r'\[TRAILER\]\s+shot\s+(\w+)\s+from', line)
        if m:
            starts[m[1]] = seconds(stamp[1])
            out[m[1]] = []
        m = re.search(r'impact (.+?) pitch=([\d.]+)', line)
        if m:
            for name, t0 in starts.items():
                d = seconds(stamp[1]) - t0
                if 0 <= d < 60:
                    out[name].append((d, m[1], float(m[2])))
    return out


SOUND_FILES = {
    'Light Armor Hit': 'Fx/Light Armor Hit.wav',
    'Heavy Armor Hit': 'Fx/Heavy Armor Hit.wav',
    'Repair': 'Fx/item/repair.wav',
    'Body Fall Small': 'Fx/bodyfallSML.wav',
}


def repitch(sound, pitch):
    idx = np.arange(0, len(sound) - 1, pitch)
    left = np.interp(idx, np.arange(len(sound)), sound[:, 0])
    right = np.interp(idx, np.arange(len(sound)), sound[:, 1])
    return np.stack([left, right], axis=1).astype(np.float32)


def make_audio(take_log, total, out, music):
    n = int((total + 0.5) * RATE)
    mix = np.zeros((n, 2), dtype=np.float32)
    starts = clip_starts()
    # ambience: wind everywhere, fire on the evening shots
    wind = load_sound(os.path.join(SOUNDS, 'Fx/envrn/wind_lt.wav'))
    loops = np.tile(wind, (n // len(wind) + 1, 1))[:n]
    mix += loops * 0.10
    fire = load_sound(os.path.join(SOUNDS, 'Fx/envrn/fire.wav'))
    strikes = impacts(take_log, None)
    cache = {}
    for clip, at in zip(EDIT, starts):
        name = clip['shot']
        if name in ('campfire', 'smelter') or clip.get('fire'):
            add(mix, fire[:int((clip['dur'] + 0.3) * RATE)], at, 0.5)
        # builders in the sped-up shots would be a rattle: only real-time shots
        if name in ('rise', 'miner', 'smelter'):
            gain = {'rise': 0.28, 'miner': 0.6, 'smelter': 0.6}[name]
            speed = (2 if name == 'rise' else 1) * clip.get('rate', 1)
            for d, sound, pitch in strikes.get(name, []):
                t = (d - clip['start']) / speed
                if 0 <= t < clip['dur']:
                    if sound not in cache:
                        cache[sound] = load_sound(os.path.join(SOUNDS, SOUND_FILES[sound]))
                    add(mix, repitch(cache[sound], pitch), at + t, gain)
        if name == 'attack':
            for sound, t, g in (('Fx/swoosh 1.wav', 0.4, 0.5), ('Fx/Medium Armor Hit.wav', 0.75, 0.55), ('Fx/swoosh 3.wav', 1.5, 0.5),
                                ('Fx/Heavy Armor Hit.wav', 1.85, 0.55), ('Fx/swoosh 2.wav', 2.4, 0.5), ('Fx/body hit.wav', 2.7, 0.6)):
                add(mix, load_sound(os.path.join(SOUNDS, sound)), at + t, g)
    # music
    if music:
        track = load_sound(music)
        track = track[:n]
        env = np.ones(len(track))
        fade = int(2 * RATE)
        env[-fade:] = np.linspace(1, 0, fade)
        mix[:len(track)] += track * env[:, None] * 0.55
    else:
        mix[:int(total * RATE)] += pad(total)[:int(total * RATE)]
        for i, clip in enumerate(EDIT):
            if clip.get('hit'):
                hit(starts[i], mix)
    # overall fades and a safe peak
    fade_in, fade_out = int(0.8 * RATE), int(1.2 * RATE)
    end = int(total * RATE)
    mix[:fade_in] *= np.linspace(0, 1, fade_in)[:, None]
    mix[end - fade_out:end] *= np.linspace(1, 0, fade_out)[:, None]
    mix[end:] = 0
    peak = float(np.abs(mix).max())
    mix *= 0.89 / peak
    print('audio peak before normalising: %.2f' % peak)
    raw = out + '.raw'
    mix[:end].tofile(raw)
    run(['ffmpeg', '-y', '-hide_banner', '-f', 'f32le', '-ar', str(RATE), '-ac', '2', '-i', raw, '-c:a', 'pcm_s16le', out])
    os.remove(raw)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('take')
    ap.add_argument('out')
    ap.add_argument('--music')
    ap.add_argument('--only', choices=['16x9', '4x5'])
    ap.add_argument('--cut', choices=sorted(CUTS), default='0.1')
    args = ap.parse_args()
    global EDIT, SUBTITLE
    cut = CUTS[args.cut]
    EDIT, SUBTITLE = cut['edit'], cut['subtitle']
    frames_dir = os.path.abspath(os.path.join(args.take, 'userdata/screenshots'))
    log = os.path.join(args.take, 'stdout.log')
    names = sorted(os.listdir(frames_dir), key=lambda x: int(re.findall(r'\d+', x)[0]))
    shots = shots_from_log(log)
    os.makedirs(args.out, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=args.out) as tmp:
        total = sum(c['dur'] for c in EDIT) + CROSSFADE
        audio = os.path.join(tmp, 'mix.wav')
        make_audio(log, total, audio, args.music)
        for label, size in (('16x9', (1920, 1080)), ('4x5', (1080, 1350))):
            if args.only and args.only != label:
                continue
            clips = [render_clip(i, c, frames_dir, names, shots, size, tmp) for i, c in enumerate(EDIT)]
            silent = os.path.join(tmp, label + '.mp4')
            join_clips(clips, size, silent, tmp)
            final = os.path.join(args.out, '%s-%s.mp4' % (cut['name'], label))
            run(['ffmpeg', '-y', '-hide_banner', '-i', silent, '-i', audio, '-c:v', 'copy', '-c:a', 'aac', '-b:a', '256k',
                 '-shortest', '-movflags', '+faststart', final])
            print('wrote', final, '%.1f s' % total)


if __name__ == '__main__':
    main()
