#!/bin/bash
# Films the trailer's raw frames with high graphics settings, in the sandboxed
# playtest config: tools/film_trailer.sh <out-dir>. See tools/make_trailer.py.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RES_X=1920 RES_Y=1080 MAX_SECONDS=${MAX_SECONDS:-580} SHOTS="" TEST_CONTENT=trailer.omwscripts EXTRA_SETTINGS="[General]
screenshot format = jpg
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
antialiasing = 4" "$ROOT/tools/playtest.sh" "$1" Pelagiad
