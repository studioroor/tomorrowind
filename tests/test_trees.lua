-- Trees: woodcutters fell the trees around their camp, felled trees sprout
-- again, and settlers plant saplings and groves that grow.
local C = require('scripts.tomorrowind.core.colony')
local defs = require('scripts.tomorrowind.defs')

local function P(x, y) return { x = x, y = y, z = 0 } end

local function colony()
    local c = C.new()
    C.found(c, P(0, 0))
    c.stock.food = 200
    C.drainEvents(c)
    return c
end

local function woodcutter(c, camp)
    local w = C.addWorker(c, { name = 'W' })
    C.assign(c, w.id, camp.id)
    C.setClock(c, 10, 30)
    return w
end

-- Run a worker's task to the end; returns the task.
local function runTask(c, wid)
    local task = C.nextTask(c, wid)
    while C.currentStep(c, wid) do C.completeStep(c, wid) end
    return task
end

local function events(c, kind)
    local n = {}
    for _, e in ipairs(C.drainEvents(c)) do
        if e.kind == kind then n[#n + 1] = e end
    end
    return n
end

test('a woodcutter walks to a tree by the camp and fells it there', function()
    local c = colony()
    local camp = C.addSite(c, 'lumber', P(1000, 0), 0, true)
    local t = C.addTree(c, { pos = P(1400, 0), model = 'flora_tree_ai_05' })
    local w = woodcutter(c, camp)
    local task = C.nextTask(c, w.id)
    eq(task.tree, t.id, 'goes for the tree')
    eq(task.steps[1].op, 'goto')
    eq(task.steps[1].tree, t.id, 'walks to it')
    eq(task.steps[2].op, 'work')
    eq(task.steps[2].tree, t.id, 'and works at it')
    local wood = c.stock.wood
    while C.currentStep(c, w.id) do C.completeStep(c, w.id) end
    eq(c.stock.wood, wood + defs.buildings.lumber.output.wood, 'the timber goes to the storehouse')
    eq(t.wood, defs.trees.wood - defs.buildings.lumber.output.wood, 'and comes out of the tree')
end)

test('trees too far from the camp are not used', function()
    local c = colony()
    local camp = C.addSite(c, 'lumber', P(1000, 0), 0, true)
    C.addTree(c, { pos = P(1000 + defs.trees.reach + 200, 0), model = 'x' })
    local w = woodcutter(c, camp)
    local task = C.nextTask(c, w.id)
    eq(task.tree, nil, 'no tree in reach: works at the stump, as before trees counted')
    eq(task.steps[2].op, 'work')
end)

test('woodcutters spread over the trees, sharing one only when there is no other', function()
    local c = colony()
    local camp = C.addSite(c, 'lumber', P(1000, 0), 0, true)
    local a = C.addTree(c, { pos = P(1200, 0), model = 'x' })
    local b = C.addTree(c, { pos = P(1500, 0), model = 'x' })
    local w1, w2, w3 = woodcutter(c, camp), woodcutter(c, camp), woodcutter(c, camp)
    eq(C.nextTask(c, w1.id).tree, a.id, 'the closest first')
    eq(C.nextTask(c, w2.id).tree, b.id, 'the next one to the next')
    local third = C.nextTask(c, w3.id).tree
    assert(third == a.id or third == b.id, 'with both taken, a third shares one')
end)

test('a tree runs out of timber and comes down; its stump sprouts and grows back', function()
    local c = colony()
    local camp = C.addSite(c, 'lumber', P(1000, 0), 0, true)
    local t = C.addTree(c, { pos = P(1300, 0), model = 'x' })
    local w = woodcutter(c, camp)
    local loads = 0
    while not t.felled and loads < 50 do
        runTask(c, w.id)
        loads = loads + 1
    end
    eq(loads, math.ceil(defs.trees.wood / defs.buildings.lumber.output.wood), 'loads in a tree')
    eq(#events(c, 'tree_felled'), 1, 'felled once')
    -- with nothing standing, the camp waits
    local task = C.nextTask(c, w.id)
    eq(task.kind, 'idle', 'nothing to fell')
    assert(c.sites[camp.id].stalled:find('grow'), 'the camp says why: ' .. tostring(c.sites[camp.id].stalled))
    assert(C.siteStatus(c, camp.id):find('1 felled'), C.siteStatus(c, camp.id))
    C.cancelTask(c, w.id)
    -- a day later it sprouts...
    C.tick(c, 1, defs.trees.sproutHours + 0.1)
    eq(t.felled, false, 'sprouted')
    eq(#events(c, 'tree_sprouted'), 1)
    near(t.grow, defs.trees.sapling, 1e-6, 'a sapling again')
    eq(C.treeReady(t), false, 'too small to fell')
    -- ...and grows up
    C.tick(c, 1, defs.trees.growHours / 2)
    assert(t.grow > defs.trees.sapling and t.grow < 1, 'half grown: ' .. t.grow)
    C.tick(c, 1, defs.trees.growHours / 2 + 0.1)
    eq(t.grow, 1, 'grown')
    eq(t.wood, defs.trees.wood, 'with its timber')
    w.fed = 1 -- three days on: fed, not off to eat
    eq(C.nextTask(c, w.id).tree, t.id, 'and it can be felled again')
end)

test('a woodcutter out of sight fells trees too, and stops when none are left', function()
    local c = colony()
    local camp = C.addSite(c, 'lumber', P(1000, 0), 0, true)
    local t = C.addTree(c, { pos = P(1300, 0), model = 'x' })
    local w = woodcutter(c, camp)
    w.offscreen = true
    local before = c.stock.wood
    for _ = 1, 400 do C.simulateWorker(c, w.id, 10) end
    eq(t.felled, true, 'the tree came down')
    eq(c.stock.wood - before, defs.trees.wood, 'and gave all its timber, no more')
    assert(c.sites[camp.id].stalled, 'the camp waits for its trees')
end)

test('laborers helping out skip a camp with no trees left', function()
    local c = colony()
    local camp = C.addSite(c, 'lumber', P(1000, 0), 0, true)
    local t = C.addTree(c, { pos = P(1300, 0), model = 'x' })
    eq(C.producerOf(c, 'wood'), c.sites[camp.id], 'trees to fell: it makes timber')
    t.felled, t.sproutIn = true, 10
    eq(C.producerOf(c, 'wood'), nil, 'all down: nothing to make timber with')
end)

test('a planted sapling becomes a small tree of the colony, and grows', function()
    local c = colony()
    local s = C.addSite(c, 'sapling', P(500, 500), 0, false, { variant = 3 })
    C.drainEvents(c)
    C.finishSite(c, s.id)
    eq(c.sites[s.id], nil, 'the planting is done with')
    local list = C.treeList(c)
    eq(#list, 1, 'one tree')
    local t = list[1]
    eq(t.model, defs.look('sapling', 3).tree, 'of the chosen kind')
    eq(t.planted, true)
    near(t.grow, defs.trees.sapling, 1e-6, 'small at first')
    eq(t.pos.x, 500)
    local planted = 0
    for _, e in ipairs(C.drainEvents(c)) do
        if e.kind == 'tree_planted' then planted = planted + 1 end
    end
    eq(planted, 1, 'the world gets told')
    C.tick(c, 1, defs.trees.growHours + 1)
    eq(C.treeReady(t), true, 'grown in a few days')
end)

test('the first kind to plant is whatever grows around the colony', function()
    local c = colony()
    c.localTree = 'flora_tree_ai_03'
    local s = C.addSite(c, 'sapling', P(500, 500), 0, false, { variant = 1 })
    C.finishSite(c, s.id)
    eq(C.treeList(c)[1].model, 'flora_tree_ai_03')
end)

test('a grove plants five saplings spread around the spot', function()
    local c = colony()
    local s = C.addSite(c, 'grove', P(0, 2000), 0.3, false)
    C.finishSite(c, s.id)
    local list = C.treeList(c)
    eq(#list, defs.buildings.grove.plants, 'five trees')
    for i, t in ipairs(list) do
        local d = math.sqrt((t.pos.x - 0) ^ 2 + (t.pos.y - 2000) ^ 2)
        assert(d <= defs.trees.groveRadius * 1.05, 'within the grove: ' .. d)
        for j = i + 1, #list do
            local o = list[j]
            local apart = math.sqrt((t.pos.x - o.pos.x) ^ 2 + (t.pos.y - o.pos.y) ^ 2)
            assert(apart > 120, 'not on top of each other: ' .. apart)
        end
    end
end)

test('a Woodcutter\'s Camp needs a standing tree close by', function()
    local list = {
        { pos = P(0, 0), felled = true },
        { pos = P(3000, 0) },
    }
    eq(C.treeNear(list, P(100, 0), defs.trees.campReach), false, 'a felled tree does not count')
    eq(C.treeNear(list, P(3000 - defs.trees.campReach + 50, 0), defs.trees.campReach), true, 'a standing one in reach does')
    eq(C.treeNear(list, P(1000, 0), defs.trees.campReach), false, 'too far')
end)

test('the woodcutter\'s camp reports on its trees', function()
    local c = colony()
    local camp = C.addSite(c, 'lumber', P(1000, 0), 0, true)
    assert(C.siteStatus(c, camp.id):find('no trees nearby'), C.siteStatus(c, camp.id))
    C.addTree(c, { pos = P(1300, 0), model = 'x' })
    C.addTree(c, { pos = P(1300, 300), model = 'x', grow = 0.5 })
    local status = C.siteStatus(c, camp.id)
    assert(status:find('1 to fell') and status:find('1 growing'), status)
end)
