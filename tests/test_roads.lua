local R = require('scripts.tomorrowind.core.roads')

local CFG = { minLength = 300, maxLength = 12000 }
local CENTER = { x = 0, y = 0 }

test('the first building gets a road to the edge of the storehouse plot', function()
    local s = R.connect({}, CENTER, 350, { x = 2000, y = 0 }, 500, CFG)
    near(s.a.x, 1500, 1e-6, 'starts at the edge of its own plot')
    near(s.a.y, 0, 1e-6)
    near(s.b.x, 350, 1e-6, 'ends at the edge of the storehouse plot')
    near(s.b.y, 0, 1e-6)
end)

test('a later building joins the nearest road instead', function()
    local roads = { { a = { x = 1500, y = 0 }, b = { x = 350, y = 0 } } }
    -- 1500 from the road, 1571 from the storehouse plot
    local s = R.connect(roads, CENTER, 350, { x = 1200, y = 1500 }, 400, CFG)
    near(s.b.x, 1200, 1e-6, 'meets the road square on')
    near(s.b.y, 0, 1e-6)
    near(s.a.y, 1100, 1e-6)
end)

test('the centre wins when it is nearer than any road', function()
    local roads = { { a = { x = 5000, y = 0 }, b = { x = 4000, y = 0 } } }
    local s = R.connect(roads, CENTER, 350, { x = 0, y = -2000 }, 400, CFG)
    near(s.b.x, 0, 1e-6)
    near(s.b.y, -350, 1e-6)
end)

test('a plot that already touches a road gets none', function()
    local roads = { { a = { x = -3000, y = 0 }, b = { x = 3000, y = 0 } } }
    eq(R.connect(roads, CENTER, 350, { x = 1000, y = 500 }, 400, CFG), nil)
end)

test('a plot next to the storehouse gets none', function()
    eq(R.connect({}, CENTER, 350, { x = 900, y = 0 }, 400, CFG), nil)
end)

test('a building far from town gets none', function()
    eq(R.connect({}, CENTER, 350, { x = 20000, y = 0 }, 400, CFG), nil)
end)

test('closest point on a segment is clamped to its ends', function()
    local q, d = R.closest({ x = -5, y = 3 }, { x = 0, y = 0 }, { x = 10, y = 0 })
    eq(q.x, 0)
    eq(q.y, 0)
    near(d, math.sqrt(34), 1e-9)
end)
