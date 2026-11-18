-- Dev-only: the same finished house on the same slope, for an OpenMW vs
-- OpenTW comparison shot. Picks the steepest buildable spot near VILLAGE.
-- Run on each engine: TEST_CONTENT=opentw_shot.omwscripts SHOTS="18" tools/playtest.sh <out>
local core = require('openmw.core')
local util = require('openmw.util')
local self = require('openmw.self')
local camera = require('openmw.camera')
local v3 = util.vector3

local VILLAGE = v3(-2504, -55848, 1300)
local t, done, spot = 0, {}, nil
local function once(key, at, fn)
    if not done[key] and t >= at then done[key] = true fn() end
end
local function dbg(e) core.sendGlobalEvent('TMW_Debug', e) end
local function h(x, y) return core.land.getHeightAt(v3(x, y, 0), self.cell) end
local function spread(x, y)
    local lo, hi = math.huge, -math.huge
    for i = 0, 7 do
        local a = i * math.pi / 4
        local z = h(x + math.sin(a) * 450, y + math.cos(a) * 450)
        lo, hi = math.min(lo, z), math.max(hi, z)
    end
    return hi - lo, (lo + hi) / 2
end

return {
    engineHandlers = {
        onUpdate = function(dt)
            t = t + dt
            once('tp', 1, function() dbg({ cmd = 'tp', pos = VILLAGE, lookAt = VILLAGE + v3(0, 100, 0) }) end)
            once('found', 3, function() core.sendGlobalEvent('TMW_Found', { yaw = 0 }) end)
            once('build', 6, function()
                local base, best = self.position, -1
                for dx = -2400, 2400, 400 do
                    for dy = -2400, -1200, 400 do
                        local s, mid = spread(base.x + dx, base.y + dy)
                        if s < 200 and s > best and mid > 100 then
                            best, spot = s, v3(base.x + dx, base.y + dy, mid)
                        end
                    end
                end
                print('[SHOT] slope under the house', best)
                dbg({ cmd = 'build', kind = 'house', pos = spot, yaw = 0.4, built = true, leveled = true, radius = 520 })
            end)
            once('look', 8, function()
                dbg({ cmd = 'quiet', on = true })
                -- a fixed camera up and to the side, looking down at the plot
                local eye = spot + v3(-1350, -1150, 750)
                local d = spot - eye
                camera.setMode(camera.MODE.Static)
                camera.setStaticPosition(eye)
                camera.setYaw(math.atan2(d.x, d.y))
                camera.setPitch(math.atan2(-d.z, math.sqrt(d.x * d.x + d.y * d.y)))
            end)
            once('quit', 22, function() core.quit() end)
        end,
    },
}
