-- Dev-only scripted playtest. Loaded only by tools/playtest.sh.
-- Founds a colony, builds production sites, assigns jobs, places a house
-- blueprint and logs colony state, then quits.
local core = require('openmw.core')
local camera = require('openmw.camera')
local util = require('openmw.util')
local self = require('openmw.self')
local nearby = require('openmw.nearby')
local types = require('openmw.types')
local terrain = require('scripts.tomorrowind.core.terrain')

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
local placeTarget

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
                -- find a moderately sloped spot (needs a foundation, not too
                -- steep) for the house, away from existing buildings
                local r = 570 -- the Hlaalu House footprint
                local function h(x, y)
                    local ok, z = pcall(core.land.getHeightAt, util.vector3(x, y, 0), self.cell)
                    return ok and z or nil
                end
                local best
                for gx = -8, 8 do
                    for gy = -8, 8 do
                        local p = offset(gx * 250, gy * 250)
                        local far = true
                        for _, site in ipairs(snap.sites) do
                            if (util.vector2(p.x - site.pos.x, p.y - site.pos.y)):length() < r + site.radius + 200 then far = false end
                        end
                        if far then
                            local hs = {}
                            for _, d in ipairs(terrain.samplePoints(r)) do hs[#hs + 1] = h(p.x + d[1], p.y + d[2]) end
                            local a = terrain.analyze(hs)
                            if a.ok and a.depth > 40 and (not best or a.depth > best.a.depth) then
                                best = { p = util.vector3(p.x, p.y, a.level), a = a }
                            end
                        end
                    end
                end
                if not best then return log('no sloped spot found') end
                log(string.format('sloped spot depth=%.0f wood=%d work=%d', best.a.depth, best.a.wood, best.a.work))
                placeTarget = best.p
                local back = util.vector3(best.p.x, best.p.y - 1300, best.p.z)
                core.sendGlobalEvent('TMW_Debug', { cmd = 'tp', pos = back, lookAt = best.p })
            end)
            once('place_start', 109.5, function()
                if placeTarget then
                    local cam = camera.getPosition()
                    local horiz = util.vector2(placeTarget.x - cam.x, placeTarget.y - cam.y):length()
                    camera.setPitch(math.atan2(cam.z - placeTarget.z, horiz))
                else
                    camera.setPitch(0.45)
                end
                self:sendEvent('TMW_DebugPlace', { kind = 'house', at = placeTarget })
            end)
            once('place_confirm', 116, function() self:sendEvent('TMW_DebugPlace', { confirm = true }) end)
            once('finish_all', 122, function() core.sendGlobalEvent('TMW_Debug', { cmd = 'finish' }) end)
            once('pilings', 126, function() core.sendGlobalEvent('TMW_Debug', { cmd = 'pilings' }) end)
            once('view_house', 128, function()
                if not placeTarget then return end
                core.sendGlobalEvent('TMW_Debug', { cmd = 'tp', pos = util.vector3(placeTarget.x - 900, placeTarget.y - 1500, placeTarget.z), lookAt = placeTarget })
            end)
            once('view_pitch', 129, function()
                if not placeTarget then return end
                local cam = camera.getPosition()
                local horiz = util.vector2(placeTarget.x - cam.x, placeTarget.y - cam.y):length()
                camera.setPitch(math.atan2(cam.z - (placeTarget.z - 150), horiz))
            end)
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
