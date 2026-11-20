#!/bin/bash
# Films the ambient footage (tests/ingame/scripts/tomorrowind_test/ambient.lua):
# a living colony along the road, from fixed cameras, every frame saved by the
# engine, with high graphics settings in the sandboxed playtest config.
#   tools/film_ambient.sh <out-dir>
#   tools/make_ambient.py <out-dir>        (loops and stills)
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RES_X=${RES_X:-1920} RES_Y=${RES_Y:-1080} MAX_SECONDS=${MAX_SECONDS:-600} SHOTS="" TEST_CONTENT=ambient.omwscripts EXTRA_SETTINGS="[General]
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
