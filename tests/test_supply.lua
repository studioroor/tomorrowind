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

local function run(c, wid)
    local ops = {}
    local st = C.currentStep(c, wid)
    while st do
        ops[#ops + 1] = st.op
        st = C.completeStep(c, wid)
    end
    return table.concat(ops, ',')
end

test('short of timber: a laborer chops it and carries it straight to the site', function()
    local c, w = colony(1)
    c.stock.wood = 0
    local lumber = C.addSite(c, 'lumber', P(400, 0), 0, true)
    local farm = C.addSite(c, 'farm', P(800, 0), 0, false) -- needs 6 wood
    local t = C.nextTask(c, w[1])
    eq(t.kind, 'gather')
    eq(t.helper, true)
    eq(t.site, lumber.id)
    eq(t.steps[3].to, farm.id, 'goes to the site, not the storehouse')
    eq(run(c, w[1]), 'goto,work,goto,supply')
    eq(farm.needs.wood, 6 - defs.buildings.lumber.output.wood)
    eq(c.stock.wood, 0)
end)

test('supply runs finish a site from nothing', function()
    local c, w = colony(2)
    c.stock.wood = 0
    C.addSite(c, 'lumber', P(400, 0), 0, true)
    local farm = C.addSite(c, 'farm', P(800, 0), 0, false)
    local guard = 0
    while not farm.built do
        guard = guard + 1
        assert(guard < 60, 'never finished')
        for _, id in ipairs(w) do
            C.nextTask(c, id)
            run(c, id)
        end
    end
    eq(c.reserved.wood, 0)
    eq(farm.incoming.wood or 0, 0)
end)

test('two helpers never overshoot what a site needs', function()
    local c, w = colony(2)
    c.stock.wood = 0
    C.addSite(c, 'lumber', P(400, 0), 0, true)
    local site = C.addSite(c, 'farm', P(800, 0), 0, false)
    site.needs.wood = 3 -- only 3 left
    local t1 = C.nextTask(c, w[1])
    local t2 = C.nextTask(c, w[2])
    eq(t1.incoming.amount, 2)
    eq(t2.incoming.amount, 1)
    run(c, w[1]); run(c, w[2])
    eq(site.needs.wood, 0)
    eq(c.stock.wood, 1, 'the extra log goes to the stockpile')
end)

test('short of ingots with ore in stock: smelt and deliver', function()
    local c, w = colony(1)
    c.stock.wood, c.stock.ore, c.stock.ingot = 100, 4, 0
    local smelter = C.addSite(c, 'smelter', P(400, 0), 0, true)
    local house = C.addSite(c, 'house', P(1500, 0), 0, false)
    house.needs.wood = 0 -- only ingots missing
    local t = C.nextTask(c, w[1])
    eq(t.kind, 'process')
    eq(t.site, smelter.id)
    eq(run(c, w[1]), 'goto,take,goto,work,goto,supply')
    eq(house.needs.ingot, defs.buildings.house.cost.ingot - 1)
    eq(c.stock.ore, 2)
end)

test('short of ingots and ore: mine ore for the smelter first', function()
    local c, w = colony(1)
    c.stock.ore, c.stock.ingot = 0, 0
    C.addSite(c, 'smelter', P(400, 0), 0, true)
    local mine = C.addSite(c, 'mine', P(600, 0), 0, true)
    local house = C.addSite(c, 'house', P(1500, 0), 0, false)
    house.needs.wood = 0
    local t = C.nextTask(c, w[1])
    eq(t.site, mine.id)
    eq(run(c, w[1]), 'goto,work,goto,store')
    eq(c.stock.ore, defs.buildings.mine.output.ore)
end)

test('no producer: finds something else to do, and the site says what it needs', function()
    local c, w = colony(1)
    c.stock.wood = 0
    local farm = C.addSite(c, 'farm', P(800, 0), 0, false)
    eq(C.nextTask(c, w[1]).downtime, true)
    eq(C.siteStatus(c, farm.id), "Timber 0/6 - needs a Woodcutter's Camp")
end)

test('progress reports materials and build percentage', function()
    local c, w = colony(1)
    c.stock.wood = 100
    local farm = C.addSite(c, 'farm', P(800, 0), 0, false)
    local p = C.siteProgress(c, farm.id)
    eq(p.phase, 'materials')
    eq(p.materials[1].have, 0)
    eq(p.materials[1].need, 6)
    farm.needs.wood = 0
    farm.progress = defs.buildings.farm.work / 2
    p = C.siteProgress(c, farm.id)
    eq(p.phase, 'building')
    eq(p.percent, 50)
    eq(C.siteStatus(c, farm.id), 'Timber 6/6 - 50% built')
end)

test('cancelling a supply run releases the promised delivery', function()
    local c, w = colony(1)
    c.stock.wood = 0
    C.addSite(c, 'lumber', P(400, 0), 0, true)
    local farm = C.addSite(c, 'farm', P(800, 0), 0, false)
    C.nextTask(c, w[1])
    eq(farm.incoming.wood, 2)
    C.cancelTask(c, w[1])
    eq(farm.incoming.wood, 0)
end)

test('off-screen laborers also make missing materials', function()
    local c, w = colony(1)
    c.stock.wood = 0
    C.addSite(c, 'lumber', P(0, 0), 0, true)
    local farm = C.addSite(c, 'farm', P(0, 0), 0, false)
    for _ = 1, 40 do C.simulateWorker(c, w[1], 10) end
    eq(farm.built, true)
end)

test('site visuals: delivered materials pile up, then get used up', function()
    local c, w = colony(1)
    c.stock.wood = 30
    local farm = C.addSite(c, 'farm', P(800, 0), 0, false) -- 6 wood, 15 work
    local v = C.siteVisuals(c, farm.id)
    eq(v.piles.wood, 0, 'nothing delivered yet')
    eq(v.pilings, 1, 'flat site: no pilings to drive')
    farm.needs.wood = 2
    eq(C.siteVisuals(c, farm.id).piles.wood, 4)
    farm.needs.wood = 0
    farm.progress = farm.work / 2
    eq(C.siteVisuals(c, farm.id).piles.wood, 3, 'half built: half the timber used')
    farm.progress = farm.work
    eq(C.siteVisuals(c, farm.id).piles.wood, 0)
    C.finishSite(c, farm.id)
    eq(C.siteVisuals(c, farm.id), nil)
end)

test('site visuals: pilings go in while leveling', function()
    local c = colony(0)
    local s = C.addSite(c, 'house', P(800, 0), 0, false, { foundation = { wood = 8, work = 20 } })
    eq(C.siteVisuals(c, s.id).pilings, 0)
    s.progress = 10
    eq(C.siteVisuals(c, s.id).pilings, 0.5)
    s.progress = 30
    eq(C.siteVisuals(c, s.id).pilings, 1)
end)

test('site visuals: the building rises once materials and foundation are ready', function()
    local c = colony(0)
    local s = C.addSite(c, 'house', P(800, 0), 0, false, { foundation = { wood = 8, work = 20 } })
    eq(C.siteVisuals(c, s.id).rise, nil, 'no materials yet')
    for res in pairs(s.needs) do s.needs[res] = 0 end
    eq(C.siteVisuals(c, s.id).rise, nil, 'still leveling')
    s.progress = 20
    eq(C.siteVisuals(c, s.id).rise, 0)
    s.progress = 20 + (s.work - 20) / 2
    eq(C.siteVisuals(c, s.id).rise, 0.5)
    s.progress = s.work
    eq(C.siteVisuals(c, s.id).rise, 1)
end)
