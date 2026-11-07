-- Dev-only: sets up a colony with a half-built site and a working forge,
-- so saveload_menu.lua can save and reload it. Logs state either side.
local core = require('openmw.core')
local util = require('openmw.util')
local self = require('openmw.self')
local types = require('openmw.types')

local t, snap, afterLoad = 0, nil, nil
local done = {}
local function log(...) print('[TMW-SL]', ...) end
local function once(key, at, fn)
    if not done[key] and t >= at then
        done[key] = true
        local ok, err = pcall(fn)
        if not ok then log('ERROR in', key, err) end
    end
end
local function dbg(e) core.sendGlobalEvent('TMW_Debug', e) end
local function offset(dx, dy)
    local p = snap.storePos
    return util.vector3(p.x + dx, p.y + dy, p.z)
end
local function siteId(kind)
    for _, s in ipairs(snap and snap.sites or {}) do
        if s.kind == kind then return s.id end
    end
end

return {
    engineHandlers = {
        onUpdate = function(dt)
            t = t + dt
            local hp = types.Actor.stats.dynamic.health(self)
            if hp.current < hp.base then hp.current = hp.base end
            if afterLoad then
                afterLoad = afterLoad + dt
                if afterLoad > 4 and not done.d1 then
                    done.d1 = true
                    dbg({ cmd = 'fxdump' })
                    for _, w in ipairs(snap.workers) do log('after load', w.name, w.status, 'enabled', w.obj.enabled) end
                    dbg({ cmd = 'hour', hour = 8 })
                end
                if afterLoad > 14 and not done.d2 then
                    done.d2 = true
                    dbg({ cmd = 'fxdump' })
                    log('workers after load:', snap and #snap.workers or -1)
                    for _, w in ipairs(snap and snap.workers or {}) do log('  ', w.name, w.job, w.status, 'enabled', w.obj.enabled) end
                end
                if afterLoad > 16 then log('done'); core.quit() end
                return
            end
            once('found', 2, function() core.sendGlobalEvent('TMW_Found', { yaw = 0 }) end)
            once('setup', 5, function()
                dbg({ cmd = 'give', amounts = { ore = 30, wood = 100, ingot = 10, food = 50 } })
                dbg({ cmd = 'build', kind = 'smelter', pos = offset(-700, 300), built = true })
                local spot = offset(1300, -2000)
                dbg({ cmd = 'build', kind = 'house', pos = util.vector3(spot.x, spot.y, core.land.getHeightAt(spot, self.cell) + 150),
                    built = false, leveled = true, radius = 570, foundation = { wood = 10, work = 20 } })
            end)
            once('assign', 7, function()
                core.sendGlobalEvent('TMW_Assign', { wid = snap.workers[1].id, target = siteId('smelter') })
            end)
            -- a building halfway out of the ground, with everyone asleep: it must come
            -- back at the right size (saves clamp scales)
            once('rising', 30, function() dbg({ cmd = 'build', kind = 'lumber', pos = offset(-900, -800), built = false }) end)
            once('stage', 31, function() dbg({ cmd = 'sitestate', kind = 'lumber', delivered = 1, progress = 0.5 }) end)
            once('night', 22, function() dbg({ cmd = 'hour', hour = 23 }) end)
            once('before', 36, function()
                dbg({ cmd = 'fxdump' })
                for _, w in ipairs(snap.workers) do log('before save', w.name, w.status, 'enabled', w.obj.enabled) end
            end)
        end,
        onSave = function() return { saved = true } end,
        onLoad = function(data)
            if data and data.saved then
                log('reloaded')
                afterLoad = 0
            end
        end,
    },
    eventHandlers = { TMW_State = function(s) snap = s end },
}
