-- Player script: colony ledger UI, worker/building panels and freeform
-- building placement. All colony state lives in the global script; this
-- script only renders snapshots and sends commands.

local ui = require('openmw.ui')
local util = require('openmw.util')
local async = require('openmw.async')
local core = require('openmw.core')
local input = require('openmw.input')
local camera = require('openmw.camera')
local nearby = require('openmw.nearby')
local self = require('openmw.self')
local I = require('openmw.interfaces')
local types = require('openmw.types')

local defs = require('scripts.tomorrowind.defs')
local C = require('scripts.tomorrowind.core.colony')
local terrain = require('scripts.tomorrowind.core.terrain')

local T = I.MWUI.templates
local v2 = util.vector2

local LEDGER_KEY = input.KEY.K
local COLONY_RADIUS = 7000
local ROTATE_SPEED = 1.6      -- rad/s while holding Z/X

local snap = { founded = false }
local ledger                 -- ui element
local tab = 'overview'
local focusWorker, focusSite
local placing                -- { obj=, kind=, yaw=, pos=, valid=, reason=, pathT= }
local hud

---------------------------------------------------------------------------
-- small layout helpers

local function text(str, width, header)
    local t = { template = header and T.textHeader or T.textNormal, props = { text = tostring(str) } }
    if width then
        t.props.autoSize = false
        t.props.size = v2(width, 20)
    end
    return t
end

local function row(items)
    return { type = ui.TYPE.Flex, props = { horizontal = true, arrange = ui.ALIGNMENT.Center },
             content = ui.content(items) }
end

local function col(items)
    return { type = ui.TYPE.Flex, props = { horizontal = false }, content = ui.content(items) }
end

local function gap(w, h)
    return { props = { size = v2(w or 8, h or 8) } }
end

local function button(label, fn, active)
    return {
        template = T.box,
        events = { mouseClick = async:callback(function() fn() end) },
        content = ui.content({
            { template = T.padding, content = ui.content({ text(label, nil, active) }) },
        }),
    }
end

local function resLabel(res) return defs.resources[res].name end

