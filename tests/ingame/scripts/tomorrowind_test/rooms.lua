-- Dev-only: enters one house of each room type, measures where its floor is
-- below the arrival point and photographs the room (bed included).
-- Run: TEST_CONTENT=rooms.omwscripts SHOTS="" tools/playtest.sh <out> Pelagiad
local core = require('openmw.core')
local camera = require('openmw.camera')
local util = require('openmw.util')
local self = require('openmw.self')
local types = require('openmw.types')
local nearby = require('openmw.nearby')
local debug = require('openmw.debug')
local I = require('openmw.interfaces')
local defs = require('scripts.tomorrowind.defs')
local v3 = util.vector3
local VILLAGE = v3(-2504, -55848, 1300)
local HOUSES = { { 2, 1000, 1300 }, { 6, -1000, 1400 }, { 4, 200, -1700 }, { 10, 1700, -300 }, { 9, -1800, -300 } }
local t, snap = 0, nil
local done = {}
local function log(...) print('[TMW-ROOMS]', ...) end
local function once(key, at, fn)
    if not done[key] and t >= at then
        done[key] = true
        local ok, err = pcall(fn)
        if not ok then log('ERROR in', key, err) end
    end
end
local function dbg(e) core.sendGlobalEvent('TMW_Debug', e) end
local function land(dx, dy)
    local p = v3(VILLAGE.x + dx, VILLAGE.y + dy, 0)
    return v3(p.x, p.y, core.land.getHeightAt(p, self.cell))
end
local arrivedZ
return {
    engineHandlers = {
        onFrame = function()
            -- the first frame in a room: where did we arrive?
            if done.watch and self.cell and self.cell.name == 'Tomorrowind Interiors' and not arrivedZ then
                arrivedZ = self.position.z
            end
        end,
        onUpdate = function(dt)
            t = t + dt
            local hp = types.Actor.stats.dynamic.health(self)
            if hp.current < hp.base then hp.current = hp.base end
            once('ui', 1, function()
                I.Camera.disableModeControl('rooms')
                dbg({ cmd = 'tp', pos = VILLAGE + v3(0, -600, 1000), lookAt = VILLAGE })
            end)
            once('found', 3.5, function() core.sendGlobalEvent('TMW_Found', { yaw = 0, pos = land(0, 0) }) end)
            once('houses', 5, function()
                dbg({ cmd = 'debug', on = true })
                for _, h in ipairs(HOUSES) do
                    dbg({ cmd = 'build', kind = 'house', variant = h[1], pos = land(h[2], h[3]), built = true })
                end
            end)
            for i, h in ipairs(HOUSES) do
                local at = 6 + (i - 1) * 7
                once('in' .. i, at, function()
                    done.watch, arrivedZ = true, nil
                    dbg({ cmd = 'enter', at = land(h[2], h[3]) })
                end)
                once('measure' .. i, at + 2.5, function()
                    local origin = v3(math.floor(self.position.x / defs.roomSpacing + 0.5) * defs.roomSpacing, 0, 0)
                    local r = nearby.castRay(origin + v3(0, 0, 60), origin - v3(0, 0, 600), { collisionType = nearby.COLLISION_TYPE.World })
                    local room = defs.look('house', h[1]).door.interior
                    log(string.format('room %s floor %.1f arrivedAt %.1f restingAt %.1f fell %.1f', room,
                        r.hit and r.hitPos.z - origin.z or -999, (arrivedZ or 0) - origin.z, self.position.z - origin.z, (arrivedZ or 0) - self.position.z))
                    local beds = {}
                    for _, s in ipairs(snap.sites) do
                        if s.host == snap.insideHost then beds[#beds + 1] = string.format('%s(%.0f,%.0f,%.0f)', s.kind, s.pos.x - origin.x, s.pos.y, s.pos.z) end
                    end
                    for _, s in ipairs(snap.sites) do
                        if s.id == snap.insideHost then log('  house says:', s.status, 'furniture:', table.concat(beds, ' ')) end
                    end
                    -- look at the bed if there is one
                    for _, s in ipairs(snap.sites) do
                        if s.host == snap.insideHost and s.kind:find('bed') then
                            camera.setMode(camera.MODE.Static)
                            local from = self.position + v3(0, 0, 130)
                            camera.setStaticPosition(from)
                            local d = s.pos - from
                            camera.setYaw(math.atan2(d.x, d.y))
                            camera.setPitch(math.atan2(from.z - s.pos.z, util.vector2(d.x, d.y):length()))
                        end
                    end
                end)
                once('shot' .. i, at + 3.5, function() debug.takeScreenshot() end)
                once('out' .. i, at + 5, function()
                    camera.setMode(camera.MODE.FirstPerson)
                    dbg({ cmd = 'leave' })
                end)
            end
            once('summary', 6 + #HOUSES * 7, function()
                log('beds in the colony:', snap.beds, 'settlers', snap.pop)
                for _, s in ipairs(snap.sites) do if s.kind == 'house' then log('  ', s.name, s.status) end end
                -- a bed placed inside counts too
                done.extra = true
                core.quit()
            end)
        end,
    },
    eventHandlers = { TMW_State = function(s) snap = s end },
}
