-- Global script: owns the colony state and connects the pure simulation
-- core to world objects (buildings, worker NPCs) and to the player's UI.

local world = require('openmw.world')
local core = require('openmw.core')
local types = require('openmw.types')
local util = require('openmw.util')
local I = require('openmw.interfaces')

local C = require('scripts.tomorrowind.core.colony')
local defs = require('scripts.tomorrowind.defs')
local records = require('scripts.tomorrowind.records')
local interiors = require('scripts.tomorrowind.interiors')

local WORKER_SCRIPT = 'scripts/tomorrowind/worker.lua'
local CAPTIVE_SCRIPT = 'scripts/tomorrowind/captive.lua'

local STATE_INTERVAL = 0.5
local ACTIVE_INTERVAL = 0.5
local STEP_WATCHDOG = 150
local SITE_INTERVAL = 1 / 30

-- persistent
local c                      -- colony state (plain table, see core/colony.lua)
local objs = { sites = {}, workers = {}, decor = {}, threats = {}, sitefx = {}, workfx = {}, indoors = {},
    shells = {}, exits = {}, doors = {}, caravan = {} }
local ghost                  -- { obj=, kind= } while the player is placing
local recIds                 -- ids of our runtime records (see records.lua)

-- runtime only
local tokens = {}            -- wid -> token of the step in flight
local stepStarted = {}       -- wid -> sim time the step was sent
local stepLimit = {}         -- wid -> seconds before the watchdog replans
local tokenCounter = 0
local stateTimer, activeTimer, offscreenDt = 0, 0, 0
local lastGameTime
local workerByObj = {}       -- object id -> wid
local applyGhostMove         -- defined with the placement code below
local checkThreats           -- defined with the main loop
local debugOn = defs.debug
local siteByObj = {}         -- object id -> sid
local doorByObj = {}         -- object id -> { sid=, exit= }
local caravanTraderId        -- object id of the trader while a caravan is here
local workFxUntil = {}       -- sid -> sim time the smelter fire may go out
local needsMigration = false
local siteTimer = 0
local quiet = false          -- no messages (filming)
local lastKind, lastRemark = {}, {} -- wid -> last task kind, sim time of last remark
local awayFrom               -- what the colony had when the player left

local doorPoint              -- defined with the workers
local caravanArrives, caravanLeaves, removeRoom, pushState
local function log(...)
    print('[Tomorrowind]', ...)
end

local function rec()
    recIds = records.ensure(recIds)
    return recIds
end

local function v3(p) return util.vector3(p.x, p.y, p.z or 0) end
local function plain(v) return { x = v.x, y = v.y, z = v.z } end

local function player() return world.players[1] end

local function message(text)
    local p = player()
    if p and not quiet then p:sendEvent('TMW_Message', { text = text }) end
end

local function rebuildIndex()
    workerByObj, siteByObj, doorByObj = {}, {}, {}
    for sid, o in pairs(objs.doors) do
        if o:isValid() then doorByObj[o.id] = { sid = sid } end
    end
    for sid, list in pairs(objs.exits) do
        for _, o in ipairs(list) do
            if o:isValid() then doorByObj[o.id] = { sid = sid, exit = true } end
        end
    end
    for wid, o in pairs(objs.workers) do
        if o:isValid() then workerByObj[o.id] = wid end
    end
    for sid, o in pairs(objs.sites) do
        if o:isValid() then siteByObj[o.id] = sid end
    end
end

---------------------------------------------------------------------------
-- world objects for sites

local function siteRadius(sid)
    local o = objs.sites[sid]
    if o and o:isValid() then
        local ok, box = pcall(o.getBoundingBox, o)
        if ok and box then
            local h = box.halfSize
            local r = math.max(h.x, h.y)
            if r > 1 and r < 5000 then return r end
        end
    end
    local s = c.sites[sid]
    return s and defs.buildings[s.kind].footprint or 150
end

-- Note: teleport's onGround does nothing for a freshly created object (it
-- isn't in the scene yet), so heights are always worked out from the land.
local function placeObject(recordId, pos, yaw, scale, cell)
    local o = world.createObject(recordId)
    o:teleport(cell or '', v3(pos), { rotation = util.transform.rotateZ(yaw or 0) })
    if scale and scale ~= 1 then o:setScale(scale) end
    return o
end

-- An exterior cell for land height lookups (a freshly created object has
-- no cell until next frame).
local function landCell()
    local store = c and objs.sites[c.storehouse]
    return (store and store:isValid() and store.cell) or (player() and player().cell)
end

local function landHeight(p)
    local ok, h = pcall(core.land.getHeightAt, p, landCell())
    return ok and h or nil
end

-- Height of the floor a site's own props stand on.
local function siteFloor(sid, p)
    local s = c.sites[sid]
    if s.leveled then return s.pos.z end
    return landHeight(p) or s.pos.z
end

-- The cell a site's objects go in: furniture indoors is in the interior cell.
local function siteCell(sid)
    return c.sites[sid].host and interiors.cell or ''
end

-- Footprint radius of the finished building: measured from the placement
-- preview, from the finished object, or the defs estimate.
local function footprintRadius(sid)
    local s = c.sites[sid]
    if s.radius then return s.radius end
    if s.built then return siteRadius(sid) end
    return defs.buildings[s.kind].footprint * 0.5
end

-- Where a site's object goes: most vanilla furniture meshes are centred
-- on their origin, so they are lifted to stand on the ground.
local function objectPos(sid)
    local s = c.sites[sid]
    local d = defs.look(s.kind, s.variant)
    local lift = s.built and d.lift or (d.small and defs.smallConstructionLift) or 0
    return util.vector3(s.pos.x, s.pos.y, s.pos.z + lift)
end

-- The record behind a site's chosen model.
local function lookRecord(kind, variant)
    local ids = rec()
    local byKind = ids.looks[kind]
    return (variant and variant > 1 and byKind and byKind[variant]) or ids.buildings[kind]
end

local function siteScale(sid)
    local s = c.sites[sid]
    if s.built then return defs.look(s.kind, s.variant).scale or 1 end
    if defs.buildings[s.kind].small then return 1 end
    -- the scaffold grows with the building it stands in for
    return math.max(1, math.min(2, footprintRadius(sid) / defs.scaffoldRadius))
end

-- Spawns a decoration in the site's frame: local offset (x, y), standing
-- `lift` above the ground there, turned by `turn` relative to the site.
local function spawnLocal(sid, decorKey, x, y, lift, turn, scale, onFloor)
    local s = c.sites[sid]
    local rot = util.transform.rotateZ(s.yaw)
    local p = v3(s.pos) + rot * util.vector3(x, y, 0)
    local ground = onFloor and siteFloor(sid, p) or (landHeight(p) or s.pos.z)
    local o = world.createObject(rec().decor[decorKey])
    o:teleport('', util.vector3(p.x, p.y, ground + (lift or 0)), { rotation = util.transform.rotateZ(s.yaw + (turn or 0)) })
    if scale and scale ~= 1 then o:setScale(scale) end
    return o
end

-- Layouts for material piles: where the i-th object of a pile goes,
-- relative to the pile's anchor. Returns x, y, lift, turn, scale.
local LOG_SCALE = 2              -- furn_log_01 at this scale: ~108 long, ~26 thick
local LOG_LAYERS = { 4, 3, 2, 1 }
local layouts = {}
layouts.logs = function(i)
    local perStack = 10
    local k, j = math.floor((i - 1) / perStack), (i - 1) % perStack
    local layer = 1
    while j >= LOG_LAYERS[layer] do j = j - LOG_LAYERS[layer]; layer = layer + 1 end
    local n = LOG_LAYERS[layer]
    local jitter = ((i * 37) % 7 - 3) * 0.015
    return k * 135 + (j - (n - 1) / 2) * 29, ((i * 13) % 5 - 2) * 4, 12 + (layer - 1) * 22, jitter, LOG_SCALE
end
layouts.heaps = function(i)
    local col, row = (i - 1) % 3, math.floor((i - 1) / 3)
    return col * 110, row * 120, -6, i * 1.3, 0.6
end
layouts.plates = function(i)
    local col, h = math.floor((i - 1) / 6), (i - 1) % 6
    return col * 60, 0, 2 + h * 10, ((i * 29) % 9 - 4) * 0.08, 2
end

-- Pile anchors (site frame), beside the footprint.
local PILE_SIDE = { wood = 0, ore = 230, ingot = -170, food = -300 }

