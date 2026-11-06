#!/bin/bash
# Scripted playtest: starts a new game in a sandboxed config/user-data dir
# (your own settings and saves are not touched), runs the autotest script,
# and takes screenshots. Usage: tools/playtest.sh <out-dir> [start-cell]
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:?out dir}"
CELL="${2:-Pelagiad}"
mkdir -p "$OUT/cfg" "$OUT/userdata" "$OUT/shots"
# window-only screenshots (never the whole screen)
swiftc -O "$ROOT/tools/winid.swift" -o "$OUT/winid" 2>/dev/null
cat > "$OUT/cfg/settings.cfg" <<CFG
[Video]
resolution x = 1280
resolution y = 800
window mode = 2
[Sound]
master volume = 0
CFG
OPENMW="${OPENMW:-/Applications/OpenMW 0.52 RC1/OpenMW.app/Contents/MacOS/openmw}"
# load the mod unless the user's own config already does
MOD_ARGS=(--data "$ROOT" --content Tomorrowind.omwscripts)
if grep -q "^content=Tomorrowind.omwscripts" "$HOME/Library/Preferences/openmw/openmw.cfg" 2>/dev/null; then
  MOD_ARGS=()
fi
"$OPENMW" --config "$OUT/cfg" --user-data "$OUT/userdata" \
  ${MOD_ARGS[@]+"${MOD_ARGS[@]}"} \
  --data "$ROOT/tests/ingame" --content autotest.omwscripts \
  --skip-menu --start "$CELL" --no-sound --no-grab \
  > "$OUT/stdout.log" 2>&1 &
PID=$!
for t in ${SHOTS:-20 45 75 110 140}; do
  sleep_until=$((SECONDS + t - ${last:-0})); last=$t
  while [ $SECONDS -lt $sleep_until ] && kill -0 $PID 2>/dev/null; do sleep 1; done
  WID=$("$OUT/winid" openmw 2>/dev/null) && kill -0 $PID 2>/dev/null && screencapture -x -o -l "$WID" "$OUT/shots/t$t.png" 2>/dev/null
done
# the autotest quits the game itself; this is only a safety net
while kill -0 $PID 2>/dev/null && [ $SECONDS -lt 240 ]; do sleep 1; done
kill $PID 2>/dev/null
wait $PID 2>/dev/null
echo "exit: done"
