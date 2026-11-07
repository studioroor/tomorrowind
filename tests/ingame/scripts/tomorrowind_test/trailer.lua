-- Dev-only: films the trailer. A village that grows through a day, seen from
-- scripted cameras; every frame is saved by the engine (no screen recording).
-- tools/make_trailer.py runs this and turns the frames into the video.
local core = require('openmw.core')
local camera = require('openmw.camera')
local util = require('openmw.util')
local self = require('openmw.self')
local types = require('openmw.types')
local debug = require('openmw.debug')
local nearby = require('openmw.nearby')
local I = require('openmw.interfaces')

local v3 = util.vector3
local FPS = 30
local VILLAGE = v3(-2504, -55848, 1300) -- the meadow: see the scout scene's map
local snap
local frame = 0
local function log(...) print('[TRAILER]', ...) end
local function dbg(e) core.sendGlobalEvent('TMW_Debug', e) end

local function at(dx, dy)
    return v3(VILLAGE.x + dx, VILLAGE.y + dy, 0)
end
local function land(dx, dy, lift)
    local p = at(dx, dy)
    return v3(p.x, p.y, core.land.getHeightAt(p, self.cell) + (lift or 0))
end
local function lerp(a, b, u) return a + (b - a) * u end
local function ease(u) return u * u * (3 - 2 * u) end

local function site(kind)
    for _, s in ipairs(snap.sites) do if s.kind == kind then return s end end
end

-- The settler currently doing something, kept once found so the camera stays on them.
local function finder(pattern)
    local found
    return function()
        if found and found.obj:isValid() then return found end
        for _, w in ipairs(snap and snap.workers or {}) do
            if w.status:find(pattern) and w.obj and w.obj:isValid() and w.obj.enabled then
                found = w
                return w
            end
        end
    end
end

-- Circling a point: a0, a1 in radians (0 = from the north, pi/2 = from the east).
local function orbit(cx, cy, r0, r1, h0, h1, a0, a1, lookZ)
    return function(u)
        local e = ease(u * 0.5 + 0.25) * 2 - 0.5 -- never quite standing still
        local a, r, h = lerp(a0, a1, e), lerp(r0, r1, e), lerp(h0, h1, e)
        local base = land(cx, cy, 0).z
        return v3(VILLAGE.x + cx + math.sin(a) * r, VILLAGE.y + cy + math.cos(a) * r, base + h), land(cx, cy, lookZ or 100)
    end
end

local function track(fromA, fromB, targetA, targetB)
    return function(u)
        local e = u
        return lerp(fromA(), fromB(), e), lerp(targetA(), targetB(), e)
    end
end

-- Beside a settler, slowly moving around them.
local function follow(find, dist, a0, a1, up, lookUp)
    return function(u)
        local w = find()
        if not w then return nil end
        local p = w.obj.position
        local a = lerp(a0, a1, u)
        return p + v3(math.sin(a) * dist, math.cos(a) * dist, up), p + v3(0, 0, lookUp or 90)
    end
end

-- Slowly around a building of the colony.
local function around(kind, r, h, a0, a1, lookZ)
    return function(u)
        local b = site(kind)
        if not b then return nil end
        local a = lerp(a0, a1, u)
        local ground = core.land.getHeightAt(b.pos, self.cell)
        return v3(b.pos.x + math.sin(a) * r, b.pos.y + math.cos(a) * r, ground + h), v3(b.pos.x, b.pos.y, ground + lookZ)
    end
end

-- At work at a building: from the side, both the worker and the building in
-- view; waits (returns nothing) until somebody is actually at it.
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
            local res = nearby.castRay(camAt(angle), c + v3(0, 0, 80), { collisionType = nearby.COLLISION_TYPE.World + nearby.COLLISION_TYPE.HeightMap, ignore = w.obj })
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

---------------------------------------------------------------------------
-- the village, in the order it goes up

-- kind, dx, dy, variant, yaw
local WAVE1 = {
    { 'lumber', -1200, -1400 }, { 'farm', -1600, -1000 }, { 'mine', 1200, -1400 },
    { 'house', -1000, 900, 2, 3.14 }, { 'smelter', 800, -200 }, { 'house', 500, 900, 5, 3.14 },
}
local WAVE2 = {
    { 'campfire', -750, -50 }, { 'house', -1700, -100, 4, 1.57 }, { 'tent', 1450, 450 },
    { 'house', 400, -1000, 3, 0 }, { 'bookshelf', -500, 200 }, { 'table', -1000, 100 },
    { 'house', 2000, -800, 6, -1.57 }, { 'guardpost', 200, -600 }, { 'stockade', -100, -2200 },
}
-- comes with the second wave, without construction
local SMALL = {
    { 'bench', -900, -220 }, { 'chair', -620, -250 }, { 'chest', -350, 170 }, { 'lamppost', -500, -180 },
    { 'lantern', -1050, -120 }, { 'lantern', -1000, 280 }, { 'bed', 1150, -700 }, { 'bedroll', 1400, -730 },
    { 'lantern', 1010, -600 }, { 'lantern', 1560, -620 }, { 'lantern', 700, 300 }, { 'lantern', -200, -500 }, { 'lamppost', 1000, 200 },
}

