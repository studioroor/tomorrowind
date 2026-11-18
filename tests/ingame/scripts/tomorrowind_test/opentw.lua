-- Dev-only, OpenTW engine: a house placed on a slope gets level, paved
-- ground; the landscaping tool raises and paints; and all of it comes back
-- after saving and loading (opentw_menu.lua saves at 20 s and loads at 26 s).
-- Run: OPENMW=<opentw>/openmw TEST_CONTENT=opentw.omwscripts SHOTS="14 40" tools/playtest.sh <out>
local core = require('openmw.core')
local util = require('openmw.util')
local self = require('openmw.self')
local camera = require('openmw.camera')
local types = require('openmw.types')
local v3 = util.vector3

local VILLAGE = v3(-2504, -55848, 1300)
local t, done = 0, {}
local S -- what the land should look like; kept across the reload
local afterLoad
local results = { pass = 0, fail = 0 }

local function log(...) print('[OPENTW]', ...) end
local function check(ok, what)
    results[ok and 'pass' or 'fail'] = results[ok and 'pass' or 'fail'] + 1
    log((ok and 'PASS ' or 'FAIL ') .. what)
end
local function once(key, at, clock, fn)
    if not done[key] and clock >= at then
        done[key] = true
        local ok, err = pcall(fn)
        if not ok then check(false, key .. ': ' .. tostring(err)) end
    end
end
local function dbg(e) core.sendGlobalEvent('TMW_Debug', e) end
local function h(x, y) return core.land.getHeightAt(v3(x, y, 0), self.cell) end
local function tex(x, y) return tostring(core.land.getTextureAt(v3(x, y, 0), self.cell)) end

-- the same aim as the landscaping tool
local function aim()
    local from = camera.getPosition()
    local dir = camera.viewportToWorldVector(util.vector2(0.5, 0.5))
    local d = 0
    while d < 6000 do
        d = d + 32
        local p = from + dir * d
        if p.z <= h(p.x, p.y) then return p end
    end
end

-- heights across the house footprint and around the raised spot
local function measure()
    local m = { ring = {} }
    for i = 0, 7 do
        local a = i * math.pi / 4
        m.ring[#m.ring + 1] = h(S.house.x + math.sin(a) * 380, S.house.y + math.cos(a) * 380)
    end
    m.mound = h(S.mound.x, S.mound.y)
    m.houseTex = tex(S.house.x, S.house.y)
    m.sandTex = S.sand and tex(S.sand.x, S.sand.y) or 'none'
    return m
end

local function verify(label)
    local m = measure()
    local lo, hi = math.huge, -math.huge
    for _, z in ipairs(m.ring) do lo, hi = math.min(lo, z), math.max(hi, z) end
    check(hi - lo < 3 and math.abs(lo - S.floor) < 3,
        string.format('%s: ground under the house is level at its floor (%.0f..%.0f, floor %.0f; was %.0f..%.0f)',
            label, lo, hi, S.floor, S.before.lo, S.before.hi))
    check(m.houseTex:lower():find('dirtroad') ~= nil, label .. ': house plot paved (' .. m.houseTex .. ')')
    check(math.abs(m.mound - (S.before.mound + 350)) < 3,
        string.format('%s: mound raised 350 (%.0f, was %.0f)', label, m.mound, S.before.mound))
    check(m.sandTex:lower():find('sand') ~= nil, label .. ': landscaping tool painted sand (' .. m.sandTex .. ')')
end

return {
    engineHandlers = {
        onUpdate = function(dt)
            t = t + dt
            local hp = types.Actor.stats.dynamic.health(self)
            if hp.current < hp.base then hp.current = hp.base end
            if afterLoad then
                afterLoad = afterLoad + dt
                once('reloaded', 4, afterLoad, function() verify('after load') end)
                once('lookAgain', 5, afterLoad, function()
                    dbg({ cmd = 'tp', pos = S.eye, lookAt = S.house })
                end)
                once('quit', 16, afterLoad, function()
                    log(string.format('done: %d passed, %d failed', results.pass, results.fail))
                    core.quit()
                end)
                return
            end
            once('tp', 1, t, function() dbg({ cmd = 'tp', pos = VILLAGE, lookAt = VILLAGE + v3(0, 100, 0) }) end)
            once('found', 3, t, function() core.sendGlobalEvent('TMW_Found', { yaw = 0 }) end)
            once('build', 6, t, function()
                local base = self.position
                S = { house = v3(base.x + 1300, base.y - 2000, 0), mound = v3(base.x - 1500, base.y - 1500, 0) }
                local ring = {}
                for i = 0, 7 do
                    local a = i * math.pi / 4
                    ring[#ring + 1] = h(S.house.x + math.sin(a) * 380, S.house.y + math.cos(a) * 380)
                end
                local lo, hi = math.huge, -math.huge
                for _, z in ipairs(ring) do lo, hi = math.min(lo, z), math.max(hi, z) end
                S.floor = (lo + hi) / 2
                S.before = { lo = lo, hi = hi, mound = h(S.mound.x, S.mound.y) }
                log(string.format('slope under the house: %.0f..%.0f', lo, hi))
                dbg({ cmd = 'give', amounts = { wood = 200, ore = 50 } })
                dbg({ cmd = 'build', kind = 'house', pos = v3(S.house.x, S.house.y, S.floor), built = false,
                    leveled = true, radius = 500 })
                core.sendGlobalEvent('TMW_Landscape', { k = 'raise', x = S.mound.x, y = S.mound.y, r = 300, h = 350, f = 500 })
                camera.setPitch(0.6) -- look down at the ground in front
            end)
            once('tool', 7, t, function()
                S.sand = aim()
                self:sendEvent('TMW_LandscapeTest', { tool = 2, radius = 300, use = true }) -- Paint: Sand
            end)
            once('verify', 9, t, function() verify('placed') end)
            once('look', 10, t, function()
                camera.setPitch(0.15)
                S.eye = v3(S.house.x - 900, S.house.y + 1400, 0)
                dbg({ cmd = 'tp', pos = S.eye, lookAt = S.house })
            end)
        end,
        onSave = function() return { S = S, results = results } end,
        onLoad = function(data)
            if data and data.S then
                S, results = data.S, data.results
                afterLoad = 0
                log('loaded')
            end
        end,
    },
}
