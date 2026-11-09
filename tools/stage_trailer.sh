#!/bin/bash
# Opens the 0.2 trailer's set in the game for you to arrange by hand:
#
#   tools/stage_trailer.sh            # start from the current layout (or the default)
#   tools/stage_trailer.sh --reset    # forget the staged layout, start from the default
#
# The village and the bridge set (two houses, stairs, a rope bridge) are built
# and you're left standing beside them. Look at something and press M to move
# it (houses, the bridge and the stairs alike; Z/X turns it, Up/Down raises or
# lowers it, Enter puts it down), Delete removes it, and the Furnish menu
# places new ones. Building finishes at once and materials and gold stay
# topped up. Quit the game when it looks right: the bridge set is written to
# tests/ingame/scripts/tomorrowind_test/trailer2_layout.lua, which the trailer
# (tools/film_trailer.sh <out> trailer2) then builds instead of its default.
#
# Runs in a sandboxed config like tools/playtest.sh: your own settings and
# saves are not touched.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/.playtest/stage"
LAYOUT="$ROOT/tests/ingame/scripts/tomorrowind_test/trailer2_layout.lua"
if [ "${1:-}" = "--reset" ]; then
  rm -f "$LAYOUT"
  echo "Forgot the staged layout: starting from the default."
fi
if pgrep -x openmw >/dev/null; then
  echo "Another test game is still running; close it first." >&2
  exit 1
fi
rm -rf "$OUT"
mkdir -p "$OUT/cfg" "$OUT/userdata"
cat > "$OUT/cfg/settings.cfg" <<CFG
[Video]
resolution x = ${RES_X:-1600}
resolution y = ${RES_Y:-900}
window mode = 2
[Sound]
master volume = 0.4
CFG
OPENMW="${OPENMW:-/Applications/OpenMW 0.52 RC1/OpenMW.app/Contents/MacOS/openmw}"
MOD_ARGS=(--data "$ROOT" --content Tomorrowind.omwaddon --content Tomorrowind.omwscripts)
if grep -q "^content=Tomorrowind.omwscripts" "$HOME/Library/Preferences/openmw/openmw.cfg" 2>/dev/null; then
  MOD_ARGS=()
  grep -q "^content=Tomorrowind.omwaddon" "$HOME/Library/Preferences/openmw/openmw.cfg" 2>/dev/null \
    || MOD_ARGS=(--content Tomorrowind.omwaddon)
fi
echo "Opening the set... quit the game (Esc > Exit) when you're done."
"$OPENMW" --config "$OUT/cfg" --user-data "$OUT/userdata" \
  ${MOD_ARGS[@]+"${MOD_ARGS[@]}"} \
  --data "$ROOT/tests/ingame" --content trailer2_stage.omwscripts \
  --skip-menu --start Pelagiad ${STAGE_ARGS:-} \
  > "$OUT/stdout.log" 2>&1

# the last layout written before quitting
BLOCK=$(awk '/\[STAGE-LAYOUT\] BEGIN/ { n = 0; delete l; next }
             /\[STAGE-LAYOUT\] END/ { out = ""; for (i = 1; i <= n; i++) out = out l[i] "\n"; last = out; next }
             /\[STAGE-LAYOUT\] / { sub(/.*\[STAGE-LAYOUT\] /, ""); l[++n] = "    " $0 }
             END { printf "%s", last }' "$OUT/stdout.log")
if [ -z "$BLOCK" ]; then
  echo "No layout was written (did the set finish building?). Nothing changed." >&2
  exit 1
fi
{
  echo "-- The bridge set for the 0.2 trailer, arranged by hand with"
  echo "-- tools/stage_trailer.sh on $(date '+%Y-%m-%d %H:%M'). Each piece:"
  echo "-- { kind, variant, x, y, z, yaw }, in world coordinates."
  echo "return {"
  printf "%s\n" "$BLOCK"
  echo "}"
} > "$LAYOUT"
echo "Saved the layout ($(printf "%s" "$BLOCK" | grep -c .) pieces) to ${LAYOUT#$ROOT/}:"
cat "$LAYOUT"
