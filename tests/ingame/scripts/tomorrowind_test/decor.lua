-- Dev-only: stairs, walkways and a rope bridge between roofs; rugs, wall
-- hangings, candles and a shrine inside a house. All through placement.
-- Run: TEST_CONTENT=decor.omwscripts SHOTS="" tools/playtest.sh <out> Pelagiad
local core = require('openmw.core')
local camera = require('openmw.camera')
local util = require('openmw.util')
local self = require('openmw.self')
local types = require('openmw.types')
local nearby = require('openmw.nearby')
local debug = require('openmw.debug')
local I = require('openmw.interfaces')
local v3 = util.vector3
local VILLAGE = v3(-2504, -55848, 1300)
local t, snap, done = 0, nil, {}
local function log(...) print('[TMW-DECOR]', ...) end
local function once(k, at, fn) if not done[k] and t >= at then done[k] = true; local ok, e = pcall(fn); if not ok then log('ERROR', k, e) end end end
local function dbg(e) core.sendGlobalEvent('TMW_Debug', e) end
local function shot(k) log('shot', k, 't=', t); debug.takeScreenshot() end
local function land(dx, dy) local p = v3(VILLAGE.x + dx, VILLAGE.y + dy, 0); return v3(p.x, p.y, core.land.getHeightAt(p, self.cell)) end
local function view(from, at)
    camera.setMode(camera.MODE.Static)
    camera.setStaticPosition(from)
    local d = at - from
    camera.setYaw(math.atan2(d.x, d.y))
    camera.setPitch(math.atan2(from.z - at.z, util.vector2(d.x, d.y):length()))
end
local function roofAt(p)
    local r = nearby.castRay(p + v3(0, 0, 3000), p - v3(0, 0, 200), { collisionType = nearby.COLLISION_TYPE.World })
    return r.hit and r.hitPos or p
end
local function place(key, at, e)
    once(key, at, function() self:sendEvent('TMW_DebugPlace', e()) end)
    once(key .. 'c', at + 1, function() self:sendEvent('TMW_DebugPlace', { confirm = true }) end)
