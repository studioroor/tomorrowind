#!/bin/bash
# Films a village going up in time-lapse (tests/ingame/scripts/tomorrowind_test/timelapse.lua)
# and turns it into a looping GIF: tools/make_timelapse.sh <out-dir> [width]
# Writes <out-dir>/timelapse.gif (and timelapse.mp4). Needs ffmpeg.
# FILM=0 skips the filming and only remakes the GIF from the frames there.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:?out dir}"
WIDTH="${2:-560}"
if [ "${FILM:-1}" != 0 ]; then
  rm -rf "$OUT/userdata/screenshots"
  RES_X=1280 RES_Y=720 MAX_SECONDS=${MAX_SECONDS:-160} SHOTS="" TEST_CONTENT=timelapse.omwscripts EXTRA_SETTINGS="[General]
screenshot format = png
[Camera]
viewing distance = 16000
[Terrain]
distant terrain = true
[Shadows]
enable shadows = true
actor shadows = true
object shadows = true
terrain shadows = true
[Shaders]
force shaders = true
[Water]
shader = true
[Video]
antialiasing = 4" "$ROOT/tools/playtest.sh" "$OUT" Pelagiad
fi
# the frames, numbered in order, as an image sequence
SEQ="$OUT/seq"
rm -rf "$SEQ" && mkdir -p "$SEQ"
i=0
for f in $(ls "$OUT/userdata/screenshots" | sort); do
  i=$((i + 1))
  ln -s "$(cd "$OUT/userdata/screenshots" && pwd)/$f" "$SEQ/$(printf %04d $i).png"
done
# a lift for the morning light, as the trailer's grade
GRADE="eq=gamma=1.12:contrast=1.05:saturation=1.18"
ffmpeg -y -loglevel error -framerate 30 -i "$SEQ/%04d.png" -vf "$GRADE,format=yuv420p" -c:v libx264 -crf 18 "$OUT/timelapse.mp4"
ffmpeg -y -loglevel error -i "$OUT/timelapse.mp4" -vf "fps=${GIF_FPS:-10},scale=$WIDTH:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=128:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=3:diff_mode=rectangle" -loop 0 "$OUT/timelapse.gif"
ls -la "$OUT/timelapse.gif" "$OUT/timelapse.mp4"
