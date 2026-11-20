-- Dev-only: trees. The colony finds the trees around it; a Woodcutter's Camp
-- goes up by one, its woodcutters walk up to the trunk and fell it (a copy
-- topples, a stump is left), the stump sprouts and grows back; a grove is
-- planted and grows. Screenshots along the way, and the state in the log.
-- Run: TEST_CONTENT=trees.omwscripts SHOTS="" tools/playtest.sh <out> Pelagiad
local core = require('openmw.core')
local camera = require('openmw.camera')
local util = require('openmw.util')
local self = require('openmw.self')
local types = require('openmw.types')
local debug = require('openmw.debug')
local I = require('openmw.interfaces')
local C = require('scripts.tomorrowind.core.colony')
local defs = require('scripts.tomorrowind.defs')

local v3 = util.vector3
local VILLAGE = v3(-2504, -55848, 1300) -- the meadow: see the scout scene's map
local snap
local t, done, stage, stageT = 0, {}, 'start', 0
local tree, camp, grove
local ghostObj
local function log(...) print('[TREES]', ...) end
local function dbg(e) core.sendGlobalEvent('TMW_Debug', e) end
local function ground(x, y) return core.land.getHeightAt(v3(x, y, 0), self.cell) end
local function onLand(p, lift) return v3(p.x, p.y, ground(p.x, p.y) + (lift or 0)) end
local function flatDist(a, b) return util.vector2(a.x - b.x, a.y - b.y):length() end
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

-- From the side, a little above: the tree and whoever is at it.
local function lookAtTree(dist, up)
    local p = v3(tree.pos.x, tree.pos.y, 0)
    local toCamp = (v3(camp.x, camp.y, 0) - p):normalize()
    local side = v3(toCamp.y, -toCamp.x, 0)
    local from = p + (side * 0.8 + toCamp * 0.6):normalize() * dist
    look(onLand(from, up), onLand(p, 220))
end

local function treeState()
    for _, tr in ipairs(snap.trees or {}) do
        if flatDist(tr.pos, tree.pos) < 2 then return tr end
    end
end

