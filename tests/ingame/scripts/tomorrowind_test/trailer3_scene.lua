-- Dev-only: films the 0.3 trailer, only what's new: woodcutters felling real
-- trees, a tree coming down and growing back, planting a grove and watching it
-- grow, and crops harvested, planted and tended. Same machinery as
-- trailer2.lua: scripted cameras, every frame saved by the engine;
-- tools/make_trailer.py --cut 0.3 cuts it.
--
-- The set is a meadow in the Ascadian Isles east of Vivec, cell (5, -9), far
-- from any town (found with region_scout, laid out with set_map). The game's
-- clock stands nearly still while filming, so the light holds; growth comes
-- from the grow command, as time-lapses. Every camera stands between the sun
-- and what it films: the sun is always behind it.
--
-- Returns a factory: (preview, only) -> script. preview: one frame a second,
-- to check the framing (trailer3_preview.omwscripts); only: { name = true },
-- film just those shots (the set is put up as always).
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
local C0 = v3(45056, -69632, 0)
-- all on grass, off the dirt road that runs through the east of the cell
-- (set_map logs the ground textures); the storehouse up in the north-east,
-- out of every shot. The farm is filmed from the south-east, looking away
-- from the coast and Vivec (south-west), the sun still behind the camera.
local STORE = { 2500, 1900 }
local FARM_TURN = 0.7 -- the farm cameras: this far round from the sun
local CAMP = { 550, -2000 }
local FARM = { -400, -1200, 0.0 }
local GROVE = { 550, -1150, 4.2 }

