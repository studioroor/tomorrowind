-- Dev-only: maps the ground around a spot, for laying out the trailer's village:
-- land height per grid square, '#' where something stands, '~' for water.
local core = require('openmw.core')
local camera = require('openmw.camera')
local util = require('openmw.util')
local self = require('openmw.self')
local types = require('openmw.types')
local nearby = require('openmw.nearby')
local debug = require('openmw.debug')
local I = require('openmw.interfaces')
local v3 = util.vector3
local CX, CY, STEP, R = -904, -56248, 200, 22
local t, done = 0, {}
local function once(k, at, fn) if not done[k] and t >= at then done[k] = true; fn() end end
return { engineHandlers = {
    onUpdate = function(dt)
        t = t + dt
        local hp = types.Actor.stats.dynamic.health(self)
        if hp.current < hp.base then hp.current = hp.base end
        once('go', 1, function()
            I.Camera.disableModeControl('scout'); I.UI.setHudVisibility(false)
            core.sendGlobalEvent('SCOUT_Tp', { pos = v3(CX, CY, 3000) })
        end)
        once('map', 6, function()
            local base = core.land.getHeightAt(v3(CX, CY, 0), self.cell)
            print('[MAP] centre land', base, 'one char =', STEP, 'units, top row = +y')
            for gy = R, -R, -1 do
                local row = {}
                for gx = -R, R do
                    local x, y = CX + gx * STEP, CY + gy * STEP
                    local h = core.land.getHeightAt(v3(x, y, 0), self.cell)
                    local r = nearby.castRay(v3(x, y, h + 1500), v3(x, y, h + 3), { collisionType = nearby.COLLISION_TYPE.World })
                    local c
                    if h < 10 then c = '~'
                    elseif r.hit then c = '#'
                    else
                        local band = math.floor((h - base) / 60 + 0.5)
                        c = band == 0 and '.' or (band > 0 and (band > 9 and '^' or tostring(band)) or (band < -9 and 'v' or string.char(96 - band)))
                    end
                    row[#row + 1] = c
                end
                print('[MAP] ' .. table.concat(row))
            end
        end)
        once('top', 7, function()
            camera.setMode(camera.MODE.Static)
            camera.setStaticPosition(v3(CX, CY - 300, 5500))
            camera.setYaw(0); camera.setPitch(1.5)
        end)
        once('shot', 10, function() debug.takeScreenshot() end)
        once('quit', 12, function() core.quit() end)
    end,
} }
