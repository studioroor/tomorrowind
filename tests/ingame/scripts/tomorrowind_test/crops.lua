-- Dev-only: crops. A farm goes up with three farmers; they harvest the ripe
-- plots (the plants go), plant the bare ones (sprouts come up) and tend the
-- rest; time runs on and the field grows back. Screenshots along the way,
-- and the farm's state and what everyone is doing in the log.
-- Run: TEST_CONTENT=crops.omwscripts SHOTS="" tools/playtest.sh <out> Pelagiad
local core = require('openmw.core')
local camera = require('openmw.camera')
local util = require('openmw.util')
local self = require('openmw.self')
local types = require('openmw.types')
local debug = require('openmw.debug')
local I = require('openmw.interfaces')

local v3 = util.vector3
local VILLAGE = v3(-2504, -55848, 1300) -- the meadow: see the scout scene's map
local FARM = VILLAGE + v3(700, -250, 0)
local snap
local t, done = 0, {}
local farmId
local function log(...) print('[CROPS]', ...) end
local function dbg(e) core.sendGlobalEvent('TMW_Debug', e) end
local function ground(x, y) return core.land.getHeightAt(v3(x, y, 0), self.cell) end
local function onLand(p, lift) return v3(p.x, p.y, ground(p.x, p.y) + (lift or 0)) end
local function once(key, at, fn)
    if not done[key] and t >= at then
        done[key] = true
        local ok, err = pcall(fn)
        if not ok then log('error in', key, err) end
    end
end
local function shot(name)
    log('shot', name)
    debug.takeScreenshot()
end

local function look(from, at)
    camera.setMode(camera.MODE.Static)
    camera.setStaticPosition(from)
    local d = at - from
    camera.setYaw(math.atan2(d.x, d.y))
    camera.setPitch(math.atan2(from.z - at.z, util.vector2(d.x, d.y):length()))
end

local function report(what)
    for _, s in ipairs(snap.sites or {}) do
        if s.id == farmId then log(what, 'farm:', s.status) end
    end
    for _, w in ipairs(snap.workers or {}) do log(what, w.id, w.status) end
end

return {
    engineHandlers = {
        onUpdate = function(dt)
            if dt <= 0 then return end
            t = t + dt
            local hp = types.Actor.stats.dynamic.health(self)
            if hp.current < hp.base then hp.current = hp.base end
            once('ui', 1, function()
                I.Camera.disableModeControl('crops')
                I.UI.setHudVisibility(false)
                dbg({ cmd = 'tp', pos = VILLAGE + v3(-600, -1400, 400), lookAt = VILLAGE })
                core.sendGlobalEvent('TRL_Sky', {})
            end)
            once('found', 4, function()
                core.sendGlobalEvent('TMW_Found', { yaw = 0, pos = onLand(VILLAGE) })
                dbg({ cmd = 'hour', hour = 9 })
            end)
            once('build', 6, function()
                dbg({ cmd = 'build', kind = 'farm', pos = onLand(FARM), yaw = 0.3, built = true })
                dbg({ cmd = 'spawn', n = 3 })
                dbg({ cmd = 'give', amounts = { food = 60 } })
            end)
            once('assign', 8, function()
                for _, s in ipairs(snap.sites) do
                    if s.kind == 'farm' then farmId = s.id end
                end
                for i = 1, 3 do
                    local w = snap.workers[i]
                    if w then core.sendGlobalEvent('TMW_Assign', { wid = w.id, target = farmId }) end
                end
                look(onLand(FARM + v3(-520, -620, 0), 330), onLand(FARM, 0))
            end)
            once('start', 9, function() report('start') shot('field at the start') end)
            for k = 1, 10 do
                once('r' .. k, 10 + k * 5, function() report(string.format('t+%d', k * 5)) end)
            end
            once('s1', 25, function() shot('farmers at work 1') end)
            once('s2', 40, function() shot('farmers at work 2') end)
            once('s3', 58, function() shot('farmers at work 3') end)
            once('g1', 62, function() dbg({ cmd = 'grow', hours = 2 }) end)
            once('g1s', 64, function() report('two hours on') shot('two hours on') end)
            once('g2', 66, function() dbg({ cmd = 'grow', hours = 6 }) end)
            once('g2s', 68, function() report('eight hours on') shot('eight hours on') end)
            once('close', 69, function() look(onLand(FARM + v3(-260, -330, 0), 170), onLand(FARM, 30)) end)
            once('closeShot', 70.5, function() shot('close up') end)
            if t > 73 then core.quit() end
        end,
    },
    eventHandlers = { TMW_State = function(s) snap = s end },
}