return function(PREVIEW, ONLY)
    local snap
    local frame = 0
    local sunAz = 1.6
    local function log(...) print('[TRAILER]', ...) end
    local function dbg(e) core.sendGlobalEvent('TMW_Debug', e) end
    local function ground(p) return core.land.getHeightAt(p, self.cell) end
    local function at(dx, dy) return v3(C0.x + dx, C0.y + dy, 0) end
    local function land(dx, dy, lift)
        local p = at(dx, dy)
        return v3(p.x, p.y, ground(p) + (lift or 0))
    end
    local function onGround(p, lift) return v3(p.x, p.y, ground(p) + (lift or 0)) end
    local function lerp(a, b, u) return a + (b - a) * u end
    local function ease(u) return u * u * (3 - 2 * u) end
    local function flat(a, b) return util.vector2(a.x - b.x, a.y - b.y):length() end
    local function site(kind)
        for _, s in ipairs(snap.sites) do if s.kind == kind then return s end end
    end
    local function worker(pattern, near, within)
        for _, w in ipairs(snap and snap.workers or {}) do
            if (w.status or ''):find(pattern) and w.obj and w.obj:isValid() and w.obj.enabled
                and (not near or flat(w.obj.position, near) < (within or 400)) then
                return w
            end
        end
    end
    local function byId(id)
        for _, w in ipairs(snap.workers) do if w.id == id then return w end end
    end
    -- the standing tree nearest p (snap.trees: { pos = {x, y}, felled })
    local function treeNear(p, reach)
        local best, bd
        for _, t in ipairs(snap.trees or {}) do
            local d = flat(t.pos, p)
            if not t.felled and d < (reach or 300) and (not bd or d < bd) then best, bd = t, d end
        end
        return best
    end
    local function treeAt(pos)
        for _, t in ipairs(snap.trees or {}) do if flat(t.pos, pos) < 5 then return t end end
    end

    -- A camera position round `target` towards the sun (turned by `turn`),
    -- `dist` out and `h` up, with nothing between it and the target: tries
    -- angles either side until the view is clear.
    local SOLID = nearby.COLLISION_TYPE.World + nearby.COLLISION_TYPE.HeightMap
    local function clearLine(cam, target)
        local fwd = nearby.castRay(cam, target, { collisionType = SOLID })
        if fwd.hit and (fwd.hitPos - target):length() > 150 then return false end
        -- and back: a camera inside a trunk or a rock sees straight out of it
        local back = nearby.castRay(target, cam, { collisionType = SOLID })
        if back.hit and (back.hitPos - target):length() > 150 then return false end
        -- a little to either side, so a trunk doesn't fill half the picture
        local d = target - cam
        local side = v3(d.y, -d.x, 0):normalize() * 60
        for _, o in ipairs({ side, -side }) do
            local r = nearby.castRay(cam + o, target + o, { collisionType = SOLID })
            if r.hit and (r.hitPos - target - o):length() > 150 then return false end
        end
        return true
    end
    local function sunSide(target, dist, h, turn)
        local a0 = sunAz + (turn or 0)
        local first
        for i = 0, 14 do
            local a = a0 + (i % 2 == 0 and 1 or -1) * math.ceil(i / 2) * 0.16
            local cam = target + v3(math.sin(a) * dist, math.cos(a) * dist, 0)
            cam = v3(cam.x, cam.y, math.max(target.z + h, ground(cam) + 120))
            first = first or cam
            if clearLine(cam, target) then return cam end
        end
        return first
    end
    -- the angle of the direction `dir` (from the north, clockwise)
    local function angleOf(dir) return math.atan2(dir.x, dir.y) end

    -- Of the two sides of a line along `dir`, the one towards the sun.
    local function sunnySide(dir)
        local sun = v3(math.sin(sunAz), math.cos(sunAz), 0)
        local p = v3(dir.y, -dir.x, 0)
        if p:dot(sun) < 0 then p = -p end
        return p
    end

    local function readSun()
        local dir = core.weather.getCurrentSunLightDirection(self.cell)
        local x, y, z = dir.x, dir.y, dir.z
        if z < 0 then x, y, z = -x, -y, -z end
        sunAz = math.atan2(x, y)
        log(string.format('sun at azimuth %.0f, elevation %.0f', math.deg(sunAz), math.deg(math.atan2(z, math.sqrt(x * x + y * y)))))
    end

    -- Time-lapse: grows trees and crops by `hours` spread over the shot.
    local function grower(hours)
        local done = 0
        return function(u)
            local want = hours * u
            if want - done >= 0.05 then
                dbg({ cmd = 'grow', hours = want - done, keepFed = true })
                done = want
            end
        end
    end

    -- A fixed camera worked out once (`find` returns pos, target or nil).
    local function fixed(find)
        local pos, target
        return function()
            if not pos then pos, target = find() end
            return pos, target
        end
    end

    local function mark(s, name)
        log('mark', s.name, name, frame)
    end

    ---------------------------------------------------------------------------
    local choppedTree, chopper
    local grovePos = function() return land(GROVE[1], GROVE[2], 0) end
    local FIELD_GROVE = function() return land((FARM[1] + GROVE[1]) / 2, (FARM[2] + GROVE[2]) / 2, 0) end

    -- the woodcutter at a tree: who, and which tree (for the chop and the fall)
    local function findChopper()
        local w = worker('Felling a tree')
        local t = w and treeNear(w.obj.position, 220)
        if t then chopper, choppedTree = w.id, t end
        return t ~= nil
    end

    local SHOTS -- (cameras below look themselves up in it)
    SHOTS = {
        -- the meadow in the morning: farmers at work, builders setting out to
        -- plant a grove. The title.
        { name = 'open', prepare = 3, dur = 8,
          setup = function()
              dbg({ cmd = 'build', kind = 'grove', pos = grovePos(), yaw = GROVE[3], variant = 1, built = false })
          end,
          cam = function(u)
              local c = FIELD_GROVE()
              local e = ease(u)
              local a = sunAz + 0.55 - 0.25 * e
              local r = lerp(1650, 1500, e)
              local cam = c + v3(math.sin(a) * r, math.cos(a) * r, 0)
              return v3(cam.x, cam.y, math.max(c.z + lerp(820, 700, e), ground(cam) + 300)), c + v3(0, 0, 30)
          end },
        -- builders plant the grove: the saplings go in
        { name = 'plant', prepare = 1, dur = 70,
          prep = function(s)
              -- film once a builder is at it
              s.ready = worker('Grove', grovePos(), 260) ~= nil
          end,
          cam = function(u)
              local g = grovePos()
              return sunSide(g + v3(0, 0, 60), lerp(1050, 980, u), 360, -0.15), g + v3(0, 0, 40)
          end,
          during = function(u, s)
              if not s.planted and not site('grove') then
                  s.planted = true
                  mark(s, 'planted')
                  s.dur = s.t + 4
              end
          end },
        -- ... and they grow into a little wood: two days
        { name = 'grove', prepare = 2, dur = 9,
          cam = function(u)
              local g = grovePos()
              -- where the planting was filmed from (leaves don't block rays: a
              -- camera further out can end up in a canopy)
              return sunSide(g + v3(0, 0, 60), lerp(1100, 1040, u), lerp(380, 450, u), -0.15), g + v3(0, 0, lerp(80, 230, u))
          end,
          during = grower(50),
          -- now there's wood: two settlers take up the camp
          after = function()
              local camp = site('lumber')
              local n = 0
              for _, w in ipairs(snap.workers) do
                  if n < 2 and camp and not (w.job or ''):find('Farmer') and not (w.status or ''):find('Harvest') then
                      n = n + 1
                      core.sendGlobalEvent('TMW_Assign', { wid = w.id, target = camp.id })
                  end
              end
          end },
        -- a woodcutter at one of the new trees, chopping
        { name = 'chop', prepare = 2, dur = 8,
          prep = function(s) s.ready = s.ready or findChopper() end,
          cam = function(u)
              local s = SHOTS[4]
              if not s.ready then return nil end
              local w = byId(chopper)
              if not w then return nil end
              if not s.pos then
                  local tp = onGround(v3(choppedTree.pos.x, choppedTree.pos.y, 0))
                  local mid = (tp + w.obj.position) * 0.5
                  s.look = v3(mid.x, mid.y, tp.z + 110)
                  local d = tp - w.obj.position
                  local side = sunnySide(v3(d.x, d.y, 0):normalize())
                  s.pos = sunSide(s.look, 460, 70, angleOf(side) - sunAz)
              end
              -- a slow push in
              return s.look + (s.pos - s.look) * lerp(1, 0.9, ease(u)), s.look
          end },
        -- down it comes: one load left in it, the camera side-on to the fall
        { name = 'fell', prepare = 1, dur = 50,
          prep = function(s)
              -- (whoever is at a tree now: the last one may be off to the storehouse)
              if not s.ready and findChopper() then s.ready = true end
          end,
          cam = function(u)
              local s = SHOTS[5]
              if not s.ready then return nil end
              if not s.pos then
                  local w = byId(chopper)
                  local tp = onGround(v3(choppedTree.pos.x, choppedTree.pos.y, 0))
                  local from = w and w.obj.position or (tp + v3(0, -100, 0))
                  local d = tp - from
                  d = v3(d.x, d.y, 0):normalize()
                  local side = sunnySide(d)
                  s.look = tp + d * 380 + v3(0, 0, 170)
                  s.pos = sunSide(s.look, 900, 430, angleOf(side + d * 0.2) - sunAz)
              end
              return s.pos, s.look
          end,
          during = function(u, s)
              if s.t > 2 and not s.lastLoad and choppedTree then
                  s.lastLoad = true
                  dbg({ cmd = 'trees', at = v3(choppedTree.pos.x, choppedTree.pos.y, 0), r = 30, wood = 2 })
              end
              local t = choppedTree and treeAt(choppedTree.pos)
              if t and t.felled and not s.down then
                  s.down = true
                  mark(s, 'down')
                  s.dur = s.t + 6
              end
          end },
        -- the stump sprouts and the tree grows back: two and a half days
        { name = 'regrow', prepare = 2, dur = 9,
          cam = fixed(function()
              if not choppedTree then return nil end
              local tp = onGround(v3(choppedTree.pos.x, choppedTree.pos.y, 0))
              return sunSide(tp + v3(0, 0, 130), 560, 380, 0.15), tp + v3(0, 0, 170)
          end),
          during = grower(62) },
        -- a farmer harvests a ripe plot: the plant goes
        { name = 'harvest', prepare = 2, dur = 60,
          prep = function(s)
              local w = worker('Harvesting', land(FARM[1], FARM[2], 0), 400)
              if w and not s.who then s.who = w.id end
              s.ready = s.who ~= nil
          end,
          cam = function(u)
              local s = SHOTS[7]
              local w = s.who and byId(s.who)
              if not w then return nil end
              local p = w.obj.position
              if not s.angle then
                  local cam = sunSide(p + v3(0, 0, 80), 420, 150, FARM_TURN)
                  local d = cam - p
                  s.angle = math.atan2(d.x, d.y)
              end
              local a = s.angle + 0.12 * u
              local cam = p + v3(math.sin(a) * 420, math.cos(a) * 420, 0)
              return v3(cam.x, cam.y, ground(cam) + 165), p + v3(0, 0, 70)
          end,
          during = function(u, s)
              local w = s.who and byId(s.who)
              if w and not s.cut and not (w.status or ''):find('Harvesting') then
                  s.cut = true
                  mark(s, 'harvested')
                  s.dur = s.t + 3
              end
          end },
        -- the field through the day: harvested, planted, tended, ripening
        { name = 'field', prepare = 2, dur = 40, speed = 6,
          cam = fixed(function()
              local f = land(FARM[1], FARM[2], 0)
              -- from the north-east, steeply down on the plots (the sun to the side)
              return sunSide(f + v3(0, 0, 20), 400, 520, -1.1), f
          end),
          during = grower(5) },
        -- the crop growing back: the field just harvested, the farmers plant
        -- it plot by plot, and the sprouts grow into rice (four and a half hours)
        { name = 'replant', prepare = 3, dur = 120, speed = 10,
          setup = function() dbg({ cmd = 'field', grow = nil }) end,
          cam = fixed(function()
              local f = land(FARM[1], FARM[2], 0)
              return sunSide(f + v3(0, 0, 30), 470, 270, FARM_TURN), f + v3(0, 0, 10)
          end),
          during = (function()
              local done, logT = 0, 0
              return function(u, s)
                  if s.t >= logT then
                      logT = logT + 10
                      local f = site('farm')
                      log('replant', string.format('%.0f s', s.t), f and f.status)
                  end
                  -- planting first, then growing as well
                  local want = 4.6 * math.max(0, (u - 0.2) / 0.8)
                  if want - done >= 0.05 then
                      dbg({ cmd = 'grow', hours = want - done, keepFed = true })
                      done = want
                  end
              end
          end)() },
        -- the field and the young wood beside it
        { name = 'ending', prepare = 3, dur = 10,
          cam = function(u)
              local c = FIELD_GROVE()
              local e = ease(u)
              local a = sunAz - 0.45 + 0.2 * e
              local r = lerp(2100, 1900, e)
              local cam = c + v3(math.sin(a) * r, math.cos(a) * r, 0)
              return v3(cam.x, cam.y, math.max(c.z + lerp(2100, 1900, e), ground(cam) + 1200)), c + v3(0, 0, 50)
          end },
    }

    ---------------------------------------------------------------------------
    -- the set: a storehouse (out of sight), a farm and a camp in a meadow

    local function setUp()
        core.sendGlobalEvent('TMW_Found', { yaw = 0.8, pos = land(STORE[1], STORE[2], 0) })
        dbg({ cmd = 'quiet', on = true })
        dbg({ cmd = 'debug', on = true })
    end
    local function build()
        dbg({ cmd = 'build', kind = 'lumber', pos = land(CAMP[1], CAMP[2], 0), yaw = 0.3, built = true })
        dbg({ cmd = 'build', kind = 'farm', pos = land(FARM[1], FARM[2], 0), yaw = FARM[3], variant = 1, built = true })
        dbg({ cmd = 'spawn', n = 6 })
        dbg({ cmd = 'give', amounts = { food = 60 } })
    end
    -- three farmers; the woodcutters come once there's a wood to work
    local function assignJobs()
        local farm = site('farm')
        local ws = snap.workers
        for i = 1, 3 do
            if ws[i] and farm then core.sendGlobalEvent('TMW_Assign', { wid = ws[i].id, target = farm.id }) end
        end
        log('jobs given; settlers', #ws)
    end

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
            local fl = util.vector2(d.x, d.y):normalize()
            dbg({ cmd = 'tp', pos = v3(pos.x - fl.x * 600, pos.y - fl.y * 600, pos.z + 300), lookAt = pos })
        end
    end

    local function once(key, at_, fn)
        if not started[key] and t >= at_ then
            started[key] = true
            local ok, err = pcall(fn)
            if not ok then log('error in', key, err) end
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
                if skyT <= 0 and t > 3 then
                    skyT = 4
                    core.sendGlobalEvent('TRL_Sky', {})
                    core.sendGlobalEvent('TRL_Clean')
                    local food = snap and snap.founded and (snap.stock.food or 0)
                    if food and food < 40 then dbg({ cmd = 'give', amounts = { food = 60 } }) end
                    -- (with the storehouse full the farmers would stop harvesting)
                    if food and food > 90 then dbg({ cmd = 'give', amounts = { food = 50 - food } }) end
                end
                if stage == 'start' then
                    once('ui', 1, function()
                        I.Camera.disableModeControl('trailer')
                        I.UI.setHudVisibility(false)
                        dbg({ cmd = 'tp', pos = land(STORE[1] + 600, STORE[2] - 900, 900), lookAt = land(STORE[1], STORE[2], 0) })
                    end)
                    once('hour', 3, function() dbg({ cmd = 'hour', hour = 11 }) end) -- a high sun: short shadows
                    once('found', 5, setUp)
                    once('build', 7, build)
                    once('jobs', 10, assignJobs)
                    once('clock', 11, function()
                        core.sendGlobalEvent('TRL_Sky', { timeScale = 0.5 }) -- the light holds still
                        readSun()
                    end)
                    -- everyone gets going first
                    once('go', 45, function()
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
                    if ONLY and not ONLY[s.name] then return end -- next one
                    if s.setup then
                        local ok, err = pcall(s.setup)
                        if not ok then log('setup error', s.name, err) end
                    end
                    waited, stage = 0, 'prepare'
                elseif stage == 'prepare' then
                    local s = SHOTS[shotI]
                    waited = waited + dt
                    if s.prep then
                        local okP, err = pcall(s.prep, s)
                        if not okP then log('prep error', s.name, err) end
                    end
                    local ok, pos, target = pcall(s.cam, 0)
                    if ok and pos then setCam(pos, target) elseif not ok then log('camera error', s.name, pos) end
                    local ready = ok and pos and (s.ready == nil or s.ready)
                    if waited >= s.prepare then
                        if not ready and waited < s.prepare + 90 then return end -- nobody doing it yet
                        log('shot', s.name, 'from', frame + 1, 'at', core.getRealTime(), 'found', tostring(ready))
                        shotT, s.t, stage, nextFrameAt = 0, 0, 'film', 0
                    end
                elseif stage == 'film' then
                    local s = SHOTS[shotI]
                    shotT = shotT + dt
                    s.t = shotT
                    local u = math.min(1, shotT / s.dur)
                    local ok, pos, target = pcall(s.cam, u)
                    if ok and pos then setCam(pos, target) elseif not ok then log('camera error', s.name, pos) end
                    if s.during then
                        local okD, err = pcall(s.during, u, s)
                        if not okD then log('during error', s.name, err) end
                    end
                    if shotT >= s.dur then
                        local counts = {}
                        for _, w in ipairs(snap.workers) do
                            local k = (w.status or ''):gsub(' .*', '')
                            counts[k] = (counts[k] or 0) + 1
                        end
                        local parts = {}
                        for k, n in pairs(counts) do parts[#parts + 1] = k .. '=' .. n end
                        log('shot', s.name, 'to', frame, 'settlers', table.concat(parts, ' '))
                        if s.after then
                            local okA, err = pcall(s.after)
                            if not okA then log('after error', s.name, err) end
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
                if shotT >= nextFrameAt then
                    nextFrameAt = nextFrameAt + (PREVIEW and 1 or (s.speed or 1) / FPS)
                    frame = frame + 1
                    debug.takeScreenshot()
                end
            end,
        },
        eventHandlers = { TMW_State = function(s) snap = s end },
    }
end
