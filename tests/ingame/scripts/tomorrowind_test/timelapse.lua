-- Dev-only: one time-lapse shot of a village going up, from an empty meadow
-- to a full colony, for an animated GIF. Every frame is saved by the engine.
-- Run: tools/make_timelapse.sh <out>   (films, then writes <out>/timelapse.gif)
local core = require('openmw.core')
local camera = require('openmw.camera')
local util = require('openmw.util')
local self = require('openmw.self')
local types = require('openmw.types')
local debug = require('openmw.debug')
local I = require('openmw.interfaces')

local v3 = util.vector3
local FPS = 30
local VILLAGE = v3(-2504, -55848, 1300) -- the meadow: see the scout scene's map
local DUR = 64      -- seconds filmed
local SPEED = 8     -- game seconds per video second: 8 s of video
local HOUR = 9.5
local TIME_SCALE = 200 -- the sun from morning to early afternoon
local snap
local frame = 0
local function log(...) print('[TIMELAPSE]', ...) end
local function dbg(e) core.sendGlobalEvent('TMW_Debug', e) end

local function at(dx, dy) return v3(VILLAGE.x + dx, VILLAGE.y + dy, 0) end
local function land(dx, dy, lift)
    local p = at(dx, dy)
    return v3(p.x, p.y, core.land.getHeightAt(p, self.cell) + (lift or 0))
end
local function lerp(a, b, u) return a + (b - a) * u end
local function ease(u) return u * u * (3 - 2 * u) end

-- kind, dx, dy, variant, yaw: the trailer's village, in the order it goes up
local BUILD = {
    { 'lumber', -1200, -1400 }, { 'farm', -1600, -1000 }, { 'house', -1000, 900, 2, 3.14 },
    { 'mine', 1200, -1400 }, { 'campfire', -750, -50 }, { 'house', 500, 900, 5, 3.14 },
    { 'smelter', 800, -200 }, { 'house', -1700, -100, 4, 1.57 }, { 'tent', 1450, 450 },
    { 'house', 400, -1000, 3, 0 }, { 'bookshelf', -500, 200 }, { 'table', -1000, 100 },
    { 'guardpost', 200, -600 }, { 'house', 2000, -800, 6, -1.57 }, { 'stockade', -100, -2200 },
}
-- set down without construction, one after another
local SMALL = {
    { 'lantern', -1050, -120 }, { 'bench', -900, -220 }, { 'chair', -620, -250 }, { 'lamppost', -500, -180 },
    { 'chest', -350, 170 }, { 'lantern', -1000, 280 }, { 'bed', 1150, -700 }, { 'bedroll', 1400, -730 },
    { 'lantern', 1010, -600 }, { 'lantern', 1560, -620 }, { 'lantern', 700, 300 }, { 'lantern', -200, -500 },
    { 'lamppost', 1000, 200 },
}
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

-- each building: materials piled up, then it rises, overlapping with the next
local function runBuild(u)
    local span = 1.6 / (#BUILD + 0.6)
    for i, it in ipairs(BUILD) do
        local p = (u - (i - 1) * span * 0.6) / span
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
    for i, it in ipairs(SMALL) do
        if not it.placed and u >= 0.45 + i * 0.04 then
            it.placed = true
            dbg({ cmd = 'build', kind = it[1], pos = land(it[2], it[3]), built = true })
        end
    end
    while wallPieces < math.min(6, math.floor(math.max(0, u - 0.35) * 12)) do placeWall() end
end

-- high over the village, above the trees, so the whole colony is in view.
-- Standing still (MOVE = 0): only what changes is stored, so the GIF stays small.
local MOVE = 0
local function cam(u)
    local cx, cy = 200, -350
    local e = 1 - MOVE * (1 - (ease(u * 0.5 + 0.25) * 2 - 0.5))
    local a, r, h = lerp(-0.35, 0.3, e), lerp(2900, 2650, e), lerp(2700, 2450, e)
    local base = land(cx, cy, 0).z
    return v3(VILLAGE.x + cx + math.sin(a) * r, VILLAGE.y + cy + math.cos(a) * r, base + h), land(cx, cy, 0)
end

local function setCam(pos, target)
    camera.setStaticPosition(pos)
    local d = target - pos
    camera.setYaw(math.atan2(d.x, d.y))
    camera.setPitch(math.atan2(pos.z - target.z, util.vector2(d.x, d.y):length()))
end

local t, filmT, nextFrameAt, skyT = 0, nil, 0, 0
local done = {}
local function once(key, at_, fn)
    if not done[key] and t >= at_ then
        done[key] = true
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
            if skyT <= 0 and done.found then
                skyT = 4
                core.sendGlobalEvent('TRL_Sky', {})
                core.sendGlobalEvent('TRL_Clean')
                -- only what's short: a full storehouse stops production
                if snap and snap.founded then
                    local top = {}
                    for res, low in pairs({ food = 60, wood = 40, ore = 30, ingot = 15 }) do
                        if (snap.stock[res] or 0) < low then top[res] = low end
                    end
                    dbg({ cmd = 'give', amounts = top })
                end
            end
            once('ui', 1, function()
                I.Camera.disableModeControl('timelapse')
                I.UI.setHudVisibility(false)
                -- the player waits behind the camera, out of the picture
                dbg({ cmd = 'tp', pos = VILLAGE + v3(-600, 3200, 1600), lookAt = VILLAGE })
            end)
            once('found', 4, function()
                core.sendGlobalEvent('TMW_Found', { yaw = 0, pos = land(0, 0, 0) })
                dbg({ cmd = 'quiet', on = true })
            end)
            once('hour', 6, function()
                dbg({ cmd = 'hour', hour = HOUR })
                core.sendGlobalEvent('TRL_Sky', { timeScale = 30 })
            end)
            once('cam', 8, function()
                camera.setMode(camera.MODE.Static)
                setCam(cam(0))
                dbg({ cmd = 'spawn', n = 4 })
            end)
            once('film', 14, function()
                log('film from frame', frame + 1)
                core.sendGlobalEvent('TRL_Sky', { timeScale = TIME_SCALE })
                filmT = 0
            end)
            if filmT then
                filmT = filmT + dt
                local u = math.min(1, filmT / DUR)
                setCam(cam(u))
                -- a moment on the empty meadow, the build, a moment on the village
                local ok, err = pcall(runBuild, math.max(0, (u - 0.05) / 0.82))
                if not ok then log('build error', err) end
                once('more1', 14 + DUR * 0.25, function() dbg({ cmd = 'spawn', n = 3 }) end)
                once('more2', 14 + DUR * 0.5, function() dbg({ cmd = 'spawn', n = 4 }) end)
                if filmT >= DUR then
                    log('done, frames', frame, 'hour', snap and snap.hour)
                    filmT = nil
                    done.quitAt = t
                end
            end
            if done.quitAt and t > done.quitAt + 3 then core.quit() end
        end,
        onFrame = function()
            if not filmT then return end
            if filmT >= nextFrameAt then
                nextFrameAt = nextFrameAt + SPEED / FPS
                frame = frame + 1
                debug.takeScreenshot()
            end
        end,
    },
    eventHandlers = { TMW_State = function(s) snap = s end },
}
