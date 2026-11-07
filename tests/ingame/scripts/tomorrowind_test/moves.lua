-- Dev-only: demolishing (salvage piles carried back) and moving buildings.
-- Run: TEST_CONTENT=moves.omwscripts SHOTS="" tools/playtest.sh <out> Pelagiad
local core = require('openmw.core')
local camera = require('openmw.camera')
local util = require('openmw.util')
local self = require('openmw.self')
local types = require('openmw.types')
local debug = require('openmw.debug')
local I = require('openmw.interfaces')
local v3 = util.vector3
local VILLAGE = v3(-2504, -55848, 1300)
local t, snap, done = 0, nil, {}
local function log(...) print('[TMW-MOVE]', ...) end
local function once(k, at, fn) if not done[k] and t >= at then done[k] = true; local ok, e = pcall(fn); if not ok then log('ERROR', k, e) end end end
local function dbg(e) core.sendGlobalEvent('TMW_Debug', e) end
local function shot(k) log('shot', k); debug.takeScreenshot() end
local function land(dx, dy) local p = v3(VILLAGE.x + dx, VILLAGE.y + dy, 0); return v3(p.x, p.y, core.land.getHeightAt(p, self.cell)) end
local function site(kind) for _, s in ipairs(snap.sites) do if s.kind == kind then return s end end end
local function view(from, at)
    camera.setMode(camera.MODE.Static)
    camera.setStaticPosition(from)
    local d = at - from
    camera.setYaw(math.atan2(d.x, d.y))
    camera.setPitch(math.atan2(from.z - at.z, util.vector2(d.x, d.y):length()))
end
local function stock() return string.format('wood=%d ore=%d ingot=%d', snap.stock.wood, snap.stock.ore, snap.stock.ingot) end
return { engineHandlers = { onUpdate = function(dt)
    t = t + dt
    local hp = types.Actor.stats.dynamic.health(self)
    if hp.current < hp.base then hp.current = hp.base end
    once('ui', 1, function() I.Camera.disableModeControl('moves'); dbg({ cmd = 'tp', pos = VILLAGE + v3(0, -600, 1000), lookAt = VILLAGE }) end)
    once('found', 3.5, function() core.sendGlobalEvent('TMW_Found', { yaw = 0, pos = land(0, 0) }) end)
    once('setup', 5, function()
        dbg({ cmd = 'debug', on = true })
        dbg({ cmd = 'give', amounts = { food = 120, wood = 60, ore = 40, ingot = 20 } })
        dbg({ cmd = 'spawn', n = 4 })
        dbg({ cmd = 'build', kind = 'smelter', pos = land(-900, -700), built = true })
        dbg({ cmd = 'build', kind = 'house', variant = 2, pos = land(900, -900), built = true })
        dbg({ cmd = 'build', kind = 'mine', pos = land(-1300, 600), built = true })
    end)
    -- demolish the smelter: a pile is left and carried back
    once('demolish', 9, function()
        log('before demolishing:', stock())
        dbg({ cmd = 'removekind', kind = 'smelter' })
    end)
    once('pileview', 10, function() local s = land(-900, -700); view(s + v3(-250, -420, 260), s) end)
    once('pileshot', 11.5, function()
        local p = site('salvage')
        log('pile:', p and p.name, p and p.status, 'stock', stock())
        shot('salvage pile')
    end)
    if t > 9 and t < 40 and (done.nextStock or 0) < t then
        done.nextStock = t + 3
        local p = site('salvage')
        log('stock', math.floor(t), stock(), 'pile', p and p.status or 'gone', 'capacity', snap.capacity)
    end
    once('pilelater', 40, function()
        local p = site('salvage')
        log('after 30s: pile', p and p.status or 'gone', 'stock', stock())
    end)
    -- move the house, through the real placement path
    once('placemove', 41, function() self:sendEvent('TMW_DebugPlace', { move = 'house', at = land(1500, 300), yaw = 1.2 }) end)
    once('moveview', 41.5, function() view(land(1200, -300) + v3(-1400, -1500, 1300), land(1200, -300) + v3(0, 0, 100)) end)
    once('placeshot', 43, function() shot('placing the move') end)
    once('confirm', 43.5, function() self:sendEvent('TMW_DebugPlace', { confirm = true }) end)
    once('movelog', 45, function()
        local m = site('move')
        log('move site:', m and m.name, m and m.status)
    end)
    for i, p in ipairs({ 0, 0.25, 0.5, 0.75, 0.95 }) do
        once('step' .. i, 46 + i * 6, function() dbg({ cmd = 'sitestate', kind = 'move', delivered = 1, progress = p }) end)
        once('mshot' .. i, 49 + i * 6, function()
            local m = site('move')
            local h = site('house')
            log('progress', p, m and m.status or 'done', 'house object at', h.obj.position)
            shot('moving ' .. p)
        end)
    end
    once('finish', 86, function() dbg({ cmd = 'finish' }) end)
    once('after', 89, function()
        local h = site('house')
        log('house now at', h.pos, 'yaw', h.yaw, h.status, 'move left:', site('move') and 'yes' or 'no')
        dbg({ cmd = 'doorinfo' })
        shot('moved')
    end)
    -- a move cancelled halfway: back where it was
    once('move2', 91, function() dbg({ cmd = 'move', kind = 'mine', pos = land(-500, 1200), yaw = 0.5 }) end)
    once('half', 92, function() dbg({ cmd = 'sitestate', kind = 'move', delivered = 1, progress = 0.5 }) end)
    once('cancel', 95, function()
        log('mine during its move', site('mine').obj.position)
        dbg({ cmd = 'removekind', kind = 'move' })
    end)
    once('cancelled', 97, function()
        local m = site('mine')
        log('mine after cancelling', m.obj.position, 'site pos', m.pos, 'salvage', site('salvage') and site('salvage').status or 'none')
        log('done')
        core.quit()
    end)
end }, eventHandlers = { TMW_State = function(s) snap = s end } }