end
local H1, H2 = { 900, 600 }, { 900, -500 }
return { engineHandlers = { onUpdate = function(dt)
    t = t + dt
    local hp = types.Actor.stats.dynamic.health(self)
    if hp.current < hp.base then hp.current = hp.base end
    once('ui', 1, function() I.Camera.disableModeControl('decor'); dbg({ cmd = 'tp', pos = VILLAGE + v3(0, -600, 1000), lookAt = VILLAGE }) end)
    once('found', 3.5, function() core.sendGlobalEvent('TMW_Found', { yaw = 0, pos = land(0, 0) }) end)
    once('setup', 5, function()
        dbg({ cmd = 'debug', on = true })
        dbg({ cmd = 'give', amounts = { wood = 140, ore = 60 }, gold = 2000 })
        dbg({ cmd = 'build', kind = 'house', variant = 4, pos = land(H1[1], H1[2]), built = true })
        dbg({ cmd = 'build', kind = 'house', variant = 4, pos = land(H2[1], H2[2]), built = true })
    end)
    -- stairs up to the first house's roof edge, on the ground
    place('stairs', 7, function() return { kind = 'stairs', variant = 4, at = land(H1[1] - 700, H1[2]), yaw = math.pi / 2 } end)
    -- a walkway from one roof towards the other, then a rope bridge alongside
    place('walk1', 9, function()
        local roof = roofAt(land(H1[1], H1[2] - 120))
        log('roof 1 at', roof)
        return { kind = 'walkway', at = roof, yaw = 0 }
    end)
    place('walk2', 11, function() return { kind = 'walkway', at = roofAt(land(H1[1], H1[2] - 120)) + v3(0, -230, 0), yaw = 0 } end)
    place('bridge', 13, function()
        local roof = roofAt(land(H1[1] + 250, H1[2] - 150))
        log('bridge from', roof, 'other roof', roofAt(land(H2[1] + 250, H2[2])))
        return { kind = 'ropebridge', variant = 1, at = roof, yaw = math.pi / 2 }
    end)
    once('finish', 15.5, function() dbg({ cmd = 'finish' }) end)
    once('sites', 17, function()
        for _, s in ipairs(snap.sites) do
            if s.kind == 'walkway' or s.kind == 'ropebridge' or s.kind == 'stairs' then log(s.kind, s.name, s.built, s.pos, 'yaw', s.yaw) end
        end
    end)
    once('v1', 17.5, function() view(land(H1[1] - 1300, 0) + v3(0, 0, 900), land(H1[1], 0) + v3(0, 0, 400)) end)
    once('s1', 19.5, function() shot('roofs from the side') end)
    once('v2', 20, function() view(land(H1[1] - 900, H1[2] - 900) + v3(0, 0, 350), land(H1[1] - 700, H1[2]) + v3(0, 0, 150)) end)
    once('s2', 22, function() shot('stairs') end)
    once('v3', 22.5, function() view(land(H1[1] + 1300, 0) + v3(0, 0, 700), land(H1[1], 0) + v3(0, 0, 400)) end)
    once('s3', 24.5, function() shot('roofs from the other side') end)
    -- inside
    once('in', 25, function() camera.setMode(camera.MODE.FirstPerson); dbg({ cmd = 'enter', at = land(H1[1], H1[2]) }) end)
    local function wallAhead(yaw)
        local from = self.position + v3(0, 0, 130)
        local r = nearby.castRay(from, from + v3(math.sin(yaw), math.cos(yaw), 0) * 900, { collisionType = nearby.COLLISION_TYPE.World })
        return r.hitPos, r.hitNormal
    end
    place('rug', 27, function() return { kind = 'rug', variant = 5, at = self.position + v3(0, 160, 0), yaw = 0 } end)
    place('tap', 29, function()
        local p, n = wallAhead(0)
        log('wall ahead', p, n)
        return { kind = 'tapestry', at = p, normal = n }
    end)
    place('tap2', 31, function()
        local p, n = wallAhead(math.pi / 2)
        return { kind = 'sconce', at = p + v3(0, 0, 40), normal = n }
    end)
    place('crest', 33, function()
        local p, n = wallAhead(-math.pi / 2)
        return { kind = 'crest', at = p + v3(0, 0, 60), normal = n }
    end)
    place('shrine', 35, function() return { kind = 'shrine', at = self.position + v3(120, 260, 0), yaw = math.pi } end)
    place('candle', 37, function() return { kind = 'candle', at = self.position + v3(-90, 120, 0), yaw = 0 } end)
    place('urn', 39, function() return { kind = 'urn', variant = 3, at = self.position + v3(-150, 230, 0), yaw = 0 } end)
    once('inside', 41, function()
        log('treasury', snap.gold)
        for _, s in ipairs(snap.sites) do if s.host then log('inside:', s.name, s.built, s.status) end end
        local p = self.position
        view(p + v3(0, 40, 160), p + v3(0, 300, 40))
    end)
    local KINDS = { 'tapestry', 'crest', 'shrine', 'candle', 'urn', 'sconce' }
    for i, k in ipairs(KINDS) do
        local at = 42 + i * 1.5
        once('look' .. k, at, function()
            for _, st in ipairs(snap.sites) do
                if st.kind == k then
                    local c = self.position + v3(0, 0, 150)
                    local sp = v3(st.pos.x, st.pos.y, st.pos.z)
                    local dir = (sp - c); dir = v3(dir.x, dir.y, 0):normalize()
                    log(k, 'at', sp, 'yaw', st.yaw)
                    view(sp - dir * 160 + v3(0, 0, 60), sp)
                end
            end
        end)
        once('shot' .. k, at + 1, function() shot(k) end)
    end
    once('refund', 53, function()
        dbg({ cmd = 'removekind', kind = 'shrine' })
    end)
    once('refund2', 54, function() log('treasury after removing the shrine', snap.gold); core.quit() end)
end }, eventHandlers = { TMW_State = function(s) snap = s end } }
