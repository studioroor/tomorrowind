local C = require('scripts.tomorrowind.core.colony')
local defs = require('scripts.tomorrowind.defs')

local function P(x, y) return { x = x, y = y, z = 0 } end

local function colony(n)
    local c = C.new()
    C.found(c, P(0, 0))
    local ids = {}
    for i = 1, n do ids[i] = C.addWorker(c, { name = 'W' .. i }).id end
    C.drainEvents(c)
    C.setClock(c, 12, 30)
    return c, ids
end

local function trader(c, wid)
    local market = C.addSite(c, 'market', P(500, 0), 0, true)
    C.assign(c, wid, market.id)
    return market
end

local function run(c, wid)
    local st = C.currentStep(c, wid)
    while st do st = C.completeStep(c, wid) end
end

local function hasEvent(events, kind)
    for _, e in ipairs(events) do if e.kind == kind then return e end end
end

test('a trader carries surplus to the stall and sells it', function()
    local c, w = colony(1)
    trader(c, w[1])
    c.stock.wood = defs.trade.keep.wood + 20
    c.stock.food, c.stock.ore, c.stock.ingot = 0, 0, 0
    local t = C.nextTask(c, w[1])
    eq(t.kind, 'trade')
    local before = c.stock.wood
    run(c, w[1])
    eq(c.stock.wood, before - defs.carryAmount)
    eq(c.reserved.wood, 0)
    assert(C.gold(c) > 0 and C.gold(c) <= defs.carryAmount * defs.trade.prices.wood)
end)

test('nothing below the keep level is sold', function()
    local c, w = colony(1)
    local market = trader(c, w[1])
    for _, r in ipairs(defs.resourceOrder) do c.stock[r] = defs.trade.keep[r] end
    local t = C.nextTask(c, w[1])
    eq(t.kind, 'idle')
    assert(market.stalled:find('keep'))
    C.setKeep(c, 'ore', 0)
    eq(C.nextTask(c, w[1]).kind, 'trade')
end)

test('the most valuable surplus goes first', function()
    local c, w = colony(1)
    trader(c, w[1])
    c.stock.wood, c.stock.ingot = 200, defs.trade.keep.ingot + 5
    local t = C.nextTask(c, w[1])
    eq(t.holds.res, 'ingot')
end)

test('selling lowers the price, down to a floor, and it recovers', function()
    local c, w = colony(1)
    trader(c, w[1])
    c.stock.ingot = 1000
    local start = C.sellPrice(c, 'ingot')
    for _ = 1, 3 do C.nextTask(c, w[1]); run(c, w[1]) end
    local low = C.sellPrice(c, 'ingot')
    assert(low < start)
    for _ = 1, 100 do C.nextTask(c, w[1]); run(c, w[1]) end
    near(C.sellPrice(c, 'ingot'), defs.trade.prices.ingot * defs.trade.minFactor, 1e-6)
    C.tick(c, 0, 100)
    assert(C.sellPrice(c, 'ingot') > defs.trade.prices.ingot * 0.8, 'recovers within days')
end)

test('cancelling a load puts it back and earns nothing', function()
    local c, w = colony(1)
    trader(c, w[1])
    c.stock.wood = 100
    local before = c.stock.wood
    C.nextTask(c, w[1])
    C.completeStep(c, w[1])
    C.completeStep(c, w[1])
    C.cancelTask(c, w[1])
    eq(c.stock.wood, before)
    eq(c.reserved.wood, 0)
    eq(C.gold(c), 0)
end)

test('caravans come to a market, pay better, then leave', function()
    local c, w = colony(1)
    C.tick(c, 0, defs.trade.caravan.everyHours + 1)
    eq(C.caravanHere(c), false, 'no market: no caravan')
    C.drainEvents(c)
    trader(c, w[1])
    local price = C.sellPrice(c, 'wood')
    C.tick(c, 0, defs.trade.caravan.everyHours)
    eq(C.caravanHere(c), true)
    assert(hasEvent(C.drainEvents(c), 'caravan_arrived'))
    near(C.sellPrice(c, 'wood'), price * defs.trade.caravan.sellBonus, 1e-6)
    C.tick(c, 0, defs.trade.caravan.stayHours)
    eq(C.caravanHere(c), false)
    assert(hasEvent(C.drainEvents(c), 'caravan_left'))
end)

