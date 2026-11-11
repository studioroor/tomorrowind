#!/bin/bash
# Shoots the stills for the logo and banners (tests/ingame/scripts/tomorrowind_test/poster.lua)
# with high graphics settings, as PNG, in the sandboxed playtest config:
# tools/shoot_poster.sh <out-dir>. The pictures land in <out-dir>/userdata/screenshots.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RES_X=${RES_X:-1920} RES_Y=${RES_Y:-1080} MAX_SECONDS=${MAX_SECONDS:-200} SHOTS="" TEST_CONTENT=poster.omwscripts EXTRA_SETTINGS="[General]
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
antialiasing = 8" "$ROOT/tools/playtest.sh" "$1" Pelagiad