local function runWave(wave, u)
    -- each building: materials, then it rises, overlapping with the next
    local span = 1.6 / (#wave + 0.6)
    for i, it in ipairs(wave) do
        local start = (i - 1) * span * 0.6
        local p = (u - start) / span
        if p >= 0 then
            local pos = at(it[2], it[3])
            if not it.placed then
                it.placed = true
                dbg({ cmd = 'build', kind = it[1], pos = land(it[2], it[3]), variant = it[4], yaw = it[5], built = false })
            elseif not it.done then
                if p >= 1 then
                    it.done = true
                    dbg({ cmd = 'sitestate', at = pos, finish = true })
                else
                    dbg({ cmd = 'sitestate', at = pos, delivered = math.min(1, p * 4), progress = math.max(0, (p - 0.25) / 0.75) * 0.99 })
                end
            end
        end
    end
end

local function finishWave(wave)
    for _, it in ipairs(wave) do
        if not it.placed then
            it.placed = true
            dbg({ cmd = 'build', kind = it[1], pos = land(it[2], it[3]), variant = it[4], yaw = it[5], built = true })
        elseif not it.done then
            it.done = true
            dbg({ cmd = 'sitestate', at = at(it[2], it[3]), finish = true })
        end
    end
end

local function assignJobs()
    local ws = snap.workers
    local function job(i, kind)
        if ws[i] and site(kind) then core.sendGlobalEvent('TMW_Assign', { wid = ws[i].id, target = site(kind).id }) end
    end
    job(1, 'mine'); job(2, 'mine'); job(3, 'smelter'); job(4, 'lumber'); job(5, 'farm'); job(6, 'guardpost'); job(7, 'guardpost')
    job(8, 'farm'); job(9, 'lumber')
end

local RISE = { 900, 2000 }
local FIGHT = { -1750, 700 }
local WALL = { 800, 1400, 0 }
local wallPieces = 0
local function placeWall()
    local half, bend = 126, 0.22
    wallPieces = wallPieces + 1
    local x, y, yaw = WALL[1], WALL[2], WALL[3]
    for _ = 2, wallPieces do
        local a1 = util.transform.rotateZ(yaw) * v3(1, 0, 0)
        yaw = yaw + bend
        local a2 = util.transform.rotateZ(yaw) * v3(1, 0, 0)
        x, y = x + (a1.x + a2.x) * half, y + (a1.y + a2.y) * half
    end
    dbg({ cmd = 'build', kind = 'wall', pos = land(x, y), yaw = yaw, built = true })
end

---------------------------------------------------------------------------
-- speed: game seconds per video second; timeScale: how fast the sun moves
local SHOTS = {
    -- one storehouse in an empty meadow: the title goes here
    { name = 'dawn', hour = 9.1, prepare = 6, dur = 7, speed = 1,
      cam = orbit(-200, -100, 2600, 2450, 1450, 1350, 0.75, 0.5, 60) },
    -- the first buildings go up
    { name = 'growth1', prepare = 1, dur = 44, speed = 5, timeScale = 200, setup = function() dbg({ cmd = 'spawn', n = 4 }) end,
      during = function(u, s)
          runWave(WAVE1, u)
          if u > 0.5 and not s.more then s.more = true; dbg({ cmd = 'spawn', n = 3 }) end
      end,
      cam = orbit(-200, -200, 2450, 2250, 1350, 1150, 0.5, -0.15, 70) },
    -- a house coming up, close: builders swinging, materials used up
    { name = 'rise', hour = 11.7, prepare = 10, dur = 12, speed = 2, setup = function()
          finishWave(WAVE1)
          assignJobs()
          dbg({ cmd = 'build', kind = 'house', pos = land(RISE[1], RISE[2]), variant = 4, yaw = 3.14, built = false })
      end,
      prep = function() dbg({ cmd = 'sitestate', at = at(RISE[1], RISE[2]), delivered = 1, progress = 0 }) end,
      during = function(u) dbg({ cmd = 'sitestate', at = at(RISE[1], RISE[2]), delivered = 1, progress = 0.01 + u * 0.97 }) end,
      after = function() dbg({ cmd = 'sitestate', at = at(RISE[1], RISE[2]), finish = true }) end,
      cam = orbit(RISE[1], RISE[2], 1300, 1150, 800, 700, 0.2, -0.2, 200) },
    { name = 'miner', prepare = 3, dur = 5, speed = 1, cam = atWork(finder('^Miner at'), 'mine', 400, 170, 1.0, 1.35) },
    { name = 'smelter', prepare = 3, dur = 5, speed = 1, cam = atWork(finder('^Smelter at'), 'smelter', 400, 165, 0.9, 1.25) },
    { name = 'carry', prepare = 1, dur = 5, speed = 1, cam = follow(finder('^Carrying Timber'), 300, 2.0, 2.6, 140, 85) },
    -- the village doubles, the sun moving on
    { name = 'growth2', hour = 12.2, prepare = 2, dur = 48, speed = 6, timeScale = 200, setup = function() dbg({ cmd = 'spawn', n = 5 }) end,
      during = function(u)
          runWave(WAVE2, u)
          while wallPieces < math.min(6, math.floor(u * 9)) do placeWall() end
      end,
      after = function()
          finishWave(WAVE2)
          for _, it in ipairs(SMALL) do dbg({ cmd = 'build', kind = it[1], pos = land(it[2], it[3]), built = true }) end
          assignJobs()
      end,
      cam = orbit(0, -100, 2550, 2400, 1400, 1200, -0.15, 0.8, 60) },
    -- evening at the campfire, the camera drifting through the square
    { name = 'campfire', hour = 18.5, prepare = 12, dur = 7, speed = 1,
      cam = track(function() return land(-1350, -650, 280) end, function() return land(-1000, -760, 240) end,
          function() return land(-780, -40, 60) end, function() return land(-700, -40, 60) end) },
    -- dusk over the village
    { name = 'dusk', hour = 18.9, prepare = 4, dur = 8, speed = 1,
      cam = orbit(-100, 0, 2300, 2100, 1200, 1050, -0.1, 0.2, 80) },
    -- asleep: on beds, lanterns burning
    { name = 'sleep', hour = 22.9, prepare = 42, dur = 6, speed = 1,
      cam = track(function() return land(1180, -330, 190) end, function() return land(1290, -340, 170) end,
          function() return land(1260, -710, 30) end, function() return land(1290, -710, 30) end) },
    -- attacked!
    { name = 'attack', hour = 10.5, prepare = 2, dur = 14, speed = 1, setup = function()
          -- on open ground: the guards there, attackers coming at them
          local n = 0
          for _, w in ipairs(snap.workers) do
              if w.job:find('^Guard') then
                  n = n + 1
                  dbg({ cmd = 'movew', wid = w.id, pos = land(FIGHT[1] + n * 90, FIGHT[2], 30) })
              end
          end
          dbg({ cmd = 'hostile', pos = land(FIGHT[1] - 260, FIGHT[2] + 160, 40), alarm = true })
          dbg({ cmd = 'hostile', pos = land(FIGHT[1] + 300, FIGHT[2] + 220, 40), alarm = true })
      end,
      cam = clearView(finder('^Fighting'), 520, 210, -2.3) },
    -- the whole village, late afternoon: title and link
    { name = 'ending', hour = 13, prepare = 14, dur = 9, speed = 1,
      cam = orbit(-100, -100, 2800, 2650, 1600, 1450, -0.15, 0.3, 60) },
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
    -- the player stands well behind the camera, out of every shot
    if not lastTp or util.vector2(pos.x - lastTp.x, pos.y - lastTp.y):length() > 1200 then
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
                core.sendGlobalEvent('TRL_Sky', {})
                if (shotI or 0) < 12 then core.sendGlobalEvent('TRL_Clean') end
                -- only what's short: a full storehouse stops production
                if snap and snap.founded then
                    local top = {}
                    for res, low in pairs({ food = 60, wood = 40, ore = 30, ingot = 15 }) do
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
                if s.hour then dbg({ cmd = 'hour', hour = s.hour }) end
                if snap and snap.workers then
                    local counts = {}
                    for _, w in ipairs(snap.workers) do
                        local k = w.status:gsub(' .*', '')
                        counts[k] = (counts[k] or 0) + 1
                    end
                    local parts = {}
                    for k, n in pairs(counts) do parts[#parts + 1] = k .. '=' .. n end
                    log('settlers', #snap.workers, table.concat(parts, ' '), 'stock', snap.stock.food, snap.stock.wood)
                end
                core.sendGlobalEvent('TRL_Sky', { timeScale = 30 })
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
                if s.prep then pcall(s.prep) end
                if waited >= s.prepare then
                    if not (ok and pos) and waited < s.prepare + 40 then return end -- nobody doing it yet
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
                    log('shot', s.name, 'to', frame, 'hour', snap and snap.hour)
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
            -- one frame per 1/30 s of video
            if shotT >= nextFrameAt then
                nextFrameAt = nextFrameAt + (s.speed or 1) / FPS
                frame = frame + 1
                debug.takeScreenshot()
            end
        end,
    },
    eventHandlers = { TMW_State = function(s) snap = s end },
}
