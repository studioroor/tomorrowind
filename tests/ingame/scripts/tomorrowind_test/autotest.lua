-- Dev-only scripted playtest. Loaded only by tools/playtest.sh.
-- Founds a colony, builds production sites, assigns jobs, places a house
-- blueprint and logs colony state, then quits.
local core = require('openmw.core')
local camera = require('openmw.camera')
local util = require('openmw.util')
local self = require('openmw.self')
local nearby = require('openmw.nearby')
local types = require('openmw.types')

local DURATION = tonumber(os and os.getenv and os.getenv('TMW_TEST_SECONDS')) or 150
local t = 0
local snap
local done = {}

local function log(...) print('[TMW-TEST]', ...) end

local function once(key, at, fn)
    if not done[key] and t >= at then
        done[key] = true
        local ok, err = pcall(fn)
        if not ok then log('ERROR in', key, err) end
    end
end

local function siteId(kind)
    for _, s in ipairs(snap and snap.sites or {}) do
        if s.kind == kind and s.built then return s.id end
    end
end

local function offset(dx, dy)
    local p = snap.storePos
    return util.vector3(p.x + dx, p.y + dy, p.z)
end

local function summary()
    if not snap or not snap.founded then return log('no colony') end
    local st = {}
    for k, v in pairs(snap.stock) do st[#st + 1] = k .. '=' .. math.floor(v) end
    table.sort(st)
    log(string.format('t=%.0f pop=%d/%d pending=%d stock: %s', t, snap.pop, snap.beds, snap.pending, table.concat(st, ' ')))
    for _, w in ipairs(snap.workers) do
        local pos = w.obj and w.obj:isValid() and w.obj.position
        log(string.format('  %-16s %-28s %-45s fed=%.2f pos=%s', w.name, w.job, w.status, w.fed,
            pos and string.format('(%.0f,%.0f,%.0f)', pos.x, pos.y, pos.z) or '?'))
    end
    for _, s in ipairs(snap.sites) do
        log(string.format('  [%s] %-18s %s r=%.0f', s.id, s.name, s.status, s.radius))
    end
end

local nextSummary = 5

return {
    engineHandlers = {
        onUpdate = function(dt)
            t = t + dt
            -- god mode: bandits must not end the test run
            local hp = types.Actor.stats.dynamic.health(self)
            if hp.current < hp.base then hp.current = hp.base end
            once('flat', 2, function()
                -- find the flattest dry 1800x1800 patch near the player
                -- bare terrain only: a ray that hits any object disqualifies the spot
                local function h(x, y)
                    local r = nearby.castRay(util.vector3(x, y, 20000), util.vector3(x, y, -2000),
                        { collisionType = nearby.COLLISION_TYPE.Default })
                    if not r.hit or r.hitObject then return nil end
                    return r.hitPos.z
                end
                local best, bestScore
                local p0 = self.position
                for gx = -6, 6 do
                    for gy = -6, 6 do
                        local cx, cy = p0.x + gx * 1000, p0.y + gy * 1000
                        local lo, hi, ok = 1e9, -1e9, true
                        for sx = -2, 2 do
                            for sy = -2, 2 do
                                local z = h(cx + sx * 500, cy + sy * 500)
                                if not z or z < 60 then ok = false else
                                    lo, hi = math.min(lo, z), math.max(hi, z) end
                            end
                        end
                        if ok and (not bestScore or hi - lo < bestScore) then
                            best, bestScore = util.vector3(cx, cy, hi), hi - lo
                        end
                    end
                end
                log('flattest patch', best, 'height range', bestScore)
                if best then
                    core.sendGlobalEvent('TMW_Debug', { cmd = 'tp', pos = best + util.vector3(0, -600, 0), lookAt = best })
                end
            end)
            once('found', 4, function()
                log('player at', self.position, 'cell', self.cell and self.cell.name, 'yaw', camera.getYaw())
                core.sendGlobalEvent('TMW_Found', { yaw = camera.getYaw() })
            end)
            once('setup', 6, function()
                core.sendGlobalEvent('TMW_Debug', { cmd = 'give', amounts = { ore = 10 } })
                core.sendGlobalEvent('TMW_Debug', { cmd = 'build', kind = 'mine', pos = offset(900, 0), built = true })
                core.sendGlobalEvent('TMW_Debug', { cmd = 'build', kind = 'smelter', pos = offset(-700, 300), built = true })
                core.sendGlobalEvent('TMW_Debug', { cmd = 'build', kind = 'lumber', pos = offset(0, -900), built = true })
                -- a farm blueprint that laborers must build first
                core.sendGlobalEvent('TMW_Debug', { cmd = 'build', kind = 'farm', pos = offset(-600, -700), built = false })
            end)
            once('camera_mine', 14, function()
                core.sendGlobalEvent('TMW_Debug', { cmd = 'tp', pos = offset(640, -260), lookAt = offset(900, 0) })
                camera.setPitch(0.25)
            end)
            once('camera_farm', 75, function()
                core.sendGlobalEvent('TMW_Debug', { cmd = 'tp', pos = offset(-250, -1100), lookAt = offset(-600, -700) })
            end)
            once('assign', 9, function()
                local ws = snap.workers
                if ws[1] then core.sendGlobalEvent('TMW_Assign', { wid = ws[1].id, target = siteId('mine') }) end
                if ws[2] then core.sendGlobalEvent('TMW_Assign', { wid = ws[2].id, target = siteId('smelter') }) end
                -- ws[3] stays a laborer and should haul + build the farm
            end)
            once('farm_job', 70, function()
                local farm = siteId('farm')
                log('farm built?', farm ~= nil)
                if farm and snap.workers[3] then
                    core.sendGlobalEvent('TMW_Assign', { wid = snap.workers[3].id, target = farm })
                end
            end)
            once('ledger_open', 98, function() self:sendEvent('TMW_DebugLedger', { open = true, tab = 'workers' }) end)
            once('ledger_build', 103, function() self:sendEvent('TMW_DebugLedger', { open = true, tab = 'build' }) end)
            once('ledger_close', 107, function() self:sendEvent('TMW_DebugLedger', { open = false }) end)
            once('place_view', 108, function()
                core.sendGlobalEvent('TMW_Debug', { cmd = 'tp', pos = offset(0, 900), lookAt = offset(0, 2000) })
            end)
            once('place_start', 109.5, function()
                camera.setPitch(0.45)
                self:sendEvent('TMW_DebugPlace', { kind = 'house' })
            end)
            once('place_confirm', 116, function() self:sendEvent('TMW_DebugPlace', { confirm = true }) end)
            if t >= nextSummary then
                nextSummary = nextSummary + 10
                summary()
            end
            once('quit', DURATION, function()
                summary()
                log('done')
                core.quit()
            end)
        end,
    },
    eventHandlers = {
        TMW_State = function(s) snap = s end,
    },
}
