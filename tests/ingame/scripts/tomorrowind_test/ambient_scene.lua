-- Dev-only: ambient footage of a living colony, and the stills for the logo
-- and banners. Nothing is staged: the village (ambient_layout.lua) is laid
-- out so that the work happens along the road, and the settlers do their own
-- thing. Morning, the sun behind every camera, fixed cameras, real speed.
--
-- Two modes (one scene file each):
--   scout (ambient_scout.omwscripts): a still from every candidate camera,
--         and where everybody walks, logged once a second
--         (tools/ambient_scout.py draws it)
--   film  (ambient.omwscripts): films the chosen cameras (L.FILM), every frame
--         saved by the engine (tools/film_ambient.sh, tools/make_ambient.py)
local core = require('openmw.core')
local camera = require('openmw.camera')
local util = require('openmw.util')
local self = require('openmw.self')
local types = require('openmw.types')
local debug = require('openmw.debug')
local I = require('openmw.interfaces')
local L = require('scripts.tomorrowind_test.ambient_layout')

local v3 = util.vector3
local FPS = 30
local WARMUP = 50           -- seconds for everybody to get going
local SHOT_SECONDS = 75
local Y = L.LANE_Y

return function(mode)
    local snap, sunAz, campTree, campPos
    local t, done = 0, {}
    local frame, filming, shotT, nextFrameAt = 0, nil, 0, 0
    local function log(...) print('[AMBIENT]', ...) end
    local function dbg(e) core.sendGlobalEvent('TMW_Debug', e) end
    local function ground(x, y) return core.land.getHeightAt(v3(x, y, 0), self.cell) end
    local function onLand(x, y, lift) return v3(x, y, ground(x, y) + (lift or 0)) end
    local function once(key, at, fn)
        if not done[key] and t >= at then
            done[key] = true
            local ok, err = pcall(fn)
            if not ok then log('error in', key, err) end
        end
    end

    local function setCam(from, to)
        camera.setMode(camera.MODE.Static)
        camera.setStaticPosition(from)
        local d = to - from
        camera.setYaw(math.atan2(d.x, d.y))
        camera.setPitch(math.atan2(from.z - to.z, util.vector2(d.x, d.y):length()))
    end

    local function readSun()
        local dir = core.weather.getCurrentSunLightDirection(self.cell)
        local x, y, z = dir.x, dir.y, dir.z
        if z < 0 then x, y, z = -x, -y, -z end
        sunAz = math.atan2(x, y)
        log(string.format('sun at azimuth %.0f, elevation %.0f', math.deg(sunAz), math.deg(math.atan2(z, math.sqrt(x * x + y * y)))))
    end

    -- Every camera: from and to as { x, y, lift above the ground }. The
    -- woodcutters' ones are worked out from the camp's tree and the sun.
    local function cameras()
        local list = {
            road1 = { { -150, Y - 120, 320 }, { -3250, Y + 60, 150 } },
            road2 = { { 300, Y - 300, 450 }, { -3250, Y + 60, 100 } },
            road3 = { { -900, Y - 60, 380 }, { -3250, Y + 60, 120 } },
            road4 = { { 100, Y - 80, 700 }, { -2600, Y, 0 } },
            square1 = { { -2100, Y - 1100, 300 }, { -2900, Y - 420, 90 } },
            square2 = { { -2200, Y - 150, 300 }, { -3000, Y - 450, 60 } },
            square3 = { { -2300, Y - 1300, 600 }, { -2900, Y - 400, 50 } },
        }
        if campTree then
            local tx, ty = campTree.pos.x, campTree.pos.y
            local function around(turn, dist, up)
                local a = sunAz + turn
                return { { tx + math.sin(a) * dist, ty + math.cos(a) * dist, up }, { tx, ty, 110 } }
            end
            list.wood1 = around(0, 600, 180)
            list.wood2 = around(0.6, 700, 220)
            list.wood3 = around(-0.6, 700, 220)
            local cx, cy = campPos[1], campPos[2]
            local ax, ay = cx - tx, cy - ty
            local len = math.max(1, math.sqrt(ax * ax + ay * ay))
            list.wood4 = { { cx + ax / len * 500 + math.sin(sunAz) * 200, cy + ay / len * 500 + math.cos(sunAz) * 200, 250 },
                { (tx + cx) / 2, (ty + cy) / 2, 100 } }
        end
        return list
    end

    local function look(c)
        setCam(onLand(c[1][1], c[1][2], c[1][3]), onLand(c[2][1], c[2][2], c[2][3]))
    end

    local function assignJobs()
        local bySite = {}
        for _, s in ipairs(snap.sites) do
            if L.JOBS[s.kind] and s.built then bySite[s.kind] = s.id end
        end
        local i = 0
        for _, kind in ipairs({ 'lumber', 'farm', 'mine', 'market' }) do
            for _ = 1, L.JOBS[kind] or 0 do
                i = i + 1
                local w = snap.workers[i]
                if w and bySite[kind] then core.sendGlobalEvent('TMW_Assign', { wid = w.id, target = bySite[kind] }) end
            end
        end
        log('jobs given to', i, 'of', #snap.workers, 'settlers')
    end

    local function setup()
        once('ui', 1, function()
            I.Camera.disableModeControl('ambient')
            I.UI.setHudVisibility(false)
            -- the player waits south-east of everything, out of every shot
            dbg({ cmd = 'tp', pos = onLand(1500, Y - 1600, 400), lookAt = onLand(0, Y) })
            core.sendGlobalEvent('TRL_Sky', {})
        end)
        once('sky2', 3, function() core.sendGlobalEvent('TRL_Sky', {}) end)
        once('clear', 3.5, function()
            dbg({ cmd = 'hide', from = onLand(-2700, Y), box = L.CLEAR, far = 4000, prefixes = L.CLEAR_PREFIXES })
        end)
        once('found', 4, function()
            core.sendGlobalEvent('TMW_Found', { yaw = L.facing(L.STORE[1], L.STORE[2]), pos = onLand(L.STORE[1], L.STORE[2]) })
            dbg({ cmd = 'quiet', on = true })
        end)
        once('hour', 6, function()
            core.sendGlobalEvent('TRL_Sky', { timeScale = 1 }) -- the light holds still
            dbg({ cmd = 'hour', hour = L.HOUR })
        end)
        once('build', 8, function()
            readSun()
            local cp
            campTree, cp = L.campFor(snap.trees)
            campPos = cp
            if campTree then log(string.format('camp tree at %.0f %.0f, camp at %.0f %.0f', campTree.pos.x, campTree.pos.y, cp[1], cp[2])) end
            for _, b in ipairs(L.VILLAGE) do
                dbg({ cmd = 'build', kind = b[1], variant = b[4], pos = onLand(b[2], b[3]), yaw = L.facing(b[2], b[3]), built = true })
            end
            if campPos then dbg({ cmd = 'build', kind = 'lumber', pos = onLand(campPos[1], campPos[2]), yaw = L.facing(campPos[1], campPos[2]), built = true }) end
            dbg({ cmd = 'spawn', n = L.SETTLERS })
            dbg({ cmd = 'give', amounts = { food = 300, wood = 40, ore = 20 } })
            -- where everything is, for the scout's map
            log(string.format('place storehouse %.0f %.0f', L.STORE[1], L.STORE[2]))
            for _, b in ipairs(L.VILLAGE) do log(string.format('place %s %.0f %.0f', b[1], b[2], b[3])) end
            if campPos then
                log(string.format('place lumber %.0f %.0f', campPos[1], campPos[2]))
                log(string.format('place tree %.0f %.0f', campTree.pos.x, campTree.pos.y))
            end
        end)
        once('hide', 9, function()
            -- the town's own buildings, lights and walls in view of the shots
            local from = onLand(0, Y)
            dbg({ cmd = 'hide', from = from, yaw = -math.pi / 2, half = 1.2, near = 200, far = 14000, report = true,
                prefixes = { 'ex_imp', 'ex_common', 'ex_de_', 'ex_nord', 'ex_t_', 'ex_s_', 'ex_v_', 'ex_pelagiad', 'ex_vivec', 'ex_drystonewall', 'furn_banner', 'furn_com', 'furn_imp', 'light_', 'active_' } })
        end)
        once('jobs', 12, assignJobs)
    end

    -- keep everyone busy and the meadow quiet
    local function keep(dt)
        done.keepT = (done.keepT or 0) - dt
        if done.keepT <= 0 and t > 12 then
            done.keepT = 5
            core.sendGlobalEvent('TRL_Clean')
            core.sendGlobalEvent('TRL_Sky', {})
            if snap and snap.stock and (snap.stock.food or 0) < 100 then dbg({ cmd = 'give', amounts = { food = 200 } }) end
        end
    end

    ---------------------------------------------------------------------------
    -- scout: stills from every camera, and where people walk

    local scoutList, scoutI, scoutT, sampleT = nil, 0, 0, 0
    local function scout(dt)
        local start = 12 + WARMUP
        if t < start then return end
        sampleT = sampleT - dt
        if sampleT <= 0 and t < start + 70 then
            sampleT = 1
            local parts = {}
            for _, w in ipairs(snap.workers) do
                if w.obj and w.obj:isValid() and w.obj.enabled then
                    parts[#parts + 1] = string.format('%.0f,%.0f', w.obj.position.x, w.obj.position.y)
                end
            end
            log('walk ' .. table.concat(parts, ' '))
        end
        if not scoutList then
            scoutList = {}
            local cams = cameras()
            local names = {}
            for name in pairs(cams) do names[#names + 1] = name end
            table.sort(names)
            for _, name in ipairs(names) do scoutList[#scoutList + 1] = { name = name, cam = cams[name] } end
        end
        scoutT = scoutT - dt
        if scoutT <= 0 then
            if scoutList[scoutI] and not scoutList[scoutI].shot then
                scoutList[scoutI].shot = true
                log('still', scoutList[scoutI].name)
                debug.takeScreenshot()
                scoutT = 0.4
                return
            end
            scoutI = scoutI + 1
            local c = scoutList[scoutI]
            if c then
                look(c.cam)
                scoutT = 2.5
            elseif t > start + 70 then
                core.quit()
            end
        end
    end

    ---------------------------------------------------------------------------
    -- film: the chosen cameras, every frame

    local shotI = 0
    local function nextShot()
        shotI = shotI + 1
        local name = L.FILM[shotI]
        if not name then
            log('done, frames', frame)
            filming = nil
            done.quitAt = t
            return
        end
        look(cameras()[name])
        filming = { name = name, wait = 1.5 } -- a moment for the view to settle
        shotT, nextFrameAt = 0, 0
    end

    local function film(dt)
        once('film', 12 + WARMUP, nextShot)
        if filming then
            if filming.wait > 0 then
                filming.wait = filming.wait - dt
                if filming.wait <= 0 then
                    log('shot', filming.name, 'from', frame + 1)
                    shotT, nextFrameAt = 0, 0
                end
            else
                shotT = shotT + dt
                if shotT >= SHOT_SECONDS then
                    log('shot', filming.name, 'to', frame)
                    nextShot()
                end
            end
        end
        if done.quitAt and t > done.quitAt + 2 then core.quit() end
    end

    return {
        engineHandlers = {
            onUpdate = function(dt)
                if dt <= 0 then return end
                t = t + dt
                local hp = types.Actor.stats.dynamic.health(self)
                if hp.current < hp.base then hp.current = hp.base end
                setup()
                keep(dt)
                if mode == 'scout' then scout(dt) else film(dt) end
            end,
            onFrame = function()
                if mode ~= 'film' or not filming or filming.wait > 0 then return end
                -- one frame per 1/30 s of play
                if shotT >= nextFrameAt then
                    nextFrameAt = nextFrameAt + 1 / FPS
                    frame = frame + 1
                    debug.takeScreenshot()
                end
            end,
        },
        eventHandlers = { TMW_State = function(s) snap = s end },
    }
end
