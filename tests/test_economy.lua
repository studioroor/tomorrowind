-- The balance of the colony's economy, worked out with the off-screen
-- simulation over whole days. These numbers are what README's economy section
-- describes: change defs and they say whether it still holds.
local C = require('scripts.tomorrowind.core.colony')
local defs = require('scripts.tomorrowind.defs')

local function P(x, y) return { x = x, y = y, z = 0 } end

-- A colony with `farmers` on farms 800 units from the storehouse and `others`
-- with nothing to do, run for `days` in steps of 10 real seconds.
local function run(jobs, others, days, stock)
    local c = C.new()
    C.found(c, P(0, 0))
    C.drainEvents(c)
    for k, v in pairs(stock or {}) do c.stock[k] = v end
    local ids = {}
    local function worker(target)
        local w = C.addWorker(c, { name = 'W' .. #ids })
        w.offscreen = true
        ids[#ids + 1] = w.id
        if target then C.assign(c, w.id, target) end
    end
    for kind, n in pairs(jobs) do
        local remaining = n
        while remaining > 0 do
            local s = C.addSite(c, kind, P(800, 0), 0, true)
            local here = math.min(remaining, defs.buildings[kind].slots)
            for _ = 1, here do worker(s.id) end
            remaining = remaining - here
        end
    end
    for _ = 1, others do worker(nil) end
    c.stock.food = c.stock.food + 0
    local hour, step = 12, 10
    local scale = 30
    local startStock = {}
    for _, r in ipairs(defs.resourceOrder) do startStock[r] = c.stock[r] end
    for _ = 1, days * 24 * 3600 / scale / step do
        hour = (hour + step * scale / 3600) % 24
        C.setClock(c, hour, scale)
        C.tick(c, step, step * scale / 3600)
        for _, id in ipairs(ids) do C.simulateWorker(c, id, step) end
        C.drainEvents(c)
    end
    local gained = {}
    for _, r in ipairs(defs.resourceOrder) do gained[r] = c.stock[r] - startStock[r] end
    return c, gained, ids
end

local function hungry(c, ids)
    local n = 0
    for _, id in ipairs(ids) do
        if c.workers[id].fed < defs.hunger.hungryBelow then n = n + 1 end
    end
    return n
end

test('one farmer feeds a handful of settlers, not a whole town', function()
    local c, gained, ids = run({ farm = 1 }, 3, 3, { food = 30 })
    eq(hungry(c, ids), 0, 'four settlers on one farmer stay fed')
    assert(gained.food > -30, 'and the stock holds up: ' .. gained.food)
    c, gained, ids = run({ farm = 1 }, 11, 3, { food = 30 })
    assert(c.stock.food < defs.hunger.mealFood, 'twelve settlers on one farmer run out')
    assert(hungry(c, ids) > 0, 'and go hungry')
end)

test('a woodcutter takes about a working day for a house worth of timber', function()
    local _, gained = run({ lumber = 1 }, 0, 1, { food = 100 })
    local house = defs.buildings.house.cost.wood
    assert(gained.wood >= house * 0.75 and gained.wood <= house * 2, 'timber per day: ' .. gained.wood)
end)

test('ingots are the expensive material: miners keep a smelter busy', function()
    local _, gained = run({ mine = 2, smelter = 1 }, 0, 1, { food = 100 })
    assert(gained.ingot >= 8 and gained.ingot <= 30, 'ingots per day: ' .. gained.ingot)
    assert(gained.ingot >= defs.buildings.house.cost.ingot, 'a house worth of ingots in a day')
end)

test('a growing colony: newcomers come more slowly the bigger it is', function()
    local function hoursFor(pop) return defs.arrival.everyHours + defs.arrival.perSettler * pop end
    assert(hoursFor(20) > hoursFor(4) * 2, 'much slower at twenty')
    assert(defs.arrival.minFood + defs.arrival.foodPerSettler * 20 > defs.buildings.storehouse.storage / 3,
        'and they need a real food surplus')
end)

test('a bed costs about the same however you get it', function()
    local function worth(cost) return (cost.wood or 0) + 5 * (cost.ingot or 0) + (cost.ore or 0) end
    local house = worth(defs.buildings.house.cost) / defs.buildings.house.beds
    local bed = worth(defs.buildings.bed.cost) / defs.buildings.bed.beds
    local roll = worth(defs.buildings.bedroll.cost) / defs.buildings.bedroll.beds
    assert(bed >= house * 0.75 and bed <= house * 1.25, string.format('bed %.0f vs house %.0f', bed, house))
    assert(roll < bed and roll >= house * 0.3, string.format('bedroll %.0f', roll))
end)

test('a market is worth having, without making everything else pointless', function()
    -- two woodcutters and a trader: about what a house costs per working day
    local c = C.new()
    C.found(c, P(0, 0))
    C.drainEvents(c)
    c.stock.food = 100
    c.stock.wood = 150
    C.setKeep(c, 'food', 200)
    C.setKeep(c, 'wood', 0)
    local ids = {}
    local market = C.addSite(c, 'market', P(500, 0), 0, true)
    local w = C.addWorker(c, { name = 'T' })
    w.offscreen = true
    C.assign(c, w.id, market.id)
    ids[1] = w.id
    local hour = 12
    for _ = 1, 24 * 3600 / 30 / 10 do
        hour = (hour + 10 * 30 / 3600) % 24
        C.setClock(c, hour, 30)
        C.tick(c, 10, 10 * 30 / 3600)
        C.simulateWorker(c, ids[1], 10)
        C.drainEvents(c)
    end
    local gold = C.gold(c)
    assert(gold > 100 and gold < 450, 'gold from 150 Timber in a day: ' .. gold)
end)

test('dumping ingots stops paying: the price sinks', function()
    local c = C.new()
    C.found(c, P(0, 0))
    C.drainEvents(c)
    local market = C.addSite(c, 'market', P(500, 0), 0, true)
    local w = C.addWorker(c, { name = 'T' })
    w.offscreen = true
    C.assign(c, w.id, market.id)
    c.stock.ingot = 150
    C.setKeep(c, 'ingot', 0)
    local hour = 12
    for _ = 1, 24 * 3600 / 30 / 10 do
        hour = (hour + 10 * 30 / 3600) % 24
        C.setClock(c, hour, 30)
        C.tick(c, 10, 10 * 30 / 3600)
        C.simulateWorker(c, w.id, 10)
        C.drainEvents(c)
    end
    local gold = C.gold(c)
    assert(gold < 150 * defs.trade.prices.ingot * 0.5, 'far below list price: ' .. gold)
end)
