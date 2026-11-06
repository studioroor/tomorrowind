local C = require('scripts.tomorrowind.core.colony')
local defs = require('scripts.tomorrowind.defs')

local function P(x, y) return { x = x, y = y, z = 0 } end

-- founded colony with n workers spawned
local function colony(n)
    local c = C.new()
    C.found(c, P(0, 0))
    local ids = {}
    for i = 1, (n or 3) do ids[i] = C.addWorker(c, { name = 'W' .. i }).id end
    C.drainEvents(c)
    return c, ids
end

-- run a worker's current task to completion, returning the ops performed
local function runTask(c, wid)
    local ops = {}
    local st = C.currentStep(c, wid)
    while st do
        ops[#ops + 1] = st.op
        st = C.completeStep(c, wid)
    end
    return table.concat(ops, ',')
end

local function hasEvent(evs, kind)
    for _, e in ipairs(evs) do if e.kind == kind then return e end end
end

test('founding creates a built storehouse and requests starting workers', function()
    local c = C.new()
    local s = C.found(c, P(0, 0))
    eq(s.built, true)
    eq(c.storehouse, s.id)
    eq(C.beds(c), defs.buildings.storehouse.beds)
    local arrivals = 0
    for _, e in ipairs(C.drainEvents(c)) do
        if e.kind == 'arrival' then arrivals = arrivals + 1 end
    end
    eq(arrivals, defs.startingWorkers)
    eq(c.pendingArrivals, defs.startingWorkers)
    C.addWorker(c, { name = 'A' })
    eq(c.pendingArrivals, defs.startingWorkers - 1)
end)

test('gatherer walks, works, carries output back to the stockpile', function()
    local c, w = colony(1)
    local mine = C.addSite(c, 'mine', P(1000, 0), 0, true)
    assert(C.assign(c, w[1], mine.id))
    local t = C.nextTask(c, w[1])
    eq(t.kind, 'gather')
    eq(runTask(c, w[1]), 'goto,work,goto,store')
    eq(c.stock.ore, defs.buildings.mine.output.ore)
    eq(c.workers[w[1]].carry, nil)
end)

test('cannot assign to unbuilt or full sites', function()
    local c, w = colony(4)
    local mine = C.addSite(c, 'mine', P(1000, 0), 0, false)
    local ok, err = C.assign(c, w[1], mine.id)
    eq(ok, false)
    assert(err:find('not built'))
    local finished = C.addSite(c, 'mine', P(0, 1000), 0, true)
    for i = 1, defs.buildings.mine.slots do assert(C.assign(c, w[i], finished.id)) end
    ok, err = C.assign(c, w[4], finished.id)
    eq(ok, false)
    assert(err:find('full'))
    -- storehouse has no jobs
    ok = C.assign(c, w[4], c.storehouse)
    eq(ok, false)
end)

test('smelter reserves ore, converts it and stalls when ore runs out', function()
    local c, w = colony(2)
    local sm = C.addSite(c, 'smelter', P(500, 0), 0, true)
    c.stock.ore = 3
    assert(C.assign(c, w[1], sm.id))
    assert(C.assign(c, w[2], sm.id))
    local t1 = C.nextTask(c, w[1])
    eq(t1.kind, 'process')
    eq(C.available(c, 'ore'), 1, 'ore reserved for first smelter')
    local t2 = C.nextTask(c, w[2])
    eq(t2.kind, 'idle', 'second smelter cannot get enough ore')
    eq(sm.stalled ~= nil, true)
    eq(runTask(c, w[1]), 'goto,take,goto,work,goto,store')
    eq(c.stock.ore, 1)
    eq(c.stock.ingot, 1)
    eq(c.reserved.ore, 0)
end)

test('laborers haul materials to construction, then build it', function()
    local c, w = colony(1)
    c.stock.wood = 30
    local farm = C.addSite(c, 'farm', P(800, 0), 0, false)
    local need = defs.buildings.farm.cost.wood
    local evs
    local guard = 0
    while not farm.built do
        guard = guard + 1
        assert(guard < 50, 'construction never finished')
        local t = C.nextTask(c, w[1])
        assert(t.kind == 'haul' or t.kind == 'build', 'unexpected task ' .. t.kind)
        runTask(c, w[1])
    end
    eq(c.stock.wood, 30 - need)
    evs = C.drainEvents(c)
    assert(hasEvent(evs, 'built'), 'built event emitted')
    eq(C.beds(c), defs.buildings.storehouse.beds, 'farm adds no beds')
end)

test('two haulers never over-deliver thanks to reservations', function()
    local c, w = colony(3)
    c.stock.wood = 100
    local farm = C.addSite(c, 'farm', P(800, 0), 0, false) -- needs 6 wood
    local t1 = C.nextTask(c, w[1])
    local t2 = C.nextTask(c, w[2])
    local t3 = C.nextTask(c, w[3])
    eq(t1.kind, 'haul')
    eq(t1.holds.amount, 5)
    eq(t2.kind, 'haul')
    eq(t2.holds.amount, 1)
    eq(t3.kind, 'idle', 'nothing left to haul, materials not yet in')
    runTask(c, w[1]); runTask(c, w[2])
    eq(farm.needs.wood, 0)
    eq(c.stock.wood, 94)
end)

test('cancelling a haul releases the reservation and returns carried goods', function()
    local c, w = colony(1)
    c.stock.wood = 10
    local farm = C.addSite(c, 'farm', P(800, 0), 0, false)
    C.nextTask(c, w[1])
    C.completeStep(c, w[1]) -- goto store
    C.completeStep(c, w[1]) -- take
    eq(c.stock.wood, 5)
    C.cancelTask(c, w[1])
    eq(c.stock.wood, 10)
    eq(c.reserved.wood, 0)
    eq(farm.incoming.wood, 0)
    eq(C.missing(c, farm.id).wood, 6)
end)

test('hungry workers eat first, starving workers stop', function()
    local c, w = colony(1)
    local mine = C.addSite(c, 'mine', P(1000, 0), 0, true)
    C.assign(c, w[1], mine.id)
    local worker = c.workers[w[1]]
    C.tick(c, 0, 4) -- 4 hours: fed = 1 - 4/6
    assert(worker.fed < defs.hunger.eatBelow)
    local t = C.nextTask(c, w[1])
    eq(t.kind, 'eat')
    local food = c.stock.food
    runTask(c, w[1])
    eq(worker.fed, 1)
    eq(c.stock.food, food - 1)

    c.stock.food = 0
    C.tick(c, 0, 5) -- below hungry threshold
    local t2 = C.nextTask(c, w[1])
    eq(t2.kind, 'gather')
    near(t2.steps[2].duration, defs.buildings.mine.cycle / defs.hunger.hungrySpeed)
    C.cancelTask(c, w[1])
    C.tick(c, 0, 5)
    eq(worker.fed, 0)
    local t3 = C.nextTask(c, w[1])
    eq(t3.kind, 'idle')
    assert(t3.label:find('Starving'))
end)

test('houses add beds, newcomers arrive only with space and food', function()
    local c, w = colony(4) -- storehouse beds = 4: full
    C.tick(c, 0, 3)
    eq(hasEvent(C.drainEvents(c), 'arrival'), nil, 'no beds free')
    C.addSite(c, 'house', P(2000, 0), 0, true)
    C.drainEvents(c)
    C.tick(c, 0, 1)
    assert(hasEvent(C.drainEvents(c), 'arrival'), 'arrival once there is a house')
    eq(c.pendingArrivals, 1)
    C.tick(c, 0, 1)
    C.addWorker(c, { name = 'New' })
    eq(c.pendingArrivals, 1) -- second arrival pending after one joined
    c.stock.food = 0
    for _, wid in ipairs(c.workerOrder) do c.workers[wid].fed = 1 end
    C.drainEvents(c)
    C.tick(c, 0, 1)
    eq(hasEvent(C.drainEvents(c), 'arrival'), nil, 'no food, no newcomers')
end)

test('reassigning cancels the current task cleanly', function()
    local c, w = colony(1)
    local sm = C.addSite(c, 'smelter', P(500, 0), 0, true)
    local mine = C.addSite(c, 'mine', P(1000, 0), 0, true)
    c.stock.ore = 4
    C.assign(c, w[1], sm.id)
    C.nextTask(c, w[1])
    eq(c.reserved.ore, 2)
    C.assign(c, w[1], mine.id)
    eq(c.reserved.ore, 0)
    eq(c.workers[w[1]].task, nil)
    eq(C.nextTask(c, w[1]).kind, 'gather')
end)

test('removing an unfinished site refunds delivered materials', function()
    local c, w = colony(1)
    c.stock.wood = 10
    local farm = C.addSite(c, 'farm', P(800, 0), 0, false)
    C.nextTask(c, w[1])
    runTask(c, w[1]) -- delivers 5
    eq(c.stock.wood, 5)
    C.removeSite(c, farm.id)
    eq(c.stock.wood, 10)
    eq(c.sites[farm.id], nil)
end)

test('abstract simulation matches rates and respects inputs', function()
    local c, w = colony(2)
    local mine = C.addSite(c, 'mine', P(0, 0), 0, true) -- zero trip time
    local sm = C.addSite(c, 'smelter', P(0, 0), 0, true)
    C.assign(c, w[1], mine.id)
    C.assign(c, w[2], sm.id)
    local d = defs.buildings.mine
    C.simulateWorker(c, w[1], d.cycle * 10)
    eq(c.stock.ore, d.output.ore * 10)
    local smd = defs.buildings.smelter
    C.simulateWorker(c, w[2], smd.cycle * 100) -- wants 100 cycles, ore for 10
    eq(c.stock.ingot, 10)
    eq(c.stock.ore, 0)
    eq(sm.stalled ~= nil, true)
end)

test('abstract builders deliver and finish construction', function()
    local c, w = colony(1)
    c.stock.wood = 50
    local farm = C.addSite(c, 'farm', P(0, 0), 0, false)
    for _ = 1, 10 do C.simulateWorker(c, w[1], 10) end
    eq(farm.built, true)
    eq(c.stock.wood, 50 - defs.buildings.farm.cost.wood)
end)

test('offscreen workers eat automatically during ticks', function()
    local c, w = colony(1)
    local worker = c.workers[w[1]]
    worker.offscreen = true
    local food = c.stock.food
    C.tick(c, 0, 4)
    eq(worker.fed, 1)
    eq(c.stock.food, food - 1)
end)

test('status strings are readable', function()
    local c, w = colony(1)
    local farm = C.addSite(c, 'farm', P(800, 0), 0, false)
    eq(C.siteStatus(c, farm.id), 'Needs 6 Timber')
    local mine = C.addSite(c, 'mine', P(1000, 0), 0, true)
    C.assign(c, w[1], mine.id)
    eq(C.siteStatus(c, mine.id), '1/3 Miners')
    C.nextTask(c, w[1])
    eq(C.workerStatus(c, w[1]), 'Walking to the Ore Vein')
    eq(C.assignmentLabel(c, mine.id), 'Miner (Ore Vein)')
end)

test('a settler dying mid-haul releases materials and frees a bed', function()
    local c, w = colony(2)
    c.stock.wood = 10
    local farm = C.addSite(c, 'farm', P(800, 0), 0, false)
    C.nextTask(c, w[1])
    C.completeStep(c, w[1]) -- at storehouse
    C.completeStep(c, w[1]) -- took 5 wood
    C.removeWorker(c, w[1])
    eq(c.stock.wood, 10)
    eq(c.reserved.wood, 0)
    eq(farm.incoming.wood, 0)
    eq(C.population(c), 1)
    eq(C.nextTask(c, w[2]).kind, 'haul', 'the other settler takes over')
end)
