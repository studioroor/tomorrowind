-- Crops: farmers harvest ripe plots, plant bare ones and tend the growing
-- ones; crops grow on their own, faster when tended.
local C = require('scripts.tomorrowind.core.colony')
local defs = require('scripts.tomorrowind.defs')

local function P(x, y) return { x = x, y = y, z = 0 } end

local function colony()
    local c = C.new()
    C.found(c, P(0, 0))
    c.stock.food = 50
    C.drainEvents(c)
    return c
end

local function farmer(c, farm)
    local w = C.addWorker(c, { name = 'F' })
    C.assign(c, w.id, farm.id)
    C.setClock(c, 10, 30)
    return w
end

-- Every plot of the farm set to `grow` (nil: bare).
local function field(farm, grow)
    for i = 1, C.plotCount() do C.plotsOf(farm)[i] = { grow = grow } end
end

local function run(c, wid)
    while C.currentStep(c, wid) do C.completeStep(c, wid) end
end

local function workStep(task)
    for _, st in ipairs(task.steps) do
        if st.op == 'work' then return st end
    end
end

test('the field: plots in a grid around a free middle', function()
    local seen = {}
    for i = 1, C.plotCount() do
        local x, y = C.plotOffset(i)
        assert(not (x == 0 and y == 0), 'the middle stays free')
        local key = x .. ',' .. y
        assert(not seen[key], 'every plot its own spot')
        seen[key] = true
    end
    eq(C.plotCount(), defs.crops.grid * defs.crops.grid - 1)
end)

test('a new farm has a mixed field: some of it ripe already', function()
    local c = colony()
    local farm = C.addSite(c, 'farm', P(800, 0), 0, true)
    local n = C.farmPlots(c, farm.id)
    assert(n.ripe >= 2, 'ripe: ' .. n.ripe)
    assert(n.growing >= 10, 'growing: ' .. n.growing)
    eq(n.ripe + n.growing + n.bare, C.plotCount())
end)

test('a farmer harvests a ripe plot and carries the food home', function()
    local c = colony()
    local farm = C.addSite(c, 'farm', P(800, 0), 0, true)
    field(farm, 0.5)
    C.plotsOf(farm)[7].grow = 1
    local w = farmer(c, farm)
    local task = C.nextTask(c, w.id)
    eq(task.plot, 7, 'goes for the ripe plot')
    eq(task.steps[1].plot, 7, 'walks to it')
    local st = workStep(task)
    eq(st.effect, 'harvest')
    eq(st.plot, 7)
    local food = c.stock.food
    run(c, w.id)
    eq(c.stock.food, food + defs.crops.yield, 'the crop goes to the storehouse')
    eq(C.plotsOf(farm)[7].grow, nil, 'and the plot is bare')
    local changed = false
    for _, e in ipairs(C.drainEvents(c)) do
        if e.kind == 'plot' and e.site == farm.id and e.plot == 7 then changed = true end
    end
    assert(changed, 'the field is told')
end)

test('with nothing ripe, a farmer plants a bare plot', function()
    local c = colony()
    local farm = C.addSite(c, 'farm', P(800, 0), 0, true)
    field(farm, 0.5)
    C.plotsOf(farm)[3].grow = nil
    local w = farmer(c, farm)
    local task = C.nextTask(c, w.id)
    eq(workStep(task).effect, 'plant')
    eq(task.plot, 3)
    run(c, w.id)
    eq(C.plotsOf(farm)[3].grow, defs.crops.sprout, 'a sprout now')
end)

test('with nothing to harvest or plant, farmers tend: the plot left alone longest', function()
    local c = colony()
    local farm = C.addSite(c, 'farm', P(800, 0), 0, true)
    field(farm, 0.5)
    for i = 1, C.plotCount() do C.plotsOf(farm)[i].tendedAt = 10 end
    C.plotsOf(farm)[9].tendedAt = 2
    local w = farmer(c, farm)
    local task = C.nextTask(c, w.id)
    eq(workStep(task).effect, 'tend')
    eq(task.plot, 9)
    run(c, w.id)
    eq(C.plotsOf(farm)[9].grow, 0.5 + defs.crops.tendGrow, 'it grows a little')
    eq(C.plotsOf(farm)[9].tendedAt, c.hours)
end)

