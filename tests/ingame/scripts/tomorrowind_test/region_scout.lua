-- Dev-only: finds a spot for a trailer set, away from towns. Measures a grid
-- of cells (how flat and dry the ground is; trees, doors and buildings
-- around: region_scout_global.lua), ranks them, then pictures the best few
-- from the south and from above.
-- Run: TEST_CONTENT=region_scout.omwscripts SHOTS="" tools/playtest.sh <out> Pelagiad
local core = require('openmw.core')
local camera = require('openmw.camera')
local util = require('openmw.util')
local self = require('openmw.self')
local types = require('openmw.types')
local debug = require('openmw.debug')
local I = require('openmw.interfaces')
local v3 = util.vector3

-- the Ascadian Isles between Pelagiad (0,-7), Suran (6,-6) and Vivec (3..5,-10 and south)
local SPOTS = {}
for x = 2, 5 do
    for y = -9, -5 do SPOTS[#SPOTS + 1] = { string.format('c%d_%d', x, y), x, y } end
end
local R = 2400 -- the set: within this of the middle
local BEST = 4

local t, i, phase, waitT = 0, 0, 'start', 0
local counts = {}
local ranked
local function log(...) print('[RS]', ...) end
local function dbg(e) core.sendGlobalEvent('TMW_Debug', e) end

local function look(from, at)
    camera.setMode(camera.MODE.Static)
    camera.setStaticPosition(from)
    local d = at - from
    camera.setYaw(math.atan2(d.x, d.y))
    camera.setPitch(math.atan2(from.z - at.z, util.vector2(d.x, d.y):length()))
end

local function centre(s) return v3((s[2] + 0.5) * 8192, (s[3] + 0.5) * 8192, 0) end

local function measure(s)
    local c = centre(s)
    local hs, water, n = {}, 0, 0
    for x = -R, R, 300 do
        for y = -R, R, 300 do
            if x * x + y * y <= R * R then
                local ok, h = pcall(core.land.getHeightAt, v3(c.x + x, c.y + y, 0), self.cell)
                if ok and h then
                    n = n + 1
                    hs[#hs + 1] = h
                    if h < 0 then water = water + 1 end
                end
            end
        end
    end
    table.sort(hs)
    local mid = hs[math.floor(#hs / 2) + 1] or 0
    local near = 0
    for _, h in ipairs(hs) do if math.abs(h - mid) < 150 then near = near + 1 end end
    s.c, s.mid = c, mid
    s.flat = math.floor(100 * near / math.max(1, n))
    s.water = math.floor(100 * water / math.max(1, n))
end

return { engineHandlers = {
    onUpdate = function(dt)
        if dt <= 0 then return end
        t = t + dt
        local hp = types.Actor.stats.dynamic.health(self)
        if hp.current < hp.base then hp.current = hp.base end
        if phase == 'start' then
            if t > 1 then
                I.Camera.disableModeControl('rs')
                I.UI.setHudVisibility(false)
                dbg({ cmd = 'hour', hour = 9 })
                phase, i = 'go', 0
            end
            return
        end
        waitT = waitT - dt
        if waitT > 0 then return end
        if phase == 'go' then
            i = i + 1
            local s = SPOTS[i]
            if not s then phase, waitT = 'rank', 1 return end
            local c = centre(s)
            dbg({ cmd = 'tp', pos = v3(c.x, c.y - 3000, 4000), lookAt = c })
            phase, waitT = 'measure', 4
        elseif phase == 'measure' then
            local s = SPOTS[i]
            measure(s)
            core.sendGlobalEvent('RS_Count', { name = s[1], pos = s.c, r = R + 1000, town = 7000 })
            phase, waitT = 'go', 0.5
        elseif phase == 'rank' then
            ranked = {}
            for _, s in ipairs(SPOTS) do
                local k = counts[s[1]] or {}
                s.trees, s.doors, s.houses = k.trees or 0, k.doors or 0, k.houses or 0
                s.score = s.flat - 3 * s.water - 25 * s.doors - 10 * s.houses - (s.trees < 6 and 20 or 0) - (s.trees > 40 and 10 or 0)
                ranked[#ranked + 1] = s
            end
            table.sort(ranked, function(a, b) return a.score > b.score end)
            for _, s in ipairs(ranked) do
                log(string.format('rank %s score %d: flat %d%% water %d%% trees %d doors %d houses %d at %.0f %.0f', s[1], s.score,
                    s.flat, s.water, s.trees, s.doors, s.houses, s.c.x, s.c.y))
            end
            i, phase = 0, 'shootGo'
        elseif phase == 'shootGo' then
            i = i + 1
            local s = ranked[i]
            if i > BEST or not s then core.quit() phase = 'done' return end
            dbg({ cmd = 'tp', pos = v3(s.c.x, s.c.y - 3600, s.mid + 1500), lookAt = s.c })
            core.sendGlobalEvent('TRL_Sky', {})
            phase, waitT = 'frame1', 5
        elseif phase == 'frame1' then
            local s = ranked[i]
            look(v3(s.c.x, s.c.y - 3400, s.mid + 1100), v3(s.c.x, s.c.y, s.mid))
            phase, waitT = 'shot1', 1.5
        elseif phase == 'shot1' then
            log('shot', ranked[i][1], 'south')
            debug.takeScreenshot()
            phase, waitT = 'frame2', 0.5 -- the picture is taken at the end of the frame: move on after
        elseif phase == 'frame2' then
            local s = ranked[i]
            look(v3(s.c.x, s.c.y - 1500, s.mid + 4200), v3(s.c.x, s.c.y + 300, s.mid))
            phase, waitT = 'shot2', 1.5
        elseif phase == 'shot2' then
            log('shot', ranked[i][1], 'above')
            debug.takeScreenshot()
            phase, waitT = 'shootGo', 0.5
        end
    end,
}, eventHandlers = {
    RS_Counted = function(e) counts[e.name] = e end,
} }
