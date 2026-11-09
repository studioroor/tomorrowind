-- Dev-only: furnishings move at once (no scaffolds, no cost): a rope bridge
-- and a bought candle, moved through the real placement path.
-- Run: TEST_CONTENT=relocate.omwscripts SHOTS="" tools/playtest.sh <out> Pelagiad
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
local function log(...) print('[TMW-RELOC]', ...) end
local function once(k, at, fn) if not done[k] and t >= at then done[k] = true; local ok, e = pcall(fn); if not ok then log('ERROR', k, e) end end end
local function dbg(e) core.sendGlobalEvent('TMW_Debug', e) end
local function land(dx, dy) local p = v3(VILLAGE.x + dx, VILLAGE.y + dy, 0); return v3(p.x, p.y, core.land.getHeightAt(p, self.cell)) end
local function site(kind) for _, s in ipairs(snap.sites) do if s.kind == kind then return s end end end
local function view(from, at)
    camera.setMode(camera.MODE.Static)
    camera.setStaticPosition(from)
    local d = at - from
    camera.setYaw(math.atan2(d.x, d.y))
    camera.setPitch(math.atan2(from.z - at.z, util.vector2(d.x, d.y):length()))
end
local function place(key, at, e)
    once(key, at, function() self:sendEvent('TMW_DebugPlace', e()) end)
    once(key .. 'c', at + 1, function() self:sendEvent('TMW_DebugPlace', { confirm = true }) end)
end
local function report(label)
    local b, c = site('ropebridge'), site('candle')
    log(label, 'bridge', b and b.pos, b and b.yaw, b and b.obj and b.obj.position, '| candle', c and c.pos, c and c.obj and c.obj.position,
        '| gold', snap.gold, 'wood', snap.stock.wood, '| sites', #snap.sites)
end
return { engineHandlers = { onUpdate = function(dt)
    t = t + dt
    local hp = types.Actor.stats.dynamic.health(self)
    if hp.current < hp.base then hp.current = hp.base end
    once('ui', 1, function() I.Camera.disableModeControl('reloc'); dbg({ cmd = 'tp', pos = VILLAGE + v3(0, -600, 1000), lookAt = VILLAGE }) end)
    once('found', 3.5, function() core.sendGlobalEvent('TMW_Found', { yaw = 0, pos = land(0, 0) }) end)
    once('setup', 5, function()
        dbg({ cmd = 'debug', on = true })
        dbg({ cmd = 'give', amounts = { wood = 100 }, gold = 500 })
        dbg({ cmd = 'build', kind = 'house', variant = 4, pos = land(-700, 300), built = true })
    end)
    place('bridge', 6, function() return { kind = 'ropebridge', at = land(600, -300), yaw = 0 } end)
    place('candle', 8, function() return { kind = 'candle', at = land(500, 200), yaw = 0 } end)
    once('finish', 10, function() dbg({ cmd = 'finish' }) end)
    once('before', 11.5, function()
        report('before')
        view(land(800, -1300) + v3(0, 0, 700), land(800, -150) + v3(0, 0, 50))
    end)
    once('s1', 13, function() debug.takeScreenshot() end)
    place('mvbridge', 14, function() return { move = 'ropebridge', at = land(600, -700), yaw = 0.6 } end)
    place('mvcandle', 16, function() return { move = 'candle', at = land(900, 200), yaw = 0 } end)
    once('after', 18.5, function() report('after') end)
    once('s2', 19.5, function() debug.takeScreenshot() end)
    -- what you see when you look at them: the hover label offers M
    once('lookb', 21, function()
        local b = site('ropebridge')
        local p = v3(b.obj.position.x, b.obj.position.y, b.obj.position.z)
        view(p + v3(-150, -150, 450), p)
    end)
    once('s3', 23, function() debug.takeScreenshot() end)
    once('lookh', 23.5, function()
        local h = site('house')
        local p = v3(h.pos.x, h.pos.y, h.pos.z + 150)
        view(p + v3(0, -800, 150), p)
    end)
    once('s4', 25.5, function() debug.takeScreenshot() end)
    -- a bridge resting on a house doesn't stop the house moving
    once('restbridge', 27, function()
        local h = site('house')
        dbg({ cmd = 'build', kind = 'ropebridge', pos = v3(h.pos.x + 300, h.pos.y, h.pos.z + 330), yaw = 0, built = true, leveled = true })
    end)
    place('mvhouse', 29, function() local h = site('house'); return { move = 'house', at = v3(h.pos.x + 60, h.pos.y + 40, h.pos.z), yaw = 0.1 } end)
    once('mvhouselog', 31, function()
        local m = site('move')
        log('house move under the bridge:', m and m.status or 'no move site (refused)')
        dbg({ cmd = 'finish' })
    end)
    -- free placement (staging): a house right on top of another one
    once('free', 32, function() self:sendEvent('TMW_DebugFree', true) end)
    place('overlap', 33, function()
        local h = site('house')
        return { kind = 'house', variant = 2, at = v3(h.pos.x + 100, h.pos.y, h.pos.z), yaw = 0, raise = 900 }
    end)
    once('overlaplog', 35, function()
        local n, zs = 0, {}
        for _, s_ in ipairs(snap.sites) do if s_.kind == 'house' then n = n + 1; zs[#zs + 1] = string.format('%.0f', s_.pos.z) end end
        log('houses after free placement:', n, 'floors at', table.concat(zs, ' '))
    end)
    once('quit', 36, function() core.quit() end)
end }, eventHandlers = { TMW_State = function(s) snap = s end } }