test('two farmers never work the same plot', function()
    local c = colony()
    local farm = C.addSite(c, 'farm', P(800, 0), 0, true)
    field(farm, 0.5)
    C.plotsOf(farm)[4].grow = 1
    local a, b = farmer(c, farm), farmer(c, farm)
    local ta = C.nextTask(c, a.id)
    local tb = C.nextTask(c, b.id)
    eq(ta.plot, 4)
    assert(tb.plot ~= 4, 'the other one finds something else')
    eq(workStep(tb).effect, 'tend')
end)

test('crops grow on their own and ripen', function()
    local c = colony()
    local farm = C.addSite(c, 'farm', P(800, 0), 0, true)
    field(farm, nil)
    C.plotsOf(farm)[1].grow = defs.crops.sprout
    C.tick(c, 0, defs.crops.growHours / 2)
    local g = C.plotsOf(farm)[1].grow
    assert(g > 0.5 and g < 1, 'half way: ' .. g)
    eq(C.plotsOf(farm)[2].grow, nil, 'bare plots stay bare')
    C.tick(c, 0, defs.crops.growHours)
    eq(C.plotsOf(farm)[1].grow, 1, 'ripe')
    eq(C.farmPlots(c, farm.id).ripe, 1)
end)

test('a kwama nest lays its eggs again: nobody plants there', function()
    local c = colony()
    local farm = C.addSite(c, 'farm', P(800, 0), 0, true, { variant = 6 })
    assert(defs.look('farm', 6).selfSown, 'the kwama nest')
    field(farm, 0.5)
    C.plotsOf(farm)[5].grow = nil
    local w = farmer(c, farm)
    local task = C.nextTask(c, w.id)
    assert(workStep(task).effect ~= 'plant', 'no planting')
    C.cancelTask(c, w.id)
    C.tick(c, 0, 1)
    assert(C.plotsOf(farm)[5].grow and C.plotsOf(farm)[5].grow > 0, 'the plot fills up by itself')
end)

test('a full storehouse: no harvest, but the field is still kept', function()
    local c = colony()
    local farm = C.addSite(c, 'farm', P(800, 0), 0, true)
    field(farm, 0.5)
    C.plotsOf(farm)[1].grow = 1
    C.plotsOf(farm)[2].grow = nil
    c.stock.food = C.capacity(c)
    local w = farmer(c, farm)
    local task = C.nextTask(c, w.id)
    eq(workStep(task).effect, 'plant', 'plants instead')
    eq(farm.stalled, 'no room in the storehouse')
    assert(C.siteStatus(c, farm.id):find('no room'), 'and says so')
end)

test('the farm says how its field is doing', function()
    local c = colony()
    local farm = C.addSite(c, 'farm', P(800, 0), 0, true)
    field(farm, 0.5)
    C.plotsOf(farm)[1].grow = 1
    C.plotsOf(farm)[2].grow = nil
    local txt = C.siteStatus(c, farm.id)
    assert(txt:find('crops: 1 ripe, 22 growing, 1 bare', 1, true), txt)
end)

test('away from the colony, farmers harvest and replant', function()
    local c = colony()
    local farm = C.addSite(c, 'farm', P(800, 0), 0, true)
    field(farm, 0.5)
    C.plotsOf(farm)[1].grow = 1
    C.plotsOf(farm)[2].grow = nil
    local w = farmer(c, farm)
    w.offscreen = true
    local food = c.stock.food
    C.simulateWorker(c, w.id, defs.buildings.farm.cycle + 2 * C.tripSeconds(c, farm.id) + 0.1)
    eq(c.stock.food, food + defs.crops.yield, 'harvested')
    eq(C.plotsOf(farm)[1].grow, defs.crops.sprout, 'and planted it again')
    eq(C.plotsOf(farm)[2].grow, nil, 'one planting a round')
end)

test('a farm with nothing ripe has no food to hand out', function()
    local c = colony()
    local farm = C.addSite(c, 'farm', P(800, 0), 0, true)
    field(farm, 0.5)
    eq(C.producerOf(c, 'food'), nil)
    C.plotsOf(farm)[3].grow = 1
    eq(C.producerOf(c, 'food'), farm)
end)
