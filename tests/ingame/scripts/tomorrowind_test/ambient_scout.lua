-- Dev-only: tries the ambient cameras and maps where people walk (see ambient_scene.lua).
-- Run: TEST_CONTENT=ambient_scout.omwscripts SHOTS="" tools/playtest.sh <out> Pelagiad
--      tools/ambient_scout.py <out>
return require('scripts.tomorrowind_test.ambient_scene')('scout')
