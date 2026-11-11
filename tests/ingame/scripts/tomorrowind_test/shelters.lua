-- Dev-only: the open shelters and the pavilion, a bed to sleep in, and a
-- house on stilts having its pilings driven.
-- Run: TEST_CONTENT=shelters.omwscripts tools/playtest.sh <out>
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
local restAt   -- real time the bed was used: the rest window pauses the game
local function log(...) print('[SHELTERS]', ...) end
local function dbg(e) core.sendGlobalEvent('TMW_Debug', e) end
local function land(dx, dy, lift)
    local p = v3(VILLAGE.x + dx, VILLAGE.y + dy, 0)
    return v3(p.x, p.y, core.land.getHeightAt(p, self.cell) + (lift or 0))
end
local function once(key, at, fn)
    if not done[key] and t >= at then
        done[key] = true
        local ok, err = pcall(fn)
        if not ok then log('error in', key, err) end
    end
end
local function site(kind, variant)
    for _, s in ipairs(snap and snap.sites or {}) do
        if s.kind == kind and (variant == nil or s.variant == variant) then return s end
    end
end
local function look(from, at)
    camera.setMode(camera.MODE.Static)
    camera.setStaticPosition(from)
    local d = at - from
    camera.setYaw(math.atan2(d.x, d.y))
    camera.setPitch(math.atan2(from.z - at.z, util.vector2(d.x, d.y):length()))
end
local function shot(label) log('shot', label); debug.takeScreenshot() end

local CANOPY, SMALL, PAVILION, HOUSE = { 700, 0 }, { 700, 650 }, { -700, 350 }, { 0, -1100 }

-- can settlers walk from outside to the middle of it?
local function pathCheck(label, at)
    local mid = land(at[1], at[2], 10)
    for _, off in ipairs({ { 0, -700 }, { 700, 0 }, { 0, 700 }, { -700, 0 } }) do
        local from = land(at[1] + off[1], at[2] + off[2], 10)
        local status, path = nearby.findPath(from, mid)
        local last = path and path[#path]
        log(string.format('path %s from (%d,%d): status %s, %d points, ends %.0f from the middle', label, off[1], off[2],
            tostring(status), path and #path or 0, last and (last - mid):length() or -1))
    end
end

return {
    engineHandlers = {
        onFrame = function()
            if not restAt then return end
            local since = core.getRealTime() - restAt
            if since > 1.5 and not done.mode then
                done.mode = true
                log('ui mode after using the bed:', tostring(I.UI.getMode()))
                shot('rest')
            elseif since > 3 then
                restAt = nil
                I.UI.setMode()
            end
        end,
        onUpdate = function(dt)
            if dt <= 0 then return end
            t = t + dt
            local hp = types.Actor.stats.dynamic.health(self)
            if hp.current < hp.base then hp.current = hp.base end
            once('tp', 1, function()
                I.Camera.disableModeControl('shelters')
                dbg({ cmd = 'tp', pos = land(0, -2200, 300), lookAt = land(0, 0) })
            end)
            once('found', 4, function()
                core.sendGlobalEvent('TMW_Found', { yaw = 0, pos = land(-1500, -300) })
                dbg({ cmd = 'hour', hour = 10 })
            end)
            once('build', 6, function()
                dbg({ cmd = 'build', kind = 'shelter', pos = land(CANOPY[1], CANOPY[2]), yaw = 0.3, built = true })
                dbg({ cmd = 'build', kind = 'shelter', variant = 2, pos = land(SMALL[1], SMALL[2]), yaw = -0.2, built = true })
                dbg({ cmd = 'build', kind = 'pavilion', pos = land(PAVILION[1], PAVILION[2]), yaw = 0.5, built = true })
                dbg({ cmd = 'build', kind = 'bed', pos = land(CANOPY[1] + 30, CANOPY[2]), yaw = 0.3, built = true })
                dbg({ cmd = 'build', kind = 'bench', pos = land(SMALL[1], SMALL[2]), yaw = -0.2, built = true })
                dbg({ cmd = 'build', kind = 'campfire', pos = land(PAVILION[1], PAVILION[2] + 30), built = true })
                -- a finished house far off, unturned, to measure
                dbg({ cmd = 'build', kind = 'house', pos = land(3500, -2500), yaw = 0, built = true })
                dbg({ cmd = 'spawn', n = 4 })
            end)
            once('stilts', 8, function()
                local ref = site('house')
                local box = ref.obj:getBoundingBox()
                local mid = box.center - ref.obj.position
                local half = { x = box.halfSize.x, y = box.halfSize.y, cx = mid.x, cy = mid.y }
                log(string.format('house half %.0f x %.0f, middle (%.0f, %.0f)', half.x, half.y, half.cx, half.cy))
                local spot = land(HOUSE[1], HOUSE[2])
                dbg({ cmd = 'build', kind = 'house', pos = v3(spot.x, spot.y, spot.z + 150), yaw = 0.4,
                    built = false, leveled = true, radius = math.max(half.x, half.y), half = half, foundation = { wood = 10, work = 20 } })
            end)
            once('wide', 9, function() look(land(0, -1700, 380), land(0, 300, 150)) end)
            once('wideShot', 10.5, function() shot('shelters') end)
            once('canopy', 11.5, function() look(land(CANOPY[1] - 250, CANOPY[2] - 520, 170), land(CANOPY[1], CANOPY[2], 110)) end)
            once('canopyShot', 13, function() shot('canopy') end)
            once('pav', 14, function() look(land(PAVILION[1] + 250, PAVILION[2] - 900, 200), land(PAVILION[1], PAVILION[2], 150)) end)
            once('pavShot', 15.5, function() shot('pavilion') end)
            once('pavIn', 15.7, function() look(land(PAVILION[1] - 120, PAVILION[2] - 250, 120), land(PAVILION[1] + 200, PAVILION[2] + 300, 120)) end)
            once('pavInShot', 16.6, function() shot('in the pavilion') end)
            once('paths', 16.8, function()
                pathCheck('canopy', CANOPY)
                pathCheck('pavilion', PAVILION)
            end)
            -- the bed: activating it should open the rest window, with sleep
            once('bed', 17, function()
                I.Camera.enableModeControl('shelters')
                camera.setMode(camera.MODE.FirstPerson)
                dbg({ cmd = 'tp', pos = land(CANOPY[1] - 30, CANOPY[2] - 160, 10), lookAt = land(CANOPY[1], CANOPY[2], 40) })
            end)
            once('sleep', 19, function()
                local bed = site('bed')
                log('bed', bed and bed.obj and bed.obj.recordId)
                core.sendGlobalEvent('SHT_Activate', { obj = bed.obj })
                restAt = core.getRealTime()
            end)
            -- the stilts: each one goes in tall and is driven down
            once('house', 21, function()
                I.Camera.disableModeControl('shelters')
                look(land(HOUSE[1] + 200, HOUSE[2] - 1300, 220), land(HOUSE[1], HOUSE[2], 80))
            end)
            local stages = { 0.04, 0.1, 0.18, 0.25 }
            for i, p in ipairs(stages) do
                once('stage' .. i, 23 + i * 3, function()
                    dbg({ cmd = 'sitestate', kind = 'house', delivered = 1, progress = p })
                end)
                once('stageShot' .. i, 25 + i * 3, function() shot('pilings ' .. p) end)
            end
            once('finish', 37, function() dbg({ cmd = 'sitestate', kind = 'house', finish = true }) end)
            once('finishShot', 40, function() shot('house built') end)
            once('quit', 42, function() core.quit() end)
        end,
    },
    eventHandlers = { TMW_State = function(s) snap = s end },
}
