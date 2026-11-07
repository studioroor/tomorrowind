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
-- the day

local function hourIn(h, from, to)
    if from <= to then return h >= from and h < to end
    return h >= from or h < to
end

-- 'work', 'free' or 'sleep' for an hour of the day.
function C.periodAt(hour)
    local d = defs.schedule
    if hourIn(hour, d.sleep, d.wake) then return 'sleep' end
    if hourIn(hour, d.workStart, d.workEnd) then return 'work' end
    return 'free'
end

-- A settler's own hours: see defs.schedule.
local function newSchedule()
    local d = defs.schedule
    local function noise() return (math.random() * 2 - 1) * d.noise end
    local t = (math.random() * 2 - 1) * d.chronotype
    return {
        wake = d.wake + t + noise(),
        workStart = d.workStart + t * 2 / 3 + noise(),
        workEnd = d.workEnd + t * 2 / 3 + noise(),
        sleep = d.sleep + t + noise(),
        eatBelow = defs.hunger.eatBelow + (math.random() * 2 - 1) * d.appetite,
    }
end

-- (older saves have no personal schedules yet)
local function schedOf(w)
    if not w.sched then w.sched = newSchedule() end
    return w.sched
end

local function periodFor(w, hour)
    local d = schedOf(w)
    if hourIn(hour, d.sleep, d.wake) then return 'sleep' end
    if hourIn(hour, d.workStart, d.workEnd) then return 'work' end
    return 'free'
end

function C.workerPeriod(c, wid)
    return periodFor(c.workers[wid], c.hourOfDay or 12)
end

function C.setClock(c, hour, timeScale)
    c.hourOfDay = hour
    c.timeScale = timeScale
end

function C.period(c) return C.periodAt(c.hourOfDay or 12) end

-- Real (simulation) seconds in `hours` of game time.
local function gameHours(c, hours)
    return hours * 3600 / math.max(c.timeScale or 30, 1)
end

-- Seconds of working time within `hours` of game time starting at `start`
-- (used when time is skipped by waiting or resting).
--   wid: whose working time (default: the standard hours)
function C.workSeconds(c, start, hours, wid)
    local w = wid and c.workers[wid]
    local steps, count = math.ceil(hours * 4), 0
    for i = 0, steps - 1 do
        local at = (start + i / 4) % 24
        local period = w and periodFor(w, at) or C.periodAt(at)
        if period == 'work' then count = count + 1 end
    end
    return gameHours(c, steps > 0 and hours * count / steps or 0)
end

---------------------------------------------------------------------------
-- construction & queries

