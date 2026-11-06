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
        if a < s then label = label .. ' (' .. math.floor(a) .. ' free)' end
        stockRow[#stockRow + 1] = text(label, 170)
    end
    items[#items + 1] = row(stockRow)
    local pop = string.format('Settlers: %d / %d beds', snap.pop, snap.beds)
    if snap.pending > 0 then pop = pop .. string.format(' (%d on the way)', snap.pending) end
    if (snap.cells or 0) > 0 or (snap.prisoners or 0) > 0 then
        pop = pop .. string.format('     Prisoners: %d / %d cells', snap.prisoners or 0, snap.cells or 0)
    end
    items[#items + 1] = text(pop)
    if snap.underAttack then items[#items + 1] = text('THE COLONY IS UNDER ATTACK', nil, true) end
    items[#items + 1] = gap(1, 10)
    items[#items + 1] = text('Buildings', nil, true)
    for _, s in ipairs(snap.sites) do
        local r = {
            text(s.name, 190, s.id == focusSite),
            text(s.status, 300),
        }
        if s.kind ~= 'storehouse' then
            r[#r + 1] = button(s.built and 'Demolish' or 'Cancel', function()
                send('TMW_RemoveSite', { sid = s.id })
            end)
        end
        items[#items + 1] = row(r)
    end
    return items
end

local function cycleAssignment(w, dir)
    local opts = snap.options
    local idx = 1
    for i, o in ipairs(opts) do
        if o.id == w.assignment then idx = i end
    end
    local nxt = opts[(idx - 1 + dir) % #opts + 1]
    send('TMW_Assign', { wid = w.id, target = nxt.id })
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

local function buildTab()
    local items = {
        row({ text('Building', 190, true), text('Materials', 230, true), text('Provides', 240, true) }),
    }
    for _, kind in ipairs(defs.buildOrder) do
        local d = defs.buildings[kind]
        local provides = d.job and string.format('%d %s jobs', d.slots, d.job)
            or (d.beds and (d.beds .. ' beds') or '')
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
        })
        local content = (tab == 'workers' and workersTab()) or (tab == 'build' and buildTab()) or overviewTab()
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

startPlacing = function(kind)
    closeLedger()
    placing = { kind = kind, yaw = camera.getYaw() + math.pi, valid = false, reason = 'Look at open ground', pathT = 0 }
    send('TMW_BeginPlace', { kind = kind })
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
            pos = placing.pos, yaw = placing.yaw,
            foundation = { wood = a.wood, work = a.work, depth = a.depth },
        })
    else
        send('TMW_PlaceCancel')
    end
    placing = nil
    clearHud()
end

-- Footprint radius and height of the building being placed, from the
-- preview's bounding box (falls back to the defs footprint).
local function ghostSize()
    local d = defs.buildings[placing.kind]
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

-- Physics check for real obstructions (trees, rocks, houses) under the
-- footprint: rays straight down, ignoring the preview building and actors.
local function obstruction(pos, r, top, bottom)
    local pts = { { 0, 0 }, { r * 0.6, 0 }, { -r * 0.6, 0 }, { 0, r * 0.6 }, { 0, -r * 0.6 } }
    for _, d in ipairs(pts) do
        local from = util.vector3(pos.x + d[1], pos.y + d[2], top)
        local to = util.vector3(pos.x + d[1], pos.y + d[2], bottom)
        local res = nearby.castRay(from, to, { collisionType = nearby.COLLISION_TYPE.World, ignore = placing.obj })
        local o = res.hit and res.hitObject
        if o and not (placing.obj and o.id == placing.obj.id) and o.type ~= types.NPC and o.type ~= types.Creature then
            local okName, rec = pcall(function() return o.type.record(o) end)
            local name = okName and rec and rec.name
            return (name and name ~= '') and name or o.recordId
        end
    end
end

local function validate(pos, dt)
    local r, height = ghostSize()
    placing.radius = r
    local heights = {}
    for _, d in ipairs(terrain.samplePoints(r)) do
        heights[#heights + 1] = groundHeight(pos.x + d[1], pos.y + d[2])
    end
    local a = terrain.analyze(heights, height)
    placing.analysis = a
    if not a.ok then return false, a.reason end
    if snap.storePos and dist2d(pos, snap.storePos) > COLONY_RADIUS then
        return false, 'too far from the storehouse'
    end
    for _, s in ipairs(snap.sites or {}) do
        if dist2d(pos, s.pos) < (s.radius + r) * 0.75 then
            return false, 'too close to the ' .. s.name
        end
    end
    -- the slower checks run a few times per second
    placing.checkT = (placing.checkT or 0) - dt
    if placing.checkT <= 0 then
        placing.checkT = 0.3
        placing.blocker = obstruction(pos, r, a.high + 800, a.low - 50)
        -- walkable ground next to the footprint (catches water, cliffs, islands)
        local ok, nav = pcall(nearby.findNearestNavMeshPosition, pos,
            { searchAreaHalfExtents = util.vector3(r + 400, r + 400, 600) })
        placing.reachable = (not ok) or (nav ~= nil and dist2d(nav, pos) < r + 400)
    end
    if placing.blocker then return false, 'something is in the way (' .. placing.blocker .. ')' end
    if not placing.reachable then return false, 'workers cannot walk there' end
    return true
end

local function updatePlacing(dt)
    if input.isKeyPressed(input.KEY.Z) then placing.yaw = placing.yaw - ROTATE_SPEED * dt end
    if input.isKeyPressed(input.KEY.X) then placing.yaw = placing.yaw + ROTATE_SPEED * dt end

    local d = defs.buildings[placing.kind]
    local hit = aimAtGround()
    local extra
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
        placing.valid, placing.reason = false, 'look at open ground'
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
    local lines = {
        text('Placing: ' .. d.name .. '   (' .. costText(d.cost) .. ')', nil, true),
        text('Z / X rotate     Enter place     Backspace cancel'),
    }
    if extra then lines[#lines + 1] = text(extra) end
    lines[#lines + 1] = text(placing.valid and 'Good spot' or ('Cannot build: ' .. (placing.reason or '')), nil, not placing.valid)
    setHud(lines)
end

---------------------------------------------------------------------------
-- floating progress labels above nearby construction sites

local LABEL_RANGE = 2500
local labels, labelT = nil, 0
local debugOn = defs.debug
local labelLogT = 0

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

local function updateLabels(dt)
    labelT = labelT - dt
    if labelT > 0 then return end
    labelT = 0.1
    if not snap.founded or ledger or placing or I.UI.getMode() then return clearLabels() end
    local screen = ui.screenSize()
    local cam = camera.getPosition()
    local items = {}
    for _, site in ipairs(snap.sites or {}) do
        if not site.built and (site.pos - cam):length() < LABEL_RANGE then
            local v = camera.worldToViewportVector(site.pos + util.vector3(0, 0, 250))
            labelLogT = labelLogT - 0.1
            if debugOn and labelLogT <= 0 then
                labelLogT = 2
                print(string.format('[Tomorrowind] label %s: dist=%.0f viewport=%s screen=%s', site.name,
                    (site.pos - cam):length(), tostring(v), tostring(screen)))
            end
            local x, y = v.x, v.y
            if math.abs(x) <= 1.5 and math.abs(y) <= 1.5 then x, y = x * screen.x, y * screen.y end
            if v.z > 0 and x > 0 and x < screen.x and y > 0 and y < screen.y then
                -- keep the label readable near the screen edges
                x = math.max(160, math.min(screen.x - 160, x))
                y = math.max(90, y)
                items[#items + 1] = {
                    template = T.boxTransparent,
                    props = { position = v2(x, y), anchor = v2(0.5, 1) },
                    content = ui.content({ { template = T.padding, content = ui.content({ col(progressLines(site)) }) } }),
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

return {
    engineHandlers = {
        onKeyPress = function(key)
            if placing then
                if key.code == input.KEY.Enter or key.code == input.KEY.NP_Enter then
                    stopPlacing(true)
                elseif key.code == input.KEY.Backspace then
                    stopPlacing(false)
                end
                return
            end
            if key.code == LEDGER_KEY then
                if ledger then
                    closeLedger()
                elseif not I.UI.getMode() then
                    openLedger()
                end
            end
        end,
        onUpdate = function(dt)
            if placing and dt > 0 then updatePlacing(dt) end
            if dt > 0 then updateLabels(dt) end
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
            if placing and placing.kind == e.kind then placing.obj = e.obj end
        end,
        TMW_OpenWorker = function(e)
            focusWorker = e.wid
            openLedger('workers')
        end,
        TMW_OpenSite = function(e)
            focusSite = e.sid
            openLedger('overview')
        end,
        -- debug hooks (used by the scripted playtest)
        TMW_DebugLedger = function(e)
            if e.open then openLedger(e.tab) else closeLedger() end
        end,
        TMW_DebugPlace = function(e)
            if e.kind then
                startPlacing(e.kind)
                placing.forcedAim = e.at
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
