-- Dev-only: spawns rows of vanilla models on open ground near Pelagiad and
-- takes a screenshot of each row, one row after another. Edit VIEWS to look
-- at other models (x: middle of the row, back: camera distance, up: camera
-- height above the row's ground, aimUp: aim this high above it).
local core = require('openmw.core')
local camera = require('openmw.camera')
local util = require('openmw.util')
local self = require('openmw.self')
local types = require('openmw.types')
local debug = require('openmw.debug')
local I = require('openmw.interfaces')
local nearby = require('openmw.nearby')

local Y = -57748
local SKY = 3000   -- the models hang this high, against the sky: nothing in the way
local VIEWS = {
    { x = -2400, spacing = 0, back = 2600, up = 500, aimUp = 250, models = { 'x/ex_velothi_hilltent_01' } },
    { x = 3000, spacing = 380, back = 1500, up = 150, aimUp = 100, models = { 'x/ex_de_shack_awning_02', 'x/ex_de_shack_awning_03', 'x/ex_de_shack_awning_04', 'x/ex_de_shack_awning_05', 'x/ex_de_shack_awning_06' } },
}
local t, view, shotAt = 0, 0, nil
local function ground(x) return core.land.getHeightAt(util.vector3(x, Y, 0), self.cell) end
return {
    engineHandlers = {
        onUpdate = function(dt)
            if dt <= 0 then return end
            t = t + dt
            local hp = types.Actor.stats.dynamic.health(self)
            if hp.current < hp.base then hp.current = hp.base end
            if view == 0 and t > 1 then
                view = -1
                I.Camera.disableModeControl('gallery')
                I.UI.setHudVisibility(false)
                core.sendGlobalEvent('GAL_Tp', { pos = util.vector3(VIEWS[1].x, Y - 1000, 1500) })
            elseif view == -1 and t > 4 then
                core.sendGlobalEvent('GAL_Spawn', { views = VIEWS, y = Y, onLand = true, lift = SKY })
                view, shotAt = 1, nil
            elseif view > 0 and t > 6 then
                local v = VIEWS[view]
                if not v then core.quit() return end
                local target = util.vector3(v.x, Y, ground(v.x) + SKY + v.aimUp)
                local from = util.vector3(v.x, Y - v.back, ground(v.x) + SKY + v.up)
                camera.setMode(camera.MODE.Static)
                camera.setStaticPosition(from)
                local d = target - from
                camera.setYaw(math.atan2(d.x, d.y))
                camera.setPitch(math.atan2(from.z - target.z, util.vector2(d.x, d.y):length()))
                if not shotAt then shotAt = t
                elseif t > shotAt + 1.5 then
                    debug.takeScreenshot()
                    if view == 1 then
                        core.sendGlobalEvent('GAL_Dump')
                        local base = ground(v.x) + SKY
                        for _, o in ipairs({ { 0, 0 }, { 250, 250 }, { 450, 0 }, { 0, 500 }, { 600, 600 } }) do
                            local x, y = v.x + o[1], Y + o[2]
                            local up = nearby.castRay(util.vector3(x, y, base - 900), util.vector3(x, y, base + 900))
                            local dn = nearby.castRay(util.vector3(x, y, base + 900), util.vector3(x, y, base - 900))
                            print(string.format('[GAL] ray at (%d,%d): from below %s, from above %s', o[1], o[2],
                                up.hit and string.format('%.0f', up.hitPos.z - base) or '-', dn.hit and string.format('%.0f', dn.hitPos.z - base) or '-'))
                        end
                    end
                    view, shotAt = view + 1, nil
                end
            end
        end,
    },
}
