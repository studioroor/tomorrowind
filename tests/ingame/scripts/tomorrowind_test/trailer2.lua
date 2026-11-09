-- Dev-only: films the 0.2 trailer, about what's new: trade and caravans, homes
-- you can walk into and furnish, crops, moving and salvaging buildings,
-- stairs and rope bridges. Same machinery as trailer.lua: scripted cameras,
-- every frame saved by the engine. tools/make_trailer.py --cut 0.2 cuts it.
local core = require('openmw.core')
local camera = require('openmw.camera')
local util = require('openmw.util')
local self = require('openmw.self')
local types = require('openmw.types')
local debug = require('openmw.debug')
local nearby = require('openmw.nearby')
local I = require('openmw.interfaces')

local PREVIEW = false -- true: one frame per second of each shot, to check the framing
local ONLY = nil -- e.g. { home = true }: film just these (the others still set up)
local v3 = util.vector3
local FPS = 30
local snap
local frame = 0
local function log(...) print('[TRAILER]', ...) end
local function dbg(e) core.sendGlobalEvent('TMW_Debug', e) end

local VILLAGE = require('scripts.tomorrowind_test.trailer2_set').VILLAGE
local function at(dx, dy) return v3(VILLAGE.x + dx, VILLAGE.y + dy, 0) end
local function land(dx, dy, lift)
    local p = at(dx, dy)
    return v3(p.x, p.y, core.land.getHeightAt(p, self.cell) + (lift or 0))
end
local function lerp(a, b, u) return a + (b - a) * u end
local function ease(u) return u * u * (3 - 2 * u) end
local function site(kind)
    for _, s in ipairs(snap.sites) do if s.kind == kind then return s end end
end
local function siteAt(dx, dy)
    local p = at(dx, dy)
    for _, s in ipairs(snap.sites) do
        if math.abs(s.pos.x - p.x) < 5 and math.abs(s.pos.y - p.y) < 5 then return s end
    end
end
local function roofAt(p)
    local r = nearby.castRay(v3(p.x, p.y, p.z + 3000), v3(p.x, p.y, p.z - 200), { collisionType = nearby.COLLISION_TYPE.World })
    return r.hit and r.hitPos or p
end

local function finder(...)
    local patterns = { ... }
    local function matches(st)
        for _, pat in ipairs(patterns) do if st:find(pat) then return true end end
    end
    local found
    return function()
        if found and found.obj:isValid() then
            for _, w in ipairs(snap.workers) do if w.id == found.id and matches(w.status) then return w end end
        end
        found = nil
        for _, w in ipairs(snap and snap.workers or {}) do
            if matches(w.status) and w.obj and w.obj:isValid() and w.obj.enabled then
                found = w
                return w
            end
        end
    end
end

-- Circling a point: a0, a1 in radians (0 = from the north, pi/2 = from the east).
local function orbit(cx, cy, r0, r1, h0, h1, a0, a1, lookZ)
    return function(u)
        local e = ease(u * 0.5 + 0.25) * 2 - 0.5
        local a, r, h = lerp(a0, a1, e), lerp(r0, r1, e), lerp(h0, h1, e)
        local base = land(cx, cy, 0).z
        return v3(VILLAGE.x + cx + math.sin(a) * r, VILLAGE.y + cy + math.cos(a) * r, base + h), land(cx, cy, lookZ or 100)
    end
end

-- An angle round a point with nothing between the camera and it, near a0.
local function clearAngle(target, r, h, a0)
    local ground = function(p) return core.land.getHeightAt(p, self.cell) end
    for i = 0, 16 do
        local a = a0 + (i % 2 == 0 and 1 or -1) * math.ceil(i / 2) * 0.3
        local cam = target + v3(math.sin(a) * r, math.cos(a) * r, 0)
        cam = v3(cam.x, cam.y, math.max(target.z + h, ground(cam) + 120))
        local hit = nearby.castRay(cam, target, { collisionType = nearby.COLLISION_TYPE.World + nearby.COLLISION_TYPE.HeightMap })
        if not hit.hit or (hit.hitPos - target):length() < 150 then return a end
    end
    return a0
