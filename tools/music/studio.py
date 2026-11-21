#!/usr/bin/env python3
"""A little studio for Tomorrowind's music: chords, a melody, the trailer's
pad and other synths, and orchestral instruments from a SoundFont.

    tools/music/studio.py            then open http://127.0.0.1:8765

Songs are saved in music/songs/<name>.json, exports go to music/out/<name>.wav
(use one in a trailer: tools/make_trailer.py ... --music music/out/<name>.wav).
Needs numpy, and fluidsynth with the SoundFont for the instruments (see
music/README.md). Only listens on this computer.
"""
import json
import os
import re
import sys
import traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from music import synth  # noqa: E402

PORT = int(os.environ.get('STUDIO_PORT', 8765))
HERE = os.path.dirname(os.path.abspath(__file__))
SONGS = os.path.join(synth.REPO, 'music', 'songs')
OUT = os.path.join(synth.REPO, 'music', 'out')
FONT = '/Applications/OpenMW 0.52 RC1/OpenMW.app/Contents/Resources/resources/vfs/fonts/MysticCards.ttf'


def safe_name(name):
    name = re.sub(r'[^a-zA-Z0-9_-]+', '-', (name or '').strip()).strip('-').lower()
    return name or 'untitled'


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def send(self, code, body, kind='application/json'):
        if isinstance(body, (dict, list)):
            body = json.dumps(body).encode()
        elif isinstance(body, str):
            body = body.encode()
        self.send_response(code)
        self.send_header('Content-Type', kind)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(body)

    def body(self):
        n = int(self.headers.get('Content-Length', 0))
        return json.loads(self.rfile.read(n) or b'{}')

    def do_GET(self):
        path = self.path.split('?')[0]
        if path in ('/', '/index.html'):
            with open(os.path.join(HERE, 'studio.html'), 'rb') as f:
                return self.send(200, f.read(), 'text/html; charset=utf-8')
        if path == '/font/MysticCards.ttf' and os.path.exists(FONT):
            with open(FONT, 'rb') as f:
                return self.send(200, f.read(), 'font/ttf')
        if path == '/api/setup':
            return self.send(200, {
                'notes': synth.NOTE_NAMES, 'qualities': list(synth.QUALITIES), 'voicings': synth.VOICINGS,
                'instruments': synth.INSTRUMENTS, 'waves': list(synth.WAVES),
                'pad': synth.PAD_DEFAULTS, 'pluck': synth.PLUCK_DEFAULTS, 'instrument': synth.INSTRUMENT_DEFAULTS,
                'soundfont': os.path.exists(synth.SOUNDFONT),
            })
        if path == '/api/songs':
            names = sorted(f[:-5] for f in os.listdir(SONGS) if f.endswith('.json')) if os.path.isdir(SONGS) else []
            return self.send(200, names)
        if path.startswith('/api/song/'):
            p = os.path.join(SONGS, safe_name(path[len('/api/song/'):]) + '.json')
            if not os.path.exists(p):
                return self.send(404, {'error': 'No song by that name'})
            with open(p) as f:
                return self.send(200, json.load(f))
        self.send(404, {'error': 'Not found'})

    def do_POST(self):
        path = self.path.split('?')[0]
        try:
            data = self.body()
            if path == '/api/render':
                mix = synth.master(synth.render(data['song'], loop=bool(data.get('loop'))))
                return self.send(200, synth.wav_bytes(mix), 'audio/wav')
            if path == '/api/save':
                song = data['song']
                song['name'] = safe_name(song.get('name'))
                os.makedirs(SONGS, exist_ok=True)
                with open(os.path.join(SONGS, song['name'] + '.json'), 'w') as f:
                    json.dump(song, f, indent=2)
                return self.send(200, {'name': song['name']})
            if path == '/api/export':
                song = data['song']
                name = safe_name(song.get('name')) + ('-loop' if data.get('loop') else '')
                os.makedirs(OUT, exist_ok=True)
                out = os.path.join(OUT, name + '.wav')
                synth.write_wav(out, synth.master(synth.render(song, loop=bool(data.get('loop')))))
                return self.send(200, {'path': os.path.relpath(out, synth.REPO)})
        except Exception as e:  # shown in the studio
            traceback.print_exc()
            return self.send(500, {'error': str(e)})
        self.send(404, {'error': 'Not found'})


def main():
    server = ThreadingHTTPServer(('127.0.0.1', PORT), Handler)
    print('Tomorrowind studio: http://127.0.0.1:%d  (Ctrl+C to stop)' % PORT)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == '__main__':
    main()
