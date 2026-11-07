-- Dev-only: spawns rows of vanilla models on open ground near Pelagiad and
-- takes a screenshot of each row. Edit VIEWS to look at other models.
local core = require('openmw.core')
local camera = require('openmw.camera')
local util = require('openmw.util')
local self = require('openmw.self')
local types = require('openmw.types')
local debug = require('openmw.debug')
local I = require('openmw.interfaces')

local Y = -57748
local VIEWS = {
    { x = 96, spacing = 230, back = 650, models = { 'f/furn_bannerd_welcome_01', 'f/furn_com_tapestry_01', 'f/furn_de_tapestry_01', 'f/furn_de_banner_book_01', 'f/furn_de_signpost_01', 'f/active_signpost_01', 'f/active_sign_c_goods_01' } },
}
local t, stage = 0, 0
local shotAt
return {
    engineHandlers = {
        onUpdate = function(dt)
            t = t + dt
            local hp = types.Actor.stats.dynamic.health(self)
            if hp.current < hp.base then hp.current = hp.base end
            local v = VIEWS[1]
            if stage == 0 and t > 1 then
                stage = 1
                I.Camera.disableModeControl('gallery')
                camera.setMode(camera.MODE.FirstPerson)
                core.sendGlobalEvent('GAL_Tp', { pos = util.vector3(v.x, Y - v.back, 1500) })
            elseif stage == 1 and t > 4 then
                stage = 2
                core.sendGlobalEvent('GAL_Spawn', { views = VIEWS, y = Y, onLand = true, lift = 100 })
            elseif stage == 2 and t > 6 then
                stage = 3
                core.sendGlobalEvent('GAL_Dump')
            elseif stage == 3 then
                local z = core.land.getHeightAt(util.vector3(v.x, Y, 0), self.cell) + 90
                local target = util.vector3(v.x, Y, z)
                local cam = camera.getPosition()
                local d = target - cam
                camera.setYaw(math.atan2(d.x, d.y))
                camera.setPitch(math.atan2(cam.z - target.z, util.vector2(d.x, d.y):length()))
                if t > 8 and not shotAt then shotAt = t; debug.takeScreenshot() end
                if shotAt and t > shotAt + 1 then core.quit() end
            end
        end,
    },
}
