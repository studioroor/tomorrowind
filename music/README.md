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
- ⌘S saves, ⌘Z / ⇧⌘Z undo and redo, ⌘K opens the command bar (type
  "compose B", "add C", "play from block 3", "open song …"), ? lists the
  keys. Right-click a block, a section, a chord or the melody for its
  options (play, repeat, copy, move, who plays, octaves, rename, remove).

## A song: three views

Switch at the top (or press 1, 2, 3):

- **Arrange**: the song from start to end, as a row of blocks. Each block
  plays a section a number of times with its own line-up: switch tracks
  (and the drums) on or off and set how loud they are, to build up or thin
  out. A block can fade in, fade out, or slow down towards its end (over
  the whole block, or its last bars). A block can have its own
  tempo, and each track its own loudness in the block (on top of the
  section's). Drag
  blocks to reorder them, drag a section in (from the row under the song,
  or a card) to add it; drag the cards to put the sections in order. With a
  block selected, "From block N" plays the song from there, and in Compose
  "As in block N" plays the section with that block's line-up. Here too: the
  **feel** for the whole song (rubato: the tempo breathes and broadens at
  the end of a phrase; human: notes a little off the grid, not all equally
  loud, chords slightly strummed; swing: off-beats come late), and the
  sections as cards (add to the song, copy, rename, remove).
- **Compose**: one section at a time, its chords, melody and drums in
  panels that fold away (folded, they still show the line-up, the chords,
  the melody's contour and the drum patterns). Play plays this section. A
  section can have its own **time signature** (beats a bar) and **tempo**;
  the sliders in Who plays what set how loud each track (and the drums) is
  in this section. Double-click a slider: back to 100%. Drag the
  chords to change their order (Option: a copy); a chord can let a track or
  the drums **sit out** (Who plays, in the chord, or right-click it).
- **The melody** (? shows how): click an empty spot for a note, double-click a note to
  take it away. Click notes to select them (Shift for more) or drag a box
  around them; drag to move, with Option to copy; drag a note's right edge
  to make it longer. Keys: Delete, arrows (Shift+↑↓ an octave), ⌘C ⌘V,
  ⌘D duplicate, ⌘A all. Note lengths from a quarter beat, **dotted** too;
  Notes ▾ (or a right-click) moves or copies the selection, or the whole
  melody, an octave up or down. **Who plays what** gives a
  track another part in this section (the harp on the melody in A, on
  arpeggios in B, the strings taking the melody) or lets it rest; a track
  you don't change plays its usual part from the Band. The ⌒ on a track is
  **legato**: each note runs on into the next. Set it for the whole song in
  the Band, for a section in Compose, or for one block in Arrange. A chord can have another
  note in the bass (G/B). The drums show only the ones the section uses
  (add one, or show all twelve: low drum, toms, hand drums, tambourine,
  shaker, triangle, cymbal, wood block, timpani on the chord's root).
- **Band**: the tracks, the same in every section: what each plays (chords,
  bass, melody or arpeggio) and how it sounds. When the next chord has the
  same notes, chords and bass hold them on rather than striking them again
  (switch a track to "play again" for a pulse): a section of D chords gets
  one long D in the bass, and a pedal note under changing chords is the
  chords' bass note (C/D).

Songs from before sections open as one section, A, in one block.

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
