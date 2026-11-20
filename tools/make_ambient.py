#!/usr/bin/env python3
"""Cuts ambient loops and stills from the frames filmed by tools/film_ambient.sh.

    tools/film_ambient.sh .playtest/amb
    tools/make_ambient.py .playtest/amb [out-dir]      (default: trailer/ambient)

For every shot in the take (see the scene's log: "[AMBIENT] shot <name> from
<n>" / "to <n>") this writes:
  ambient-<name>.mp4   a seamless loop: the end crossfades into the start
  stills/<name>-<s>.jpg   a full-size frame every few seconds, to pick the
                          banner and the other pictures from (make_banners.py)
and ambient.mp4, the shots one after another. Needs ffmpeg.
"""
import os
import re
import subprocess
import sys
import tempfile

FPS = 30
FADE = 2.0        # seconds of crossfade where a loop wraps around
STILL_EVERY = 5   # seconds between stills
GRADE = 'eq=gamma=1.28:contrast=1.06:saturation=1.15'


def shots_from_log(path):
    shots, order = {}, []
    with open(path, errors='replace') as f:
        for line in f:
            m = re.search(r'\[AMBIENT\]\s+shot\s+(\S+)\s+(from|to)\s+(\d+)', line)
            if m:
                name, which, n = m.group(1), m.group(2), int(m.group(3))
                if name not in shots:
                    shots[name] = {}
                    order.append(name)
                shots[name][which] = n
    return [(name, shots[name]['from'], shots[name]['to']) for name in order if 'to' in shots[name]]


def run(cmd):
    subprocess.run(cmd, check=True)


def frames_list(names, frames_dir, a, b, path):
    """An ffmpeg concat list of frames a..b (1-based, as the scene counts them)."""
    with open(path, 'w') as f:
        for k in range(a - 1, b):
            f.write("file '%s'\nduration %f\n" % (os.path.join(frames_dir, names[k]), 1 / FPS))
    return path


def main():
    take = sys.argv[1]
    out = sys.argv[2] if len(sys.argv) > 2 else 'trailer/ambient'
    os.makedirs(os.path.join(out, 'stills'), exist_ok=True)
    frames_dir = os.path.abspath(os.path.join(take, 'userdata/screenshots'))
    names = sorted(os.listdir(frames_dir), key=lambda x: int(re.findall(r'\d+', x)[0]))
    shots = shots_from_log(os.path.join(take, 'stdout.log'))
    if not shots:
        sys.exit('no shots in the log')
    loops = []
    with tempfile.TemporaryDirectory() as tmp:
        for name, a, b in shots:
            n = b - a + 1
            seconds = n / FPS
            print('%s: frames %d..%d, %.1f s' % (name, a, b, seconds))
            lst = frames_list(names, frames_dir, a, b, os.path.join(tmp, name + '.txt'))
            plain = os.path.join(tmp, name + '.mp4')
            # the frames are JPEGs: full-range colour, converted to the standard range
            run(['ffmpeg', '-y', '-loglevel', 'error', '-f', 'concat', '-safe', '0', '-i', lst,
                 '-vf', 'scale=in_range=full:out_range=tv,%s,fps=%d,format=yuv420p' % (GRADE, FPS),
                 '-c:v', 'libx264', '-crf', '16', '-preset', 'medium', plain])
            # seamless: the shot from FADE on, its last FADE seconds fading into its first
            loop = os.path.join(out, 'ambient-%s.mp4' % name)
            body = seconds - FADE
            run(['ffmpeg', '-y', '-loglevel', 'error', '-i', plain, '-filter_complex',
                 '[0]trim=start=%f,setpts=PTS-STARTPTS[main];'
                 '[0]trim=end=%f,setpts=PTS-STARTPTS[head];'
                 '[main][head]xfade=transition=fade:duration=%f:offset=%f,format=yuv420p[v]' % (FADE, FADE, FADE, body - FADE),
                 '-map', '[v]', '-c:v', 'libx264', '-crf', '16', '-preset', 'medium', '-r', str(FPS), loop])
            loops.append(loop)
            for s in range(0, int(seconds), STILL_EVERY):
                src = os.path.join(frames_dir, names[a - 1 + s * FPS])
                dst = os.path.join(out, 'stills', '%s-%02d.jpg' % (name, s))
                run(['ffmpeg', '-y', '-loglevel', 'error', '-i', src, '-q:v', '2', dst])
        # all the shots in a row, crossfading from one to the next
        if len(loops) > 1:
            inputs, chain, offset, last = [], '', 0.0, '0:v'
            durations = []
            for loop in loops:
                inputs += ['-i', loop]
                d = float(subprocess.run(['ffprobe', '-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', loop],
                                         capture_output=True, text=True).stdout)
                durations.append(d)
            for i in range(1, len(loops)):
                offset += durations[i - 1] - FADE
                label = 'x%d' % i
                chain += '[%s][%d:v]xfade=transition=fade:duration=%f:offset=%f[%s];' % (last, i, FADE, offset, label)
                last = label
            run(['ffmpeg', '-y', '-loglevel', 'error'] + inputs + ['-filter_complex', chain.rstrip(';'), '-map', '[%s]' % last,
                 '-c:v', 'libx264', '-crf', '16', '-preset', 'medium', '-pix_fmt', 'yuv420p', os.path.join(out, 'ambient.mp4')])
    print('wrote', out)


if __name__ == '__main__':
    main()
