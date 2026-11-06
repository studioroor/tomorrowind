local T = require('scripts.tomorrowind.core.terrain')
local C = require('scripts.tomorrowind.core.colony')
local defs = require('scripts.tomorrowind.defs')

test('flat ground needs no foundation', function()
    local r = T.analyze({ 100, 100, 102, 99 })
    eq(r.ok, true)
    eq(r.depth, 0)
    eq(r.wood, 0)
    eq(r.work, 0)
end)

test('a moderate slope is leveled with a foundation', function()
    local r = T.analyze({ 0 + 100, 300 + 100 }) -- 300 spread
    eq(r.ok, true)
    near(r.level, 100 + 300 * defs.slope.levelAt)
    near(r.depth, 300 * defs.slope.levelAt - defs.slope.hiddenDepth)
    eq(r.wood, math.ceil(r.depth * defs.slope.woodPerUnit))
    assert(r.work > 0)
end)

test('a cliff is too steep', function()
    local r = T.analyze({ 100, 900 })
    eq(r.ok, false)
    eq(r.reason, 'too steep')
end)

test('water is refused', function()
    local r = T.analyze({ -200, 10 })
    eq(r.ok, false)
    eq(r.reason, 'under water')
end)

test('sample points cover centre and two rings', function()
    local pts = T.samplePoints(100)
    eq(#pts, 17)
    near(math.sqrt(pts[17][1] ^ 2 + pts[17][2] ^ 2), 95, 1e-6)
end)

test('foundation adds timber and leveling work to a site', function()
    local c = C.new()
    C.found(c, { x = 0, y = 0, z = 0 })
    local w = C.addWorker(c, { name = 'A' }).id
    c.stock.wood = 100
    local farm = C.addSite(c, 'farm', { x = 500, y = 0, z = 0 }, 0, false, { foundation = { wood = 4, work = 20 } })
    eq(farm.needs.wood, defs.buildings.farm.cost.wood + 4)
    eq(farm.work, defs.buildings.farm.work + 20)
    -- haul everything, then the first build trip is leveling
    local guard = 0
    while not C.materialsComplete(c, farm.id) do
        guard = guard + 1; assert(guard < 20)
        C.nextTask(c, w)
        local st = C.currentStep(c, w)
        while st do st = C.completeStep(c, w) end
    end
    eq(C.siteStatus(c, farm.id), 'Leveling the ground (0%)')
    local t = C.nextTask(c, w)
    assert(t.steps[2].label:find('Leveling'), t.steps[2].label)
    -- refund includes the foundation timber
    C.cancelTask(c, w)
    C.removeSite(c, farm.id)
    eq(c.stock.wood, 100)
end)

test('tall buildings may sink deeper into a slope', function()
    local spread = 500 -- burial = 500 * (1 - levelAt) = 300 > 220
    eq(T.analyze({ 100, 100 + spread }).ok, false)
    eq(T.analyze({ 100, 100 + spread }, 1000).ok, true) -- 0.35 * 1000 = 350
end)