function C.new()
    local c = {
        version = 1,
        nextId = 0,
        time = 0,              -- simulation seconds
        hours = 0,             -- game hours elapsed
        hourOfDay = 12,        -- game clock, kept current by the game layer
        timeScale = 30,        -- game seconds per real second
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

-- How much of each resource the colony can store: 0 means no limit yet
-- (no storehouse). Goods already in stock stay; production just stops.
function C.capacity(c)
    local n = 0
    for _, sid in ipairs(c.siteOrder) do
        local s = c.sites[sid]
        if s.built then n = n + (def(s).storage or 0) end
    end
    return n
end

local function storageFull(c, res)
    local cap = C.capacity(c)
    return cap > 0 and (c.stock[res] or 0) >= cap
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
    if s and s.host then s = c.sites[s.host] end
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
        variant = opts and opts.variant,
        host = opts and opts.host,     -- the house it stands in, for furniture indoors
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
    -- what stands inside goes with the house
    for i = #c.siteOrder, 1, -1 do
        local other = c.sites[c.siteOrder[i]]
        if other and other.host == sid then C.removeSite(c, other.id) end
    end
    for _, wid in ipairs(c.workerOrder) do
        local w = c.workers[wid]
        if w.task and w.task.site == sid then C.cancelTask(c, wid) end
        if w.assignment == sid then w.assignment = nil end
    end
    -- furnishings can be rearranged freely: their materials always come back
    if not s.built or def(s).small then
        for res, n in pairs(s.cost or def(s).cost) do
            local delivered = n - (s.needs[res] or 0)
            c.stock[res] = c.stock[res] + delivered
        end
    end
    for _, wid in ipairs(c.workerOrder) do
        if c.workers[wid].bed == sid then c.workers[wid].bed = nil end
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
        sched = newSchedule(),
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
-- trade

local function tradeOf(c)
    if not c.trade then
        c.trade = { keep = copy(defs.trade.keep), want = {}, factor = {}, caravanTimer = 0 }
        for res in pairs(defs.trade.prices) do c.trade.factor[res] = 1 end
    end
    return c.trade
end
C.tradeOf = tradeOf

function C.gold(c) return c.gold or 0 end

function C.caravanHere(c) return tradeOf(c).caravan ~= nil end

-- What a unit fetches right now.
function C.sellPrice(c, res)
    local t = tradeOf(c)
    local price = defs.trade.prices[res] * t.factor[res]
    if t.caravan then price = price * defs.trade.caravan.sellBonus end
    return price
end

function C.buyPrice(res)
    return defs.trade.prices[res] * defs.trade.buyMarkup
end

-- Sell goods: each unit fetches a little less than the one before.
local function sellGoods(c, res, amount)
    local t = tradeOf(c)
    local earned = 0
    for _ = 1, amount do
        earned = earned + C.sellPrice(c, res)
        t.factor[res] = math.max(defs.trade.minFactor, t.factor[res] * (1 - defs.trade.pressure[res]))
    end
    c.gold = C.gold(c) + earned
    return earned
end

-- The resource worth selling now, and how much of it can go in one load.
local function pickToSell(c)
    local t = tradeOf(c)
    local best, bestPrice
    for _, res in ipairs(defs.resourceOrder) do
        local surplus = C.available(c, res) - (t.keep[res] or 0)
        if surplus >= 1 then
            local price = C.sellPrice(c, res)
            if not bestPrice or price > bestPrice then best, bestPrice = res, price end
        end
    end
    if not best then return nil end
    return best, math.floor(math.min(defs.carryAmount, C.available(c, best) - (t.keep[best] or 0)))
end

-- Clamp and store the player's trade levels.
function C.setKeep(c, res, value) tradeOf(c).keep[res] = math.max(0, value) end
function C.setWant(c, res, value) tradeOf(c).want[res] = math.max(0, value) end

-- Move gold between the treasury and the player. Returns what actually moved.
function C.withdraw(c, amount)
    local n = math.min(math.floor(C.gold(c)), amount)
    c.gold = C.gold(c) - n
    return n
end

function C.deposit(c, amount)
    c.gold = C.gold(c) + amount
end

local function marketSite(c)
    for _, sid in ipairs(c.siteOrder) do
        local s = c.sites[sid]
        if s.built and def(s).trade then return s end
    end
end
C.marketSite = marketSite

-- The caravan buys and sells during its visit: fills the buy list.
local function caravanTrade(c)
    local t = tradeOf(c)
    if not t.caravan then return end
    for _, res in ipairs(defs.resourceOrder) do
        local short = (t.want[res] or 0) - (c.stock[res] or 0)
        local cap = C.capacity(c)
        if cap > 0 then short = math.min(short, cap - (c.stock[res] or 0)) end
        local price = C.buyPrice(res)
        local n = math.floor(math.min(short, t.caravan.supply[res] or 0, C.gold(c) / price))
        if n >= 1 then
            c.gold = C.gold(c) - n * price
            c.stock[res] = (c.stock[res] or 0) + n
            t.caravan.supply[res] = t.caravan.supply[res] - n
            t.caravan.bought = (t.caravan.bought or 0) + n
        end
    end
end

local function tickTrade(c, hours)
    local t = tradeOf(c)
    for res, f in pairs(t.factor) do
        t.factor[res] = math.min(1, f + (1 - f) * math.min(1, defs.trade.recover * hours))
    end
    local market = marketSite(c)
    if t.caravan and (not market or c.hours >= t.caravan.leavesAt) then
        t.caravan = nil
        emit(c, { kind = 'caravan_left' })
        if market then emit(c, { kind = 'msg', text = 'The caravan has moved on.' }) end
    end
    if market and not t.caravan then
        t.caravanTimer = t.caravanTimer + hours
        if t.caravanTimer >= defs.trade.caravan.everyHours then
            t.caravanTimer = 0
            local supply = {}
            for res in pairs(defs.trade.prices) do supply[res] = defs.trade.caravan.supply end
            t.caravan = { leavesAt = c.hours + defs.trade.caravan.stayHours, supply = supply }
            emit(c, { kind = 'caravan_arrived', site = market.id })
            emit(c, { kind = 'msg', text = 'A Hlaalu caravan has reached the market.' })
        end
    end
    caravanTrade(c)
end

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

-- With a campfire, settlers fetch their food and eat it there.
local function eatTask(c)
    local portion = defs.hunger.mealFood
    reserve(c, 'food', portion)
    local fire
    for _, sid in ipairs(c.siteOrder) do
        local s = c.sites[sid]
        if s.built and def(s).interact and def(s).interact.meal then fire = s break end
    end
    local task = { kind = 'eat', label = 'Going to eat', holds = { res = 'food', amount = portion } }
    if fire then
        task.steps = {
            step('goto', { to = storeId(c), label = 'Fetching some food' }),
            step('take', { res = 'food', amount = portion, label = 'Taking some food' }),
            step('goto', { to = fire.id, label = 'Going to eat by the campfire' }),
            step('eat', { at = fire.id, duration = gameHours(c, defs.hunger.mealHours), label = 'Eating by the campfire' }),
        }
    else
        task.steps = {
            step('goto', { to = storeId(c), label = 'Going to eat' }),
            step('eat', { label = 'Eating' }),
        }
    end
    return task
end

-- The bed a settler sleeps in: they keep the same one. Real beds come first,
-- then room in the buildings; if the colony is short of beds they squeeze
-- into the storehouse.
local function bedFor(c, w)
    local used = {}
    for _, wid in ipairs(c.workerOrder) do
        local b = c.workers[wid].bed
        if b and wid ~= w.id then used[b] = (used[b] or 0) + 1 end
    end
    local function free(sid)
        local s = c.sites[sid]
        return s and s.built and def(s).beds and (used[sid] or 0) < def(s).beds
    end
    if w.bed and free(w.bed) then return c.sites[w.bed] end
    for _, wantReal in ipairs({ true, false }) do
        for _, sid in ipairs(c.siteOrder) do
            if free(sid) and (def(c.sites[sid]).sleepOn or false) == wantReal then
                w.bed = sid
                return c.sites[sid]
            end
        end
    end
    w.bed = nil
    return c.sites[c.storehouse]
end

local function sleepTask(c, w)
    local bed = bedFor(c, w)
    local d = def(bed)
    local seconds = gameHours(c, (schedOf(w).wake - (c.hourOfDay or 12)) % 24)
    return {
        kind = 'sleep', site = bed.id, label = 'Sleeping',
        steps = {
            step('goto', { to = bed.id, door = true, label = 'Going to bed' }),
            step('sleep', {
                at = bed.id, duration = seconds, onBed = d.sleepOn or nil, inside = not d.sleepOn or nil,
                label = d.sleepOn and 'Sleeping' or ('Sleeping in the ' .. d.name),
            }),
        },
    }
end

-- Free time: pick something to do among the furnishings with room left,
-- preferring a change from last time.
local function leisureTask(c, w)
    local users = {}
    for _, wid in ipairs(c.workerOrder) do
        local t = c.workers[wid].task
        if wid ~= w.id and t and t.kind == 'leisure' then users[t.site] = (users[t.site] or 0) + 1 end
    end
    local options, total = {}, 0
    for _, sid in ipairs(c.siteOrder) do
        local s = c.sites[sid]
        local i = s.built and def(s).interact
        if i and (users[sid] or 0) < i.slots then
            local weight = i.weight
            if s.kind == w.lastLeisure then weight = weight * 0.25 end
            options[#options + 1] = { site = s, weight = weight }
            total = total + weight
        end
    end
    if #options == 0 then return nil end
    local pick, roll = options[1], math.random() * total
    for _, o in ipairs(options) do
        roll = roll - o.weight
        if roll <= 0 then pick = o break end
    end
    local s, i = pick.site, def(pick.site).interact
    w.lastLeisure = s.kind
    local spread = 1 + (math.random() * 2 - 1) * defs.schedule.leisureSpread
    return {
        kind = 'leisure', site = s.id, label = i.label,
        steps = {
            step('goto', { to = s.id, label = 'Heading to the ' .. def(s).name }),
            step('interact', { at = s.id, duration = gameHours(c, i.hours * spread), prop = i.prop, label = i.label }),
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

-- A trader takes a load of surplus to the market stall and sells it.
local function tradeTask(c, w, s, speed)
    local d = def(s)
    local res, amount = pickToSell(c)
    if not res or amount < 1 then
        s.stalled = 'nothing above the keep levels to sell'
        return idleTask(c, 'Minding the stall', 15, s.id)
    end
    s.stalled = nil
    reserve(c, res, amount)
    local name = resName(res)
    return {
        kind = 'trade', site = s.id, label = 'Trading',
        holds = { res = res, amount = amount },
        steps = {
            step('goto', { to = storeId(c), label = 'Fetching ' .. name .. ' to sell' }),
            step('take', { res = res, amount = amount, label = 'Taking ' .. name }),
            step('goto', { to = s.id, label = 'Carrying ' .. name .. ' to the ' .. d.name }),
            step('sell', { at = s.id, duration = d.cycle / speed, label = 'Selling ' .. name }),
        },
    }
end

local function gatherTask(c, w, s, speed)
    local d = def(s)
    local res, amount = next(d.output)
    if storageFull(c, res) then
        s.stalled = 'no room in the storehouse'
        return idleTask(c, 'No room for more ' .. resName(res), 15, s.id)
    end
    s.stalled = nil
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
    if storageFull(c, outRes) then
        s.stalled = 'no room in the storehouse'
        return idleTask(c, 'No room for more ' .. resName(outRes), 15, s.id)
    end
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

-- How many settlers are on a construction site: hauling for it or building it.
local function crewOn(c, sid)
    local n = 0
    for _, wid in ipairs(c.workerOrder) do
        local t = c.workers[wid].task
        if t and ((t.kind == 'build' and t.site == sid) or (t.incoming and t.incoming.site == sid)) then
            n = n + 1
        end
    end
    return n
end

-- Room for one more on this site? See maxBuilders in defs.
local function hasRoom(c, s)
    local cap = def(s).maxBuilders
    return not cap or crewOn(c, s.id) < cap
end
C.crewOn = crewOn

-- Haul materials to the oldest construction site that still needs
-- something we have in stock.
local function haulTask(c)
    for _, sid in ipairs(c.siteOrder) do
        local s = c.sites[sid]
        if not s.built and hasRoom(c, s) then
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
        if not s.built and materialsComplete(s) and hasRoom(c, s) then
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

-- The first built site that produces `res` (nil if the colony has none).
local function producerOf(c, res)
    for _, sid in ipairs(c.siteOrder) do
        local s = c.sites[sid]
        if s.built and def(s).output and def(s).output[res] then return s end
    end
end
C.producerOf = producerOf

-- Name of the kind of building that produces `res` ("Woodcutter's Camp").
local function producerName(res)
    for _, kind in ipairs(defs.buildOrder) do
        local d = defs.buildings[kind]
        if d.output and d.output[res] then return d.name end
    end
end

-- Gather at producer `p`. With `site`, carry the result straight to that
-- construction site; otherwise to the storehouse.
local function helperGather(c, p, speed, site, need)
    local d = def(p)
    local res, amount = next(d.output)
    local task = {
        kind = 'gather', site = p.id, helper = true,
        steps = {
            step('goto', { to = p.id, label = 'Walking to the ' .. d.name }),
            step('work', {
                at = p.id, duration = d.cycle / speed, tool = d.tool,
                effect = 'produce', res = res, amount = amount,
                label = 'Helping out: ' .. d.job .. ' at the ' .. d.name,
            }),
        },
    }
    if site then
        local n = math.min(amount, need)
        site.incoming[res] = (site.incoming[res] or 0) + n
        task.incoming = { site = site.id, res = res, amount = n }
        task.label = 'Fetching ' .. resName(res) .. ' for the ' .. def(site).name
        task.steps[#task.steps + 1] = step('goto', { to = site.id, label = 'Carrying ' .. resName(res) .. ' to the ' .. def(site).name .. ' site' })
        task.steps[#task.steps + 1] = step('supply', { at = site.id, label = 'Unloading at the ' .. def(site).name .. ' site' })
    else
        task.label = 'Making ' .. resName(res)
        task.steps[#task.steps + 1] = step('goto', { to = storeId(c), label = 'Carrying ' .. resName(res) .. ' to the storehouse' })
        task.steps[#task.steps + 1] = step('store', { label = 'Storing ' .. resName(res) })
    end
    return task
end

-- Process at `p` (e.g. smelt) and carry the output straight to `site`.
local function helperProcess(c, p, speed, site, need)
    local d = def(p)
    local inRes, inAmount = next(d.input)
    local outRes, outAmount = next(d.output)
    reserve(c, inRes, inAmount)
    local n = math.min(outAmount, need)
    site.incoming[outRes] = (site.incoming[outRes] or 0) + n
    local name = def(site).name
    return {
        kind = 'process', site = p.id, helper = true,
        label = 'Making ' .. resName(outRes) .. ' for the ' .. name,
        holds = { res = inRes, amount = inAmount },
        incoming = { site = site.id, res = outRes, amount = n },
        steps = {
            step('goto', { to = storeId(c), label = 'Fetching ' .. resName(inRes) }),
            step('take', { res = inRes, amount = inAmount, label = 'Taking ' .. resName(inRes) }),
            step('goto', { to = p.id, label = 'Carrying ' .. resName(inRes) .. ' to the ' .. d.name }),
            step('work', {
                at = p.id, duration = d.cycle / speed, tool = d.tool,
                effect = 'convert', res = outRes, amount = outAmount,
                label = 'Helping out: ' .. d.job .. ' at the ' .. d.name,
            }),
            step('goto', { to = site.id, label = 'Carrying ' .. resName(outRes) .. ' to the ' .. name .. ' site' }),
            step('supply', { at = site.id, label = 'Unloading at the ' .. name .. ' site' }),
        },
    }
end

-- A construction site is short of something the storehouse doesn't have:
-- go and make it. Works one step up the chain (no ore for ingots: mine).
local function supplyRunTask(c, speed)
    for _, sid in ipairs(c.siteOrder) do
        local site = c.sites[sid]
        if not site.built and hasRoom(c, site) then
            for _, res in ipairs(defs.resourceOrder) do
                local left = (site.needs[res] or 0) - (site.incoming[res] or 0)
                if left > 0 and C.available(c, res) <= 0 then
                    local p = producerOf(c, res)
                    if p and not def(p).input then
                        return helperGather(c, p, speed, site, left)
                    elseif p then
                        local inRes, inAmount = next(def(p).input)
                        if C.available(c, inRes) >= inAmount then
                            return helperProcess(c, p, speed, site, left)
                        end
                        local q = producerOf(c, inRes)
                        if q and not def(q).input then
                            return helperGather(c, q, speed, nil)
                        end
                    end
                end
            end
        end
    end
end

local function constructionWork(c, speed)
    return buildTask(c, speed) or haulTask(c) or supplyRunTask(c, speed)
end

---------------------------------------------------------------------------
-- downtime: what settlers do with nothing to do

local function between(range)
    return range[1] + math.random() * (range[2] - range[1])
end

-- A built site of the colony, at random (not furnishings).
local function someBuilding(c)
    local list = {}
    for _, sid in ipairs(c.siteOrder) do
        local s = c.sites[sid]
        if s.built and not def(s).small then list[#list + 1] = s end
    end
    return list[math.random(#list)]
end

-- A building settlers can go inside: the houses, or the storehouse.
local function someShelter(c)
    local list = {}
    for _, sid in ipairs(c.siteOrder) do
        local s = c.sites[sid]
        if s.built and def(s).beds and not def(s).sleepOn then list[#list + 1] = s end
    end
    return #list > 0 and list[math.random(#list)] or nil
end

-- A production site with room for a helper, that needs no input.
local function helpNeeded(c)
    local list = {}
    for _, sid in ipairs(c.siteOrder) do
        local s = c.sites[sid]
        local d = def(s)
        if s.built and d.job and d.output and not d.input and not d.guard and not storageFull(c, next(d.output)) then
            local n = #C.assignedTo(c, sid)
            for _, wid in ipairs(c.workerOrder) do
                local t = c.workers[wid].task
                if t and t.helper and t.site == sid then n = n + 1 end
            end
            if n < d.slots then list[#list + 1] = s end
        end
    end
    return #list > 0 and list[math.random(#list)] or nil
end

local function tidyTask(c)
    local s = someBuilding(c)
    local name = def(s).name
    local label = 'Tidying up around the ' .. name
    return {
        kind = 'tidy', label = label, site = s.id,
        steps = {
            step('goto', { to = s.id, label = 'Walking to the ' .. name }),
            step('work', { at = s.id, duration = between(defs.downtime.tidySeconds), tool = defs.builderTool, label = label }),
        },
    }
end

local function strollTask(c)
    local s = someBuilding(c)
    local label = 'Taking a stroll'
    return {
        kind = 'stroll', label = label,
        steps = {
            step('goto', { to = s.id, label = label }),
            step('idle', { at = s.id, duration = between(defs.downtime.strollSeconds), label = label }),
        },
    }
end

local function indoorsTask(c)
    local s = someShelter(c)
    if not s then return nil end
    local name = def(s).name
    return {
        kind = 'indoors', label = 'Relaxing indoors', site = s.id,
        steps = {
            step('goto', { to = s.id, door = true, label = 'Going into the ' .. name }),
            step('rest', { at = s.id, inside = true, duration = gameHours(c, between(defs.downtime.indoorsHours)),
                label = 'Relaxing in the ' .. name }),
        },
    }
end

-- Two settlers with nothing to do meet somewhere for a talk. The other one is
-- pulled from their own pastime: the game layer picks that up from the event.
local function chatTask(c, w)
    local other
    for _, wid in ipairs(c.workerOrder) do
        local o = c.workers[wid]
        if wid ~= w.id and not o.prisoner and not o.offscreen and o.task and o.task.downtime and o.task.kind ~= 'chat' then
            other = o
            break
        end
    end
    if not other then return nil end
    local s = someBuilding(c)
    local angle = math.random() * 2 * math.pi
    local seconds = between(defs.downtime.chatSeconds)
    local function forPerson(person, partner)
        return {
            kind = 'chat', label = 'Chatting with ' .. partner.name, site = s.id, downtime = true, i = 1,
            steps = {
                step('goto', { to = s.id, meet = angle, label = 'Going over to talk to ' .. partner.name }),
                step('chat', { at = s.id, meet = angle, with = partner.id, duration = seconds, label = 'Chatting with ' .. partner.name }),
            },
        }
    end
    C.cancelTask(c, other.id)
    other.task = forPerson(other, w)
    emit(c, { kind = 'retask', wid = other.id })
    return forPerson(w, other)
end

-- `period`: 'work' or 'free', which table of chances in defs.downtime to use.
local function downtimeTask(c, w, period, speed)
    local chances = defs.downtime[period]
    local makers = {
        helping = function()
            local p = helpNeeded(c)
            return p and helperGather(c, p, speed, nil)
        end,
        tidy = function() return tidyTask(c) end,
        chat = function() return chatTask(c, w) end,
        stroll = function() return strollTask(c) end,
        leisure = function() return leisureTask(c, w) end,
        indoors = function() return indoorsTask(c) end,
    }
    -- try the options in a random order weighted by their chances
    local options, total = {}, 0
    for name, weight in pairs(chances) do
        options[#options + 1] = { name = name, weight = weight }
        total = total + weight
    end
    table.sort(options, function(a, b) return a.name < b.name end) -- pairs order isn't stable
    while #options > 0 do
        local roll = math.random() * total
        local at = #options
        for i, o in ipairs(options) do
            roll = roll - o.weight
            if roll <= 0 then at = i break end
        end
        local o = table.remove(options, at)
        total = total - o.weight
        local task = makers[o.name]()
        if task then
            task.downtime = true
            return task
        end
    end
    return idleTask(c, 'Taking it easy', 20)
end

-- Plan the next task for a free worker and remember it on the worker.
function C.nextTask(c, wid)
    local w = c.workers[wid]
    assert(w, 'no such worker ' .. tostring(wid))
    if w.task then C.cancelTask(c, wid) end
    local task

    local attacked = C.underAttack(c)
    local guard = isGuard(c, w)
    local period = C.workerPeriod(c, wid)
    local offDuty = not guard and not w.prisoner
    if attacked and guard then
        task = fightTask(c, w)
    elseif attacked and not w.prisoner then
        task = shelterTask(c)
    elseif period == 'sleep' and offDuty then
        task = sleepTask(c, w)
    elseif (w.fed < schedOf(w).eatBelow or (period == 'free' and offDuty and w.fed < defs.hunger.mealBelow))
        and C.available(c, 'food') >= defs.hunger.mealFood then
        task = eatTask(c)
    elseif w.prisoner and (period ~= 'work' or not (w.assignment and c.sites[w.assignment])) then
        local _, stockade = C.cells(c)
        task = idleTask(c, 'Locked up', 15, stockade)
    elseif period == 'free' and offDuty then
        task = downtimeTask(c, w, 'free', math.max(C.speed(c, wid), 0.1))
    else
        local speed = C.speed(c, wid)
        if speed <= 0 then
            task = idleTask(c, 'Starving - too weak to work', 15)
        else
            local s = w.assignment and w.assignment ~= 'builder' and c.sites[w.assignment]
            if s and def(s).guard then
                task = patrolTask(c, w, s)
            elseif s and def(s).trade then
                task = tradeTask(c, w, s, speed)
            elseif s then
                if def(s).input then
                    task = processTask(c, w, s, speed)
                else
                    task = gatherTask(c, w, s, speed)
                end
            elseif w.assignment == 'builder' then
                task = constructionWork(c, speed) or downtimeTask(c, w, 'work', speed)
            elseif w.prisoner then
                task = idleTask(c, 'Locked up', 15)
            else
                task = constructionWork(c, speed) or downtimeTask(c, w, 'work', speed)
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
            local need = s.needs[carry.res] or 0
            local used = math.min(need, carry.amount)
            s.needs[carry.res] = need - used
            local expected = task.incoming and task.incoming.amount or carry.amount
            s.incoming[carry.res] = math.max(0, (s.incoming[carry.res] or 0) - expected)
            -- anything left over goes to the stockpile
            if carry.amount > used then
                c.stock[carry.res] = (c.stock[carry.res] or 0) + carry.amount - used
            end
            w.carry = nil
            task.incoming = nil
        end
    elseif st.op == 'sell' then
        if w.carry then
            sellGoods(c, w.carry.res, w.carry.amount)
            w.carry = nil
        end
    elseif st.op == 'eat' then
        if w.carry and w.carry.res == 'food' then
            w.carry = nil -- brought along to the campfire
        else
            unreserve(c, 'food', defs.hunger.mealFood)
            c.stock.food = c.stock.food - defs.hunger.mealFood
        end
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
--   skipping: time was skipped (waiting, resting): settlers eat on their own
function C.tick(c, dt, hours, skipping)
    c.time = c.time + dt
    c.hours = c.hours + hours

    for _, wid in ipairs(c.workerOrder) do
        local w = c.workers[wid]
        local before = w.fed
        local sleeper = not isGuard(c, w) and not w.prisoner
        local left, at = hours, ((c.hourOfDay or 12) - hours) % 24
        repeat
            local chunk = math.min(left, 0.5)
            local rate = defs.hunger.decayPerHour
            if sleeper and periodFor(w, at) == 'sleep' then rate = rate * defs.hunger.asleepFactor end
            w.fed = math.max(0, w.fed - chunk * rate)
            if (w.offscreen or skipping) and w.fed < defs.hunger.eatBelow and C.available(c, 'food') >= defs.hunger.mealFood then
                c.stock.food = c.stock.food - defs.hunger.mealFood
                w.fed = 1
            end
            left, at = left - chunk, (at + chunk) % 24
        until left <= 1e-9
        if before > 0 and w.fed <= 0 then
            emit(c, { kind = 'msg', text = w.name .. ' is starving.' })
        end
    end

    tickTrade(c, hours)

    if c.storehouse then
        c.arrivalTimer = c.arrivalTimer + hours
        local pop = C.population(c) + c.pendingArrivals
        local wait = defs.arrival.everyHours + defs.arrival.perSettler * pop
        while c.arrivalTimer >= wait do
            c.arrivalTimer = c.arrivalTimer - wait
            if pop < C.beds(c)
                and C.available(c, 'food') >= defs.arrival.minFood + defs.arrival.foodPerSettler * pop then
                c.pendingArrivals = c.pendingArrivals + 1
                emit(c, { kind = 'arrival' })
            end
        end
    end
end

-- Abstract simulation for a worker that is not physically simulated
-- (player far away, or a time skip). Uses the same rates as real work.
--   anyTime: dt is already working time (see workSeconds)
function C.simulateWorker(c, wid, dt, anyTime)
    local w = c.workers[wid]
    if not w then return end
    if w.task then C.cancelTask(c, wid) end
    if not anyTime and C.workerPeriod(c, wid) ~= 'work' and not isGuard(c, w) then return end
    local speed = C.speed(c, wid)
    if speed <= 0 then return end

    local s = w.assignment and w.assignment ~= 'builder' and c.sites[w.assignment]
    if s and def(s).guard then return end -- guards just keep watch
    if w.prisoner and not s then return end -- locked up
    if s and def(s).trade then
        local cycle = def(s).cycle + 2 * C.tripSeconds(c, s.id)
        w.abstractProgress = w.abstractProgress + dt * speed / cycle
        while w.abstractProgress >= 1 do
            w.abstractProgress = w.abstractProgress - 1
            local res, amount = pickToSell(c)
            if not res or amount < 1 then
                w.abstractProgress = 0
                break
            end
            c.stock[res] = c.stock[res] - amount
            sellGoods(c, res, amount)
        end
        return
    end
    if s then
        local d = def(s)
        local cycle = d.cycle + 2 * C.tripSeconds(c, s.id)
        w.abstractProgress = w.abstractProgress + dt * speed / cycle
        while w.abstractProgress >= 1 do
            w.abstractProgress = w.abstractProgress - 1
            if storageFull(c, next(d.output)) then
                s.stalled = 'no room in the storehouse'
                w.abstractProgress = 0
                break
            end
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
            -- nothing in stock: make what's missing at a producer
            for _, res in ipairs(defs.resourceOrder) do
                local left = (site.needs[res] or 0) - (site.incoming[res] or 0)
                local p = left > 0 and producerOf(c, res)
                if p and not def(p).input then
                    local d = def(p)
                    local cycle = d.cycle + C.tripSeconds(c, p.id) + C.tripSeconds(c, sid)
                    w.abstractProgress = w.abstractProgress + dt * speed / cycle
                    while w.abstractProgress >= 1 and (site.needs[res] or 0) > 0 do
                        w.abstractProgress = w.abstractProgress - 1
                        local made = d.output[res]
                        local used = math.min(made, site.needs[res])
                        site.needs[res] = site.needs[res] - used
                        c.stock[res] = c.stock[res] + made - used
                    end
                    return
                end
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
    if w.offscreen then
        local period = C.workerPeriod(c, wid)
        if isGuard(c, w) or period == 'work' then return 'Working (away)' end
        return period == 'sleep' and 'Sleeping (away)' or 'Off duty (away)'
    end
    return 'Idle'
end

-- Construction progress: delivered materials and work done.
-- returns { materials = { {res=, name=, have=, need=} }, complete=, phase=, percent= }
function C.siteProgress(c, sid)
    local s = c.sites[sid]
    if not s then return nil end
    local p = { materials = {}, complete = true }
    for _, res in ipairs(defs.resourceOrder) do
        local total = (s.cost or def(s).cost)[res]
        if total and total > 0 then
            local left = s.built and 0 or (s.needs[res] or 0)
            p.materials[#p.materials + 1] = { res = res, name = resName(res), have = total - left, need = total }
            if left > 0 then p.complete = false end
        end
    end
    local work, level = siteWork(s), s.levelWork or 0
    if s.built then
        p.phase, p.percent = 'built', 100
    elseif not p.complete then
        p.phase, p.percent = 'materials', 0
    elseif s.progress < level then
        p.phase, p.percent = 'leveling', math.floor(100 * s.progress / level)
    else
        p.phase = 'building'
        p.percent = math.floor(100 * (s.progress - level) / math.max(1, work - level))
    end
    return p
end

function C.siteStatus(c, sid)
    local s = c.sites[sid]
    if not s then return '' end
    local d = def(s)
    if not s.built then
        local p = C.siteProgress(c, sid)
        local parts = {}
        for _, m in ipairs(p.materials) do
            parts[#parts + 1] = string.format('%s %d/%d', m.name, m.have, m.need)
        end
        local tail
        if p.phase == 'materials' then
            tail = 'waiting for materials'
            -- say why, if nobody can make what's missing
            for _, m in ipairs(p.materials) do
                if m.have < m.need and C.available(c, m.res) <= 0 and not producerOf(c, m.res) then
                    local maker = producerName(m.res)
                    tail = 'needs a ' .. (maker or 'source of ' .. m.name)
                    break
                end
            end
        elseif p.phase == 'leveling' then
            tail = string.format('leveling the ground %d%%', p.percent)
        else
            tail = string.format('%d%% built', p.percent)
        end
        if #parts == 0 then return tail end
        return table.concat(parts, ', ') .. ' - ' .. tail
    end
    if d.job then
        local n = #C.assignedTo(c, sid)
        local txt = string.format('%d/%d %ss', n, d.slots, d.job)
        if s.stalled then txt = txt .. ' - ' .. s.stalled end
        return txt
    end
    if d.beds then return d.beds == 1 and '1 bed' or (d.beds .. ' beds') end
    if d.storage then return 'Holds ' .. d.storage .. ' of everything' end
    if d.cells then
        return string.format('%d/%d prisoners (all cells)', C.prisonerCount(c), (C.cells(c)))
    end
    if d.small then return d.desc or '' end
    return 'Built'
end

-- A house's room in the interior cell (given out the first time it's entered).
function C.roomOf(c, sid)
    c.rooms = c.rooms or {}
    if not c.rooms[sid] then
        c.nextRoom = (c.nextRoom or 0) + 1
        c.rooms[sid] = c.nextRoom
    end
    return c.rooms[sid]
end

function C.drainEvents(c)
    local evs = c.events
    c.events = {}
    return evs
end

-- What a construction site should show physically: how much of each
-- delivered material is still lying there (it is used up as building work
-- progresses), how far the foundation pilings have gone in (0..1, they go in
-- while the ground is leveled) and how far the building itself has risen
-- (0..1, nil before it starts). nil for finished buildings.
--   busy: building work in progress on top of what's been completed: settlers
--   only book their work when they finish it, but it should show as they go
function C.siteVisuals(c, sid, busy)
    local s = c.sites[sid]
    if not s or s.built then return nil end
    local work = siteWork(s)
    local progress = math.min(work, s.progress + (busy or 0))
    local used = work > 0 and progress / work or 0
    local v = { piles = {}, pilings = 1 }
    for res, total in pairs(s.cost or def(s).cost) do
        local have = total - (s.needs[res] or 0)
        v.piles[res] = math.max(0, have * (1 - used))
    end
    local level = s.levelWork or 0
    if level > 0 then v.pilings = math.min(1, progress / level) end
    -- the building comes up once the materials are in and the ground is ready
    if materialsComplete(s) and progress >= level then
        v.rise = math.min(1, (progress - level) / math.max(1, work - level))
    end
    return v
end

return C