end

-- Slowly round a point that may move, from a clear angle.
local function aroundClear(getTarget, r0, r1, h, a0, turn)
    local base
    return function(u)
        local tg = getTarget()
        if not tg then return nil end
        base = base or clearAngle(tg, (r0 + r1) / 2, h, type(a0) == 'function' and a0() or a0)
        local e = ease(u * 0.5 + 0.25) * 2 - 0.5
        local a, r = base + turn * e, lerp(r0, r1, e)
        local cam = tg + v3(math.sin(a) * r, math.cos(a) * r, 0)
        return v3(cam.x, cam.y, math.max(tg.z + h, core.land.getHeightAt(cam, self.cell) + 120)), tg
    end
end

-- Keeping someone in view: picks an angle with nothing in the way, and swings
-- round smoothly when something gets in between.
local function clearView(find, r, h, start)
    local a, wanted, checkT, lastU
    return function(u)
        local w = find()
        if not w then return nil end
        local c = w.obj.position
        local function camAt(angle) return c + v3(math.sin(angle) * r, math.cos(angle) * r, h) end
        local function clear(angle)
            local res = nearby.castRay(camAt(angle), c + v3(0, 0, 80), { collisionType = nearby.COLLISION_TYPE.World + nearby.COLLISION_TYPE.HeightMap + nearby.COLLISION_TYPE.Actor, ignore = w.obj })
            return not res.hit
        end
        if not a then a, wanted = start or 0.8, start or 0.8 end
        lastU = lastU or u
        checkT = (checkT or 0) - (u - lastU)
        if checkT <= 0 then
            checkT = 0.04
            if not clear(wanted) then
                for i = 1, 8 do
                    local try = wanted + (i % 2 == 0 and 1 or -1) * math.ceil(i / 2) * 0.55
                    if clear(try) then wanted = try break end
                end
            end
        end
        if u == 0 then a = wanted end
        a = a + (wanted - a) * math.min(1, (u - lastU) * 12) + (u - lastU) * 0.35
        wanted = wanted + (u - lastU) * 0.35
        lastU = u
        return camAt(a), c + v3(0, 0, 75)
    end
end

-- At work at a building: waits (returns nothing) until somebody is at it.
local function atWork(find, kind, r, h, turn0, turn1)
    local base
    return function(u)
        local w, b = find(), site(kind)
        if not w or not b then return nil end
        local d = w.obj.position - b.pos
        base = base or math.atan2(d.x, d.y)
        local a = base + lerp(turn0, turn1, u)
        local ground = core.land.getHeightAt(b.pos, self.cell)
        local mid = (w.obj.position + v3(b.pos.x, b.pos.y, w.obj.position.z)) * 0.5
        return v3(b.pos.x + math.sin(a) * r, b.pos.y + math.cos(a) * r, ground + h), v3(mid.x, mid.y, ground + 85)
    end
end

---------------------------------------------------------------------------
-- the village: all there from the start, this trailer is about what's new

local SET = require('scripts.tomorrowind_test.trailer2_set')
local HOME, MOVE_TO = SET.HOME, SET.MOVE_TO

