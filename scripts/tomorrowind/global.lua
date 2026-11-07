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

local WORKER_SCRIPT = 'scripts/tomorrowind/worker.lua'
local CAPTIVE_SCRIPT = 'scripts/tomorrowind/captive.lua'

local STATE_INTERVAL = 0.5
local ACTIVE_INTERVAL = 0.5
local STEP_WATCHDOG = 150

-- persistent
local c                      -- colony state (plain table, see core/colony.lua)
local objs = { sites = {}, workers = {}, decor = {}, threats = {}, sitefx = {}, workfx = {} }
local ghost                  -- { obj=, kind= } while the player is placing
local recIds                 -- ids of our runtime records (see records.lua)

-- runtime only
local tokens = {}            -- wid -> token of the step in flight
local stepStarted = {}       -- wid -> sim time the step was sent
local tokenCounter = 0
local stateTimer, activeTimer, offscreenDt = 0, 0, 0
local lastGameTime
local workerByObj = {}       -- object id -> wid
local applyGhostMove         -- defined with the placement code below
local checkThreats           -- defined with the main loop
local debugOn = defs.debug
local siteByObj = {}         -- object id -> sid
local workFxUntil = {}       -- sid -> sim time the smelter fire may go out
local needsMigration = false

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
    if p then p:sendEvent('TMW_Message', { text = text }) end
end

local function rebuildIndex()
    workerByObj, siteByObj = {}, {}
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
local function placeObject(recordId, pos, yaw, scale)
    local o = world.createObject(recordId)
    o:teleport('', v3(pos), { rotation = util.transform.rotateZ(yaw or 0) })
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

-- Footprint radius of the finished building: measured from the placement
-- preview, from the finished object, or the defs estimate.
local function footprintRadius(sid)
    local s = c.sites[sid]
    if s.radius then return s.radius end
    if s.built then return siteRadius(sid) end
    return defs.buildings[s.kind].footprint * 0.5
end

local function siteScale(sid)
    local s = c.sites[sid]
    if s.built then return defs.buildings[s.kind].scale or 1 end
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
    if not s.leveled then return spots end
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
    objs.sitefx[sid] = nil
end

-- Construction made visible: stacks of the delivered materials beside the
-- site (used up as the building goes up) and, on slopes, the pilings going
-- in one by one while the ground is leveled.
local function syncSiteFx(sid)
    local s = c.sites[sid]
    local v = s and C.siteVisuals(c, sid)
    if not v then return end
    local fx = objs.sitefx[sid] or { piles = {}, pilings = {} }
    objs.sitefx[sid] = fx
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
    local d = defs.buildings[s.kind]
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
    local recordId = s.built and rec().buildings[s.kind] or rec().construction
    -- leveled sites have their floor worked out; everything else sits on the land
    if not s.leveled then s.pos.z = landHeight(v3(s.pos)) or s.pos.z end
    objs.sites[sid] = placeObject(recordId, s.pos, s.yaw, siteScale(sid))
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
    msg.carryModel = w.carry and defs.carryModels[w.carry.res] or nil
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
    if s then
        msg.center = v3(s.pos)
        msg.standoff = siteRadius(sid) * 0.8 + 60
        msg.slotAngle = slotAngle(wid, sid)
    end

    if st.op == 'work' and s then
        local d = defs.buildings[s.kind]
        msg.sound = s.built and d.sound or (not s.built and defs.buildSound) or nil
        if s.built and d.workFx then workFxOn(sid, (st.duration or 5) + 3) end
    end

    local pos = moveTo or o.position
    local opts
    if st.op == 'work' and s then
        -- face the work target
        local dir = v3(s.pos) - pos
        opts = { rotation = util.transform.rotateZ(math.atan2(dir.x, dir.y)) }
    end
    if moveTo or opts then
        opts = opts or {}
        opts.onGround = moveTo ~= nil
        local ok, err = pcall(o.teleport, o, o.cell, pos, opts)
        if not ok then log('teleport failed for', wid, err) end
    end
    o:sendEvent('TMW_Step', msg)
end