test('a caravan fills the buy list as far as gold and its supply go', function()
    local c, w = colony(1)
    trader(c, w[1])
    c.stock.ingot = 0
    c.gold = C.buyPrice('ingot') * 10
    C.setWant(c, 'ingot', 50)
    C.tick(c, 0, defs.trade.caravan.everyHours)
    eq(c.stock.ingot, 10, 'as much as the gold pays for')
    near(C.gold(c), 0, 1e-6)
    c.gold = 100000
    C.tick(c, 0, 1)
    eq(c.stock.ingot, defs.trade.caravan.supply, 'then what it has')
    C.tick(c, 0, 1)
    eq(c.stock.ingot, defs.trade.caravan.supply)
end)

test('a caravan does not buy past the storage limit', function()
    local c, w = colony(1)
    trader(c, w[1])
    c.gold = 100000
    c.stock.ore = C.capacity(c) - 5
    C.setWant(c, 'ore', C.capacity(c) * 2)
    C.tick(c, 0, defs.trade.caravan.everyHours)
    eq(c.stock.ore, C.capacity(c))
end)

test('removing the market sends the caravan away', function()
    local c, w = colony(1)
    local market = trader(c, w[1])
    C.tick(c, 0, defs.trade.caravan.everyHours)
    C.drainEvents(c)
    C.removeSite(c, market.id)
    C.tick(c, 0, 0.1)
    eq(C.caravanHere(c), false)
    assert(hasEvent(C.drainEvents(c), 'caravan_left'))
end)

test('traders keep selling while the player is away, and stop at the keep level', function()
    local c, w = colony(1)
    trader(c, w[1])
    c.stock.wood = defs.trade.keep.wood + 30
    c.stock.food, c.stock.ore, c.stock.ingot = 0, 0, 0
    C.simulateWorker(c, w[1], 5000)
    eq(c.stock.wood, defs.trade.keep.wood)
    assert(C.gold(c) > 0)
end)

test('gold moves between the treasury and the player', function()
    local c = colony(0)
    c.gold = 120.6
    eq(C.withdraw(c, 100), 100)
    eq(C.withdraw(c, 100), 20, 'only what is there, in whole coins')
    C.deposit(c, 50)
    near(C.gold(c), 50.6, 1e-6)
end)

test('older colonies get trade settings when they first need them', function()
    local c = colony(0)
    c.trade, c.gold = nil, nil
    eq(C.gold(c), 0)
    eq(C.caravanHere(c), false)
    eq(C.tradeOf(c).keep.wood, defs.trade.keep.wood)
end)

test('furniture indoors goes with its house and refunds its materials', function()
    local c = colony(0)
    local house = C.addSite(c, 'house', P(800, 0), 0, true)
    local chair = C.addSite(c, 'chair', P(50000, 0), 0, true, { host = house.id })
    local before = c.stock.wood
    C.removeSite(c, house.id)
    eq(c.sites[chair.id], nil)
    eq(c.stock.wood, before + defs.buildings.chair.cost.wood)
end)

test('trips to furniture indoors are measured to its house', function()
    local c = colony(0)
    local house = C.addSite(c, 'house', P(800, 0), 0, true)
    local chair = C.addSite(c, 'chair', P(500000, 0), 0, false, { host = house.id })
    eq(C.tripSeconds(c, chair.id), C.tripSeconds(c, house.id))
end)

test('each house gets its own room, and keeps it', function()
    local c = colony(0)
    local a = C.addSite(c, 'house', P(800, 0), 0, true)
    local b = C.addSite(c, 'house', P(1800, 0), 0, true)
    local ra, rb = C.roomOf(c, a.id), C.roomOf(c, b.id)
    assert(ra ~= rb)
    eq(C.roomOf(c, a.id), ra)
end)
