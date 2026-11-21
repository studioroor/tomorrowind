# Music

Songs for Tomorrowind's trailers and videos, made in a little studio that
runs in your browser: chords, a melody, a low drum, and tracks that play
them with the trailer's synth pad, a plucked-string synth, or orchestral
instruments (strings, choir, horns, harp, flutes, timpani...).

```sh
tools/music/studio.py          # then open http://127.0.0.1:8765
```

- Songs are saved in `music/songs/<name>.json` (`trailer` is the trailers'
  own soundtrack, as chords to start from).
- **Export WAV** writes `music/out/<name>.wav`, or `<name>-loop.wav` with
  Loop on: the end flows back into the start, for ambient videos.
- A trailer with your music: `tools/make_trailer.py <take> trailer/ --music music/out/<name>.wav`.
  Without `--music` the trailers keep their own pad (`pad()` in
  `tools/music/synth.py`).
- Space plays and stops. Changes made while it plays are heard a moment later.

## Setting up

The studio needs Python with numpy. The instruments also need fluidsynth and
a SoundFont (the synths work without them):

```sh
brew install fluid-synth
mkdir -p music/soundfonts && cd music/soundfonts
curl -LO https://ftp.osuosl.org/pub/musescore/soundfont/MuseScore_General/MuseScore_General.sf2
curl -LO https://ftp.osuosl.org/pub/musescore/soundfont/MuseScore_General/MuseScore_General_License.md
```

MuseScore_General.sf2 (S. Christian Collins, from FluidR3 by Frank Wen) is
MIT licensed; it isn't kept in the repository (215 MB). The studio's
headings use MysticCards, the font that ships with OpenMW.
