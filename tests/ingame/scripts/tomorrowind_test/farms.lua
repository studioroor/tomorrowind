-- Dev-only: one farm of each crop, photographed.
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
local function once(k, at, fn) if not done[k] and t >= at then done[k] = true; local ok, e = pcall(fn); if not ok then print('[FARMS] ERROR', k, e) end end end
local function dbg(e) core.sendGlobalEvent('TMW_Debug', e) end
local function land(dx, dy) local p = v3(VILLAGE.x + dx, VILLAGE.y + dy, 0); return v3(p.x, p.y, core.land.getHeightAt(p, self.cell)) end
local SPOTS = { { -1200, -900 }, { -500, -1000 }, { 200, -1000 }, { 900, -900 }, { -1200, 900 }, { 900, 900 } }
return { engineHandlers = { onUpdate = function(dt)
    t = t + dt
    local hp = types.Actor.stats.dynamic.health(self)
    if hp.current < hp.base then hp.current = hp.base end
    once('ui', 1, function() I.Camera.disableModeControl('farms'); dbg({ cmd = 'tp', pos = VILLAGE + v3(0, -600, 1000), lookAt = VILLAGE }) end)
    once('found', 3.5, function() core.sendGlobalEvent('TMW_Found', { yaw = 0, pos = land(0, 0) }) end)
    once('farms', 5, function()
        for i, sp in ipairs(SPOTS) do dbg({ cmd = 'build', kind = 'farm', variant = i, pos = land(sp[1], sp[2]), built = true }) end
    end)
    for i, sp in ipairs(SPOTS) do
        once('view' .. i, 6 + i * 2, function()
            camera.setMode(camera.MODE.Static)
            local c = land(sp[1], sp[2])
            local from = c + v3(-260, -480, 260)
            camera.setStaticPosition(from)
            local d = c - from
            camera.setYaw(math.atan2(d.x, d.y))
            camera.setPitch(math.atan2(from.z - c.z, util.vector2(d.x, d.y):length()))
        end)
        once('shot' .. i, 7.2 + i * 2, function() debug.takeScreenshot() end)
    end
    once('names', 21, function()
        for _, s in ipairs(snap.sites) do if s.kind == 'farm' then print('[FARMS]', s.name, s.status) end end
        print('[FARMS] stock label', snap and 'ok')
        core.quit()
    end)
end }, eventHandlers = { TMW_State = function(s) snap = s end } }
