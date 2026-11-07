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

local function ops(task)
    local out = {}
    for _, st in ipairs(task.steps) do out[#out + 1] = st.op end
    return table.concat(out, ',')
end

test('the day is divided into work, free time and sleep', function()
    eq(C.periodAt(5.9), 'sleep')
    eq(C.periodAt(6), 'free')
    eq(C.periodAt(7), 'work')
    eq(C.periodAt(17.9), 'work')
    eq(C.periodAt(18), 'free')
    eq(C.periodAt(22), 'sleep')
    eq(C.periodAt(23.5), 'sleep')
end)

test('settlers work by day and go to bed at night', function()
    local c, w = colony(1)
    local lumber = C.addSite(c, 'lumber', P(400, 0), 0, true)
    C.assign(c, w[1], lumber.id)
    C.setClock(c, 12, 30)
    eq(C.nextTask(c, w[1]).kind, 'gather')
    C.setClock(c, 23, 30)
    local t = C.nextTask(c, w[1])
    eq(t.kind, 'sleep')
    eq(ops(t), 'goto,sleep')
    near(t.steps[2].duration, (c.workers[w[1]].sched.wake - 23) % 24 * 3600 / 30, 1e-6, 'sleeps until their own morning')
    eq(t.steps[2].inside, true, 'the storehouse has no visible bed')
end)

test('free time goes to the furnishings, and each has room for so many', function()
    local c, w = colony(3)
    local shelf = C.addSite(c, 'bookshelf', P(100, 0), 0, true)
    C.setClock(c, 19, 30)
    defs.buildings.bookshelf.interact.slots = 2
    local free = defs.downtime.free
    defs.downtime.free = { leisure = 1 }
    local a, b, d = C.nextTask(c, w[1]), C.nextTask(c, w[2]), C.nextTask(c, w[3])
    defs.downtime.free = free
    eq(a.kind, 'leisure')
    eq(a.site, shelf.id)
    eq(a.steps[2].prop, 'book')
    local spread = defs.schedule.leisureSpread
    assert(a.steps[2].duration >= (1 - spread) * 3600 / 30 and a.steps[2].duration <= (1 + spread) * 3600 / 30, 'about one game hour')
    eq(b.kind, 'leisure')
    assert(d.kind ~= 'leisure', 'the third finds the shelf full')
end)

test('free time without furnishings: still something to do', function()
    local c, w = colony(1)
    C.setClock(c, 19, 30)
    local kinds = {}
    for _ = 1, 40 do
        local t = C.nextTask(c, w[1])
        kinds[t.kind] = true
        C.cancelTask(c, w[1])
    end
    assert(kinds.stroll or kinds.indoors, 'strolls or goes indoors')
end)

test('with a campfire, meals are taken there', function()
    local c, w = colony(1)
    local fire = C.addSite(c, 'campfire', P(200, 0), 0, true)
    C.setClock(c, 19, 30)
    local worker = c.workers[w[1]]
    worker.fed = 0.6
    local before = c.stock.food
    local t = C.nextTask(c, w[1])
    eq(t.kind, 'eat')
    eq(ops(t), 'goto,take,goto,eat')
    eq(t.steps[3].to, fire.id)
    while C.currentStep(c, w[1]) do C.completeStep(c, w[1]) end
    eq(worker.fed, 1)
    eq(c.stock.food, before - defs.hunger.mealFood)
    eq(c.reserved.food, 0)
end)

test('a meal interrupted on the way puts the food back', function()
    local c, w = colony(1)
    C.addSite(c, 'campfire', P(200, 0), 0, true)
    C.setClock(c, 19, 30)
    c.workers[w[1]].fed = 0.6
    local before = c.stock.food
    C.nextTask(c, w[1])
    C.completeStep(c, w[1]) -- at the storehouse
    C.completeStep(c, w[1]) -- took the food
    C.cancelTask(c, w[1])
    eq(c.stock.food, before)
    eq(c.reserved.food, 0)
end)

test('beds: real beds first, one sleeper each, and the same bed every night', function()
    local c, w = colony(2)
    local bed = C.addSite(c, 'bed', P(100, 0), 0, true)
    C.setClock(c, 23, 30)
    local a = C.nextTask(c, w[1])
    eq(a.site, bed.id)
    eq(a.steps[2].onBed, true)
    local b = C.nextTask(c, w[2])
    eq(b.site, c.storehouse, 'the bed is taken')
    C.cancelTask(c, w[1])
    eq(C.nextTask(c, w[1]).site, bed.id, 'still theirs')
    eq(C.beds(c), defs.buildings.storehouse.beds + 1)
end)

test('removing a bed sends its sleeper elsewhere', function()
    local c, w = colony(1)
    local bed = C.addSite(c, 'bed', P(100, 0), 0, true)
    C.setClock(c, 23, 30)
    C.nextTask(c, w[1])
    C.removeSite(c, bed.id)
    eq(c.workers[w[1]].bed, nil)
    eq(C.nextTask(c, w[1]).site, c.storehouse)
end)

test('guards keep watch all night; prisoners stay locked up outside work', function()
    local c, w = colony(2)
    local post = C.addSite(c, 'guardpost', P(100, 0), 0, true)
    local mine = C.addSite(c, 'mine', P(300, 0), 0, true)
    C.addSite(c, 'stockade', P(500, 0), 0, true)
    C.assign(c, w[1], post.id)
    local p = C.addWorker(c, { name = 'Bandit', prisoner = true })
    C.assign(c, p.id, mine.id)
    C.setClock(c, 23, 30)
    eq(C.nextTask(c, w[1]).kind, 'patrol')
    eq(C.nextTask(c, p.id).steps[1].label, 'Locked up')
    C.setClock(c, 12, 30)
    eq(C.nextTask(c, p.id).kind, 'gather')
end)

test('an alarm wakes everybody', function()
    local c, w = colony(1)
    C.setClock(c, 23, 30)
    eq(C.nextTask(c, w[1]).kind, 'sleep')
    C.addThreat(c, { name = 'Bandit' })
    eq(C.nextTask(c, w[1]).kind, 'shelter')
end)

test('hunger grows slower overnight', function()
    local c, w = colony(1)
    local worker = c.workers[w[1]]
    C.setClock(c, 5, 30) -- the last 6 hours were all night
    C.tick(c, 0, 6)
    near(worker.fed, 1 - 6 * defs.hunger.decayPerHour * defs.hunger.asleepFactor, 1e-9)
end)

test('a skipped night leaves settlers fed if there is food', function()
    local c, w = colony(1)
    local worker = c.workers[w[1]]
    C.setClock(c, 12, 30)
    local before = c.stock.food
    C.tick(c, 0, 24, true)
    assert(worker.fed >= defs.hunger.eatBelow, 'ate along the way')
    assert(c.stock.food < before)
end)

test('off-screen settlers only produce during working hours', function()
    local c, w = colony(1)
    local lumber = C.addSite(c, 'lumber', P(100, 0), 0, true)
    C.assign(c, w[1], lumber.id)
    local before = c.stock.wood
    C.setClock(c, 23, 30)
    C.simulateWorker(c, w[1], 1000)
    eq(c.stock.wood, before)
    C.setClock(c, 12, 30)
    C.simulateWorker(c, w[1], 1000)
    assert(c.stock.wood > before)
end)

test('skipped time counts only the working hours', function()
    local c = colony(0)
    C.setClock(c, 0, 30)
    near(C.workSeconds(c, 22, 8), 0, 1e-9, 'all night')
    near(C.workSeconds(c, 8, 2), 2 * 3600 / 30, 1e-9, 'all work')
    near(C.workSeconds(c, 0, 24), 11 * 3600 / 30, 1e-9, 'a whole day')
end)

test('removed furnishings give their materials back, buildings do not', function()
    local c = colony(0)
    local chair = C.addSite(c, 'chair', P(100, 0), 0, true)
    local mine = C.addSite(c, 'mine', P(300, 0), 0, true)
    local before = c.stock.wood
    C.removeSite(c, chair.id)
    eq(c.stock.wood, before + defs.buildings.chair.cost.wood)
    before = c.stock.wood
    C.removeSite(c, mine.id)
    eq(c.stock.wood, before)
end)

test('everybody keeps their own hours, within sensible limits', function()
    local c = colony(0)
    local wakes = {}
    for i = 1, 200 do
        local id = C.addWorker(c, { name = 'W' .. i }).id
        local d = c.workers[id].sched
        assert(d.wake < d.workStart, 'up before work')
        assert(d.workEnd < d.sleep, 'bed after work')
        assert(d.wake > 4.9 and d.wake < 7.1, 'wake')
        assert(d.sleep > 20.9 and d.sleep < 23.1, 'sleep')
        wakes[string.format('%.2f', d.wake)] = true
        C.setClock(c, 12, 30)
        eq(C.workerPeriod(c, id), 'work', 'noon is always work')
        C.setClock(c, 1, 30)
        eq(C.workerPeriod(c, id), 'sleep', 'one at night is always sleep')
    end
    local n = 0
    for _ in pairs(wakes) do n = n + 1 end
    assert(n > 20, 'and they really differ')
end)

test('older saves get personal schedules when needed', function()
    local c, w = colony(1)
    c.workers[w[1]].sched = nil
    C.setClock(c, 1, 30)
    eq(C.nextTask(c, w[1]).kind, 'sleep')
    assert(c.workers[w[1]].sched)
end)

test('a chair takes at most two settlers; a house takes everyone', function()
    local c, w = colony(6)
    c.stock.wood = 100
    c.stock.ingot = 10
    local chair = C.addSite(c, 'chair', P(100, 0), 0, false)
    chair.needs.wood = 0 -- materials are in: everybody could build now
    C.setClock(c, 12, 30)
    for i = 1, 6 do C.nextTask(c, w[i]) end
    eq(C.crewOn(c, chair.id), defs.buildings.chair.maxBuilders)
    for i = 1, 6 do C.cancelTask(c, w[i]) end
    C.removeSite(c, chair.id)
    local house = C.addSite(c, 'house', P(800, 0), 0, false)
    house.needs.wood = 60 -- plenty of loads for everybody
    c.stock.wood = 200
    local onHouse = 0
    for i = 1, 6 do
        local t = C.nextTask(c, w[i])
        if t.incoming and t.incoming.site == house.id then onHouse = onHouse + 1 end
    end
    eq(onHouse, 6)
end)

test('settlers with nothing to do lend a hand, potter about or chat', function()
    local c, w = colony(4)
    C.addSite(c, 'lumber', P(400, 0), 0, true)
    C.setClock(c, 12, 30)
    local kinds = {}
    for _ = 1, 60 do
        for i = 1, 4 do
            local t = C.nextTask(c, w[i])
            kinds[t.kind] = true
            eq(t.downtime, true)
            assert(t.i == 1)
        end
        for i = 1, 4 do C.cancelTask(c, w[i]) end
        C.drainEvents(c)
    end
    assert(kinds.gather, 'helping out')
    assert(kinds.chat, 'chatting')
    assert(kinds.stroll, 'strolling')
    assert(kinds.indoors, 'indoors')
    assert(kinds.tidy, 'tidying')
end)

test('helping out produces real goods and respects the free slots', function()
    local c, w = colony(5)
    local lumber = C.addSite(c, 'lumber', P(400, 0), 0, true)
    C.setClock(c, 12, 30)
    for _ = 1, 40 do
        for i = 1, 5 do C.nextTask(c, w[i]) end
        local helpers = 0
        for i = 1, 5 do
            local t = c.workers[w[i]].task
            if t and t.helper then helpers = helpers + 1 end
        end
        assert(helpers <= defs.buildings.lumber.slots)
        for i = 1, 5 do C.cancelTask(c, w[i]) end
        C.drainEvents(c)
    end
    eq(lumber.built, true)
end)

test('chatting takes two: both get the task and the other is told', function()
    local c, w = colony(2)
    C.addSite(c, 'lumber', P(400, 0), 0, true)
    C.setClock(c, 19, 30)
    local a, b = c.workers[w[1]], c.workers[w[2]]
    b.task = { kind = 'stroll', downtime = true, steps = { { op = 'idle' } }, i = 1 }
    -- force the choice of chatting
    local free = defs.downtime.free
    defs.downtime.free = { chat = 1 }
    local t = C.nextTask(c, w[1])
    defs.downtime.free = free
    eq(t.kind, 'chat')
    eq(b.task.kind, 'chat')
    eq(t.steps[2].with, b.id)
    eq(b.task.steps[2].with, a.id)
    eq(t.steps[2].meet, b.task.steps[2].meet, 'the same spot')
    local told
    for _, e in ipairs(C.drainEvents(c)) do
        if e.kind == 'retask' and e.wid == b.id then told = true end
    end
    eq(told, true)
end)

test('prisoners do not get downtime', function()
    local c = colony(0)
    C.addSite(c, 'stockade', P(500, 0), 0, true)
    local p = C.addWorker(c, { name = 'Bandit', prisoner = true })
    C.setClock(c, 12, 30)
    eq(C.nextTask(c, p.id).steps[1].label, 'Locked up')
end)

test('storage: production stops when the storehouse is full, then resumes', function()
    local c, w = colony(1)
    local lumber = C.addSite(c, 'lumber', P(400, 0), 0, true)
    C.assign(c, w[1], lumber.id)
    C.setClock(c, 12, 30)
    local cap = C.capacity(c)
    eq(cap, defs.buildings.storehouse.storage)
    c.stock.wood = cap
    local t = C.nextTask(c, w[1])
    eq(t.kind, 'idle')
    assert(t.steps[1].label:find('No room'))
    C.simulateWorker(c, w[1], 1000)
    eq(c.stock.wood, cap, 'nothing gained while away either')
    C.addSite(c, 'warehouse', P(800, 0), 0, true)
    eq(C.capacity(c), cap + defs.buildings.warehouse.storage)
    eq(C.nextTask(c, w[1]).kind, 'gather')
end)

test('a full storehouse stops helpers too, but not direct supply runs', function()
    local c, w = colony(1)
    C.addSite(c, 'lumber', P(400, 0), 0, true)
    C.setClock(c, 12, 30)
    c.stock.wood = C.capacity(c)
    for _ = 1, 30 do
        local t = C.nextTask(c, w[1])
        assert(not t.helper, 'no helping when there is no room')
        C.cancelTask(c, w[1])
    end
end)

test('variants are remembered on the site', function()
    local c = colony(0)
    local s = C.addSite(c, 'house', P(800, 0), 0, false, { variant = 3 })
    eq(s.variant, 3)
    eq(defs.look('house', 3).model, defs.buildings.house.variants[3].model)
    eq(defs.look('house', 3).beds, defs.buildings.house.beds, 'everything else comes from the building')
    eq(defs.look('mine').model, defs.buildings.mine.model)
end)

test('rising and piles can show work in progress', function()
    local c = colony(0)
    local s = C.addSite(c, 'farm', P(800, 0), 0, false)
    s.needs.wood = 0
    eq(C.siteVisuals(c, s.id).rise, 0)
    near(C.siteVisuals(c, s.id, s.work / 4).rise, 0.25, 1e-9)
    eq(C.siteVisuals(c, s.id, s.work * 2).rise, 1, 'never past the end')
end)
