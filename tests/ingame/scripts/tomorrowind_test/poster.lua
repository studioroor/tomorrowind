-- Dev-only: stills for the logo and banners. Settlers walk across the
-- picture, left to right, towards the rising sun on the right, Hlaalu houses
-- along the horizon. Side-lit rather than straight into the light, so the
-- settlers can be seen. The sun's direction is read from the game, and the
-- houses, the camera and the walk are placed around it.
-- Run: tools/shoot_poster.sh <out>   (high graphics settings, PNG)
local core = require('openmw.core')
local camera = require('openmw.camera')
local util = require('openmw.util')
local self = require('openmw.self')
local types = require('openmw.types')
local debug = require('openmw.debug')
local I = require('openmw.interfaces')

local v3 = util.vector3
local VILLAGE = v3(-2504, -55848, 1300)
local t, snap, done = 0, nil, {}
local function log(...) print('[POSTER]', ...) end
local function dbg(e) core.sendGlobalEvent('TMW_Debug', e) end
local function ground(x, y) return core.land.getHeightAt(v3(x, y, 0), self.cell) end
local function once(key, at, fn)
    if not done[key] and t >= at then
        done[key] = true
        local ok, err = pcall(fn)
        if not ok then log('error in', key, err) end
    end
end

-- South-west of the meadow: open, even ground for the walk, and the land low
-- enough towards the sun. The trees and rocks in the way, and Pelagiad's
-- buildings on the horizon, are switched off for the shot (debug 'hide').
local CAM = v3(VILLAGE.x - 1800, VILLAGE.y - 1200, 0)
local CAM_HEIGHT = 150
local HOUR = 7.1
-- houses either side of the sun: angle off the sun line (radians), distance, model
local SUN_RIGHT = 0.5   -- the sun this far right of the middle of the picture (radians)
-- houses along the horizon: angle off the middle of the picture, distance, model
local HOUSES = { { -0.45, 2600, 4 }, { -0.15, 2900, 2 }, { 0.12, 2700, 5 }, { 0.32, 3000, 3 }, { 0.72, 2800, 4 } }
-- the walk: from the left of the picture, close, to the right, further off
local WALK_FROM = { -0.55, 430 }
local WALK_TO = { 0.32, 1500 }
local sunAz, sunEl      -- where the sun is: azimuth (0 = north), elevation

local function along(az, d) return v3(CAM.x + math.sin(az) * d, CAM.y + math.cos(az) * d, 0) end
local function onLand(p, lift) return v3(p.x, p.y, ground(p.x, p.y) + (lift or 0)) end

local function readSun()
    local dir = core.weather.getCurrentSunLightDirection(self.cell)
    log('sun light direction', dir)
    -- the light points away from the sun, or at it: whichever is above the horizon
    local x, y, z = dir.x, dir.y, dir.z
    if z < 0 then x, y, z = -x, -y, -z end
    sunAz = math.atan2(x, y)
    sunEl = math.atan2(z, math.sqrt(x * x + y * y))
    log(string.format('sun at azimuth %.1f, elevation %.1f degrees', math.deg(sunAz), math.deg(sunEl)))
end

local function view()
    local from = onLand(CAM, CAM_HEIGHT)
    camera.setMode(camera.MODE.Static)
    camera.setStaticPosition(from)
    camera.setYaw(sunAz - SUN_RIGHT)
    camera.setPitch(-0.04)
end

-- the settlers in a loose line, walking across the picture
local function setOff(wave)
    local yaw = sunAz - SUN_RIGHT
    local from = along(yaw + WALK_FROM[1], WALK_FROM[2])
    local to = along(yaw + WALK_TO[1], WALK_TO[2])
    local dir = (to - from):normalize()
    local side = v3(dir.y, -dir.x, 0)
    local paths = {}
    for i = 1, #snap.workers do
        -- one behind the other, a little apart, starting just out of the picture
        local back = (i - 1) * 95 + wave * 15
        local off = ((i % 2 == 0) and 1 or -1) * (20 + (i % 3) * 18)
        paths[i] = { from = onLand(from - dir * back + side * off, 20), to = onLand(to + side * off, 20) }
    end
    dbg({ cmd = 'march', paths = paths })
end

return {
    engineHandlers = {
        onUpdate = function(dt)
            if dt <= 0 then return end
            t = t + dt
            local hp = types.Actor.stats.dynamic.health(self)
            if hp.current < hp.base then hp.current = hp.base end
            once('ui', 1, function()
                I.Camera.disableModeControl('poster')
                I.UI.setHudVisibility(false)
                dbg({ cmd = 'tp', pos = onLand(CAM - v3(500, 0, 0), 300), lookAt = CAM })
            end)
            once('found', 4, function()
                core.sendGlobalEvent('TMW_Found', { yaw = 0, pos = onLand(CAM + v3(-1700, 1200, 0)) })
                dbg({ cmd = 'quiet', on = true })
            end)
            once('hour', 6, function()
                core.sendGlobalEvent('TRL_Sky', { timeScale = 1 })
                dbg({ cmd = 'hour', hour = HOUR })
            end)
            once('sun', 9, readSun)
            once('build', 9.5, function()
                for _, h in ipairs(HOUSES) do
                    local az = sunAz - SUN_RIGHT + h[1]
                    dbg({ cmd = 'build', kind = 'house', variant = h[3], pos = onLand(along(az, h[2])), yaw = az + math.pi, built = true })
                end
                dbg({ cmd = 'spawn', n = 6 })
                dbg({ cmd = 'give', amounts = { food = 200 } })
                core.sendGlobalEvent('TRL_Sky', { timeScale = 1 })
            end)
            once('hide', 10.5, function()
                dbg({ cmd = 'hide', from = onLand(CAM), yaw = sunAz - SUN_RIGHT, half = 1.0, near = 1500, far = 14000, report = true,
                    prefixes = { 'ex_imp', 'ex_common', 'ex_de_', 'ex_nord', 'ex_t_', 'ex_s_', 'ex_v_', 'ex_pelagiad', 'ex_vivec', 'ex_drystonewall', 'furn_banner', 'furn_com', 'furn_imp', 'light_', 'active_' } })
            end)
            once('cam', 11, view)
            for wave = 1, 2 do
                local at = 12 + (wave - 1) * 14
                once('go' .. wave, at, function() setOff(wave) end)
                for k, d in ipairs({ 3, 5, 7, 9, 11 }) do
                    once('shot' .. wave .. k, at + d, function()
                        log('shot wave', wave, 'after', d, 's')
                        debug.takeScreenshot()
                    end)
                end
            end
            once('quit', 12 + 2 * 14, function() core.quit() end)
        end,
    },
    eventHandlers = { TMW_State = function(s) snap = s end },
}
