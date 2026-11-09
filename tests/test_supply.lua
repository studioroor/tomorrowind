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
    local farm = C.addSite(c, 'farm', P(800, 0), 0, false)
    local need = defs.buildings.farm.cost.wood
    local t = C.nextTask(c, w[1])
    eq(t.kind, 'gather')
    eq(t.helper, true)
    eq(t.site, lumber.id)
    eq(t.steps[3].to, farm.id, 'goes to the site, not the storehouse')
    eq(run(c, w[1]), 'goto,work,goto,supply')
    eq(farm.needs.wood, need - defs.buildings.lumber.output.wood)
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
    eq(C.siteStatus(c, farm.id), string.format("Timber 0/%d - needs a Woodcutter's Camp", defs.buildings.farm.cost.wood))
end)

test('progress reports materials and build percentage', function()
    local c, w = colony(1)
    c.stock.wood = 100
    local farm = C.addSite(c, 'farm', P(800, 0), 0, false)
    local p = C.siteProgress(c, farm.id)
    eq(p.phase, 'materials')
    eq(p.materials[1].have, 0)
    local need = defs.buildings.farm.cost.wood
    eq(p.materials[1].need, need)
    farm.needs.wood = 0
    farm.progress = defs.buildings.farm.work / 2
    p = C.siteProgress(c, farm.id)
    eq(p.phase, 'building')
    eq(p.percent, 50)
    eq(C.siteStatus(c, farm.id), string.format('Timber %d/%d - 50%% built', need, need))
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
    local farm = C.addSite(c, 'farm', P(800, 0), 0, false)
    farm.cost.wood, farm.needs.wood = 6, 6
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

local function salvagePile(c)
    for _, sid in ipairs(c.siteOrder) do if c.sites[sid].goods then return c.sites[sid] end end
end

test('salvage is carried back by laborers, then the pile is gone', function()
    local c, w = colony(2)
    local smelter = C.addSite(c, 'smelter', P(600, 0), 0, true)
    local events = C.drainEvents(c)
    local wood, ore = c.stock.wood, c.stock.ore
    C.removeSite(c, smelter.id)
    local pile = salvagePile(c)
    local share = defs.salvage.share
    eq(pile.goods.wood, math.floor(defs.buildings.smelter.cost.wood * share))
    eq(pile.goods.ore, math.floor(defs.buildings.smelter.cost.ore * share))
    local added = false
    for _, e in ipairs(C.drainEvents(c)) do if e.kind == 'site_added' and e.site == pile.id then added = true end end
    eq(added, true)
    C.setClock(c, 12, 30)
    local guard = 0
    while c.sites[pile.id] do
        guard = guard + 1
        assert(guard < 40, 'never cleared')
        for _, id in ipairs(w) do
            local t = C.nextTask(c, id)
            run(c, id)
        end
    end
    eq(c.stock.wood, wood + math.floor(defs.buildings.smelter.cost.wood * share))
    eq(c.stock.ore, ore + math.floor(defs.buildings.smelter.cost.ore * share))
end)

test('two settlers never fetch the same salvage twice', function()
    local c, w = colony(2)
    local mine = C.addSite(c, 'mine', P(600, 0), 0, true)
    C.removeSite(c, mine.id)
    local pile = salvagePile(c)
    pile.goods.wood = 6
    C.setClock(c, 12, 30)
    local a, b = C.nextTask(c, w[1]), C.nextTask(c, w[2])
    eq(a.kind, 'salvage')
    eq(b.kind, 'salvage')
    eq(a.salvage.amount + b.salvage.amount, 6)
    C.cancelTask(c, w[2])
    eq(pile.claimed.wood, a.salvage.amount, 'a cancelled load is free again')
end)

test('salvage comes in while you are away too', function()
    local c, w = colony(1)
    local mine = C.addSite(c, 'mine', P(600, 0), 0, true)
    local wood = c.stock.wood
    C.removeSite(c, mine.id)
    local pile = salvagePile(c)
    C.setClock(c, 12, 30)
    C.simulateWorker(c, w[1], 2000)
    eq(c.sites[pile.id], nil)
    eq(c.stock.wood, wood + math.floor(defs.buildings.mine.cost.wood * defs.salvage.share))
end)

test('construction comes before salvage', function()
    local c, w = colony(1)
    local mine = C.addSite(c, 'mine', P(600, 0), 0, true)
    C.removeSite(c, mine.id)
    C.addSite(c, 'farm', P(900, 0), 0, false)
    C.setClock(c, 12, 30)
    eq(C.nextTask(c, w[1]).kind, 'haul')
end)

test('a salvage pile says what is left', function()
    local c = colony(0)
    local mine = C.addSite(c, 'mine', P(600, 0), 0, true)
    C.removeSite(c, mine.id)
    local pile = salvagePile(c)
    eq(C.siteStatus(c, pile.id), math.floor(defs.buildings.mine.cost.wood * defs.salvage.share) .. ' Timber to carry back')
    eq(C.siteVisuals(c, pile.id).piles.wood, pile.goods.wood)
end)

test('moving costs more the further and the more it turns', function()
    local from = { x = 0, y = 0, yaw = 0 }
    local near_ = C.moveCost('house', from, { x = 300, y = 0, yaw = 0 })
    local far = C.moveCost('house', from, { x = 3000, y = 0, yaw = 0 })
    local turned = C.moveCost('house', from, { x = 300, y = 0, yaw = math.pi / 2 })
    assert(far.wood > near_.wood and turned.wood > near_.wood)
    local _, w1 = C.moveCost('house', from, { x = 300, y = 0, yaw = 0 })
    local _, w2 = C.moveCost('house', from, { x = 300, y = 0, yaw = math.pi })
    assert(w2 > w1)
    -- turning right round one way or the other costs the same
    local a = C.moveCost('house', from, { x = 0, y = 0, yaw = 0.3 })
    local b = C.moveCost('house', from, { x = 0, y = 0, yaw = -0.3 })
    eq(a.wood, b.wood)
end)

test('a move is built like anything else, then the building is in its new spot', function()
    local c, w = colony(2)
    c.stock.wood = 100
    local mine = C.addSite(c, 'mine', P(600, 0), 0, true)
    C.assign(c, w[1], mine.id)
    local m = C.startMove(c, mine.id, P(1500, 400), 1.0, nil, false, 150)
    assert(m)
    eq(C.startMove(c, mine.id, P(0, 0), 0), nil, 'one move at a time')
    eq(C.canMove(c, m.id), false)
    C.setClock(c, 12, 30)
    local guard = 0
    while c.sites[m.id] do
        guard = guard + 1
        assert(guard < 60, 'never moved')
        local t = C.nextTask(c, w[2])
        run(c, w[2])
    end
    eq(mine.pos.x, 1500)
    eq(mine.yaw, 1.0)
    eq(mine.moving, nil)
    eq(mine.built, true)
    eq(c.workers[w[1]].assignment, mine.id, 'its workers stay on')
    local moved = false
    for _, e in ipairs(C.drainEvents(c)) do if e.kind == 'moved' and e.site == mine.id then moved = true end end
    eq(moved, true)
    for _, sid in ipairs(c.siteOrder) do assert(not c.sites[sid].goods, 'a finished move leaves no salvage') end
end)

test('cancelling a move leaves the building where it was', function()
    local c = colony(0)
    local mine = C.addSite(c, 'mine', P(600, 0), 0, true)
    local m = C.startMove(c, mine.id, P(1500, 0), 0)
    C.drainEvents(c)
    C.removeSite(c, m.id)
    eq(mine.pos.x, 600)
    eq(mine.moving, nil)
    local cancelled = false
    for _, e in ipairs(C.drainEvents(c)) do if e.kind == 'move_cancelled' then cancelled = true end end
    eq(cancelled, true)
    eq(C.canMove(c, mine.id), true)
end)

test('demolishing a building on the move cancels the move', function()
    local c = colony(0)
    local mine = C.addSite(c, 'mine', P(600, 0), 0, true)
    local m = C.startMove(c, mine.id, P(1500, 0), 0)
    C.removeSite(c, mine.id)
    eq(c.sites[m.id], nil)
end)

test('moves are named after what they move', function()
    local c, w = colony(1)
    c.stock.wood = 100
    local mine = C.addSite(c, 'mine', P(600, 0), 0, true)
    C.startMove(c, mine.id, P(1500, 0), 0)
    C.setClock(c, 12, 30)
    local t = C.nextTask(c, w[1])
    assert(t.steps[3].label:find(defs.buildings.mine.name), t.steps[3].label)
end)

test('furnishings are moved at once and for nothing', function()
    local c = colony(0)
    local bridge = C.addSite(c, 'ropebridge', P(600, 0), 0, true)
    local candle = C.addSite(c, 'candle', P(700, 0), 0, true)
    candle.price = 8
    local gold, wood = C.gold(c), c.stock.wood
    eq(C.canMove(c, bridge.id), false, 'no scaffolds for a bridge')
    eq(C.canRelocate(c, bridge.id), true)
    C.drainEvents(c)
    eq(C.relocate(c, bridge.id, P(900, 50), 1.2), true)
    eq(bridge.pos.x, 900)
    eq(bridge.yaw, 1.2)
    eq(C.relocate(c, candle.id, P(950, 0), 0), true)
    eq(C.gold(c), gold, 'moving something bought costs nothing')
    eq(c.stock.wood, wood)
    eq(#c.siteOrder, 3, 'no move site, no salvage') -- the storehouse, the bridge, the candle
    local moved = 0
    for _, e in ipairs(C.drainEvents(c)) do if e.kind == 'moved' then moved = moved + 1 end end
    eq(moved, 2)
    -- buildings still go through a move, unfinished furnishings don't move
    local mine = C.addSite(c, 'mine', P(-600, 0), 0, true)
    eq(C.canRelocate(c, mine.id), false)
    local lamp = C.addSite(c, 'lamppost', P(-900, 0), 0, false)
    eq(C.canRelocate(c, lamp.id), false)
end)