local function startNextTask(wid)
    C.nextTask(c, wid)
    sendStep(wid)
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
        elseif e.kind == 'built' then
            setSiteObject(e.site)
            log('built', e.site, c.sites[e.site].kind)
        elseif e.kind == 'site_removed' then
            local o = objs.sites[e.site]
            if o and o:isValid() then o:remove() end
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
        workers = {}, sites = {}, options = {},
        storePos = c.storehouse and v3(c.sites[c.storehouse].pos),
    }
    for _, r in ipairs(defs.resourceOrder) do
        snap.stock[r] = c.stock[r]
        snap.available[r] = C.available(c, r)
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
        }
    end
    for _, opt in ipairs(C.assignmentOptions(c)) do
        snap.options[#snap.options + 1] = { id = opt, label = C.assignmentLabel(c, opt) }
    end
    return snap
end

local function pushState()
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

local function updateWorkers(dt)
    offscreenDt = offscreenDt + dt
    activeTimer = activeTimer + dt
    if activeTimer < ACTIVE_INTERVAL then return end
    activeTimer = 0
    checkDeaths()
    checkThreats()
    updateWorkFx()
    for _, sid in ipairs(c.siteOrder) do
        if not c.sites[sid].built then syncSiteFx(sid) end
    end
    local active = activeSet()
    for _, wid in ipairs(c.workerOrder) do
        local w = c.workers[wid]
        local o = objs.workers[wid]
        local isActive = o and o:isValid() and active[o.id]
        if isActive then
            if w.offscreen then
                w.offscreen = false
                tokens[wid] = nil
            end
            if not tokens[wid] or not w.task then
                startNextTask(wid)
            elseif c.time - (stepStarted[wid] or c.time) > STEP_WATCHDOG then
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
    offscreenDt = 0
end

-- Older saves: buildings whose model changed get their new look.
local function migrateSites()
    for _, sid in ipairs(c.siteOrder) do
        local o = objs.sites[sid]
        if c.sites[sid].built and o and o:isValid() and o.recordId ~= rec().buildings[c.sites[sid].kind] then
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
    if hours > expected * 3 + 0.05 then
        -- time skip (wait, rest, travel): simulate the missing work
        local skipped = hours - expected
        local seconds = skipped * 3600 / math.max(scale, 1)
        log(string.format('time skip of %.2f h, simulating %.0f s of work', skipped, seconds))
        for _, wid in ipairs(c.workerOrder) do
            tokens[wid] = nil
            C.simulateWorker(c, wid, seconds)
        end
    end
    C.tick(c, dt, hours)
    updateWorkers(dt)
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
        C.nextTask(c, wid)
        sendStep(wid, e.teleport)
    end
    processEvents()
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
    if ghost and ghost.obj and ghost.obj:isValid() then ghost.obj:remove() end
    ghost = nil
end

local function beginPlace(e)
    if not c then return message('Found a colony first.') end
    local d = defs.buildings[e.kind]
    if not d then return end
    removeGhost()
    local p = player()
    local o = world.createObject(rec().buildings[e.kind])
    o:teleport(p.cell, p.position + util.vector3(0, 0, -5000))
    if d.scale then o:setScale(d.scale) end
    ghost = { obj = o, kind = e.kind }
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
        pcall(ghost.obj.teleport, ghost.obj, '', e.pos, { rotation = util.transform.rotateZ(e.yaw or 0) })
    end
end

local function placeConfirm(e)
    if not c or not ghost then return end
    local kind = ghost.kind
    removeGhost()
    local s = C.addSite(c, kind, plain(e.pos), e.yaw or 0, false, { foundation = e.foundation })
    s.leveled = true -- e.pos.z is the computed floor level
    s.radius = e.radius
    processEvents()
    message(defs.buildings[kind].name .. ' site placed.')
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
    elseif e.cmd == 'build' and c then
        local s = C.addSite(c, e.kind, plain(e.pos), e.yaw or 0, e.built, { foundation = e.foundation })
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
        o:teleport('', e.pos, { onGround = true })
        world.createObject('iron club'):moveInto(types.Actor.inventory(o))
        local victim = objs.workers[c.workerOrder[1]]
        if victim then o:sendEvent('StartAIPackage', { type = 'Combat', target = victim }) end
        log('spawned test hostile')
    elseif e.cmd == 'debug' then
        debugOn = e.on
        if player() then player():sendEvent('TMW_SetDebug', e.on) end
        for _, o in pairs(objs.workers) do
            if o:isValid() then o:sendEvent('TMW_SetDebug', e.on) end
        end
    elseif e.cmd == 'sitestate' and c then
        -- test helper: jump a construction site to a stage of its progress
        for _, sid in ipairs(c.siteOrder) do
            local site = c.sites[sid]
            if site.kind == e.kind and not site.built then
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
-- activation: workers and buildings open the colony panel

I.Activation.addHandlerForType(types.NPC, function(obj, actor)
    local wid = workerByObj[obj.id]
    if wid and actor.type == types.Player then
        actor:sendEvent('TMW_OpenWorker', { wid = wid })
        return false
    end
end)

I.Activation.addHandlerForType(types.Activator, function(obj, actor)
    if ghost and ghost.obj:isValid() and ghost.obj.id == obj.id then return false end
    local sid = siteByObj[obj.id]
    if sid and actor.type == types.Player then
        actor:sendEvent('TMW_OpenSite', { sid = sid })
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
            objs.workfx = objs.workfx or {} -- fires go out on the next update
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
        TMW_Assign = assign,
        TMW_BeginPlace = beginPlace,
        TMW_PlaceMove = placeMove,
        TMW_PlaceConfirm = placeConfirm,
        TMW_PlaceCancel = removeGhost,
        TMW_RemoveSite = removeSite,
        TMW_RequestState = pushState,
        TMW_Debug = debugCommand,
        TMW_Attacked = onAttacked,
        TMW_Subdued = onSubdued,
    },
}