return {
    engineHandlers = {
        onUpdate = function(dt)
            if dt <= 0 then return end
            t = t + dt
            local hp = types.Actor.stats.dynamic.health(self)
            if hp.current < hp.base then hp.current = hp.base end
            once('ui', 1, function()
                I.Camera.disableModeControl('trees')
                I.UI.setHudVisibility(false)
                dbg({ cmd = 'tp', pos = VILLAGE + v3(0, -900, 400), lookAt = VILLAGE })
                core.sendGlobalEvent('TRL_Sky', {})
            end)
            once('found', 4, function()
                core.sendGlobalEvent('TMW_Found', { yaw = 0, pos = onLand(VILLAGE) })
                dbg({ cmd = 'debug', on = true }) -- the woodcutters log the trunks they measure
                dbg({ cmd = 'hour', hour = 10 })
            end)
            once('pick', 6, function()
                log('trees known', #(snap.trees or {}))
                dbg({ cmd = 'trees' })
                -- a tree a little way from the storehouse, with open ground towards it
                local best
                for _, tr in ipairs(snap.trees) do
                    local d = flatDist(tr.pos, snap.storePos)
                    if not tr.felled and d > 900 and d < 2500 and (not best or d < flatDist(best.pos, snap.storePos)) then best = tr end
                end
                tree = best
                log('chosen tree at', tree.pos.x, tree.pos.y, 'from the storehouse', flatDist(tree.pos, snap.storePos))
                local toStore = (v3(snap.storePos.x, snap.storePos.y, 0) - v3(tree.pos.x, tree.pos.y, 0)):normalize()
                camp = v3(tree.pos.x, tree.pos.y, 0) + toStore * 500
                -- the placement rule
                log('rule: camp by the tree ok =', tostring(C.treeNear(snap.trees, camp, defs.trees.campReach)))
                local far = v3(snap.storePos.x, snap.storePos.y, 0)
                for _, tr in ipairs(snap.trees) do
                    if flatDist(tr.pos, far) < defs.trees.campReach then far = nil break end
                end
                if far then log('rule: camp in the open (storehouse) ok =', tostring(C.treeNear(snap.trees, far, defs.trees.campReach))) end
                dbg({ cmd = 'build', kind = 'lumber', pos = onLand(camp), yaw = 0, built = true })
                dbg({ cmd = 'spawn', n = 2 })
                dbg({ cmd = 'trees', at = tree.pos, r = 30, wood = 4 }) -- two loads bring it down
                core.sendGlobalEvent('TRL_Sky', { timeScale = 30 })
            end)
            once('assign', 9, function()
                local sid
                for _, s in ipairs(snap.sites) do if s.kind == 'lumber' then sid = s.id end end
                for _, w in ipairs(snap.workers) do core.sendGlobalEvent('TMW_Assign', { wid = w.id, target = sid }) end
                log('assigned', #snap.workers, 'woodcutters to', sid)
                lookAtTree(520, 200)
                stage, stageT = 'chop', 0
            end)
            if stage == 'chop' then
                stageT = stageT + dt
                for _, w in ipairs(snap.workers) do
                    if not done['status' .. w.id .. w.status] then
                        done['status' .. w.id .. w.status] = true
                        local d = w.obj and w.obj:isValid() and flatDist(w.obj.position, tree.pos)
                        log(w.id, w.status, d and string.format('(%.0f from the chosen tree)', d) or '')
                    end
                end
                for k, at in ipairs({ 12, 22, 32 }) do once('chopshot' .. k, 9 + at, function() shot('chopping ' .. k) end) end
                local st = treeState()
                if st and st.felled then
                    log('felled after', stageT)
                    stage, stageT = 'fall', 0
                elseif stageT > 150 then
                    log('not felled in time')
                    stage = 'grow'
                end
            elseif stage == 'fall' then
                stageT = stageT + dt
                once('fall1', 0, function() lookAtTree(1100, 350) end)
                if stageT > 0.5 and not done.f1 then done.f1 = true shot('falling 1') end
                if stageT > 1.0 and not done.f1b then done.f1b = true shot('falling 2') end
                if stageT > 1.5 and not done.f1c then done.f1c = true shot('falling 3') end
                if stageT > 2.6 and not done.f2 then done.f2 = true shot('down') end
                if stageT > 6 and not done.f3 then
                    done.f3 = true
                    shot('stump')
                    dbg({ cmd = 'trees', at = tree.pos, r = 30 })
                    stage, stageT = 'grow', 0
                end
            elseif stage == 'grow' then
                stageT = stageT + dt
                if not done.g1 then
                    done.g1 = true
                    dbg({ cmd = 'grow', hours = defs.trees.sproutHours + 1 })
                    dbg({ cmd = 'trees', at = tree.pos, r = 30 })
                end
                if stageT > 1 and not done.g1b then
                    done.g1b = true
                    dbg({ cmd = 'trees', at = tree.pos, r = 30 })
                    lookAtTree(420, 120)
                end
                if stageT > 2 and not done.g2 then done.g2 = true shot('sprouted') dbg({ cmd = 'grow', hours = defs.trees.growHours / 2 }) end
                if stageT > 4 and not done.g3 then done.g3 = true shot('half grown') dbg({ cmd = 'grow', hours = defs.trees.growHours / 2 + 1 }) end
                if stageT > 6 and not done.g4 then
                    done.g4 = true
                    lookAtTree(1100, 350)
                    shot('grown back')
                    dbg({ cmd = 'trees', at = tree.pos, r = 30 })
                    -- a grove in the open, on the far side of the storehouse
                    local away = (v3(snap.storePos.x, snap.storePos.y, 0) - v3(tree.pos.x, tree.pos.y, 0)):normalize()
                    grove = v3(snap.storePos.x, snap.storePos.y, 0) + away * 900
                    core.sendGlobalEvent('TMW_BeginPlace', { kind = 'grove', variant = 4 }) -- a kind that isn't around here: measured
                    stage, stageT = 'preview', 0
                end
            elseif stage == 'preview' then
                stageT = stageT + dt
                if not done.p0 then
                    done.p0 = true
                    local away = (grove - v3(snap.storePos.x, snap.storePos.y, 0)):normalize()
                    look(onLand(grove + away * 900, 3000), onLand(grove, 0)) -- from high above the treetops
                end
                if stageT > 0.3 then core.sendGlobalEvent('TMW_PlaceMove', { pos = onLand(grove), yaw = 0.4 }) end
                if stageT > 1.5 and not done.p1 then
                    done.p1 = true
                    shot('grove preview')
                    if ghostObj and ghostObj:isValid() then
                        local box = ghostObj:getBoundingBox()
                        local g = core.land.getHeightAt(ghostObj.position, self.cell)
                        log(string.format('preview: tree bottom %.0f against the ground (roots go %d deep)', box.center.z - box.halfSize.z - g, defs.trees.sink))
                    end
                    core.sendGlobalEvent('TMW_PlaceCancel')
                    dbg({ cmd = 'build', kind = 'grove', pos = onLand(grove), yaw = 0.4, built = true, variant = 1 })
                    -- placed raised, as an older version let you: the crate still goes on the ground
                    dbg({ cmd = 'build', kind = 'sapling', pos = onLand(grove + v3(1400, 0, 0), 300), yaw = 0, built = false, variant = 3, leveled = true })
                    stage, stageT = 'grove', 0
                end
            elseif stage == 'grove' then
                stageT = stageT + dt
                if not done.v0 then
                    done.v0 = true
                    local away = (grove - v3(snap.storePos.x, snap.storePos.y, 0)):normalize()
                    look(onLand(grove + away * 900, 3000), onLand(grove, 0)) -- from high above the treetops
                end
                if stageT > 2 and not done.v1 then
                    done.v1 = true
                    shot('grove planted')
                    for _, s in ipairs(snap.sites) do
                        log('site', s.id, s.kind, s.built, s.status)
                        if s.kind == 'sapling' and s.obj and s.obj:isValid() then
                            local box = s.obj:getBoundingBox()
                            log(string.format('sapling crate bottom %.0f against the ground', box.center.z - box.halfSize.z - core.land.getHeightAt(s.obj.position, self.cell)))
                        end
                    end
                    dbg({ cmd = 'finish' }) -- the single sapling, planted
                    dbg({ cmd = 'grow', hours = defs.trees.growHours / 2 })
                end
                if stageT > 4 and not done.v2 then done.v2 = true shot('grove growing') dbg({ cmd = 'grow', hours = defs.trees.growHours }) end
                if stageT > 6 and not done.v3 then
                    done.v3 = true
                    shot('grove grown')
                    dbg({ cmd = 'trees', at = grove, r = 1200 })
                    for _, s in ipairs(snap.sites) do if s.kind == 'lumber' then log('camp status:', s.status) end end
                end
                if stageT > 9 then core.quit() end
            end
        end,
    },
    eventHandlers = {
        TMW_State = function(s) snap = s end,
        TMW_Ghost = function(e) ghostObj = e.obj end,
    },
}
