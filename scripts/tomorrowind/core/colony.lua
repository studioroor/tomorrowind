-- Colony simulation core.
--
-- Pure Lua (5.1/LuaJIT), no OpenMW dependencies, so it can be unit tested
-- outside the game. All state lives in one plain table `c` so it can be
-- saved as-is. Positions are plain {x=, y=, z=} tables.
--
-- How work flows:
--   * The game layer asks `nextTask(c, wid)` whenever a worker is free.
--     The planner picks the most useful thing for that worker (eat, do
--     their job, haul materials, build, idle) and returns a task: a list
--     of steps (goto / work / take / store / supply / eat / idle).
--   * The game layer performs one step at a time (walking, swinging a
--     tool) and calls `completeStep(c, wid)` when it is done. Effects
--     (stock changes, building progress) are applied only then.
--   * Materials are reserved when a task is planned, so two workers never
--     go for the same timber. `cancelTask` releases everything.
--   * Workers the player can't see are simulated abstractly with
--     `simulateWorker`, using the same rates.

local defs = require('scripts.tomorrowind.defs')

local C = {}

---------------------------------------------------------------------------
-- helpers

local function copy(t)
    local r = {}
    for k, v in pairs(t or {}) do r[k] = v end
    return r
end

local function dist(a, b)
    local dx, dy, dz = a.x - b.x, a.y - b.y, (a.z or 0) - (b.z or 0)
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end
C.dist = dist