local function spawnPileItem(sid, res, i, anchorX, anchorY)
    local style = defs.piles[res] or defs.piles.food
    local x, y, lift, turn, scale = layouts[style.layout](i)
    return spawnLocal(sid, style.model, anchorX + x, anchorY + y, lift, turn, scale)
end

local function removeDecor(sid)
    for _, o in ipairs(objs.decor[sid] or {}) do
        if o:isValid() then o:remove() end
    end
    objs.decor[sid] = nil
end

-- Timber pilings around the footprint wherever the ground drops away
-- below a leveled building's floor.
local function pilingSpots(sid)
    local s = c.sites[sid]
    local spots = {}
    if not s.leveled or defs.buildings[s.kind].small then return spots end
    local r = footprintRadius(sid) * 0.85
    local count = math.max(8, math.floor(2 * math.pi * r / 160))
    for i = 0, count - 1 do
        local a = i * 2 * math.pi / count
        local p = v3(s.pos) + util.vector3(math.sin(a) * r, math.cos(a) * r, 0)
        local ground = landHeight(p)
        if ground and s.pos.z - ground > defs.slope.hiddenDepth then
            spots[#spots + 1] = { x = p.x, y = p.y, a = a }
        end
    end
    return spots
end

local function spawnPiling(sid, spot)
    local o = world.createObject(rec().decor.piling)
    -- the piling mesh is centred on its origin: top at floor level
    o:teleport('', util.vector3(spot.x, spot.y, c.sites[sid].pos.z - defs.slope.pilingHalfHeight),
        { rotation = util.transform.rotateZ(spot.a) })
    return o
end

-- Timber pilings around the footprint wherever the ground drops away
-- below a leveled building's floor.
local function spawnPilings(sid, list)
    for _, spot in ipairs(pilingSpots(sid)) do list[#list + 1] = spawnPiling(sid, spot) end
end

local function removeAll(list)
    for _, o in ipairs(list or {}) do
        if o:isValid() then o:remove() end
    end
end

local function removeSiteFx(sid)
    local fx = objs.sitefx[sid]
    if not fx then return end
    for _, list in pairs(fx.piles or {}) do removeAll(list) end
    removeAll(fx.pilings)
    if fx.rising and fx.rising:isValid() then fx.rising:remove() end
    objs.sitefx[sid] = nil
end

-- The building itself comes up out of the ground as the work progresses,
-- growing to full size on the way. A static copy: the site's own object stays
-- the scaffold until the building is done.
local function syncRising(sid, s, d, v, fx)
    if v.rise == nil or (d.small and not d.rises) then return end
    local fullScale = d.scale or 1
    if fx.rising == nil then
        -- out of sight for now: its size can only be measured next time
        local under = objectPos(sid) - util.vector3(0, 0, 3000)
        fx.rising = placeObject(rec().risingLooks[s.kind][s.variant or 1], under, s.yaw, fullScale)
        fx.riseWait = 2
        return
    end
    if not fx.rising:isValid() then return end
    if fx.riseWait then
        fx.riseWait = fx.riseWait > 1 and fx.riseWait - 1 or nil
        return
    end
    if not fx.riseHeight then
        -- how far its top stands above the floor once it's up: it starts with
        -- the top just under the ground, so all of the work shows
        local box = fx.rising:getBoundingBox()
        fx.riseHeight = box.center.z + box.halfSize.z - fx.rising.position.z + (d.lift or 0)
    end
    -- never back down, and only redraw when it moved: a step costs a bit
    local shown = math.max(fx.riseShown or 0, v.rise)
    local step = math.floor(shown * 100 / defs.rise.stepPercent)
    if step == fx.riseStep then return end
    fx.riseShown, fx.riseStep = shown, step
    local p = step * defs.rise.stepPercent / 100
    local at = objectPos(sid)
    local from = defs.rise.fromScale
    fx.rising:teleport('', util.vector3(at.x, at.y, at.z - (1 - p) * fx.riseHeight),
        { rotation = util.transform.rotateZ(s.yaw) })
    fx.rising:setScale(fullScale * (from + (1 - from) * p))
end

-- Construction made visible: stacks of the delivered materials beside the
-- site (used up as the building goes up), on slopes the pilings going in one
-- by one while the ground is leveled, then the building rising.
local function syncSiteFx(sid)
    local s = c.sites[sid]
    if not s or s.built then return end
    -- work in progress counts: settlers only book it when they finish
    local busy = 0
    for _, wid in ipairs(c.workerOrder) do
        local st = C.currentStep(c, wid)
        if st and st.op == 'work' and st.effect == 'build' and st.at == sid and st.duration and stepStarted[wid] then
            busy = busy + st.amount * math.min(1, (c.time - stepStarted[wid]) / st.duration)
        end
    end
    local v = C.siteVisuals(c, sid, busy)
    local d = defs.look(s.kind, s.variant)
    local fx = objs.sitefx[sid] or { piles = {}, pilings = {} }
    objs.sitefx[sid] = fx
    syncRising(sid, s, d, v, fx)
    if d.small then return end
    local anchorX = footprintRadius(sid) + 110
    for res, amount in pairs(v.piles) do
        local style = defs.piles[res] or defs.piles.food
        local want = math.min(style.max, math.ceil(amount / style.per - 1e-6))
        local list = fx.piles[res] or {}
        fx.piles[res] = list
        while #list > want do
            local o = table.remove(list)
            if o:isValid() then o:remove() end
        end
        while #list < want do
            list[#list + 1] = spawnPileItem(sid, res, #list + 1, anchorX, PILE_SIDE[res] or -300)
        end
    end
    if s.leveled then
        fx.spots = fx.spots or pilingSpots(sid)
        local want = math.floor(#fx.spots * v.pilings + 1e-6)
        while #fx.pilings > want do
            local o = table.remove(fx.pilings)
            if o:isValid() then o:remove() end
        end
        while #fx.pilings < want do
            fx.pilings[#fx.pilings + 1] = spawnPiling(sid, fx.spots[#fx.pilings + 1])
        end
    end
end

-- The smelter's fire burns while someone is working the forge.
local function workFxOn(sid, seconds)
    local s = c.sites[sid]
    local fxDef = s and s.built and defs.buildings[s.kind].workFx
    if not fxDef then return end
    workFxUntil[sid] = math.max(workFxUntil[sid] or 0, c.time + seconds)
    local o = objs.workfx[sid]
    if o and o:isValid() then return end
    local rot = util.transform.rotateZ(s.yaw)
    local off = fxDef.offset
    local p = v3(s.pos) + rot * util.vector3(off[1], off[2], 0)
    o = world.createObject(fxDef.light)
    o:teleport('', util.vector3(p.x, p.y, siteFloor(sid, p) + off[3]), { rotation = rot })
    objs.workfx[sid] = o
end

local function updateWorkFx()
    for sid, o in pairs(objs.workfx) do
        if not c.sites[sid] or not workFxUntil[sid] or c.time > workFxUntil[sid] then
            if o:isValid() then o:remove() end
            objs.workfx[sid] = nil
            workFxUntil[sid] = nil
        end
    end
end

local function spawnDecor(sid)
    local s = c.sites[sid]
    local d = defs.look(s.kind, s.variant)
    local list = {}
    -- pilings driven during construction stay; any still missing (the site
    -- may have finished during a time skip) go in now
    local fx = objs.sitefx[sid]
    if fx and fx.spots then
        for _, o in ipairs(fx.pilings) do list[#list + 1] = o end
        for i = #fx.pilings + 1, #fx.spots do list[#list + 1] = spawnPiling(sid, fx.spots[i]) end
        fx.pilings = {}
    else
        spawnPilings(sid, list)
    end
    objs.decor[sid] = list
    for _, prop in ipairs(d.props or {}) do
        local off = prop.offset or { 0, 0, 0 }
        local rot = util.transform.rotateZ(s.yaw)
        local p = v3(s.pos) + rot * util.vector3(off[1], off[2], off[3])
        local o = world.createObject(prop.light or rec().decor[prop.decor])
        o:teleport(siteCell(sid), p, { rotation = util.transform.rotateZ(s.yaw + (prop.turn or 0)) })
        if prop.scale then o:setScale(prop.scale) end
        list[#list + 1] = o
    end
    if d.door and not s.host then
        local rot = util.transform.rotateZ(s.yaw)
        local at = objectPos(sid) + rot * util.vector3(d.door.offset[1], d.door.offset[2], d.door.offset[3])
        local door = world.createObject(d.door.id)
        door:teleport('', at, { rotation = util.transform.rotateZ(s.yaw + d.door.turn) })
        objs.doors[sid] = door
        list[#list + 1] = door
    end
    if d.decor == 'lumber' then
        -- a stack of logs beside the chopping stump, and a couple lying loose
        for i = 1, 20 do
            local x, y, lift, turn, scale = layouts.logs(i)
            list[#list + 1] = spawnLocal(sid, 'log', 280 + x, y, lift, turn, scale)
        end
        list[#list + 1] = spawnLocal(sid, 'log', -230, 60, 12, 1.1, LOG_SCALE)
        list[#list + 1] = spawnLocal(sid, 'log', -210, -90, 12, 1.9, LOG_SCALE)
        return
    end
    if d.decor == 'smelter' then
        -- the coal bed inside the forge (vanilla smithy layout)
        list[#list + 1] = spawnLocal(sid, 'coals', 0, 0, 91, 0, 0.69, true)
        return
    end
    if d.decor == 'stockade' then
        -- a ring of fence segments around the cell block
        local r, n = 420, 12
        for i = 0, n - 1 do
            local a = s.yaw + i * 2 * math.pi / n
            local p = v3(s.pos) + util.vector3(math.sin(a) * r, math.cos(a) * r, 0)
            local o = world.createObject(rec().decor.fence)
            o:teleport('', util.vector3(p.x, p.y, landHeight(p) or p.z), { rotation = util.transform.rotateZ(a + math.pi / 2) })
            list[#list + 1] = o
        end
        return
    end
    if d.decor ~= 'farm' then return end
    local rot = util.transform.rotateZ(s.yaw)
    for ix = -2, 2 do
        for iy = -2, 2 do
            if not (ix == 0 and iy == 0) then
                local p = v3(s.pos) + rot * util.vector3(ix * 110, iy * 110, 0)
                local o = world.createObject(rec().decor.saltrice)
                o:teleport('', util.vector3(p.x, p.y, landHeight(p) or p.z), { rotation = util.transform.rotateZ(math.random() * 6.28) })
                list[#list + 1] = o
            end
        end
    end
end

local function setSiteObject(sid)
    local s = c.sites[sid]
    local old = objs.sites[sid]
    if old and old:isValid() then old:remove() end
    local d = defs.look(s.kind, s.variant)
    local recordId = (s.built and lookRecord(s.kind, s.variant))
        or (d.small and rec().constructionSmall) or rec().construction
    -- leveled sites have their floor worked out; everything else sits on the land
    if not s.leveled then s.pos.z = landHeight(v3(s.pos)) or s.pos.z end
    objs.sites[sid] = placeObject(recordId, objectPos(sid), s.yaw, siteScale(sid), siteCell(sid))
    removeDecor(sid)
    if s.built then
        spawnDecor(sid)
        removeSiteFx(sid)
    else
        syncSiteFx(sid)
    end
    rebuildIndex()
end

---------------------------------------------------------------------------
-- workers

local function slotAngle(wid, sid)
    local list = C.assignedTo(c, sid)
    for i, id in ipairs(list) do
        if id == wid then return (i - 1) * 1.1 end
    end
    -- haulers/builders: spread by worker id number
    local n = tonumber(wid:match('%d+')) or 0
    return (n % 5) * 0.9 - 1.8
end

-- Tents: routes don't go through their doors, so settlers walk via a
-- waypoint in front of the door (always on the local -y side). This returns
-- the built tent a position is inside, if any.
local function tentAround(pos)
    for _, sid in ipairs(c.siteOrder) do
        local s = c.sites[sid]
        if s.built and defs.buildings[s.kind].hollow then
            local d = util.vector2(pos.x - s.pos.x, pos.y - s.pos.y):length()
            if d < siteRadius(sid) * 0.9 then return sid end
        end
    end
end

-- Points on the tent's door line: `outward` of its radius from the middle.
local function tentDoor(sid, outward)
    local s = c.sites[sid]
    local out = util.transform.rotateZ(s.yaw) * util.vector3(0, -siteRadius(sid) * outward, 0)
    local p = v3(s.pos) + out
    return util.vector3(p.x, p.y, landHeight(p) or s.pos.z)
end

-- The waypoints between two places when a tent wall is in the way: routes
-- lead to the front of the door, and settlers step through it in a straight
-- line. `inside` tells the worker its destination is under a tent roof.
local function tentRoute(from, to)
    if from == to then return nil, to ~= nil end
    local via = {}
    if from then
        via[#via + 1] = { pos = tentDoor(from, 0.55), straight = true }
        via[#via + 1] = { pos = tentDoor(from, 1.35), straight = true }
    end
    if to then
        via[#via + 1] = { pos = tentDoor(to, 1.35) }
        via[#via + 1] = { pos = tentDoor(to, 0.55), straight = true }
    end
    return via, to ~= nil
end

-- The spot just outside a house's door.
doorPoint = function(sid)
    local s = c.sites[sid]
    local d = defs.look(s.kind, s.variant).door
    local rot = util.transform.rotateZ(s.yaw)
    local door = objectPos(sid) + rot * util.vector3(d.offset[1], d.offset[2], d.offset[3])
    local out = util.transform.rotateZ(s.yaw + d.turn) * util.vector3(0, -130, 0)
    local p = door + out
    return util.vector3(p.x, p.y, landHeight(p) or s.pos.z)
end

-- Sends the worker's current step. `moveTo` (optional) is a position the
-- worker must be moved to first (stuck recovery). Position and facing are
-- applied in a single teleport: OpenMW rejects a second teleport of the
-- same object in one frame.
local function sendStep(wid, moveTo)
    local o = objs.workers[wid]
    local st = C.currentStep(c, wid)
    if not o or not o:isValid() or not st then return end
    tokenCounter = tokenCounter + 1
    tokens[wid] = tokenCounter
    stepStarted[wid] = c.time

    local msg = {}
    for k, v in pairs(st) do msg[k] = v end
    msg.token = tokenCounter
    if st.tool then msg.tool = rec().tools[st.tool] end
    local w = c.workers[wid]
    msg.carryModel = (w.carry and defs.carryModels[w.carry.res]) or (st.prop and defs.propModels[st.prop]) or nil
    stepLimit[wid] = math.max(STEP_WATCHDOG, (st.duration or 0) + 60)

    -- sleeping indoors: the settler simply isn't around until morning
    if objs.indoors[wid] then
        objs.indoors[wid] = nil
        o.enabled = true
    end
    local atSite = st.at and c.sites[st.at]
    local indoorsHere = atSite and atSite.host and (st.op == 'work' or st.op == 'interact' or st.op == 'sleep' or st.op == 'eat')
    if st.inside or indoorsHere then
        objs.indoors[wid] = c.time + (st.duration or 0)
        o:sendEvent('TMW_Stop')
        o.enabled = false
        return
    end
    if st.op == 'fight' then
        -- guards go for the nearest enemy
        local best, bestD
        for _, t in pairs(objs.threats) do
            if t:isValid() then
                local d = (t.position - o.position):length()
                if not bestD or d < bestD then best, bestD = t, d end
            end
        end
        msg.targetObj = best or objs.threats[st.target]
    end

    local sid = st.to or st.at or c.storehouse
    local s = c.sites[sid]
    local hostSite = s and s.host and c.sites[s.host]
    if hostSite or (s and st.door and defs.look(s.kind, s.variant).door) then
        -- to the door of the house: the rest happens inside
        msg.center = doorPoint(hostSite and s.host or sid)
        msg.standoff, msg.slotAngle = 40, 0
    elseif s then
        msg.center = v3(s.pos)
        -- around the building to come, not just its scaffold
        local radius = s.built and siteRadius(sid) or math.max(siteRadius(sid), footprintRadius(sid))
        msg.standoff = radius * 0.8 + 60
        msg.slotAngle = slotAngle(wid, sid)
        if st.meet then
            -- settlers meeting up: a spot beside the building
            local r = radius + 150
            local spot = v3(s.pos) + util.vector3(math.sin(st.meet) * r, math.cos(st.meet) * r, 0)
            msg.center = util.vector3(spot.x, spot.y, landHeight(spot) or s.pos.z)
            msg.standoff, msg.slotAngle = 50, 0
        end
        if st.with then msg.faceObj = objs.workers[st.with] end
        if st.op == 'goto' then
            local from, to = tentAround(moveTo or o.position), tentAround(msg.center)
            msg.via, msg.inside = tentRoute(from, to)
        end
    end

    if st.op == 'work' and s then
        local d = defs.buildings[s.kind]
        -- real work sounds like the place; tidying up sounds like a mallet
        msg.sound = (s.built and st.effect and d.sound) or defs.buildSound
        if s.built and st.effect and d.workFx then workFxOn(sid, (st.duration or 5) + 3) end
    end

    local pos = moveTo or o.position
    local opts
    if st.op == 'work' and s then
        -- face the work target
        local dir = (msg.center or v3(s.pos)) - pos
        opts = { rotation = util.transform.rotateZ(math.atan2(dir.x, dir.y)) }
    end
    local lying = st.op == 'sleep' and st.onBed and s
    if lying then
        -- lie down on the bed; on waking, get up beside it
        local d = defs.look(s.kind, s.variant)
        local rot = util.transform.rotateZ(s.yaw)
        pos = v3(s.pos) + util.vector3(0, 0, d.sleepZ or 40)
        opts = { rotation = util.transform.rotateZ(s.yaw + (defs.sleepYaw or 0)) }
        msg.wakeAt = v3(s.pos) + rot * util.vector3(0, -(siteRadius(sid) + 70), 10)
    end
    if moveTo or opts then
        opts = opts or {}
        opts.onGround = moveTo ~= nil and not lying
        local ok, err = pcall(o.teleport, o, o.cell, pos, opts)
        if not ok then log('teleport failed for', wid, err) end
    end
    o:sendEvent('TMW_Step', msg)
end

-- Now and then a settler remarks on what they're about to do.
local function maybeRemark(wid, task)
    local kindChanged = lastKind[wid] ~= task.kind
    lastKind[wid] = task.kind
    local lines = defs.utter.lines[task.label] or defs.utter.lines[task.kind]
    if not kindChanged or not lines or math.random() > defs.utter.chance then return end
    if c.time - (lastRemark[wid] or -1000) < defs.utter.cooldown then return end
    local w, o = c.workers[wid], objs.workers[wid]
    if w.prisoner or not o or not o:isValid() or objs.indoors[wid] then return end
    lastRemark[wid] = c.time
    o:sendEvent('TMW_Say', {
        text = lines[math.random(#lines)],
        voice = task.kind == 'shelter' and 'alarm' or (math.random() < defs.utter.voiceChance and 'grunt') or nil,
    })
end

local function startNextTask(wid)
    local task = C.nextTask(c, wid)
    sendStep(wid)
    maybeRemark(wid, task)
end

-- A settler said something: the player sees it as a bubble over their head.
local function onUtter(e)
    local p = player()
    if p and e.actor and e.actor:isValid() then
        p:sendEvent('TMW_Bubble', { obj = e.actor, text = e.text })
    end
end

-- Dress a settler for their job: the colony shirt plus job gear. Old job
-- gear is taken away (otherwise auto-equip would put it straight back on).
-- Prisoners keep their own clothes.
local function dress(wid)
    local w = c.workers[wid]
    local o = objs.workers[wid]
    if not w or w.prisoner or not o or not o:isValid() then return end
    local job
    if w.assignment == 'builder' then
        job = 'Builder'
    elseif w.assignment and c.sites[w.assignment] then
        job = defs.buildings[c.sites[w.assignment].kind].job
    end
    local uniformIds = rec().uniform
    local wear = {}
    for _, slot in ipairs(defs.uniform.managed) do wear[slot] = false end
    for slot, piece in pairs(defs.uniform.base) do wear[slot] = uniformIds[piece.template] end
    for slot, piece in pairs(job and defs.uniform.jobs[job] or {}) do wear[slot] = uniformIds[piece.template] end
    local wanted = {}
    for _, id in pairs(wear) do if id then wanted[id] = true end end
    local inv = types.Actor.inventory(o)
    for _, id in pairs(uniformIds) do
        local item = inv:find(id)
        if item and not wanted[id] then item:remove() end
        if wanted[id] and not item then world.createObject(id):moveInto(inv) end
    end
    o:sendEvent('TMW_Wear', wear)
end

local function spawnWorker()
    local store = c.sites[c.storehouse]
    if not store then return end
    local recordId, name = records.newSettler()
    local w = C.addWorker(c, { name = name, recordId = recordId })
    local a = math.random() * 2 * math.pi
    local r = siteRadius(c.storehouse) + 250
    local pos = v3(store.pos) + util.vector3(math.sin(a) * r, math.cos(a) * r, 50)
    local o = world.createObject(recordId)
    o:teleport('', pos, { onGround = true })
    -- every settler carries the full tool set
    for _, toolId in pairs(rec().tools) do
        world.createObject(toolId):moveInto(types.Actor.inventory(o))
    end
    o:addScript(WORKER_SCRIPT, { wid = w.id })
    if debugOn then o:sendEvent('TMW_SetDebug', true) end
    objs.workers[w.id] = o
    dress(w.id)
    rebuildIndex()
    message(name .. ' has joined the colony.')
    log('worker joined', w.id, name)
end

---------------------------------------------------------------------------
-- events from the core

---------------------------------------------------------------------------
-- caravans

local function caravanRemove()
    for _, o in pairs(objs.caravan) do
        if o:isValid() then o:remove() end
    end
    objs.caravan = {}
    caravanTraderId = nil
end

caravanArrives = function(marketId)
    caravanRemove()
    local market = c.sites[marketId]
    local base = types.NPC.records['assumanu mantiti']
    local rec_ = world.createRecord(types.NPC.createRecordDraft({
        template = base, name = 'Hlaalu Caravan Trader', isMale = true, class = 'commoner',
        head = 'b_n_dark elf_m_head_07', hair = 'b_n_dark elf_m_hair_03',
    }))
    -- they come walking in from out of town, with a pack guar in tow
    local a = market.yaw + 2.2
    local from = v3(market.pos) + util.vector3(math.sin(a) * 1300, math.cos(a) * 1300, 60)
    local stand = v3(market.pos) + util.transform.rotateZ(market.yaw) * util.vector3(-60, -150, 0)
    local trader = world.createObject(rec_.id)
    trader:teleport('', from, { onGround = true })
    trader:sendEvent('StartAIPackage', { type = 'Travel', destPosition = stand })
    local guar = world.createObject('guar_pack')
    guar:teleport('', from + util.vector3(120, -60, 0), { onGround = true })
    guar:sendEvent('StartAIPackage', { type = 'Follow', target = trader })
    objs.caravan = { trader = trader, guar = guar }
    caravanTraderId = trader.id
end

caravanLeaves = function()
    caravanRemove()
end

-- Pack guars get stuck easily: once the trader is at the stall, so is the guar.
local function caravanGuar()
    local trader, guar = objs.caravan.trader, objs.caravan.guar
    if not (trader and guar and trader:isValid() and guar:isValid()) then return end
    local market = C.marketSite(c)
    if market and (trader.position - v3(market.pos)):length() < 350 and (guar.position - trader.position):length() > 500 then
        guar:teleport('', trader.position + util.transform.rotateZ(market.yaw) * util.vector3(170, -60, 40), { onGround = true })
    end
end

---------------------------------------------------------------------------
-- interiors: every house has a room of its own in the interior cell. Its
-- architecture is copied from a vanilla house when it's first entered; its
-- furniture stays there, as sites hosted by the house.

local function roomOrigin(sid)
    return util.vector3(C.roomOf(c, sid) * defs.roomSpacing, 0, 0)
end

local function roomTransform(piece)
    local t = util.transform
    return t.rotateZ(piece[7]) * t.rotateY(piece[6]) * t.rotateX(piece[5])
end

local function buildRoom(sid)
    if objs.shells[sid] then return end
    local s = c.sites[sid]
    local room = interiors[defs.look(s.kind, s.variant).door.interior]
    local origin = roomOrigin(sid)
    local shell, exits = {}, {}
    local function place(piece)
        local o = world.createObject(piece[1])
        o:teleport(interiors.cell, origin + util.vector3(piece[2], piece[3], piece[4]), { rotation = roomTransform(piece) })
        if piece[8] and piece[8] ~= 1 then o:setScale(piece[8]) end
        return o
    end
    for _, piece in ipairs(room.pieces) do shell[#shell + 1] = place(piece) end
    for _, piece in ipairs(room.exits) do exits[#exits + 1] = place(piece) end
    objs.shells[sid], objs.exits[sid] = shell, exits
    rebuildIndex()
    log('built room', sid, #shell, 'pieces')
end

local function enterHouse(sid, actor)
    local ok, cell = pcall(world.getCellByName, interiors.cell)
    if not ok or not cell then
        return message('Enable Tomorrowind.omwaddon in the launcher to enter houses.')
    end
    buildRoom(sid)
    local s = c.sites[sid]
    local room = interiors[defs.look(s.kind, s.variant).door.interior]
    objs.insideHost = sid
    actor:teleport(interiors.cell, roomOrigin(sid), { rotation = util.transform.rotateZ(room.arrive.yaw) })
    actor:sendEvent('TMW_Face', { yaw = room.arrive.yaw })
    pushState()
end

local function leaveHouse(sid, actor)
    local s = c.sites[sid]
    local d = defs.look(s.kind, s.variant).door
    objs.insideHost = nil
    local yaw = s.yaw + d.turn + math.pi
    actor:teleport('', doorPoint(sid) + util.vector3(0, 0, 20), { rotation = util.transform.rotateZ(yaw), onGround = true })
    actor:sendEvent('TMW_Face', { yaw = yaw })
    pushState()
end

-- A house is gone: its room goes too (the furniture has its own removal).
removeRoom = function(sid)
    if objs.insideHost == sid and player() then
        local p = player()
        local s = c.sites[c.storehouse]
        objs.insideHost = nil
        p:teleport('', v3(s.pos) + util.vector3(0, -600, 100), { onGround = true })
    end
    for _, o in ipairs(objs.shells[sid] or {}) do if o:isValid() then o:remove() end end
    for _, o in ipairs(objs.exits[sid] or {}) do if o:isValid() then o:remove() end end
    objs.shells[sid], objs.exits[sid], objs.doors[sid] = nil, nil, nil
end

---------------------------------------------------------------------------

-- Everyone drops what they're doing and re-plans (alarm / all clear).
local function replanAll()
    for _, wid in ipairs(c.workerOrder) do
        C.cancelTask(c, wid)
        tokens[wid] = nil
        local o = objs.workers[wid]
        if o and o:isValid() then o:sendEvent('TMW_Stop') end
    end
end

local function processEvents()
    for _, e in ipairs(C.drainEvents(c)) do
        if e.kind == 'alarm' or e.kind == 'all_clear' then
            replanAll()
            log(e.kind)
        elseif e.kind == 'arrival' then
            spawnWorker()
        elseif e.kind == 'site_placed' then
            setSiteObject(e.site)
            -- new work: those just pottering about get to it
            for _, wid in ipairs(c.workerOrder) do
                local w = c.workers[wid]
                if w.task and w.task.downtime and not w.prisoner and C.workerPeriod(c, wid) == 'work' then
                    C.cancelTask(c, wid)
                    tokens[wid] = nil
                    local o = objs.workers[wid]
                    if o and o:isValid() then o:sendEvent('TMW_Stop') end
                end
            end
        elseif e.kind == 'retask' then
            local o = objs.workers[e.wid]
            if o and o:isValid() and c.workers[e.wid] then
                o:sendEvent('TMW_Stop')
                sendStep(e.wid)
            end
        elseif e.kind == 'built' then
            setSiteObject(e.site)
            log('built', e.site, c.sites[e.site].kind)
        elseif e.kind == 'caravan_arrived' then
            caravanArrives(e.site)
        elseif e.kind == 'caravan_left' then
            caravanLeaves()
        elseif e.kind == 'site_removed' then
            removeRoom(e.site)
            local o = objs.sites[e.site]
            if o and o:isValid() then
                -- what was in a chest goes to the player, not into thin air
                if types.Container.objectIsInstance(o) and player() then
                    local inv = types.Container.inventory(o)
                    inv:resolve()
                    for _, item in ipairs(inv:getAll()) do item:moveInto(types.Actor.inventory(player())) end
                end
                o:remove()
            end
            objs.sites[e.site] = nil
            removeDecor(e.site)
            removeSiteFx(e.site)
            local fire = objs.workfx[e.site]
            if fire and fire:isValid() then fire:remove() end
            objs.workfx[e.site] = nil
            rebuildIndex()
        elseif e.kind == 'msg' then
            message(e.text)
        end
    end
end

---------------------------------------------------------------------------
-- snapshot for the UI

local function snapshot()
    if not c then return { founded = false } end
    local snap = {
        founded = true,
        stock = {}, available = {},
        beds = C.beds(c), pop = C.population(c), pending = c.pendingArrivals,
        prisoners = C.prisonerCount(c), cells = (C.cells(c)),
        underAttack = C.underAttack(c),
        hour = c.hourOfDay, period = C.period(c), capacity = C.capacity(c),
        insideHost = objs.insideHost, caravanObj = objs.caravan.trader,
        gold = C.gold(c), caravan = C.caravanHere(c), market = C.marketSite(c) ~= nil, trade = {},
        workers = {}, sites = {}, options = {},
        storePos = c.storehouse and v3(c.sites[c.storehouse].pos),
    }
    for _, r in ipairs(defs.resourceOrder) do
        snap.stock[r] = c.stock[r]
        snap.available[r] = C.available(c, r)
        local t = C.tradeOf(c)
        snap.trade[r] = { sell = C.sellPrice(c, r), buy = C.buyPrice(r), keep = t.keep[r] or 0, want = t.want[r] or 0 }
    end
    for _, wid in ipairs(c.workerOrder) do
        local w = c.workers[wid]
        snap.workers[#snap.workers + 1] = {
            id = wid, name = w.name, obj = objs.workers[wid],
            assignment = w.assignment or false,
            job = C.assignmentLabel(c, w.assignment, w.prisoner),
            prisoner = w.prisoner,
            status = C.workerStatus(c, wid),
            fed = w.fed,
        }
    end
    for _, sid in ipairs(c.siteOrder) do
        local s = c.sites[sid]
        snap.sites[#snap.sites + 1] = {
            id = sid, kind = s.kind, name = defs.buildings[s.kind].name,
            built = s.built, status = C.siteStatus(c, sid),
            progress = C.siteProgress(c, sid),
            pos = v3(s.pos), radius = siteRadius(sid),
            obj = objs.sites[sid], yaw = s.yaw, small = defs.buildings[s.kind].small, variant = s.variant, host = s.host,
        }
    end
    for _, opt in ipairs(C.assignmentOptions(c)) do
        snap.options[#snap.options + 1] = { id = opt, label = C.assignmentLabel(c, opt) }
    end
    return snap
end

pushState = function()
    local p = player()
    if p then p:sendEvent('TMW_State', snapshot()) end
end

---------------------------------------------------------------------------
-- main loop

local function activeSet()
    local set = {}
    for _, a in ipairs(world.activeActors) do set[a.id] = true end
    return set
end

-- Dead settlers leave the colony: their task is cancelled (reserved
-- materials are released, carried goods go back to the stockpile) and a
-- bed frees up. The body stays in the world.
local function checkDeaths()
    local changed = false
    for i = #c.workerOrder, 1, -1 do
        local wid = c.workerOrder[i]
        local o = objs.workers[wid]
        if o and o:isValid() and types.Actor.isDead(o) then
            local name = c.workers[wid].name
            C.removeWorker(c, wid)
            objs.workers[wid] = nil
            tokens[wid] = nil
            changed = true
            message(name .. ' has died.')
            log('worker died', wid, name)
        end
    end
    if changed then rebuildIndex() end
end

local function distToStore(pos)
    local store = c.sites[c.storehouse]
    if not store then return math.huge end
    return (pos - v3(store.pos)):length()
end

-- Threats end when the enemy dies, is knocked out (handled by
-- TMW_Subdued) or runs off.
checkThreats = function()
    for tid, o in pairs(objs.threats) do
        local gone = not o:isValid()
        local dead = not gone and types.Actor.isDead(o)
        local fled = not gone and not dead and distToStore(o.position) > defs.defense.colonyRadius * 1.5
        if gone or dead or fled then
            local name = c.threats[tid] and c.threats[tid].name or 'The attacker'
            objs.threats[tid] = nil
            C.removeThreat(c, tid)
            if dead then message(name .. ' is dead.') elseif fled then message(name .. ' fled.') end
            log('threat over', tid, dead and 'dead' or fled and 'fled' or 'gone')
        end
    end
    processEvents()
end

-- When the player comes back, tell them what happened while they were away.
local function noteAway(anyActive)
    if not anyActive then
        if not awayFrom then
            awayFrom = { time = c.time, stock = {}, built = 0, gold = C.gold(c) }
            for _, r in ipairs(defs.resourceOrder) do awayFrom.stock[r] = c.stock[r] end
            for _, sid in ipairs(c.siteOrder) do
                if c.sites[sid].built then awayFrom.built = awayFrom.built + 1 end
            end
        end
        return
    end
    if not awayFrom then return end
    local was = awayFrom
    awayFrom = nil
    if c.time - was.time < defs.awaySummaryAfter then return end
    local parts = {}
    for _, r in ipairs(defs.resourceOrder) do
        local gained = math.floor(c.stock[r] - was.stock[r])
        if gained > 0 then parts[#parts + 1] = '+' .. gained .. ' ' .. defs.resources[r].name end
    end
    local earned = math.floor(C.gold(c) - was.gold)
    if earned > 0 then parts[#parts + 1] = '+' .. earned .. ' gold' end
    local built = -was.built
    for _, sid in ipairs(c.siteOrder) do
        if c.sites[sid].built then built = built + 1 end
    end
    if built > 0 then parts[#parts + 1] = built .. (built == 1 and ' new building' or ' new buildings') end
    log('back after', math.floor(c.time - was.time), 's away:', table.concat(parts, ', '))
    if #parts > 0 then message('While you were away: ' .. table.concat(parts, ', ') .. '.') end
end

-- Construction moves on every other frame or so, so buildings rise smoothly.
local function updateSites(dt)
    siteTimer = siteTimer + dt
    if siteTimer < SITE_INTERVAL then return end
    siteTimer = 0
    for _, sid in ipairs(c.siteOrder) do
        if not c.sites[sid].built then syncSiteFx(sid) end
    end
end

local function updateWorkers(dt)
    offscreenDt = offscreenDt + dt
    activeTimer = activeTimer + dt
    if activeTimer < ACTIVE_INTERVAL then return end
    activeTimer = 0
    checkDeaths()
    checkThreats()
    updateWorkFx()
    caravanGuar()
    local active = activeSet()
    local anyActive = false
    for _, wid in ipairs(c.workerOrder) do
        local w = c.workers[wid]
        local o = objs.workers[wid]
        local isActive = o and o:isValid() and active[o.id]
        anyActive = anyActive or isActive
        local wakeAt = objs.indoors[wid]
        if wakeAt then
            -- asleep indoors: wakes in the morning, or when the task was
            -- cancelled (alarm, time skip)
            if not w.task or c.time >= wakeAt then
                if w.task then C.completeStep(c, wid) end
                startNextTask(wid)
            end
        elseif isActive then
            if w.offscreen then
                w.offscreen = false
                tokens[wid] = nil
            end
            if not tokens[wid] or not w.task then
                startNextTask(wid)
            elseif c.time - (stepStarted[wid] or c.time) > (stepLimit[wid] or STEP_WATCHDOG) then
                log('watchdog: replanning', wid)
                startNextTask(wid)
            end
        else
            if not w.offscreen then
                w.offscreen = true
                C.cancelTask(c, wid)
                tokens[wid] = nil
            end
            C.simulateWorker(c, wid, offscreenDt)
        end
    end
    -- inside one of the colony's own houses isn't away
    if #c.workerOrder > 0 then noteAway(anyActive or objs.insideHost ~= nil) end
    offscreenDt = 0
end

-- The colony board stands by the storehouse.
local function addBoard()
    local store = c.sites[c.storehouse]
    local rot = util.transform.rotateZ(store.yaw)
    local p = v3(store.pos) + rot * util.vector3(siteRadius(c.storehouse) + 60, -siteRadius(c.storehouse) * 0.7, 0)
    local s = C.addSite(c, 'board', plain(p), store.yaw, true)
    setSiteObject(s.id)
end

-- Older saves: buildings whose model changed get their new look.
local function migrateSites()
    local hasBoard = false
    for _, sid in ipairs(c.siteOrder) do
        if c.sites[sid].kind == 'board' then hasBoard = true end
    end
    if not hasBoard and c.storehouse then addBoard() end
    for _, sid in ipairs(c.siteOrder) do
        local s = c.sites[sid]
        if s.built and not s.host and defs.look(s.kind, s.variant).door and not objs.doors[sid] then
            setSiteObject(sid)
        end
    end
    for _, sid in ipairs(c.siteOrder) do
        local o = objs.sites[sid]
        if c.sites[sid].built and o and o:isValid() and o.recordId ~= lookRecord(c.sites[sid].kind, c.sites[sid].variant) then
            log('updating model of', sid, c.sites[sid].kind)
            setSiteObject(sid)
        end
    end
end

local function onUpdate(dt)
    applyGhostMove()
    if not c then return end
    if needsMigration then
        needsMigration = false
        migrateSites()
    end
    local gt = world.getGameTime()
    lastGameTime = lastGameTime or gt
    local hours = math.max(0, (gt - lastGameTime) / 3600)
    lastGameTime = gt
    local scale = world.getGameTimeScale()
    local expected = dt * scale / 3600
    local hourNow = (gt / 3600) % 24
    local skipping = hours > expected * 3 + 0.05
    C.setClock(c, hourNow, scale)
    if skipping then
        -- time skip (wait, rest, travel): simulate the working hours within it
        local skipped = hours - expected
        log(string.format('time skip of %.2f h', skipped))
        for _, wid in ipairs(c.workerOrder) do
            tokens[wid] = nil
            C.simulateWorker(c, wid, C.workSeconds(c, (hourNow - skipped) % 24, skipped, wid), true)
        end
    end
    C.tick(c, dt, hours, skipping)
    updateWorkers(dt)
    updateSites(dt)
    processEvents()

    stateTimer = stateTimer + dt
    if stateTimer >= STATE_INTERVAL then
        stateTimer = 0
        pushState()
    end
end

---------------------------------------------------------------------------
-- commands from the player

local function found(e)
    if c then return message('A colony already exists.') end
    local p = player()
    if not p.cell or not p.cell.isExterior then
        return message('A colony must be founded outdoors.')
    end
    c = C.new()
    local yaw = e.yaw or 0
    local pos = e.pos or (p.position + util.vector3(math.sin(yaw) * 600, math.cos(yaw) * 600, 0))
    local s = C.found(c, plain(pos), yaw)
    setSiteObject(s.id)
    addBoard()
    lastGameTime = world.getGameTime()
    message('You have founded a colony. Your first settlers are on their way.')
    log('colony founded at', pos)
    processEvents()
    pushState()
end

local function onStepDone(e)
    if not c then return end
    local wid = e.wid or (e.actor and workerByObj[e.actor.id])
    if not wid or not c.workers[wid] or tokens[wid] ~= e.token then return end
    if e.teleport then log('stuck, teleporting', wid) end
    if C.completeStep(c, wid) then
        sendStep(wid, e.teleport)
    else
        local task = C.nextTask(c, wid)
        sendStep(wid, e.teleport)
        maybeRemark(wid, task)
    end
    processEvents()
end

-- A settler couldn't step through a tent door by themselves.
local function onHop(e)
    local a = e.actor
    if a and a:isValid() then pcall(a.teleport, a, a.cell, e.pos, { onGround = true }) end
end

local function recordName(o)
    local ok, r = pcall(function() return o.type.record(o) end)
    return ok and r and r.name or 'an attacker'
end

local function onAttacked(e)
    local a = e.attacker
    if not c or not a or not a:isValid() then return end
    if a.type == types.Player or workerByObj[a.id] then return end
    if types.Actor.isDead(a) or distToStore(a.position) > defs.defense.colonyRadius then return end
    for _, o in pairs(objs.threats) do
        if o.id == a.id then return end
    end
    local tid = C.addThreat(c, { name = recordName(a) })
    objs.threats[tid] = a
    -- with room in the stockade, NPC attackers are taken alive
    if a.type == types.NPC and C.canTakePrisoner(c) and not a:hasScript(CAPTIVE_SCRIPT) then
        a:addScript(CAPTIVE_SCRIPT)
    end
    log('threat', tid, recordName(a))
    processEvents()
end

local function onSubdued(e)
    local a = e.actor
    if not c or not a or not a:isValid() then return end
    for tid, o in pairs(objs.threats) do
        if o.id == a.id then
            objs.threats[tid] = nil
            C.removeThreat(c, tid)
        end
    end
    if a:hasScript(CAPTIVE_SCRIPT) then a:removeScript(CAPTIVE_SCRIPT) end
    if not C.canTakePrisoner(c) or workerByObj[a.id] then
        processEvents()
        return
    end
    local name = recordName(a)
    local w = C.addWorker(c, { name = name, recordId = a.recordId, prisoner = true })
    for _, toolId in pairs(rec().tools) do
        world.createObject(toolId):moveInto(types.Actor.inventory(a))
    end
    a:addScript(WORKER_SCRIPT, { wid = w.id, prisoner = true })
    objs.workers[w.id] = a
    rebuildIndex()
    message(name .. ' has been knocked out and taken prisoner.')
    log('prisoner', w.id, name)
    processEvents()
end

-- Guards get a sword and some chitin the first time they're posted.
local function equipGuard(wid)
    local w = c.workers[wid]
    local o = objs.workers[wid]
    if w.geared or not o or not o:isValid() then return end
    for _, id in ipairs(defs.guardGear) do
        world.createObject(id):moveInto(types.Actor.inventory(o))
    end
    o:sendEvent('TMW_TrainGuard')
    w.geared = true
end

local function assign(e)
    if not c then return end
    local ok, err = C.assign(c, e.wid, e.target or nil)
    if not ok then return message(err) end
    if C.isGuard(c, e.wid) then equipGuard(e.wid) end
    dress(e.wid)
    tokens[e.wid] = nil -- replan on next active pass
    local o = objs.workers[e.wid]
    if o and o:isValid() then o:sendEvent('TMW_Stop') end
    pushState()
end

local function removeGhost()
    -- pcall: an object created this very frame can't be removed yet
    if ghost and ghost.obj and ghost.obj:isValid() then pcall(ghost.obj.remove, ghost.obj) end
    ghost = nil
end

local function beginPlace(e)
    if not c then return message('Found a colony first.') end
    local d = defs.buildings[e.kind]
    if not d then return end
    removeGhost()
    local p = player()
    local look = defs.look(e.kind, e.variant)
    local o = world.createObject(lookRecord(e.kind, e.variant))
    o:teleport(p.cell, p.position + util.vector3(0, 0, -5000))
    if look.scale then o:setScale(look.scale) end
    ghost = { obj = o, kind = e.kind, variant = e.variant }
    p:sendEvent('TMW_Ghost', { obj = o, kind = e.kind })
end

-- The player sends a position every frame; apply at most one teleport per
-- frame (OpenMW rejects a second teleport of the same object in a frame).
local function placeMove(e)
    if ghost then ghost.pending = e end
end

applyGhostMove = function()
    local e = ghost and ghost.pending
    if not e then return end
    ghost.pending = nil
    if ghost.obj:isValid() then
        local lift = defs.look(ghost.kind, ghost.variant).lift or 0
        pcall(ghost.obj.teleport, ghost.obj, objs.insideHost and interiors.cell or '', e.pos + util.vector3(0, 0, lift), { rotation = util.transform.rotateZ(e.yaw or 0) })
    end
end

local function placeConfirm(e)
    if not c or not ghost then return end
    local kind = ghost.kind
    local variant = ghost.variant
    removeGhost()
    local s = C.addSite(c, kind, plain(e.pos), e.yaw or 0, false, { foundation = e.foundation, variant = variant, host = objs.insideHost })
    s.leveled = true -- e.pos.z is the computed floor level
    s.radius = e.radius
    processEvents()
    message(defs.buildings[kind].name .. ' site placed.')
    pushState()
end

local function tradeSet(e)
    if not c or not defs.trade.prices[e.res] then return end
    if e.keep then C.setKeep(c, e.res, e.keep) end
    if e.want then C.setWant(c, e.res, e.want) end
    pushState()
end

-- amount > 0: from the treasury to the player; < 0: the other way.
local function treasury(e)
    local p = player()
    if not c or not p then return end
    local inv = types.Actor.inventory(p)
    if e.amount > 0 then
        local n = C.withdraw(c, e.amount)
        if n > 0 then world.createObject('gold_001', n):moveInto(inv) end
    else
        local have = inv:countOf('gold_001')
        local n = math.min(have, -e.amount)
        if n > 0 then
            inv:find('gold_001'):remove(n)
            C.deposit(c, n)
        end
    end
    pushState()
end

local function removeSite(e)
    if not c then return end
    if C.removeSite(c, e.sid) then
        processEvents()
        pushState()
    end
end

-- Debug / test helpers (used by the autotest script and the console)
local function debugCommand(e)
    if e.cmd == 'give' and c then
        for res, n in pairs(e.amounts or {}) do c.stock[res] = (c.stock[res] or 0) + n end
        if e.gold then C.deposit(c, e.gold) end
    elseif e.cmd == 'build' and c then
        local s = C.addSite(c, e.kind, plain(e.pos), e.yaw or 0, e.built, { foundation = e.foundation, variant = e.variant })
        s.leveled, s.radius = e.leveled, e.radius
        if e.built then setSiteObject(s.id) end
        processEvents()
    elseif e.cmd == 'tp' then
        -- move the player to look at a point (used for test screenshots)
        local p = player()
        local dir = e.lookAt - e.pos
        p:teleport('', e.pos, { rotation = util.transform.rotateZ(math.atan2(dir.x, dir.y)), onGround = true })
    elseif e.cmd == 'finish' and c then
        for _, sid in ipairs(c.siteOrder) do C.finishSite(c, sid) end
        processEvents()
    elseif e.cmd == 'pilings' and c then
        for sid, list in pairs(objs.decor) do
            local s = c.sites[sid]
            for _, o in ipairs(list) do
                if o:isValid() and o.recordId == rec().decor.piling then
                    local ok, box = pcall(o.getBoundingBox, o)
                    log(string.format('piling at site %s floor=%.0f origin=%.0f box z=[%.0f,%.0f]', sid, s.pos.z, o.position.z,
                        ok and box.center.z - box.halfSize.z or -1, ok and box.center.z + box.halfSize.z or -1))
                    break
                end
            end
            if s and s.leveled then
                log(string.format('leveled site %s %s floor=%.0f wood=%s work=%s', sid, s.kind, s.pos.z, tostring(s.cost.wood), tostring(s.levelWork)))
            end
        end
    elseif e.cmd == 'hostile' and c then
        -- a test bandit that attacks the first settler
        local base = types.NPC.records['assumanu mantiti']
        local r = world.createRecord(types.NPC.createRecordDraft({ template = base, name = 'Test Bandit', isMale = true,
            head = 'b_n_dark elf_m_head_04', hair = 'b_n_dark elf_m_hair_05', class = 'commoner' }))
        local o = world.createObject(r.id)
        -- by the first settler, or right next to a guard
        local victim = objs.workers[c.workerOrder[1]]
        local pos = e.pos
        if e.nearGuard then
            for _, wid in ipairs(c.workerOrder) do
                local g = objs.workers[wid]
                if C.isGuard(c, wid) and g and g:isValid() then victim = g break end
            end
            pos = victim.position + util.vector3(math.sin(e.angle or 0) * e.nearGuard, math.cos(e.angle or 0) * e.nearGuard, 60)
        end
        o:teleport('', pos, { onGround = true })
        world.createObject('iron club'):moveInto(types.Actor.inventory(o))
        if e.alarm then onAttacked({ attacker = o }) end
        if victim then o:sendEvent('StartAIPackage', { type = 'Combat', target = victim }) end
        log('spawned test hostile')
    elseif e.cmd == 'debug' then
        debugOn = e.on
        if player() then player():sendEvent('TMW_SetDebug', e.on) end
        for _, o in pairs(objs.workers) do
            if o:isValid() then o:sendEvent('TMW_SetDebug', e.on) end
        end
    elseif e.cmd == 'activate' and c then
        -- test helper: the player uses the first site of a kind
        for _, sid in ipairs(c.siteOrder) do
            if c.sites[sid].kind == e.kind then
                objs.sites[sid]:activateBy(player())
                log('activated', e.kind)
                break
            end
        end
    elseif e.cmd == 'stash' and c then
        -- test helper: put something in the first chest
        for _, sid in ipairs(c.siteOrder) do
            if c.sites[sid].kind == 'chest' then
                world.createObject('ingred_saltrice_01', 3):moveInto(types.Container.inventory(objs.sites[sid]))
                log('stashed in', sid)
                break
            end
        end
    elseif e.cmd == 'removekind' and c then
        for _, sid in ipairs(c.siteOrder) do
            if c.sites[sid].kind == e.kind then
                C.removeSite(c, sid)
                processEvents()
                log('removed', e.kind)
                break
            end
        end
    elseif e.cmd == 'enter' and c then
        for _, sid in ipairs(c.siteOrder) do
            local site = c.sites[sid]
            if objs.doors[sid] and (not e.at or (v3(site.pos) - util.vector3(e.at.x, e.at.y, site.pos.z)):length() < 5) then
                objs.doors[sid]:activateBy(player())
                break
            end
        end
    elseif e.cmd == 'leave' and c and objs.insideHost then
        objs.exits[objs.insideHost][1]:activateBy(player())
    elseif e.cmd == 'caravan' and c then
        local t = C.tradeOf(c)
        t.caravanTimer = defs.trade.caravan.everyHours
        C.tick(c, 0, 0.001)
        processEvents()
    elseif e.cmd == 'doorinfo' and c then
        for _, sid in ipairs(c.siteOrder) do
            local o = objs.doors[sid]
            if o and o:isValid() then log('door', sid, c.sites[sid].kind, c.sites[sid].variant, o.position, doorPoint(sid)) end
        end
    elseif e.cmd == 'movew' and c then
        local o = objs.workers[e.wid]
        if o then o:teleport(o.cell, e.pos, { onGround = true }) end
    elseif e.cmd == 'risedump' and c then
        for sid, fx in pairs(objs.sitefx) do
            if fx.rising and fx.rising:isValid() then
                log(string.format('rise %s shown=%.3f progress=%.1f/%.1f z=%.0f', sid, fx.riseShown or -1, c.sites[sid].progress, c.sites[sid].work, fx.rising.position.z))
            end
        end
    elseif e.cmd == 'talk' and c then
        local o = objs.workers[c.workerOrder[1]]
        if o then o:activateBy(player()) end
    elseif e.cmd == 'spawn' and c then
        for _ = 1, e.n or 1 do spawnWorker() end
    elseif e.cmd == 'say' and c then
        local o = objs.workers[e.wid or c.workerOrder[1]]
        if o then o:sendEvent('TMW_Say', { text = e.text, voice = e.voice }) end
    elseif e.cmd == 'stripdecor' and c then
        for _, sid in ipairs(c.siteOrder) do
            if c.sites[sid].kind == e.kind then removeDecor(sid) end
        end
    elseif e.cmd == 'hour' then
        -- test helper: run the clock forward to an hour of the day
        world.advanceTime(((e.hour - (world.getGameTime() / 3600)) % 24))
    elseif e.cmd == 'quiet' then
        quiet = e.on
        if player() then player():sendEvent('TMW_DebugQuiet', e.on) end
    elseif e.cmd == 'sitestate' and c then
        -- test helper: jump a construction site (by kind, or the one at a
        -- position) to a stage of its progress, or finish it
        for _, sid in ipairs(c.siteOrder) do
            local site = c.sites[sid]
            local here = e.at and (v3(site.pos) - util.vector3(e.at.x, e.at.y, site.pos.z)):length() < 5
            if (here or (not e.at and site.kind == e.kind)) and not site.built then
                if e.finish then
                    C.finishSite(c, sid)
                    processEvents()
                    break
                end
                for res, total in pairs(site.cost) do
                    site.needs[res] = math.floor(total * (1 - e.delivered) + 0.5)
                end
                site.progress = site.work * (e.progress or 0)
            end
        end
    elseif e.cmd == 'fxdump' and c then
        for _, sid in ipairs(c.siteOrder) do
            local site = c.sites[sid]
            local o = objs.sites[sid]
            local fx = objs.sitefx[sid]
            local parts = {}
            for res, list in pairs(fx and fx.piles or {}) do parts[#parts + 1] = res .. '=' .. #list end
            local box = o and o:isValid() and o:getBoundingBox()
            local fire = objs.workfx[sid]
            local objZ = o and o:isValid() and o.position.z or -1
            if fx and fx.rising and fx.rising:isValid() then
                log(string.format('rising %s z=%.0f scale=%.2f step=%s', site.kind, fx.rising.position.z, fx.rising.scale, tostring(fx.riseStep)))
            end
            log(string.format('fx %s %-10s built=%s z=%.0f land=%.0f half=%s scale=%.2f piles[%s] pilings=%d/%d decor=%d fire=%s | %s', sid, site.kind, tostring(site.built),
                objZ, landHeight(v3(site.pos)) or -1,
                box and tostring(box.halfSize) or '?', o and o:isValid() and o.scale or -1, table.concat(parts, ' '),
                fx and fx.pilings and #fx.pilings or 0, fx and fx.spots and #fx.spots or 0,
                #(objs.decor[sid] or {}), tostring(fire and fire:isValid()), C.siteStatus(c, sid)))
        end
    elseif e.cmd == 'dump' then
        log('state', c and C.population(c), c and c.stock.food)
    end
    pushState()
end

---------------------------------------------------------------------------
-- activation: buildings open the colony panel (settlers just talk)

I.Activation.addHandlerForType(types.Door, function(obj, actor)
    local door = doorByObj[obj.id]
    if door and actor.type == types.Player then
        local s = c and c.sites[door.sid]
        if s and s.built then
            core.sound.playSound3d('Door Heavy Open', actor)
            if door.exit then leaveHouse(door.sid, actor) else enterHouse(door.sid, actor) end
        end
        return false
    end
end)

-- The caravan's trader opens the trade page.
I.Activation.addHandlerForType(types.NPC, function(obj, actor)
    if obj.id == caravanTraderId and actor.type == types.Player then
        actor:sendEvent('TMW_OpenLedger', { tab = 'trade' })
        return false
    end
end)

I.Activation.addHandlerForType(types.Activator, function(obj, actor)
    if ghost and ghost.obj:isValid() and ghost.obj.id == obj.id then return false end
    local sid = siteByObj[obj.id]
    if sid and actor.type == types.Player then
        local site = c and c.sites[sid]
        local d = site and defs.buildings[site.kind]
        if d and d.opensLedger and site.built then
            actor:sendEvent('TMW_OpenLedger')
        elseif not (site and site.built and d.small) then
            actor:sendEvent('TMW_OpenSite', { sid = sid })
        end
        return false
    end
end)

return {
    engineHandlers = {
        onUpdate = onUpdate,
        onSave = function()
            return { colony = c, objs = objs, recIds = recIds, ghost = ghost }
        end,
        onLoad = function(data)
            data = data or {}
            c = data.colony
            objs = data.objs or { sites = {}, workers = {}, decor = {} }
            objs.decor = objs.decor or {}
            objs.threats = objs.threats or {}
            objs.sitefx = objs.sitefx or {}
            objs.shells, objs.exits, objs.doors = objs.shells or {}, objs.exits or {}, objs.doors or {}
            objs.caravan = objs.caravan or {}
            caravanTraderId = objs.caravan.trader and objs.caravan.trader:isValid() and objs.caravan.trader.id or nil
            objs.workfx = objs.workfx or {} -- fires go out on the next update
            -- tasks don't survive a reload: everyone who was asleep indoors gets up
            for wid in pairs(objs.indoors or {}) do
                local o = objs.workers[wid]
                if o and o:isValid() then o.enabled = true end
            end
            objs.indoors = {}
            -- saves clamp scales: rising buildings get theirs back on the next step
            for _, fx in pairs(objs.sitefx) do fx.riseStep = nil end
            workFxUntil = {}
            needsMigration = true
            recIds = data.recIds
            ghost = data.ghost
            removeGhost() -- placement does not survive a reload
            tokens = {}
            if c then
                for _, wid in ipairs(c.workerOrder) do C.cancelTask(c, wid) end
            end
            lastGameTime = nil
            rebuildIndex()
        end,
        onPlayerAdded = function() pushState() end,
    },
    eventHandlers = {
        TMW_Found = found,
        TMW_StepDone = onStepDone,
        TMW_Hop = onHop,
        TMW_Utter = onUtter,
        TMW_Assign = assign,
        TMW_BeginPlace = beginPlace,
        TMW_PlaceMove = placeMove,
        TMW_PlaceConfirm = placeConfirm,
        TMW_PlaceCancel = removeGhost,
        TMW_RemoveSite = removeSite,
        TMW_TradeSet = tradeSet,
        TMW_Treasury = treasury,
        TMW_RequestState = pushState,
        TMW_Debug = debugCommand,
        TMW_Attacked = onAttacked,
        TMW_Subdued = onSubdued,
    },
}