local function assignJobs()
    local ws = snap.workers
    local farms = {}
    for _, s in ipairs(snap.sites) do if s.kind == 'farm' then farms[#farms + 1] = s end end
    local function job(i, target) if ws[i] and target then core.sendGlobalEvent('TMW_Assign', { wid = ws[i].id, target = target.id }) end end
    job(1, site('mine')); job(2, site('smelter')); job(3, site('lumber')); job(4, site('guardpost'))
    for i, f in ipairs(farms) do job(4 + i, f) end
    job(9, site('market'))
end

-- inside: furnish the room around where we came in (positions found in the decor scene)
local function furnishInside()
    local p, host = self.position, snap.insideHost
    log('inside at', p, 'facing', self.rotation:getYaw(), 'host', host)
    local function put(kind, dx, dy, extra)
        local e = { cmd = 'build', kind = kind, pos = p + v3(dx, dy, 0), built = true, host = host, leveled = true }
        for k, v in pairs(extra or {}) do e[k] = v end
        dbg(e)
    end
    local function wall(kind, yaw, up, extra)
        local from = p + v3(0, 0, 130)
        local r = nearby.castRay(from, from + v3(math.sin(yaw), math.cos(yaw), 0) * 900, { collisionType = nearby.COLLISION_TYPE.World })
        if not r.hit then return end
        local n = r.hitNormal
        local e = { cmd = 'build', kind = kind, pos = r.hitPos + n * 5 + v3(0, 0, up),
            yaw = math.atan2(n.x, n.y), built = true, host = host, leveled = true }
        for k, v in pairs(extra or {}) do e[k] = v end
        dbg(e)
    end
    put('rug', 0, 170, { variant = 5 })
    put('shrine', 120, 260, { yaw = math.pi })
    put('lectern', -140, 280, { yaw = 0.6 })
    put('candle', -90, 120)
    put('candle', 70, 330, { variant = 2 })
    put('urn', 170, 120, { variant = 3 })
    put('plant', -170, 100)
    wall('tapestry', 0, 0)
    wall('sconce', math.pi / 2, 40)
end

-- One move across the room: from the lectern over the tapestry to the
-- shrine, edging forward, the camera above the settlers' heads.
local function panRoom()
    return function(u)
        if self.cell.isExterior or not snap.insideHost then return nil end
        local p = self.position
        local e = ease(u)
        local t0, t1, t2 = v3(-150, 270, 70), v3(0, 345, 135), v3(125, 255, 70)
        local look = t0 * (1 - e) ^ 2 + t1 * (2 * e * (1 - e)) + t2 * e ^ 2
        return p + v3(lerp(55, -45, e), lerp(5, 85, e), 185), p + look
    end
end

-- rising up the stairs to the roof (the offsets are for stairs turned a
-- quarter round, climbing east; they turn with the stairs)
local function stairsCam()
    return function(u)
        local st = site('stairs')
        if not st then return nil end
        local base = v3(st.pos.x, st.pos.y, st.pos.z)
        local turn = util.transform.rotateZ((st.yaw or 0) - math.pi / 2)
        local e = ease(u)
        local cam = base + turn * v3(lerp(-650, -250, e), lerp(-520, -380, e), lerp(140, 640, e))
        cam = v3(cam.x, cam.y, math.max(cam.z, core.land.getHeightAt(cam, self.cell) + 130))
        return cam, base + turn * v3(lerp(0, 450, e), 0, lerp(150, 520, e))
    end
end

local function setCtx() return { dbg = dbg, land = land, roofAt = roofAt, log = log } end

---------------------------------------------------------------------------
local SHOTS = {
    -- the village in the morning: the title
    { name = 'open', hour = 9.1, prepare = 12, dur = 7, speed = 1,
      setup = function()
          for _, it in ipairs(SET.village) do
              dbg({ cmd = 'build', kind = it[1], pos = land(it[2], it[3]), variant = it[4], yaw = it[5], built = true })
          end
          dbg({ cmd = 'spawn', n = 12 })
          dbg({ cmd = 'give', gold = 500 })
      end,
      prep = function(s) if not s.assigned and snap and #snap.workers >= 12 then s.assigned = true; assignJobs() end end,
      cam = orbit(-100, -200, 2700, 2550, 1500, 1380, -0.55, -0.3, 60) },
    -- a caravan comes in to the market
    { name = 'caravan', prepare = 4, dur = 10, speed = 1,
      setup = function() dbg({ cmd = 'caravan' }) end,
      -- from the south of the stall, the trader and the guar walking up to it
      cam = function(u)
          local m, tr = site('market'), snap.caravanObj
          if not m or not tr or not tr:isValid() then return nil end
          local cam = land(lerp(430, 380, u), -180, 0)
          cam = v3(cam.x, cam.y, cam.z + lerp(280, 250, u))
          local tp = tr.position
          return cam, v3(tp.x, tp.y, tp.z + 80)
      end },
    -- the stairs up a house, and the rope bridge across to the next roof
    { name = 'stairs', prepare = 5, dur = 5, speed = 1,
      setup = function() SET.buildSet(1, setCtx()) end,
      cam = stairsCam() },
    { name = 'bridge', prepare = 3, dur = 6, speed = 1,
      setup = function() SET.buildSet(2, setCtx()) end,
      -- from the side of the bridge, whichever way it runs
      cam = aroundClear(function()
          local b = site('ropebridge')
          return b and v3(b.pos.x, b.pos.y, b.pos.z - 40)
      end, 1150, 1000, 300, function()
          local b = site('ropebridge')
          return (b and b.yaw or 0) + 0.35
      end, -0.5) },
    -- a house moves to a new spot
    -- (the clock slowed down, or the builders would have it done in a moment)
    { name = 'move', prepare = 3, dur = 9, speed = 1, slow = true,
      setup = function() dbg({ cmd = 'move', kind = 'house', pos = land(MOVE_TO[1], MOVE_TO[2]), yaw = MOVE_TO[3] }) end,
      prep = function() dbg({ cmd = 'sitestate', kind = 'move', delivered = 1, progress = 0.02 }) end,
      during = function(u) dbg({ cmd = 'sitestate', kind = 'move', delivered = 1, progress = 0.02 + ease(u) * 0.96 }) end,
      after = function()
          local m, h = site('move'), siteAt(400, -1000)
          log('move site', m and m.status, 'house', h and h.obj and h.obj.position)
          dbg({ cmd = 'risedump' })
          dbg({ cmd = 'sitestate', kind = 'move', finish = true })
      end,
      cam = aroundClear(function() return land(75, -1225, 150) end, 1450, 1420, 950, -1.0, 0.05) },
    -- evening at home: settlers reading and praying, candles lit
    { name = 'indoors', hour = 20.2, prepare = 6, dur = 8, speed = 1,
      setup = function() dbg({ cmd = 'enter', at = land(HOME[1], HOME[2]) }) end,
      prep = function(s)
          if not s.furnished and not self.cell.isExterior and snap.insideHost then
              s.furnished = true
              furnishInside()
          end
      end,
      cam = panRoom() },
    -- the whole village: title and link
    { name = 'ending', hour = 15, prepare = 8, dur = 9, speed = 1,
      setup = function() dbg({ cmd = 'leave' }) end,
      cam = orbit(-100, -100, 2900, 2750, 1650, 1500, -0.2, 0.25, 60) },
}

---------------------------------------------------------------------------

local stage, shotI, shotT, waited = 'start', 0, 0, 0
local nextFrameAt = 0
local t, skyT = 0, 0
local started = {}
local lastTp

local function setCam(pos, target)
    if not pos then return end
    camera.setStaticPosition(pos)
    local d = target - pos
    camera.setYaw(math.atan2(d.x, d.y))
    camera.setPitch(math.atan2(pos.z - target.z, util.vector2(d.x, d.y):length()))
    -- outdoors the player stands well behind the camera, out of every shot
    if self.cell.isExterior and (not lastTp or util.vector2(pos.x - lastTp.x, pos.y - lastTp.y):length() > 1200) then
        lastTp = pos
        local flat = util.vector2(d.x, d.y):normalize()
        dbg({ cmd = 'tp', pos = v3(pos.x - flat.x * 500, pos.y - flat.y * 500, pos.z + 200), lookAt = pos })
    end
end

local function once(key, at_, fn)
    if not started[key] and t >= at_ then
        started[key] = true
        fn()
    end
end

return {
    engineHandlers = {
        onUpdate = function(dt)
            if dt <= 0 then return end
            t = t + dt
            local hp = types.Actor.stats.dynamic.health(self)
            if hp.current < hp.base then hp.current = hp.base end
            skyT = skyT - dt
            if skyT <= 0 and stage ~= 'start' then
                skyT = 4
                if self.cell.isExterior then
                    core.sendGlobalEvent('TRL_Sky', {})
                    core.sendGlobalEvent('TRL_Clean')
                end
                if snap and snap.founded then
                    local top = {}
                    for res, low in pairs({ food = 80 }) do
                        if (snap.stock[res] or 0) < low then top[res] = low end
                    end
                    dbg({ cmd = 'give', amounts = top })
                end
            end
            if stage == 'start' then
                once('ui', 1, function()
                    I.Camera.disableModeControl('trailer')
                    I.UI.setHudVisibility(false)
                    dbg({ cmd = 'tp', pos = VILLAGE + v3(0, -600, 1000), lookAt = VILLAGE })
                end)
                once('found', 4, function()
                    core.sendGlobalEvent('TMW_Found', { yaw = 0, pos = land(0, 0, 0) })
                    dbg({ cmd = 'quiet', on = true })
                    dbg({ cmd = 'debug', on = true })
                end)
                once('go', 7, function()
                    camera.setMode(camera.MODE.Static)
                    stage, shotI = 'next', 0
                end)
            elseif stage == 'next' then
                shotI = shotI + 1
                local s = SHOTS[shotI]
                if not s then
                    log('done, frames', frame)
                    stage, waited = 'quit', 0
                    return
                end
                if ONLY and not ONLY[s.name] then s.prepare, s.dur = math.min(s.prepare, 3), 0.01 end
                if s.hour then dbg({ cmd = 'hour', hour = s.hour }) end
                if self.cell.isExterior then core.sendGlobalEvent('TRL_Sky', { timeScale = s.slow and 0.01 or 30 }) end
                if s.setup then
                    local ok, err = pcall(s.setup)
                    if not ok then log('setup error', s.name, err) end
                end
                waited, stage = 0, 'prepare'
            elseif stage == 'prepare' then
                local s = SHOTS[shotI]
                waited = waited + dt
                local ok, pos, target = pcall(s.cam, 0)
                if ok and pos then setCam(pos, target) end
                if s.prep then
                    local okP, err = pcall(s.prep, s)
                    if not okP then log('prep error', s.name, err) end
                end
                if waited >= s.prepare then
                    if not (ok and pos) and waited < s.prepare + 40 and not (ONLY and not ONLY[s.name]) then return end -- nobody doing it yet
                    log('shot', s.name, 'from', frame + 1, 'at', core.getRealTime(), 'found', tostring(ok and pos ~= nil))
                    if s.timeScale then core.sendGlobalEvent('TRL_Sky', { timeScale = s.timeScale }) end
                    shotT, stage, nextFrameAt = 0, 'film', 0
                end
            elseif stage == 'film' then
                local s = SHOTS[shotI]
                shotT = shotT + dt
                local u = math.min(1, shotT / s.dur)
                local ok, pos, target = pcall(s.cam, u)
                if ok and pos then setCam(pos, target) elseif not ok then log('camera error', pos) end
                if s.during then
                    local okD, err = pcall(s.during, u, s)
                    if not okD then log('during error', err) end
                end
                if shotT >= s.dur then
                    local counts = {}
                    for _, w in ipairs(snap.workers) do
                        local k = (w.status or ''):gsub(' .*', '')
                        counts[k] = (counts[k] or 0) + 1
                    end
                    local parts = {}
                    for k, n in pairs(counts) do parts[#parts + 1] = k .. '=' .. n end
                    log('shot', s.name, 'to', frame, 'hour', snap and snap.hour, 'settlers', table.concat(parts, ' '))
                    if s.after then
                        local okA, err = pcall(s.after)
                        if not okA then log('after error', err) end
                    end
                    stage = 'next'
                end
            elseif stage == 'quit' then
                waited = waited + dt
                if waited > 3 then core.quit() end
            end
        end,
        onFrame = function()
            if stage ~= 'film' then return end
            local s = SHOTS[shotI]
            if ONLY and not ONLY[s.name] then return end
            if shotT >= nextFrameAt then
                nextFrameAt = nextFrameAt + (PREVIEW and 1 or (s.speed or 1) / FPS)
                frame = frame + 1
                debug.takeScreenshot()
            end
        end,
    },
    eventHandlers = { TMW_State = function(s) snap = s end },
}