local function emit(c, ev)
    c.events[#c.events + 1] = ev
end

local function newId(c, prefix)
    c.nextId = c.nextId + 1
    return prefix .. c.nextId
end

local function def(site) return defs.buildings[site.kind] end

local function resName(res) return defs.resources[res].name end

---------------------------------------------------------------------------
-- construction & queries

function C.new()
    local c = {
        version = 1,
        nextId = 0,
        time = 0,              -- simulation seconds
        hours = 0,             -- game hours elapsed
        stock = copy(defs.startingStock),
        reserved = {},
        sites = {},
        siteOrder = {},
        workers = {},
        workerOrder = {},
        storehouse = nil,
        threats = {},          -- tid -> { id=, name= } (enemies attacking the colony)
        threatOrder = {},
        arrivalTimer = 0,
        pendingArrivals = 0,
        events = {},
    }
    for _, r in ipairs(defs.resourceOrder) do
        c.stock[r] = c.stock[r] or 0
        c.reserved[r] = 0
    end
    return c
end

function C.available(c, res)
    return (c.stock[res] or 0) - (c.reserved[res] or 0)
end

function C.beds(c)
    local n = 0
    for _, sid in ipairs(c.siteOrder) do
        local s = c.sites[sid]
        if s.built then n = n + (def(s).beds or 0) end
    end
    return n
end

-- Free settlers (prisoners live in the stockade, not in beds).
function C.population(c)
    local n = 0
    for _, wid in ipairs(c.workerOrder) do
        if not c.workers[wid].prisoner then n = n + 1 end
    end
    return n
end

function C.prisonerCount(c)
    return #c.workerOrder - C.population(c)
end

-- Stockade capacity and the stockade site to send prisoners to.
function C.cells(c)
    local n, sid = 0, nil
    for _, id in ipairs(c.siteOrder) do
        local s = c.sites[id]
        if s.built and def(s).cells then
            n = n + def(s).cells
            sid = sid or id
        end
    end
    return n, sid
end

function C.canTakePrisoner(c)
    return C.cells(c) > C.prisonerCount(c)
end

function C.assignedTo(c, sid)
    local list = {}
    for _, wid in ipairs(c.workerOrder) do
        if c.workers[wid].assignment == sid then list[#list + 1] = wid end
    end
    return list
end

function C.speed(c, wid)
    local w = c.workers[wid]
    if w.fed <= 0 then return 0 end
    if w.fed < defs.hunger.hungryBelow then return defs.hunger.hungrySpeed end
    return 1
end

-- Estimated seconds for one walk between a site and the storehouse.
function C.tripSeconds(c, sid)
    local store = c.sites[c.storehouse]
    local s = c.sites[sid]
    if not store or not s then return 0 end
    return dist(s.pos, store.pos) / defs.walkSpeed
end

---------------------------------------------------------------------------
-- sites

-- opts.foundation = { wood=, work= } for sloped ground (see core/terrain.lua)
function C.addSite(c, kind, pos, yaw, built, opts)
    local d = defs.buildings[kind]
    assert(d, 'unknown building ' .. tostring(kind))
    local foundation = opts and opts.foundation
    local cost = copy(d.cost)
    if foundation and foundation.wood and foundation.wood > 0 then
        cost.wood = (cost.wood or 0) + foundation.wood
    end
    local site = {
        id = newId(c, 's'),
        kind = kind,
        pos = { x = pos.x, y = pos.y, z = pos.z },
        yaw = yaw or 0,
        built = built and true or false,
        cost = cost,                 -- materials incl. foundation
        work = d.work + (foundation and foundation.work or 0),
        levelWork = foundation and foundation.work or 0,
        needs = built and {} or copy(cost),
        incoming = {},
        progress = 0,
        stalled = nil,       -- reason a production site is idle
    }
    c.sites[site.id] = site
    c.siteOrder[#c.siteOrder + 1] = site.id
    if kind == 'storehouse' and not c.storehouse then c.storehouse = site.id end
    if not built then
        emit(c, { kind = 'site_placed', site = site.id })
    end
    return site
end

function C.found(c, pos, yaw)
    assert(not c.storehouse, 'colony already founded')
    local s = C.addSite(c, 'storehouse', pos, yaw, true)
    for _ = 1, defs.startingWorkers do
        c.pendingArrivals = c.pendingArrivals + 1
        emit(c, { kind = 'arrival' })
    end
    return s
end

-- Remaining materials a construction site still needs (excluding what is
-- already on its way).
function C.missing(c, sid)
    local s = c.sites[sid]
    local m = {}
    for res, n in pairs(s.needs) do
        local left = n - (s.incoming[res] or 0)
        if left > 0 then m[res] = left end
    end
    return m
end

local function materialsComplete(s)
    for _, n in pairs(s.needs) do
        if n > 0 then return false end
    end
    return true
end
C.materialsComplete = function(c, sid) return materialsComplete(c.sites[sid]) end

local function siteWork(s) return s.work or def(s).work end

local function finishBuilding(c, s)
    s.built = true
    s.progress = siteWork(s)
    emit(c, { kind = 'built', site = s.id })
    emit(c, { kind = 'msg', text = def(s).name .. ' is finished.' })
end

local function addBuildProgress(c, s, amount)
    if s.built then return end
    s.progress = s.progress + amount
    if s.progress >= siteWork(s) then finishBuilding(c, s) end
end

-- Completes a site immediately (quests, debugging). Undelivered
-- materials are waived.
function C.finishSite(c, sid)
    local s = c.sites[sid]
    if not s or s.built then return false end
    for _, wid in ipairs(c.workerOrder) do
        local w = c.workers[wid]
        if w.task and w.task.site == sid then C.cancelTask(c, wid) end
    end
    s.needs, s.incoming = {}, {}
    finishBuilding(c, s)
    return true
end

-- Removes a site (cancel construction / demolish). Delivered materials
-- go back to the stockpile; workers on it are unassigned.
function C.removeSite(c, sid)
    local s = c.sites[sid]
    if not s or sid == c.storehouse then return false end
    for _, wid in ipairs(c.workerOrder) do
        local w = c.workers[wid]
        if w.task and w.task.site == sid then C.cancelTask(c, wid) end
        if w.assignment == sid then w.assignment = nil end
    end
    if not s.built then
        for res, n in pairs(s.cost or def(s).cost) do
            local delivered = n - (s.needs[res] or 0)
            c.stock[res] = c.stock[res] + delivered
        end
    end
    c.sites[sid] = nil
    for i, id in ipairs(c.siteOrder) do
        if id == sid then table.remove(c.siteOrder, i) break end
    end
    emit(c, { kind = 'site_removed', site = sid })
    return true
end

---------------------------------------------------------------------------
-- workers

function C.addWorker(c, info)
    local w = {
        id = newId(c, 'w'),
        name = info.name or 'Worker',
        recordId = info.recordId,
        prisoner = info.prisoner or nil,
        assignment = nil,      -- site id, 'builder', or nil (laborer)
        fed = 1,
        task = nil,
        carry = nil,           -- { res=, amount= }
        abstractProgress = 0,
    }
    c.workers[w.id] = w
    c.workerOrder[#c.workerOrder + 1] = w.id
    if c.pendingArrivals > 0 then c.pendingArrivals = c.pendingArrivals - 1 end
    return w
end

function C.removeWorker(c, wid)
    if not c.workers[wid] then return end
    C.cancelTask(c, wid)
    c.workers[wid] = nil
    for i, id in ipairs(c.workerOrder) do
        if id == wid then table.remove(c.workerOrder, i) break end
    end
end

-- target: a built production site id, 'builder', or nil (laborer).
function C.assign(c, wid, target)
    local w = c.workers[wid]
    if not w then return false, 'no such worker' end
    if target == false then target = nil end
    if w.prisoner then
        if target == 'builder' then return false, 'prisoners cannot build' end
        local ps = target and c.sites[target]
        if ps and not defs.prisonerJobs[def(ps).job or ''] then
            return false, 'prisoners can only mine or cut wood'
        end
    end
    if target ~= nil and target ~= 'builder' then
        local s = c.sites[target]
        if not s then return false, 'no such building' end
        local d = def(s)
        if not d.job then return false, d.name .. ' has no jobs' end
        if not s.built then return false, d.name .. ' is not built yet' end
        if w.assignment ~= target and #C.assignedTo(c, target) >= d.slots then
            return false, d.name .. ' is full'
        end
    end
    if w.assignment == target then return true end
    C.cancelTask(c, wid)
    w.assignment = target
    w.abstractProgress = 0
    return true
end

-- Every assignment option, in display order: laborer, builder, then each
-- built production site.
function C.assignmentOptions(c)
    local opts = { false, 'builder' }
    for _, sid in ipairs(c.siteOrder) do
        local s = c.sites[sid]
        if s.built and def(s).job then opts[#opts + 1] = sid end
    end
    return opts
end

function C.assignmentLabel(c, target, prisoner)
    if target == nil or target == false then return prisoner and 'Prisoner' or 'Laborer' end
    if target == 'builder' then return 'Builder' end
    local s = c.sites[target]
    if not s then return '?' end
    return def(s).job .. ' (' .. def(s).name .. ')'
end

---------------------------------------------------------------------------
-- threats

function C.addThreat(c, info)
    local t = { id = newId(c, 't'), name = info.name or 'an attacker' }
    c.threats[t.id] = t
    c.threatOrder[#c.threatOrder + 1] = t.id
    emit(c, { kind = 'alarm', threat = t.id })
    emit(c, { kind = 'msg', text = 'The colony is under attack by ' .. t.name .. '!' })
    return t.id
end

function C.removeThreat(c, tid)
    if not c.threats[tid] then return end
    c.threats[tid] = nil
    for i, id in ipairs(c.threatOrder) do
        if id == tid then table.remove(c.threatOrder, i) break end
    end
    if #c.threatOrder == 0 then
        emit(c, { kind = 'all_clear' })
        emit(c, { kind = 'msg', text = 'The colony is safe again.' })
    end
end

function C.underAttack(c)
    return #c.threatOrder > 0
end

local function isGuard(c, w)
    local s = w.assignment and w.assignment ~= 'builder' and c.sites[w.assignment]
    return s and def(s).guard and true or false
end
C.isGuard = function(c, wid) return isGuard(c, c.workers[wid]) end

---------------------------------------------------------------------------
-- reservations

local function reserve(c, res, amount)
    c.reserved[res] = (c.reserved[res] or 0) + amount
end

local function unreserve(c, res, amount)
    c.reserved[res] = math.max(0, (c.reserved[res] or 0) - amount)
end

---------------------------------------------------------------------------
-- task planning

local function step(op, t)
    t = t or {}
    t.op = op
    return t
end

local function storeId(c) return c.storehouse end

local function eatTask(c)
    reserve(c, 'food', 1)
    return {
        kind = 'eat', label = 'Going to eat',
        holds = { res = 'food', amount = 1 },
        steps = {
            step('goto', { to = storeId(c), label = 'Going to eat' }),
            step('eat', { label = 'Eating' }),
        },
    }
end

local function idleTask(c, label, duration, at)
    return {
        kind = 'idle', label = label,
        steps = { step('idle', { at = at or storeId(c), duration = duration or 12, label = label }) },
    }
end

local function shelterTask(c)
    local label = 'Sheltering in the storehouse'
    return {
        kind = 'shelter', label = label,
        steps = {
            step('goto', { to = storeId(c), label = 'Running for the storehouse' }),
            step('idle', { at = storeId(c), duration = defs.defense.shelterSeconds, label = label, stay = true }),
        },
    }
end

local function fightTask(c, w)
    local tid = c.threatOrder[1]
    local t = c.threats[tid]
    return {
        kind = 'fight', label = 'Fighting',
        steps = { step('fight', { target = tid, label = 'Fighting ' .. t.name }) },
    }
end

-- Guards walk between the colony's buildings and their post.
local function patrolTask(c, w, post)
    local stops = {}
    for _, sid in ipairs(c.siteOrder) do
        local s = c.sites[sid]
        if s.built and sid ~= post.id then stops[#stops + 1] = sid end
    end
    local target = #stops > 0 and stops[math.random(#stops)] or post.id
    local idle = defs.defense.patrolIdle
    return {
        kind = 'patrol', site = post.id, label = 'Patrolling',
        steps = {
            step('goto', { to = target, label = 'Patrolling' }),
            step('idle', { at = target, duration = idle, label = 'Keeping watch', stay = true }),
            step('goto', { to = post.id, label = 'Returning to the Guard Post' }),
            step('idle', { at = post.id, duration = idle, label = 'On watch', stay = true }),
        },
    }
end

local function gatherTask(c, w, s, speed)
    local d = def(s)
    local res, amount = next(d.output)
    return {
        kind = 'gather', site = s.id, label = d.job,
        steps = {
            step('goto', { to = s.id, label = 'Walking to the ' .. d.name }),
            step('work', {
                at = s.id, duration = d.cycle / speed, tool = d.tool,
                effect = 'produce', res = res, amount = amount,
                label = d.job .. ' at the ' .. d.name,
            }),
            step('goto', { to = storeId(c), label = 'Carrying ' .. resName(res) .. ' to the storehouse' }),
            step('store', { label = 'Storing ' .. resName(res) }),
        },
    }
end

local function processTask(c, w, s, speed)
    local d = def(s)
    local inRes, inAmount = next(d.input)
    local outRes, outAmount = next(d.output)
    if C.available(c, inRes) < inAmount then
        s.stalled = 'needs ' .. resName(inRes)
        return idleTask(c, 'Waiting for ' .. resName(inRes), 10)
    end
    s.stalled = nil
    reserve(c, inRes, inAmount)
    return {
        kind = 'process', site = s.id, label = d.job,
        holds = { res = inRes, amount = inAmount },
        steps = {
            step('goto', { to = storeId(c), label = 'Fetching ' .. resName(inRes) }),
            step('take', { res = inRes, amount = inAmount, label = 'Taking ' .. resName(inRes) }),
            step('goto', { to = s.id, label = 'Carrying ' .. resName(inRes) .. ' to the ' .. d.name }),
            step('work', {
                at = s.id, duration = d.cycle / speed, tool = d.tool,
                effect = 'convert', res = outRes, amount = outAmount,
                label = d.job .. ' at the ' .. d.name,
            }),
            step('goto', { to = storeId(c), label = 'Carrying ' .. resName(outRes) .. ' to the storehouse' }),
            step('store', { label = 'Storing ' .. resName(outRes) }),
        },
    }
end

-- Haul materials to the oldest construction site that still needs
-- something we have in stock.
local function haulTask(c)
    for _, sid in ipairs(c.siteOrder) do
        local s = c.sites[sid]
        if not s.built then
            for _, res in ipairs(defs.resourceOrder) do
                local left = (s.needs[res] or 0) - (s.incoming[res] or 0)
                local avail = C.available(c, res)
                if left > 0 and avail > 0 then
                    local amount = math.min(left, avail, defs.carryAmount)
                    reserve(c, res, amount)
                    s.incoming[res] = (s.incoming[res] or 0) + amount
                    local name = def(s).name
                    return {
                        kind = 'haul', site = sid, label = 'Hauling',
                        holds = { res = res, amount = amount },
                        incoming = { site = sid, res = res, amount = amount },
                        steps = {
                            step('goto', { to = storeId(c), label = 'Fetching ' .. resName(res) }),
                            step('take', { res = res, amount = amount, label = 'Taking ' .. resName(res) }),
                            step('goto', { to = sid, label = 'Hauling ' .. resName(res) .. ' to the ' .. name .. ' site' }),
                            step('supply', { at = sid, label = 'Unloading at the ' .. name .. ' site' }),
                        },
                    }
                end
            end
        end
    end
end

local function buildTask(c, speed)
    for _, sid in ipairs(c.siteOrder) do
        local s = c.sites[sid]
        if not s.built and materialsComplete(s) then
            local name = def(s).name
            local leveling = s.progress < (s.levelWork or 0)
            return {
                kind = 'build', site = sid, label = leveling and 'Leveling' or 'Building',
                steps = {
                    step('goto', { to = sid, label = 'Walking to the ' .. name .. ' site' }),
                    step('work', {
                        at = sid, duration = defs.buildWorkPerTrip / speed, tool = defs.builderTool,
                        effect = 'build', amount = defs.buildWorkPerTrip,
                        label = (leveling and 'Leveling the ground for the ' or 'Building the ') .. name,
                    }),
                },
            }
        end
    end
end

local function constructionWork(c, speed)
    return buildTask(c, speed) or haulTask(c)
end

-- Plan the next task for a free worker and remember it on the worker.
function C.nextTask(c, wid)
    local w = c.workers[wid]
    assert(w, 'no such worker ' .. tostring(wid))
    if w.task then C.cancelTask(c, wid) end
    local task

    local attacked = C.underAttack(c)
    local guard = isGuard(c, w)
    if attacked and guard then
        task = fightTask(c, w)
    elseif attacked and not w.prisoner then
        task = shelterTask(c)
    elseif w.fed < defs.hunger.eatBelow and C.available(c, 'food') >= 1 then
        task = eatTask(c)
    elseif w.prisoner and not (w.assignment and c.sites[w.assignment]) then
        local _, stockade = C.cells(c)
        task = idleTask(c, 'Locked up', 15, stockade)
    else
        local speed = C.speed(c, wid)
        if speed <= 0 then
            task = idleTask(c, 'Starving - too weak to work', 15)
        else
            local s = w.assignment and w.assignment ~= 'builder' and c.sites[w.assignment]
            if s and def(s).guard then
                task = patrolTask(c, w, s)
            elseif s then
                if def(s).input then
                    task = processTask(c, w, s, speed)
                else
                    task = gatherTask(c, w, s, speed)
                end
            elseif w.assignment == 'builder' then
                task = constructionWork(c, speed) or idleTask(c, 'Waiting for construction work', 10)
            else
                task = constructionWork(c, speed) or idleTask(c, 'Idle', 15)
            end
        end
    end

    task.i = 1
    w.task = task
    return task
end

function C.currentStep(c, wid)
    local w = c.workers[wid]
    if not w or not w.task then return nil end
    return w.task.steps[w.task.i]
end

local function applyStep(c, w, st)
    local task = w.task
    if st.op == 'take' then
        unreserve(c, st.res, st.amount)
        c.stock[st.res] = c.stock[st.res] - st.amount
        w.carry = { res = st.res, amount = st.amount }
        task.holds = nil
    elseif st.op == 'store' then
        if w.carry then
            c.stock[w.carry.res] = (c.stock[w.carry.res] or 0) + w.carry.amount
            w.carry = nil
        end
    elseif st.op == 'supply' then
        local s = c.sites[st.at]
        local carry = w.carry
        if s and carry then
            s.needs[carry.res] = math.max(0, (s.needs[carry.res] or 0) - carry.amount)
            s.incoming[carry.res] = math.max(0, (s.incoming[carry.res] or 0) - carry.amount)
            w.carry = nil
            task.incoming = nil
        end
    elseif st.op == 'eat' then
        unreserve(c, 'food', 1)
        c.stock.food = c.stock.food - 1
        w.fed = 1
        task.holds = nil
    elseif st.op == 'work' then
        if st.effect == 'produce' or st.effect == 'convert' then
            w.carry = { res = st.res, amount = st.amount }
        elseif st.effect == 'build' then
            local s = c.sites[st.at]
            if s then addBuildProgress(c, s, st.amount) end
        end
    end
end

-- Mark the current step done, apply its effect and return the next step,
-- or nil when the task is finished (the worker is free again).
function C.completeStep(c, wid)
    local w = c.workers[wid]
    if not w or not w.task then return nil end
    local st = w.task.steps[w.task.i]
    applyStep(c, w, st)
    w.task.i = w.task.i + 1
    local nxt = w.task.steps[w.task.i]
    if not nxt then w.task = nil end
    return nxt
end

-- Drop the current task: release reservations, return carried goods.
function C.cancelTask(c, wid)
    local w = c.workers[wid]
    if not w then return end
    local task = w.task
    if task then
        if task.holds then unreserve(c, task.holds.res, task.holds.amount) end
        if task.incoming then
            local s = c.sites[task.incoming.site]
            if s then
                s.incoming[task.incoming.res] =
                    math.max(0, (s.incoming[task.incoming.res] or 0) - task.incoming.amount)
            end
        end
        w.task = nil
    end
    if w.carry then
        c.stock[w.carry.res] = (c.stock[w.carry.res] or 0) + w.carry.amount
        w.carry = nil
    end
end

---------------------------------------------------------------------------
-- time

-- Advance colony-wide state: hunger, newcomers.
--   dt: simulation seconds, hours: game hours passed in the same period
function C.tick(c, dt, hours)
    c.time = c.time + dt
    c.hours = c.hours + hours

    for _, wid in ipairs(c.workerOrder) do
        local w = c.workers[wid]
        local before = w.fed
        w.fed = math.max(0, w.fed - hours * defs.hunger.decayPerHour)
        if w.offscreen and w.fed < defs.hunger.eatBelow and C.available(c, 'food') >= 1 then
            c.stock.food = c.stock.food - 1
            w.fed = 1
        end
        if before > 0 and w.fed <= 0 then
            emit(c, { kind = 'msg', text = w.name .. ' is starving.' })
        end
    end

    if c.storehouse then
        c.arrivalTimer = c.arrivalTimer + hours
        while c.arrivalTimer >= defs.arrival.everyHours do
            c.arrivalTimer = c.arrivalTimer - defs.arrival.everyHours
            if C.population(c) + c.pendingArrivals < C.beds(c)
                and C.available(c, 'food') >= defs.arrival.minFood then
                c.pendingArrivals = c.pendingArrivals + 1
                emit(c, { kind = 'arrival' })
            end
        end
    end
end

-- Abstract simulation for a worker that is not physically simulated
-- (player far away, or a time skip). Uses the same rates as real work.
function C.simulateWorker(c, wid, dt)
    local w = c.workers[wid]
    if not w then return end
    if w.task then C.cancelTask(c, wid) end
    local speed = C.speed(c, wid)
    if speed <= 0 then return end

    local s = w.assignment and w.assignment ~= 'builder' and c.sites[w.assignment]
    if s and def(s).guard then return end -- guards just keep watch
    if w.prisoner and not s then return end -- locked up
    if s then
        local d = def(s)
        local cycle = d.cycle + 2 * C.tripSeconds(c, s.id)
        w.abstractProgress = w.abstractProgress + dt * speed / cycle
        while w.abstractProgress >= 1 do
            w.abstractProgress = w.abstractProgress - 1
            if d.input then
                local inRes, inAmount = next(d.input)
                if C.available(c, inRes) < inAmount then
                    s.stalled = 'needs ' .. resName(inRes)
                    w.abstractProgress = 0
                    break
                end
                c.stock[inRes] = c.stock[inRes] - inAmount
                s.stalled = nil
            end
            for res, n in pairs(d.output) do c.stock[res] = c.stock[res] + n end
        end
        return
    end

    -- builders and laborers: move materials, then build
    for _, sid in ipairs(c.siteOrder) do
        local site = c.sites[sid]
        if not site.built then
            for res, need in pairs(site.needs) do
                local n = math.min(need - (site.incoming[res] or 0), C.available(c, res))
                if n > 0 then
                    c.stock[res] = c.stock[res] - n
                    site.needs[res] = need - n
                end
            end
            if materialsComplete(site) then
                local trip = defs.buildWorkPerTrip + 2 * C.tripSeconds(c, sid)
                addBuildProgress(c, site, dt * speed * defs.buildWorkPerTrip / trip)
                return
            end
        end
    end
end

---------------------------------------------------------------------------
-- status text for the UI

function C.workerStatus(c, wid)
    local w = c.workers[wid]
    if not w then return '' end
    local st = C.currentStep(c, wid)
    if st and st.label then return st.label end
    if w.offscreen then return 'Working (away)' end
    return 'Idle'
end

function C.siteStatus(c, sid)
    local s = c.sites[sid]
    if not s then return '' end
    local d = def(s)
    if not s.built then
        local parts = {}
        for _, res in ipairs(defs.resourceOrder) do
            local n = s.needs[res]
            if n and n > 0 then parts[#parts + 1] = n .. ' ' .. resName(res) end
        end
        if #parts > 0 then return 'Needs ' .. table.concat(parts, ', ') end
        if s.progress < (s.levelWork or 0) then
            return string.format('Leveling the ground (%d%%)', math.floor(100 * s.progress / s.levelWork))
        end
        return string.format('Under construction (%d%%)', math.floor(100 * s.progress / math.max(1, siteWork(s))))
    end
    if d.job then
        local n = #C.assignedTo(c, sid)
        local txt = string.format('%d/%d %ss', n, d.slots, d.job)
        if s.stalled then txt = txt .. ' - ' .. s.stalled end
        return txt
    end
    if d.beds then return d.beds .. ' beds' end
    if d.cells then
        return string.format('%d/%d prisoners (all cells)', C.prisonerCount(c), (C.cells(c)))
    end
    return 'Built'
end

function C.drainEvents(c)
    local evs = c.events
    c.events = {}
    return evs
end

return C
