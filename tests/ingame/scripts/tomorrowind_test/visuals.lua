-- Dev-only: a scene for checking the colony's visuals by screenshot.
-- Run: TEST_CONTENT=visuals.omwscripts SHOTS="..." tools/playtest.sh <out> Vos
local core = require('openmw.core')
local camera = require('openmw.camera')
local util = require('openmw.util')
local self = require('openmw.self')
local nearby = require('openmw.nearby')
local types = require('openmw.types')
local I = require('openmw.interfaces')

local t, snap = 0, nil
local done = {}
local function log(...) print('[TMW-VIS]', ...) end
local function once(key, at, fn)
    if not done[key] and t >= at then
        done[key] = true
        local ok, err = pcall(fn)
        if not ok then log('ERROR in', key, err) end
    end
end
local function offset(dx, dy, dz)
    local p = snap.storePos
    return util.vector3(p.x + dx, p.y + dy, p.z + (dz or 0))
end
local function siteId(kind)
    for _, s in ipairs(snap and snap.sites or {}) do
        if s.kind == kind then return s.id end
    end
end
local function dbg(e) core.sendGlobalEvent('TMW_Debug', e) end

-- two steps: move the player, then aim the camera once they've landed
local function view(key, at, from, target)
    once(key .. '_tp', at, function() dbg({ cmd = 'tp', pos = from(), lookAt = target() }) end)
    once(key .. '_aim', at + 1, function()
        local tg, cam = target(), camera.getPosition()
        local d = tg - cam
        camera.setYaw(math.atan2(d.x, d.y))
        camera.setPitch(math.atan2(cam.z - tg.z, util.vector2(d.x, d.y):length()))
        log('view', key, 'at t=', t)
    end)
end

local LUMBER, SMELTER, HOUSE, FARM = { 0, -900 }, { -700, 300 }, { 1300, -2000 }, { -600, -700 }

return {
    engineHandlers = {
        onUpdate = function(dt)
            t = t + dt
            local hp = types.Actor.stats.dynamic.health(self)
            if hp.current < hp.base then hp.current = hp.base end
            once('camera_mode', 1, function()
                -- no vanity orbit and no player model in the way of screenshots
                I.Camera.disableModeControl('visuals')
                camera.setMode(camera.MODE.FirstPerson)
            end)
            once('flat', 2, function()
                local function h(x, y)
                    local r = nearby.castRay(util.vector3(x, y, 20000), util.vector3(x, y, -2000),
                        { collisionType = nearby.COLLISION_TYPE.Default })
                    if not r.hit or r.hitObject then return nil end
                    return r.hitPos.z
                end
                local best, bestScore
                local p0 = self.position
                for gx = -6, 6 do
                    for gy = -6, 6 do
                        local cx, cy = p0.x + gx * 1000, p0.y + gy * 1000
                        local lo, hi, ok = 1e9, -1e9, true
                        for sx = -2, 2 do
                            for sy = -2, 2 do
                                local z = h(cx + sx * 500, cy + sy * 500)
                                if not z or z < 60 then ok = false else
                                    lo, hi = math.min(lo, z), math.max(hi, z) end
                            end
                        end
                        if ok and (not bestScore or hi - lo < bestScore) then
                            best, bestScore = util.vector3(cx, cy, hi), hi - lo
                        end
                    end
                end
                log('flattest patch', best, bestScore)
                if best then dbg({ cmd = 'tp', pos = best + util.vector3(0, -600, 0), lookAt = best }) end
            end)
            once('found', 4, function() core.sendGlobalEvent('TMW_Found', { yaw = 0 }) end)
            once('debug', 5, function() dbg({ cmd = 'debug', on = true }) end)
            once('setup', 6, function()
                dbg({ cmd = 'give', amounts = { ore = 30, wood = 100, ingot = 10, food = 50 } })
                dbg({ cmd = 'build', kind = 'lumber', pos = offset(LUMBER[1], LUMBER[2]), built = true })
                dbg({ cmd = 'build', kind = 'smelter', pos = offset(SMELTER[1], SMELTER[2]), built = true })
                dbg({ cmd = 'build', kind = 'mine', pos = offset(900, -300), built = true })
                dbg({ cmd = 'build', kind = 'farm', pos = offset(FARM[1], FARM[2]), built = false })
                -- a house on stilts: the floor 150 above the ground
                local spot = offset(HOUSE[1], HOUSE[2])
                local floor = core.land.getHeightAt(spot, self.cell) + 150
                dbg({ cmd = 'build', kind = 'house', pos = util.vector3(spot.x, spot.y, floor),
                    built = false, leveled = true, radius = 570, foundation = { wood = 10, work = 20 } })
            end)
            once('assign', 8, function()
                local ws = snap.workers
                if ws[1] then core.sendGlobalEvent('TMW_Assign', { wid = ws[1].id, target = siteId('smelter') }) end
            end)
            view('lumber', 10, function() return offset(LUMBER[1] + 20, LUMBER[2] - 480) end,
                function() return offset(LUMBER[1] + 20, LUMBER[2], 40) end)
            view('smelter', 22, function() return offset(SMELTER[1], SMELTER[2] - 300) end,
                function() return offset(SMELTER[1], SMELTER[2], 110) end)
            view('smelterSide', 34, function() return offset(SMELTER[1] - 320, SMELTER[2]) end,
                function() return offset(SMELTER[1], SMELTER[2], 110) end)
            view('farmsite', 46, function() return offset(FARM[1] + 150, FARM[2] - 520) end,
                function() return offset(FARM[1] + 150, FARM[2], 40) end)
            -- the house site in stages: half the materials, all of them,
            -- pilings half in, pilings done, then half built
            view('house', 60, function() return offset(HOUSE[1] + 300, HOUSE[2] - 1300) end,
                function() return offset(HOUSE[1] + 300, HOUSE[2], 60) end)
            once('stage1', 63, function() dbg({ cmd = 'sitestate', kind = 'house', delivered = 0.5 }) end)
            once('stage2', 71, function() dbg({ cmd = 'sitestate', kind = 'house', delivered = 1, progress = 0.1 }) end)
            once('stage3', 79, function() dbg({ cmd = 'sitestate', kind = 'house', delivered = 1, progress = 0.25 }) end)
            once('stage4', 87, function() dbg({ cmd = 'sitestate', kind = 'house', delivered = 1, progress = 0.65 }) end)
            if t >= (done.nextDump or 12) then
                done.nextDump = t + 12
                dbg({ cmd = 'fxdump' })
            end
            once('quit', 120, function()
                dbg({ cmd = 'fxdump' })
                log('done')
                core.quit()
            end)
        end,
    },
    eventHandlers = { TMW_State = function(s) snap = s end },
}