local function costText(cost)
    local parts = {}
    for _, r in ipairs(defs.resourceOrder) do
        if cost[r] then parts[#parts + 1] = cost[r] .. ' ' .. resLabel(r) end
    end
    return #parts > 0 and table.concat(parts, ', ') or 'free'
end

---------------------------------------------------------------------------
-- ledger

local closeLedger -- forward
local startMoving -- forward

local function send(name, data) core.sendGlobalEvent(name, data or {}) end

-- Tell the colony when the player is attacked near it (the global script
-- checks the distance), so guards come to help.
if I.Combat then
    I.Combat.addOnHitHandler(function(attack)
        if snap.founded and attack.attacker then
            send('TMW_Attacked', { victim = self.object, attacker = attack.attacker })
        end
    end)
end

local function overviewTab()
    local items = {}
    local stockRow = {}
    for _, r in ipairs(defs.resourceOrder) do
        local s, a = snap.stock[r] or 0, snap.available[r] or 0
        local label = resLabel(r) .. ': ' .. math.floor(s)
        if (snap.capacity or 0) > 0 then label = label .. ' / ' .. snap.capacity end
        stockRow[#stockRow + 1] = text(label, 170)
    end
    items[#items + 1] = row(stockRow)
    items[#items + 1] = text(string.format('Treasury: %d gold', math.floor(snap.gold or 0)))
    local pop = string.format('Settlers: %d / %d beds', snap.pop, snap.beds)
    if snap.pending > 0 then pop = pop .. string.format(' (%d on the way)', snap.pending) end
    if (snap.cells or 0) > 0 or (snap.prisoners or 0) > 0 then
        pop = pop .. string.format('     Prisoners: %d / %d cells', snap.prisoners or 0, snap.cells or 0)
    end
    items[#items + 1] = text(pop)
    if snap.hour then
        local h = math.floor(snap.hour)
        local name = snap.period == 'work' and 'working hours'
            or snap.period == 'free' and 'free time' or 'night'
        items[#items + 1] = text(string.format('%02d:%02d, %s', h, math.floor((snap.hour - h) * 60), name))
    end
    if snap.underAttack then items[#items + 1] = text('THE COLONY IS UNDER ATTACK', nil, true) end
    items[#items + 1] = gap(1, 10)
    items[#items + 1] = text('Buildings', nil, true)
    local furnished = 0
    for _, s in ipairs(snap.sites) do
        if s.small and s.built then furnished = furnished + 1 end
    end
    for _, s in ipairs(snap.sites) do
        if s.small and s.built then goto continue end
        local r = {
            text(s.name, 190, s.id == focusSite),
            text(s.status, 300),
        }
        if s.canMove then
            r[#r + 1] = button('Move', function() startMoving(s) end)
            r[#r + 1] = gap(4, 1)
        end
        if s.kind ~= 'storehouse' and s.kind ~= 'salvage' then
            r[#r + 1] = button(s.built and 'Demolish' or 'Cancel', function()
                send('TMW_RemoveSite', { sid = s.id })
            end)
        end
        items[#items + 1] = row(r)
        ::continue::
    end
    if furnished > 0 then
        items[#items + 1] = gap(1, 6)
        items[#items + 1] = text(furnished .. ' furnishings. Look at one and press Delete to remove it.')
    end
    return items
end

local function cycleAssignment(w, dir)
    send('TMW_CycleJob', { wid = w.id, dir = dir })
end

local function workersTab()
    local items = {
        row({ text('Name', 150, true), text('Job', 220, true), text('Doing', 290, true), text('Fed', 50, true) }),
    }
    for _, w in ipairs(snap.workers) do
        local fed = math.floor((w.fed or 0) * 100 + 0.5) .. '%'
        items[#items + 1] = row({
            text(w.name, 150, w.id == focusWorker),
            button('<', function() cycleAssignment(w, -1) end),
            text(w.job, 170),
            button('>', function() cycleAssignment(w, 1) end),
            gap(6, 1),
            text(w.status, 290),
            text(fed, 50),
            button('Talk', function()
                if w.obj then
                    closeLedger()
                    I.UI.setMode('Dialogue', { target = w.obj })
                end
            end),
        })
    end
    if #snap.workers == 0 then items[#items + 1] = text('No settlers yet.') end
    return items
end

local function canAfford(cost)
    for r, n in pairs(cost) do
        if (snap.available[r] or 0) < n then return false end
    end
    return true
end

local startPlacing -- forward
local outdoorsOnly

local function buildTab()
    local items = {
        row({ text('Building', 190, true), text('Materials', 230, true), text('Provides', 240, true) }),
    }
    if snap.insideHost then
        items[#items + 1] = text('Step outside to place buildings.')
        return items
    end
    for _, kind in ipairs(defs.buildOrder) do
        local d = defs.buildings[kind]
        local provides = d.job and string.format('%d %s jobs', d.slots, d.job)
            or (d.door and 'A room to furnish, with a bed') or (d.beds and (d.beds .. ' beds') or '')
        if d.output then
            local res, n = next(d.output)
            provides = provides .. ', ' .. n .. ' ' .. resLabel(res)
            if d.input then
                local ir, inn = next(d.input)
                provides = provides .. ' from ' .. inn .. ' ' .. resLabel(ir)
            end
        end
        local cost = costText(d.cost)
        if not canAfford(d.cost) then cost = cost .. ' (short)' end
        items[#items + 1] = row({
            text(d.name, 190), text(cost, 230), text(provides, 240),
            button('Place', function() startPlacing(kind) end),
        })
    end
    items[#items + 1] = gap(1, 8)
    items[#items + 1] = text('Materials are hauled to the site by laborers and builders.')
    return items
end

outdoorsOnly = function(d)
    return d.hollow or d.segment or d.rises or d.opensLedger
end

local function furnishTab()
    local items = {
        row({ text('Furnishing', 190, true), text('Materials', 230, true), text('', 240, true) }),
    }
    if snap.insideHost then items[#items + 1] = text('Placing inside this house.', nil, true) end
    for _, kind in ipairs(defs.furnishOrder) do
        local d = defs.buildings[kind]
        if not (snap.insideHost and outdoorsOnly(d)) then
            local cost = costText(d.cost)
            if not canAfford(d.cost) then cost = cost .. ' (short)' end
            items[#items + 1] = row({
                text(d.name, 190), text(cost, 230), text(d.desc or '', 240),
                button('Place', function() startPlacing(kind) end),
            })
        end
    end
    items[#items + 1] = gap(1, 8)
    items[#items + 1] = text('Settlers use these in their free time. Removing one gives its materials back.')
    return items
end

-- One row of the trade page: price, and the levels to keep and to buy up to.
local function tradeRow(r)
    local t = snap.trade[r]
    local step = defs.trade.step
    local function level(field, value)
        return {
            button('<', function() send('TMW_TradeSet', { res = r, [field] = math.max(0, value - step) }) end),
            text(value, 44),
            button('>', function() send('TMW_TradeSet', { res = r, [field] = value + step }) end),
        }
    end
    local cells = { text(resLabel(r), 110), text(math.floor(snap.stock[r] or 0), 56), text(string.format('%.1f', t.sell), 56) }
    for _, x in ipairs(level('keep', t.keep)) do cells[#cells + 1] = x end
    cells[#cells + 1] = gap(24, 1)
    cells[#cells + 1] = text(string.format('%.1f', t.buy), 56)
    for _, x in ipairs(level('want', t.want)) do cells[#cells + 1] = x end
    return row(cells)
end

local function tradeTab()
    local items = {
        row({
            text(string.format('Treasury: %d gold', math.floor(snap.gold or 0)), 220, true),
            button('Take 100', function() send('TMW_Treasury', { amount = 100 }) end), gap(),
            button('Give 100', function() send('TMW_Treasury', { amount = -100 }) end),
        }),
        gap(1, 8),
        row({ text('', 110), text('Stock', 56, true), text('Sells', 56, true), text('Keep', 110, true), gap(24, 1), text('Costs', 56, true), text('Buy up to', 110, true) }),
    }
    for _, r in ipairs(defs.resourceOrder) do items[#items + 1] = tradeRow(r) end
    items[#items + 1] = gap(1, 8)
    if not snap.market then
        items[#items + 1] = text('Build a Market Stall and give it a Trader to start selling.')
    else
        items[#items + 1] = text('Traders sell what is above Keep. Prices drop as you sell, then recover.')
        items[#items + 1] = text(snap.caravan and 'A caravan is here: better prices, and it sells your buy list.'
            or 'Caravans come every couple of days: better prices, and they sell your buy list.')
    end
    return items
end

local function ledgerLayout()
    local body
    if not snap.founded then
        body = {
            text('You have no colony yet.'),
            gap(1, 8),
            button('Found a colony here', function()
                local yaw = camera.getYaw()
                send('TMW_Found', { yaw = yaw })
            end),
        }
    else
        local tabs = row({
            button('Overview', function() tab = 'overview'; ledger.layout = ledgerLayout(); ledger:update() end, tab == 'overview'),
            gap(),
            button('Workers', function() tab = 'workers'; ledger.layout = ledgerLayout(); ledger:update() end, tab == 'workers'),
            gap(),
            button('Build', function() tab = 'build'; ledger.layout = ledgerLayout(); ledger:update() end, tab == 'build'),
            gap(),
            button('Furnish', function() tab = 'furnish'; ledger.layout = ledgerLayout(); ledger:update() end, tab == 'furnish'),
            gap(),
            button('Trade', function() tab = 'trade'; ledger.layout = ledgerLayout(); ledger:update() end, tab == 'trade'),
        })
        local content = (tab == 'workers' and workersTab()) or (tab == 'build' and buildTab())
            or (tab == 'furnish' and furnishTab()) or (tab == 'trade' and tradeTab()) or overviewTab()
        body = { tabs, gap(1, 10), col(content) }
    end
    local all = { row({ text('Colony Ledger', 400, true), button('Close', function() closeLedger() end) }), gap(1, 8) }
    for _, b in ipairs(body) do all[#all + 1] = b end
    return {
        layer = 'Windows',
        template = T.boxSolidThick,
        props = { relativePosition = v2(0.5, 0.5), anchor = v2(0.5, 0.5) },
        content = ui.content({
            { template = T.padding, content = ui.content({
                { template = T.padding, content = ui.content({ col(all) }) },
            }) },
        }),
    }
end

local function refreshLedger()
    if ledger then
        ledger.layout = ledgerLayout()
        ledger:update()
    end
end

local function openLedger(newTab)
    if newTab then tab = newTab end
    send('TMW_RequestState')
    if ledger then return refreshLedger() end
    I.UI.setPauseOnMode('Interface', false)
    I.UI.setMode('Interface', { windows = {} })
    ledger = ui.create(ledgerLayout())
end

closeLedger = function()
    if ledger then
        ledger:destroy()
        ledger = nil
    end
    focusWorker, focusSite = nil, nil
    I.UI.setPauseOnMode('Interface', true)
    if I.UI.getMode() == 'Interface' then I.UI.setMode() end
end

---------------------------------------------------------------------------
-- placement

local function setHud(lines)
    local layout = {
        layer = 'HUD',
        template = T.boxTransparent,
        props = { relativePosition = v2(0.5, 0.08), anchor = v2(0.5, 0) },
        content = ui.content({ { template = T.padding, content = ui.content({ col(lines) }) } }),
    }
    if hud then
        hud.layout = layout
        hud:update()
    else
        hud = ui.create(layout)
    end
end

local function clearHud()
    if hud then hud:destroy() hud = nil end
end

-- Choices that carry over to the next placement of the same kind: building
-- a curve, every segment keeps bending the same way.
local lastCurve = {}

startPlacing = function(kind)
    if snap.insideHost and (not defs.buildings[kind].small or outdoorsOnly(defs.buildings[kind])) then
        return ui.showMessage('That has to be placed outdoors.')
    end
    closeLedger()
    placing = { kind = kind, yaw = camera.getYaw() + math.pi, valid = false, reason = 'Look at open ground', pathT = 0,
        variant = 1, raise = 0, curve = lastCurve[kind] or 0 }
    send('TMW_BeginPlace', { kind = kind, variant = 1 })
end

-- Moving a building: place it again, as it is.
startMoving = function(site)
    startPlacing(site.kind)
    placing.moving, placing.from, placing.variant = site.id, site, site.variant or 1
    placing.yaw = site.yaw
    send('TMW_BeginPlace', { kind = site.kind, variant = placing.variant, moving = site.id })
end

-- Next or previous model for what's being placed (a new preview object).
local function cycleVariant(dir)
    local count = #(defs.buildings[placing.kind].variants or {})
    if count < 2 or placing.moving then return end
    placing.variant = (placing.variant - 1 + dir) % count + 1
    placing.obj = nil
    send('TMW_BeginPlace', { kind = placing.kind, variant = placing.variant })
end

local function stopPlacing(confirm)
    if not placing then return end
    if confirm then
        if not placing.valid then
            ui.showMessage('Cannot build here: ' .. (placing.reason or '?'))
            local an = placing.analysis or {}
            print(string.format('[Tomorrowind] placement refused: %s at %s (footprint r=%.0f, ground %.0f..%.0f)',
                tostring(placing.reason), tostring(placing.pos), placing.radius or -1, an.low or -1, an.high or -1))
            return
        end
        local a = placing.analysis
        send('TMW_PlaceConfirm', {
            moving = placing.moving,
            pos = placing.pos, yaw = placing.yaw, radius = placing.radius,
            foundation = { wood = a.wood, work = a.work, depth = a.depth },
        })
    else
        send('TMW_PlaceCancel')
    end
    if confirm then lastCurve[placing.kind] = placing.snapped and placing.curve or 0 end
    placing = nil
    clearHud()
end

-- Footprint radius and height of the building being placed, from the
-- preview's bounding box (falls back to the defs footprint).
local function ghostSize()
    local d = defs.look(placing.kind, placing.variant)
    if placing.obj and placing.obj:isValid() then
        local ok, box = pcall(placing.obj.getBoundingBox, placing.obj)
        if ok and box and box.halfSize.x > 1 and box.halfSize.x < 5000 then
            return math.max(box.halfSize.x, box.halfSize.y), box.halfSize.z * 2
        end
    end
    return d.footprint, nil
end

local function dist2d(a, b)
    return util.vector2(a.x - b.x, a.y - b.y):length()
end

local function groundHeight(x, y)
    local ok, h = pcall(core.land.getHeightAt, util.vector3(x, y, 0), self.cell)
    return ok and h or nil
end

-- Where the view ray meets the terrain, found by stepping along the ray and
-- comparing with the land height. Unlike a physics ray this can't be
-- blocked by the player's body or the (moving) preview building.
local function aimAtGround()
    if placing.forcedAim then return placing.forcedAim end -- scripted tests
    local from = camera.getPosition()
    local dir = camera.viewportToWorldVector(v2(0.5, 0.5))
    local t, step = 0, 24
    while t < 4000 do
        t = t + step
        local p = from + dir * t
        local h = groundHeight(p.x, p.y)
        if h and p.z <= h then return util.vector3(p.x, p.y, h) end
    end
end

-- Indoors there's no land: the view ray has to hit a floor.
local function aimAtFloor()
    if placing.forcedAim then return placing.forcedAim end
    local from = camera.getPosition()
    local dir = camera.viewportToWorldVector(v2(0.5, 0.5))
    local res = nearby.castRay(from, from + dir * 1500, { collisionType = nearby.COLLISION_TYPE.World, ignore = placing.obj })
    if res.hit and res.hitNormal and res.hitNormal.z > 0.7 then return res.hitPos end
end

-- Physics check for real obstructions (trees, rocks, houses) under the
-- footprint: rays straight down, ignoring the preview building and actors.
local function obstruction(pos, r, top, bottom)
    local pts = { { 0, 0 }, { r * 0.6, 0 }, { -r * 0.6, 0 }, { 0, r * 0.6 }, { 0, -r * 0.6 } }
    for _, d in ipairs(pts) do
        local from = util.vector3(pos.x + d[1], pos.y + d[2], top)
        local to = util.vector3(pos.x + d[1], pos.y + d[2], bottom)
        local res = nearby.castRay(from, to, { collisionType = nearby.COLLISION_TYPE.World, ignore = placing.obj })
        local o = res.hit and res.hitObject
        local hollow = false
        if o then
            for _, s in ipairs(snap.sites or {}) do
                -- a tent you're placing inside, or a wall you're joining onto
                if s.obj and s.obj.id == o.id and (defs.buildings[s.kind].hollow
                    or (placing.snapped and defs.look(s.kind, s.variant).segment)) then
                    hollow = true
                end
            end
        end
        if o and placing.from and placing.from.obj and o.id == placing.from.obj.id then hollow = true end -- itself, where it stands now
        if o and not hollow and not (placing.obj and o.id == placing.obj.id) and o.type ~= types.NPC and o.type ~= types.Creature then
            local okName, rec = pcall(function() return o.type.record(o) end)
            local name = okName and rec and rec.name
            return (name and name ~= '') and name or o.recordId
        end
    end
end

-- Does a site stop this one being placed here? Furnishings only keep clear
-- of each other and of buildings going up: finished buildings are checked by
-- the obstruction rays, so a lantern can stand right next to a wall.
local function tooClose(d, pos, r, s)
    local other = defs.buildings[s.kind]
    if s.id == placing.moving or (placing.moving and s.kind == 'salvage') then return false end
    if s.host ~= snap.insideHost then return false end -- another place entirely
    if snap.insideHost then return dist2d(pos, s.pos) < (s.radius + r) * 0.6 end
    if d.small then
        if other.hollow or d.hollow then return false end
        if placing.snapped and defs.look(s.kind, s.variant).segment then return false end
        if not other.small and s.built then return false end
        if other.small then return dist2d(pos, s.pos) < (s.radius + r) * 0.6 end
    end
    return dist2d(pos, s.pos) < (s.radius + r) * 0.75
end

local function validate(pos, dt)
    local d = defs.look(placing.kind, placing.variant)
    local r, height = ghostSize()
    placing.radius = r
    local a
    if snap.insideHost then
        placing.analysis = { ok = true, level = pos.z + placing.raise, low = pos.z, high = pos.z, depth = 0, wood = 0, work = 0 }
        for _, s in ipairs(snap.sites or {}) do
            if tooClose(d, pos, r, s) then return false, 'too close to the ' .. s.name end
        end
        return true
    end
    if d.small then
        -- furnishings follow the ground under their middle: no foundations
        local level = pos.z + placing.raise
        a = { ok = pos.z >= -20, reason = 'under water', level = level, low = pos.z, high = pos.z, depth = 0, wood = 0, work = 0 }
    else
        local heights = {}
        for _, p in ipairs(terrain.samplePoints(r)) do
            heights[#heights + 1] = groundHeight(pos.x + p[1], pos.y + p[2])
        end
        a = terrain.analyze(heights, height, placing.raise)
    end
    placing.analysis = a
    if not a.ok then return false, a.reason end
    if snap.storePos and dist2d(pos, snap.storePos) > COLONY_RADIUS then
        return false, 'too far from the storehouse'
    end
    for _, s in ipairs(snap.sites or {}) do
        if tooClose(d, pos, r, s) then
            return false, 'too close to the ' .. s.name
        end
    end
    -- the slower checks run a few times per second
    placing.checkT = (placing.checkT or 0) - dt
    if placing.checkT <= 0 then
        placing.checkT = 0.3
        -- furnishings look only as high as they are: they fit under a tent
        -- roof or a tree, and rays for them ignore a tent they stand in
        local top = d.small and (a.high + math.min(height or 100, 180) + 10) or (a.high + 800)
        placing.blocker = obstruction(pos, r, top, a.low - 50)
        -- walkable ground next to the footprint (catches water, cliffs, islands)
        local ok, nav = pcall(nearby.findNearestNavMeshPosition, pos,
            { searchAreaHalfExtents = util.vector3(r + 400, r + 400, 600) })
        placing.reachable = (not ok) or (nav ~= nil and dist2d(nav, pos) < r + 400)
    end
    if placing.blocker then return false, 'something is in the way (' .. placing.blocker .. ')' end
    if not placing.reachable then return false, 'workers cannot walk there' end
    return true
end

-- Walls, fences and gates snap end to end with the ones already there, and
-- can bend around the joint: Z and X turn the new piece around the end of the
-- one it attaches to, so walls can curve.
local SNAP_RANGE = 180
local function snapSegment(d, hit)
    local best, bestD, bestYaw
    local mine = d.segment
    for _, s in ipairs(snap.sites or {}) do
        local other = defs.look(s.kind, s.variant).segment
        if other and s.yaw then
            local axis = util.transform.rotateZ(s.yaw) * util.vector3(1, 0, 0)
            local middle = s.pos + axis * (other.at or 0)
            local yaw = s.yaw + placing.curve
            local newAxis = util.transform.rotateZ(yaw) * util.vector3(1, 0, 0)
            for _, side in ipairs({ -1, 1 }) do
                local joint = middle + axis * (side * other.half)
                local p = joint + newAxis * (side * mine.half - (mine.at or 0))
                local dd = dist2d(p, hit)
                if dd < SNAP_RANGE and (not bestD or dd < bestD) then best, bestD, bestYaw = p, dd, yaw end
            end
        end
    end
    if not best then return hit end
    placing.snapped = true
    placing.yaw = bestYaw
    return util.vector3(best.x, best.y, groundHeight(best.x, best.y) or hit.z)
end

local function updatePlacing(dt)
    -- when snapped, rotating bends the new piece around the joint
    local turn = 0
    if input.isKeyPressed(input.KEY.Z) then turn = turn - ROTATE_SPEED * dt end
    if input.isKeyPressed(input.KEY.X) then turn = turn + ROTATE_SPEED * dt end
    if placing.snapped then placing.curve = placing.curve + turn else placing.yaw = placing.yaw + turn end
    local cfg = defs.placeRaise
    if input.isKeyPressed(input.KEY.UpArrow) then placing.raise = math.min(cfg.limit, placing.raise + cfg.speed * dt) end
    if input.isKeyPressed(input.KEY.DownArrow) then placing.raise = math.max(-cfg.limit, placing.raise - cfg.speed * dt) end

    local d = defs.look(placing.kind, placing.variant)
    local hit = snap.insideHost and aimAtFloor() or (not snap.insideHost and aimAtGround()) or nil
    local extra
    placing.snapped = false
    if hit and d.segment then hit = snapSegment(d, hit) end
    if hit then
        placing.valid, placing.reason = validate(hit, dt)
        local a = placing.analysis
        local level = (a and a.level) or hit.z
        placing.pos = util.vector3(hit.x, hit.y, level)
        send('TMW_PlaceMove', { pos = placing.pos, yaw = placing.yaw })
        if a and a.ok and a.wood > 0 then
            extra = string.format('Sloped ground: foundation +%d Timber, +%ds leveling work', a.wood, a.work)
        end
    else
        placing.valid, placing.reason = false, snap.insideHost and 'look at the floor' or 'look at open ground'
    end
    if defs.debug then
        placing.logT = (placing.logT or 0) - dt
        if placing.logT <= 0 then
            placing.logT = 1
            print(string.format('[Tomorrowind] placing: hit=%s valid=%s reason=%s depth=%s',
                tostring(hit), tostring(placing.valid), tostring(placing.reason),
                tostring(placing.analysis and placing.analysis.depth)))
        end
    end
    local variants = not placing.moving and defs.buildings[placing.kind].variants
    local title = 'Placing: ' .. d.name .. '   (' .. costText(d.cost) .. ')'
    if placing.moving and placing.pos then
        local f = placing.from
        local a = placing.analysis
        local cost, work = C.moveCost(placing.kind, { x = f.pos.x, y = f.pos.y, yaw = f.yaw },
            { x = placing.pos.x, y = placing.pos.y, yaw = placing.yaw }, a and a.ok and { wood = a.wood, work = a.work } or nil)
        title = string.format('Moving: %s   (%s, %ds of work)', d.label or d.name, costText(cost), work)
    end
    local lines = {
        text(title, nil, true),
        text((placing.snapped and 'Z / X bend' or 'Z / X rotate') .. '     Up / Down height     Enter place     Backspace cancel'),
    }
    if variants then
        lines[#lines + 1] = text(string.format('Left / Right model: %s (%d of %d)', d.label or d.name, placing.variant, #variants))
    end
    if placing.snapped then
        lines[#lines + 1] = text(string.format('Joined up, bent by %d degrees', math.floor(math.deg(placing.curve) + 0.5)))
    end
    if math.abs(placing.raise) >= 1 then
        lines[#lines + 1] = text(string.format('Height: %+d', math.floor(placing.raise + 0.5)))
    end
    if extra then lines[#lines + 1] = text(extra) end
    lines[#lines + 1] = text(placing.valid and 'Good spot' or ('Cannot build: ' .. (placing.reason or '')), nil, not placing.valid)
    setHud(lines)
end

---------------------------------------------------------------------------
-- floating labels: progress of the construction site you're looking at, and
-- what settlers just said

local LABEL_RANGE = 3000
local LABEL_CONE = 0.22        -- how near the middle of the view, as part of the screen
local labels, labelT = nil, 0
local debugOn = defs.debug
local quietUi = false        -- no labels or panels (filming)
local hoverSite              -- the furnishing being looked at (has its own panel)
local hoverWorker            -- the settler being looked at
local hoverMove              -- the building being looked at, if it can be moved
local bubbles = {}           -- list of { obj=, text=, until= }

local function clearLabels()
    if labels then labels:destroy() labels = nil end
end

local function progressLines(site)
    local p = site.progress
    local lines = { text(site.name, nil, true) }
    if p then
        local mats = {}
        for _, m in ipairs(p.materials) do mats[#mats + 1] = string.format('%s %d/%d', m.name, m.have, m.need) end
        if #mats > 0 then lines[#lines + 1] = text(table.concat(mats, '   ')) end
        local phase = p.phase == 'materials' and 'Waiting for materials'
            or p.phase == 'leveling' and string.format('Leveling the ground: %d%%', p.percent)
            or string.format('Construction: %d%%', p.percent)
        lines[#lines + 1] = text(phase)
    end
    return lines
end

-- Size of the HUD layer: the units UI positions are in. These are scaled
-- units, not the pixels the camera reports (they differ on high-DPI screens).
local function hudSize()
    return ui.layers[ui.layers.indexOf('HUD')].size
end

-- Where a world point appears, in HUD units; nil if behind the camera.
local function toScreen(pos, screen)
    local v = camera.worldToViewportVector(pos)
    if v.z <= 0 then return nil end
    local pixels = ui.screenSize()
    return v.x * screen.x / pixels.x, v.y * screen.y / pixels.y
end

-- The one building site nearest the middle of the view, within range.
-- (Furnishings show their progress when you look right at them.)
local function lookedAtSite(screen, cam)
    if hoverSite then return nil end
    local best, bestD, bx, by
    for _, site in ipairs(snap.sites or {}) do
        if not site.built and not site.small and (site.pos - cam):length() < LABEL_RANGE then
            local x, y = toScreen(site.pos + util.vector3(0, 0, 250), screen)
            if x then
                local dx, dy = (x - screen.x / 2) / screen.x, (y - screen.y / 2) / screen.y
                local d = math.sqrt(dx * dx + dy * dy)
                if d < LABEL_CONE and (not bestD or d < bestD) then best, bestD, bx, by = site, d, x, y end
            end
        end
    end
    return best, bx, by
end

local function updateLabels(dt)
    labelT = labelT - dt
    if labelT > 0 then return end
    labelT = 0.1
    if quietUi or not snap.founded or ledger or placing or I.UI.getMode() then return clearLabels() end
    local screen = hudSize()
    local cam = camera.getPosition()
    local items = {}
    local site, x, y = lookedAtSite(screen, cam)
    if site then
        items[#items + 1] = {
            template = T.boxTransparent,
            props = { position = v2(math.max(160, math.min(screen.x - 160, x)), math.max(90, y)), anchor = v2(0.5, 1) },
            content = ui.content({ { template = T.padding, content = ui.content({ col(progressLines(site)) }) } }),
        }
    end
    local now = core.getRealTime()
    for i = #bubbles, 1, -1 do
        local b = bubbles[i]
        if now > b.untilT or not b.obj:isValid() or not b.obj.enabled then
            table.remove(bubbles, i)
        elseif (b.obj.position - cam):length() < defs.utter.range then
            local bx, by = toScreen(b.obj.position + util.vector3(0, 0, 150), screen)
            if bx and bx > 0 and bx < screen.x and by > 0 and by < screen.y then
                items[#items + 1] = {
                    template = T.boxTransparent,
                    props = { position = v2(bx, by), anchor = v2(0.5, 1) },
                    content = ui.content({ { template = T.padding, content = ui.content({ text(b.text) }) } }),
                }
            end
        end
    end
    if #items == 0 then return clearLabels() end
    local layout = { layer = 'HUD', props = { relativeSize = v2(1, 1) }, content = ui.content(items) }
    if labels then
        labels.layout = layout
        labels:update()
    else
        labels = ui.create(layout)
    end
end

---------------------------------------------------------------------------
-- what you're looking at: settlers say what they're doing

local HOVER_RANGE = 900
local BOARD_RANGE = 600
local BOARD_SITES, BOARD_WORKERS = 3, 11
local hoverEl, hoverT = nil, 0
local hoverText

local function clearHover()
    if hoverEl then hoverEl:destroy() hoverEl = nil end
    hoverSite, hoverWorker, hoverMove, hoverText = nil, nil, nil, nil
end

-- The colony board: the ledger's overview and workers, to read.
local function boardContent()
    local rows = { text('Colony Board   (activate for the ledger)', nil, true) }
    local h = math.floor(snap.hour or 0)
    rows[#rows + 1] = text(string.format('%02d:%02d     Settlers: %d / %d beds', h, math.floor(((snap.hour or 0) - h) * 60), snap.pop, snap.beds))
    local stock = {}
    for _, r in ipairs(defs.resourceOrder) do
        stock[#stock + 1] = resLabel(r) .. ': ' .. math.floor(snap.stock[r] or 0)
    end
    stock[#stock + 1] = math.floor(snap.gold or 0) .. ' gold'
    rows[#rows + 1] = text(table.concat(stock, '    '))
    if snap.underAttack then rows[#rows + 1] = text('THE COLONY IS UNDER ATTACK', nil, true) end
    -- what's being built: buildings each, furnishings counted per kind
    local building, counts, order = {}, {}, {}
    for _, site in ipairs(snap.sites) do
        if not site.built then
            if site.small then
                if not counts[site.name] then order[#order + 1] = site.name end
                counts[site.name] = (counts[site.name] or 0) + 1
            else
                building[#building + 1] = site
            end
        end
    end
    if #building + #order > 0 then
        rows[#rows + 1] = text('Being built', nil, true)
        for i, site in ipairs(building) do
            if i <= BOARD_SITES then rows[#rows + 1] = row({ text(site.name, 130), text(site.status, 400) }) end
        end
        local parts = {}
        for _, name in ipairs(order) do parts[#parts + 1] = counts[name] .. ' ' .. name end
        if #parts > 0 then rows[#rows + 1] = text(table.concat(parts, ', ')) end
    end
    rows[#rows + 1] = text('Settlers', nil, true)
    for i, w in ipairs(snap.workers) do
        if i <= BOARD_WORKERS then
            rows[#rows + 1] = row({ text(w.name, 130), text((w.job:gsub(' %(.*%)', '')), 90), text(w.status, 310) })
        end
    end
    if #snap.workers > BOARD_WORKERS then
        rows[#rows + 1] = text('...and ' .. (#snap.workers - BOARD_WORKERS) .. ' more in the ledger')
    end
    return rows
end

local function hoverLines(id, dist)
    for _, w in ipairs(snap.workers or {}) do
        if w.obj and w.obj.id == id then
            hoverWorker = w.id
            return { w.name, w.job, w.status, 'Fed ' .. math.floor((w.fed or 0) * 100 + 0.5) .. '%', 'K: job in the ledger' }
        end
    end
    for _, s in ipairs(snap.sites or {}) do
        if s.obj and s.obj.id == id then
            if s.kind == 'board' and s.built then
                hoverSite = s.id
                return dist < BOARD_RANGE and { board = true } or { s.name, 'Come closer to read it' }
            end
            local lines = { s.name, s.status }
            if s.small then
                hoverSite = s.id
                lines[#lines + 1] = s.built and 'Delete: remove' or 'Delete: cancel'
            elseif s.canMove then
                hoverMove = s
                lines[#lines + 1] = 'M: move'
            end
            return lines
        end
    end
end

local function updateHover(dt)
    hoverT = hoverT - dt
    if hoverT > 0 then return end
    hoverT = 0.15
    if quietUi or not snap.founded or ledger or placing or I.UI.getMode() then return clearHover() end
    local from = camera.getPosition()
    local to = from + camera.viewportToWorldVector(v2(0.5, 0.5)) * HOVER_RANGE
    local res = nearby.castRenderingRay(from, to, { ignore = self.object })
    hoverSite, hoverWorker, hoverMove = nil, nil, nil
    local dist = res.hit and (res.hitPos - from):length() or 0
    local lines = res.hit and res.hitObject and hoverLines(res.hitObject.id, dist)
    if not lines then return clearHover() end
    local key = lines.board and tostring(snap) or table.concat(lines, '|')
    if key == hoverText then return end
    hoverText = key
    if debugOn then print('[Tomorrowind] hover: ' .. (lines.board and 'the board' or key)) end
    local content = {}
    if lines.board then
        content = boardContent()
    else
        for i, l in ipairs(lines) do content[i] = text(l, nil, i == 1) end
    end
    local layout = {
        layer = 'HUD',
        template = lines.board and T.boxSolidThick or T.boxTransparent,
        props = lines.board and { relativePosition = v2(0.5, 0.5), anchor = v2(0.5, 0.5) }
            or { relativePosition = v2(0.5, 0.56), anchor = v2(0.5, 0) },
        content = ui.content({ { template = T.padding, content = ui.content({ col(content) }) } }),
    }
    if hoverEl then
        hoverEl.layout = layout
        hoverEl:update()
    else
        hoverEl = ui.create(layout)
    end
end

---------------------------------------------------------------------------

return {
    engineHandlers = {
        onKeyPress = function(key)
            if placing then
                if key.code == input.KEY.Enter or key.code == input.KEY.NP_Enter then
                    stopPlacing(true)
                elseif key.code == input.KEY.Backspace then
                    stopPlacing(false)
                elseif key.code == input.KEY.RightArrow then
                    cycleVariant(1)
                elseif key.code == input.KEY.LeftArrow then
                    cycleVariant(-1)
                end
                return
            end
            if key.code == input.KEY.M and hoverMove and not I.UI.getMode() then
                local site = hoverMove
                clearHover()
                startMoving(site)
                return
            end
            if key.code == input.KEY.Delete and hoverSite and not I.UI.getMode() then
                send('TMW_RemoveSite', { sid = hoverSite })
                clearHover()
                return
            end
            if key.code == LEDGER_KEY then
                if ledger then
                    closeLedger()
                elseif not I.UI.getMode() then
                    if hoverWorker then
                        focusWorker = hoverWorker
                        openLedger('workers')
                    else
                        openLedger()
                    end
                end
            end
        end,
        onUpdate = function(dt)
            if placing and dt > 0 then updatePlacing(dt) end
            if dt > 0 then updateLabels(dt) end
        end,
        onFrame = function(dt)
            if dt > 0 then updateHover(dt) end
        end,
        onLoad = function()
            placing = nil
        end,
    },
    eventHandlers = {
        TMW_State = function(s)
            snap = s
            refreshLedger()
        end,
        TMW_Message = function(e) ui.showMessage(e.text) end,
        TMW_SetDebug = function(on) debugOn = on end,
        TMW_Ghost = function(e)
            if placing and placing.kind == e.kind then placing.obj = e.obj; placing.checkT = 0 end
        end,
        TMW_OpenWorker = function(e)
            focusWorker = e.wid
            openLedger('workers')
        end,
        TMW_OpenSite = function(e)
            focusSite = e.sid
            openLedger('overview')
        end,
        TMW_OpenLedger = function(e) openLedger(e and e.tab or 'overview') end,
        TMW_Face = function(e) camera.setYaw(e.yaw) end,
        TMW_Bubble = function(e)
            for i = #bubbles, 1, -1 do
                if bubbles[i].obj.id == e.obj.id then table.remove(bubbles, i) end
            end
            bubbles[#bubbles + 1] = { obj = e.obj, text = e.text, untilT = core.getRealTime() + defs.utter.seconds }
        end,
        -- debug hooks (used by the scripted playtest)
        TMW_DebugQuiet = function(on) quietUi = on end,
        TMW_DebugLedger = function(e)
            if e.open then openLedger(e.tab) else closeLedger() end
        end,
        TMW_DebugPlace = function(e)
            if e.move then
                for _, s in ipairs(snap.sites) do
                    if s.kind == e.move and s.canMove then startMoving(s) break end
                end
                placing.forcedAim = e.at
                if e.yaw then placing.yaw = e.yaw end
            elseif e.kind then
                startPlacing(e.kind)
                placing.forcedAim = e.at
                if e.curve then placing.curve = e.curve end
                if e.raise then placing.raise = e.raise end
            elseif e.cycle then
                cycleVariant(e.cycle)
            else
                stopPlacing(e.confirm)
            end
        end,
        UiModeChanged = function(e)
            -- player pressed Escape or opened another menu
            if ledger and e.newMode ~= 'Interface' then
                ledger:destroy()
                ledger = nil
                I.UI.setPauseOnMode('Interface', true)
            end
        end,
    },
}
