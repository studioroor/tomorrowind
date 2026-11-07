-- Dev-only: each house model with its door, floating out at sea against open sky.
local core = require('openmw.core')
local camera = require('openmw.camera')
local util = require('openmw.util')
local self = require('openmw.self')
local debug = require('openmw.debug')
local types = require('openmw.types')
local I = require('openmw.interfaces')
local defs = require('scripts.tomorrowind.defs')
local v3 = util.vector3
local CENTER = v3(0, 270000, 1500)
local t, i, nextT = 0, 0, 3
local started, shotAt
return { engineHandlers = {
    onUpdate = function(dt)
        t = t + dt
        local hp = types.Actor.stats.dynamic.health(self)
        if hp.current < hp.base then hp.current = hp.base end
        if t < 2 then return end
        if i == 0 and not started then
            started = true
            I.Camera.disableModeControl('doors')
            I.UI.setHudVisibility(false)
            core.sendGlobalEvent('GAL_Tp', { pos = CENTER + v3(0, 0, -1480) })
        end
        if t < nextT then return end
        if shotAt then debug.takeScreenshot(); shotAt = nil; nextT = t + 0.4; return end
        i = i + 1
        local look = defs.look('house', i)
        if i > 11 then core.quit() return end
        if not look.door then nextT = t + 0.1; return end
        local d = look.door
        local door = CENTER + v3(d.offset[1], d.offset[2], d.offset[3])
        core.sendGlobalEvent('GAL_House', { model = look.model, pos = CENTER, door = d.id, doorPos = door, turn = d.turn })
        camera.setMode(camera.MODE.Static)
        local out = util.transform.rotateZ(d.turn) * v3(0, -1, 0)
        local pos = door + out * 560 + v3(0, 0, 90)
        camera.setStaticPosition(pos)
        local dir = door - pos
        camera.setYaw(math.atan2(dir.x, dir.y))
        camera.setPitch(math.atan2(pos.z - door.z, util.vector2(dir.x, dir.y):length()))
        print('[DOORS]', i, look.label, d.interior)
        shotAt = true
        nextT = t + 1.6
    end,
} }
