local C = require('scripts.tomorrowind.core.colony')
local defs = require('scripts.tomorrowind.defs')

local function P(x, y) return { x = x, y = y, z = 0 } end

local function colony(n)
    local c = C.new()
    C.found(c, P(0, 0))
    local ids = {}
    for i = 1, n do ids[i] = C.addWorker(c, { name = 'W' .. i }).id end
    C.drainEvents(c)
    return c, ids
end

local function kinds(evs)
    local k = {}
    for _, e in ipairs(evs) do k[e.kind] = true end
    return k
end

test('an attack raises the alarm; settlers shelter, guards fight', function()
    local c, w = colony(3)
    local post = C.addSite(c, 'guardpost', P(300, 0), 0, true)
    local mine = C.addSite(c, 'mine', P(900, 0), 0, true)
    assert(C.assign(c, w[1], post.id))
    assert(C.assign(c, w[2], mine.id))
    local tid = C.addThreat(c, { name = 'a bandit' })
    assert(kinds(C.drainEvents(c)).alarm)
    local g = C.nextTask(c, w[1])
    eq(g.kind, 'fight')
    eq(g.steps[1].target, tid)
    eq(C.nextTask(c, w[2]).kind, 'shelter', 'miner shelters')
    eq(C.nextTask(c, w[3]).kind, 'shelter', 'laborer shelters')
    C.removeThreat(c, tid)
    assert(kinds(C.drainEvents(c)).all_clear)
    eq(C.nextTask(c, w[2]).kind, 'gather', 'back to work')
    eq(C.nextTask(c, w[1]).kind, 'patrol', 'guard patrols in peacetime')
end)

test('guards patrol between buildings and their post', function()
    local c, w = colony(1)
    local post = C.addSite(c, 'guardpost', P(300, 0), 0, true)
    C.assign(c, w[1], post.id)
    local t = C.nextTask(c, w[1])
    eq(t.kind, 'patrol')
    eq(#t.steps, 4)
    eq(t.steps[3].to, post.id)
end)

test('prisoners need a stockade with room', function()
    local c = colony(0)
    eq(C.canTakePrisoner(c), false)
    C.addSite(c, 'stockade', P(-500, 0), 0, true)
    eq(C.cells(c), defs.buildings.stockade.cells)
    for i = 1, defs.buildings.stockade.cells do
        assert(C.canTakePrisoner(c))
        C.addWorker(c, { name = 'P' .. i, prisoner = true })
    end
    eq(C.canTakePrisoner(c), false)
end)

test('prisoners do not use beds and can only mine or cut wood', function()
    local c, w = colony(4) -- storehouse full
    local stockade = C.addSite(c, 'stockade', P(-500, 0), 0, true)
    local mine = C.addSite(c, 'mine', P(900, 0), 0, true)
    local farm = C.addSite(c, 'farm', P(0, 900), 0, true)
    local p = C.addWorker(c, { name = 'Bandit', prisoner = true }).id
    eq(C.population(c), 4)
    eq(C.prisonerCount(c), 1)
    local ok, err = C.assign(c, p, farm.id)
    eq(ok, false)
    assert(err:find('only mine'))
    eq(C.assign(c, p, 'builder'), false)
    local t = C.nextTask(c, p)
    eq(t.kind, 'idle')
    eq(t.steps[1].at, stockade.id, 'locked up in the stockade')
    assert(C.assign(c, p, mine.id))
    eq(C.nextTask(c, p).kind, 'gather', 'forced labour')
    eq(C.assignmentLabel(c, nil, true), 'Prisoner')
end)

test('prisoners do not shelter during an attack', function()
    local c = colony(0)
    C.addSite(c, 'stockade', P(-500, 0), 0, true)
    local p = C.addWorker(c, { name = 'Bandit', prisoner = true }).id
    C.addThreat(c, { name = 'another bandit' })
    eq(C.nextTask(c, p).kind, 'idle')
end)

test('off-screen guards and idle prisoners produce nothing', function()
    local c, w = colony(1)
    local post = C.addSite(c, 'guardpost', P(300, 0), 0, true)
    C.assign(c, w[1], post.id)
    C.simulateWorker(c, w[1], 1000)
    C.addSite(c, 'stockade', P(-500, 0), 0, true)
    local p = C.addWorker(c, { name = 'B', prisoner = true }).id
    C.simulateWorker(c, p, 1000)
    eq(c.stock.ore, 0)
    eq(c.stock.wood, defs.startingStock.wood)
end)

test('stockade status shows prisoners', function()
    local c = colony(0)
    local st = C.addSite(c, 'stockade', P(-500, 0), 0, true)
    C.addWorker(c, { name = 'B', prisoner = true })
    eq(C.siteStatus(c, st.id), '1/4 prisoners (all cells)')
end)

test('going through jobs skips full ones, in both directions', function()
    local c = C.new()
    C.found(c, { x = 0, y = 0, z = 0 })
    local ids = {}
    for i = 1, 4 do ids[i] = C.addWorker(c, { name = 'W' .. i }).id end
    local post = C.addSite(c, 'guardpost', { x = 300, y = 0, z = 0 }, 0, true)
    local mine = C.addSite(c, 'mine', { x = 600, y = 0, z = 0 }, 0, true)
    C.assign(c, ids[1], post.id)
    C.assign(c, ids[2], post.id) -- the post is now full
    -- laborer, builder, (post), mine: from builder, forward lands on the mine
    C.assign(c, ids[3], 'builder')
    local nextJob = C.nextAssignment(c, ids[3], 1)
    eq(nextJob, mine.id)
    -- and from the mine, back past the post to builder
    C.assign(c, ids[3], mine.id)
    eq(C.nextAssignment(c, ids[3], -1), 'builder')
    -- someone already at a full post can still move on
    assert(C.nextAssignment(c, ids[1], 1) == mine.id)
    -- the whole way round works: laborer is false
    C.assign(c, ids[3], 'builder')
    eq(C.nextAssignment(c, ids[3], -1), false)
end)

test('prisoners only go through the jobs they can do', function()
    local c = C.new()
    C.found(c, { x = 0, y = 0, z = 0 })
    C.addSite(c, 'stockade', { x = 900, y = 0, z = 0 }, 0, true)
    local farm = C.addSite(c, 'farm', { x = 300, y = 0, z = 0 }, 0, true)
    local mine = C.addSite(c, 'mine', { x = 600, y = 0, z = 0 }, 0, true)
    local p = C.addWorker(c, { name = 'P', prisoner = true }).id
    eq(C.nextAssignment(c, p, 1), mine.id, 'not builder, not the farm')
    eq(farm.built, true)
end)
