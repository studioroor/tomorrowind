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

local function furnished(c)
    local house = C.addSite(c, 'house', P(800, 0), 0, true)
    local function inside(kind, built)
        return C.addSite(c, kind, P(50000, 0), 0, built ~= false, { host = house.id })
    end
    return house, inside
end

test('at night, sleepers with a bed in the house are in it', function()
    local c, w = colony(3)
    local house, inside = furnished(c)
    local bed = inside('bed')
    C.setClock(c, 23.9, 30)
    c.hours = 100
    local r = C.roomRoster(c, house.id)
    local n, who = 0, nil
    for wid, e in pairs(r) do n = n + 1; who = e; eq(e.kind, 'sleep') end
    eq(n, 1, 'one bed, one sleeper')
    eq(who.site, bed.id)
end)

test('in free time people use the furniture, never over its limit', function()
    local c, w = colony(30)
    defs.rooms.maxPeople = 30
    local house, inside = furnished(c)
    local shelf = inside('bookshelf')
    C.setClock(c, 19.5, 30)
    local seen = false
    for hour = 1, 30 do
        c.hours = hour
        local users = 0
        for _, e in pairs(C.roomRoster(c, house.id)) do
            if e.kind == 'use' then
                users = users + 1
                eq(e.site, shelf.id)
                eq(e.prop, 'book')
                seen = true
            end
        end
        assert(users <= defs.buildings.bookshelf.interact.slots)
    end
    defs.rooms.maxPeople = 6
    assert(seen)
end)

test('the same people stay for the whole hour', function()
    local c = colony(12)
    local house, inside = furnished(c)
    inside('table')
    C.setClock(c, 19.5, 30)
    c.hours = 50.1
    local a = C.roomRoster(c, house.id)
    c.hours = 50.9
    local b = C.roomRoster(c, house.id)
    for wid in pairs(a) do assert(b[wid], 'still there') end
    for wid in pairs(b) do assert(a[wid], 'not new') end
end)

test('builders work on what has its materials, up to the crew limit', function()
    local c = colony(6)
    local house, inside = furnished(c)
    local chair = inside('chair', false)
    C.setClock(c, 12, 30)
    local n = 0
    for _ in pairs(C.roomRoster(c, house.id)) do n = n + 1 end
    eq(n, 0, 'waiting for materials')
    chair.needs.wood = 0
    n = 0
    for _, e in pairs(C.roomRoster(c, house.id)) do n = n + 1; eq(e.kind, 'build') end
    eq(n, defs.buildings.chair.maxBuilders)
end)

test('whoever was busy indoors when you came in is still there', function()
    local c, w = colony(1)
    local house, inside = furnished(c)
    local shelf = inside('bookshelf')
    C.setClock(c, 19.5, 30)
    local worker = c.workers[w[1]]
    worker.task = { kind = 'leisure', i = 1, steps = { { op = 'interact', at = shelf.id, label = 'Reading a book', prop = 'book' } } }
    local stay = { [w[1]] = C.roomStay(c, w[1], house.id) }
    eq(stay[w[1]].kind, 'use')
    C.cancelTask(c, w[1])
    eq(C.roomRoster(c, house.id, stay)[w[1]].label, 'Reading a book')
end)

test('nobody stays home in an attack, guards and prisoners never come', function()
    local c, w = colony(2)
    local house, inside = furnished(c)
    inside('bed')
    local post = C.addSite(c, 'guardpost', P(300, 0), 0, true)
    C.assign(c, w[1], post.id)
    C.setClock(c, 23.9, 30)
    local r = C.roomRoster(c, house.id)
    eq(r[w[1]], nil, 'on watch')
    assert(r[w[2]], 'in bed')
    C.addThreat(c, { name = 'Bandit' })
    eq(next(C.roomRoster(c, house.id)), nil)
end)

test('hover and ledger say what someone in a room is doing', function()
    local c, w = colony(1)
    c.workers[w[1]].roomStatus = 'Reading a book'
    eq(C.workerStatus(c, w[1]), 'Reading a book')
end)

test('about three meals a day', function()
    local c, w = colony(1)
    local worker = c.workers[w[1]]
    worker.sched.eatBelow = defs.hunger.eatBelow
    worker.offscreen = true
    c.stock.food = 100
    local hour, before = 7, c.stock.food
    for _ = 1, 24 * 4 do
        hour = (hour + 0.25) % 24
        C.setClock(c, hour, 30)
        C.tick(c, 0, 0.25)
    end
    local meals = (before - c.stock.food) / defs.hunger.mealFood
    assert(meals >= 2 and meals <= 4, 'meals in a day: ' .. meals)
end)

test('in the house you are watching, only the crew you see builds', function()
    local c, w = colony(3)
    local house, inside = furnished(c)
    local chair = inside('chair', false)
    chair.needs.wood = 0
    C.setClock(c, 12, 30)
    c.watchedHouse = house.id
    C.simulateWorker(c, w[1], 100)
    eq(chair.built, false)
    eq(chair.progress, 0)
    C.roomWork(c, chair.id, 2)
    eq(chair.progress, 2)
    c.watchedHouse = nil
    C.simulateWorker(c, w[1], 100)
    assert(chair.progress > 2, 'away, it goes on as usual')
end)

test('a house you can enter counts the beds in its room', function()
    local c = colony(0)
    local store = defs.buildings.storehouse.beds
    local house = C.addSite(c, 'house', P(800, 0), 0, true)
    eq(C.beds(c), store, 'an empty room has no beds')
    eq(C.siteStatus(c, house.id), '0 beds')
    local added = C.furnishHouse(c, house.id, { { kind = 'bed', pos = P(50000, 0), yaw = 0 } })
    eq(#added, 1)
    eq(C.beds(c), store + 1)
    eq(C.siteStatus(c, house.id), '1 bed')
    C.addSite(c, 'bedroll', P(50100, 0), 0, true, { host = house.id })
    eq(C.siteStatus(c, house.id), '2 beds')
    eq(#C.furnishHouse(c, house.id, { { kind = 'bed', pos = P(1, 0), yaw = 0 } }), 0, 'only once')
end)

test('a house without a door still has its own beds', function()
    local c = colony(0)
    local stilts = C.addSite(c, 'house', P(800, 0), 0, true, { variant = 11 })
    eq(C.beds(c), defs.buildings.storehouse.beds + defs.buildings.house.beds)
    eq(C.siteStatus(c, stilts.id), defs.buildings.house.beds .. ' beds')
end)

test('the beds a house came with give nothing back', function()
    local c = colony(0)
    local house = C.addSite(c, 'house', P(800, 0), 0, true)
    local bed = C.furnishHouse(c, house.id, { { kind = 'bed', pos = P(50000, 0), yaw = 0 } })[1]
    local before = c.stock.wood
    C.removeSite(c, bed.id)
    eq(c.stock.wood, before)
end)

test('someone with a bed in a house sleeps in it', function()
    local c, w = colony(1)
    local house = C.addSite(c, 'house', P(800, 0), 0, true)
    local bed = C.furnishHouse(c, house.id, { { kind = 'bed', pos = P(50000, 0), yaw = 0 } })[1]
    C.setClock(c, 23, 30)
    eq(C.nextTask(c, w[1]).site, bed.id)
end)
