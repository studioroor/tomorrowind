-- Dev-only, OpenTW: a few buildings around a new colony and the roads that
-- join them up, seen from above.
-- Run: OPENMW=<opentw>/openmw TEST_CONTENT=roads_shot.omwscripts SHOTS="20 24" tools/playtest.sh <out>
local core = require('openmw.core')
local util = require('openmw.util')
local self = require('openmw.self')
local camera = require('openmw.camera')
local v3 = util.vector3

local VILLAGE = v3(-2504, -55848, 1300)
local t, done, base = 0, {}, nil
local function once(key, at, fn)
    if not done[key] and t >= at then done[key] = true fn() end
end
local function dbg(e) core.sendGlobalEvent('TMW_Debug', e) end
local function build(kind, dx, dy, r)
    local x, y = base.x + dx, base.y + dy
    local z = core.land.getHeightAt(v3(x, y, 0), self.cell)
    dbg({ cmd = 'build', kind = kind, pos = v3(x, y, z), built = true, leveled = true, radius = r })
end

return {
    engineHandlers = {
        onUpdate = function(dt)
            t = t + dt
            once('tp', 1, function() dbg({ cmd = 'tp', pos = VILLAGE, lookAt = VILLAGE + v3(0, 100, 0) }) end)
            once('found', 3, function() core.sendGlobalEvent('TMW_Found', { yaw = 0 }) end)
            once('b1', 6, function()
                base = self.position
                dbg({ cmd = 'quiet', on = true })
                build('house', 1400, -2200, 500)
            end)
            -- these join the house's road rather than going all the way to the storehouse
            once('b2', 7, function() build('farm', 2900, -1100, 300) end)
            once('b3', 8, function() build('lumber', -2200, -1600, 250) end)
            once('b4', 9, function() build('smelter', 3000, -3300, 200) end)
            once('look', 11, function()
                local target = base + v3(900, -1500, 0)
                local eye = target + v3(-1800, -3600, 3600)
                local d = target - eye
                camera.setMode(camera.MODE.Static)
                camera.setStaticPosition(eye)
                camera.setYaw(math.atan2(d.x, d.y))
                camera.setPitch(math.atan2(-d.z, math.sqrt(d.x * d.x + d.y * d.y)))
            end)
            once('quit', 28, function() core.quit() end)
        end,
    },
}
