-- Dev-only: scans a tent's doorway with rays to see what blocks it.
local core = require('openmw.core')
local util = require('openmw.util')
local self = require('openmw.self')
local types = require('openmw.types')
local nearby = require('openmw.nearby')
local camera = require('openmw.camera')
local debug = require('openmw.debug')
local I = require('openmw.interfaces')
local t, snap = 0, nil
local done = {}
local function log(...) print('[TMW-TENT]', ...) end
local function once(key, at, fn)
    if not done[key] and t >= at then
        done[key] = true
        local ok, err = pcall(fn)
        if not ok then log('ERROR in', key, err) end
    end
end
local function dbg(e) core.sendGlobalEvent('TMW_Debug', e) end
local function scan(label, kind)
    local site
    for _, s in ipairs(snap.sites) do if s.kind == kind then site = s end end
    local c = site.pos
    log(label, 'tent at', c, 'land', core.land.getHeightAt(c, self.cell))
    for _, z in ipairs({ 20, 50, 90, 130, 170, 210 }) do
        local line = {}
        for x = -100, 100, 25 do
            local from = util.vector3(c.x + x, c.y - 600, c.z + z)
            local to = util.vector3(c.x + x, c.y + 60, c.z + z)
            local r = nearby.castRay(from, to, { collisionType = nearby.COLLISION_TYPE.World + nearby.COLLISION_TYPE.Door + nearby.COLLISION_TYPE.HeightMap })
            local name = ''
            if r.hit then
                name = r.hitObject and (r.hitObject.recordId:sub(1, 9)) or 'land'
                line[#line + 1] = string.format('%4.0f', r.hitPos.y - c.y)
            else
                line[#line + 1] = '   .'
            end
        end
        log(string.format('z+%3d', z), table.concat(line, ' '))
    end
    -- navmesh: can a settler path from outside the door to the middle?
    local ok, status, path = pcall(nearby.findPath, util.vector3(c.x, c.y - 600, c.z), util.vector3(c.x, c.y, c.z))
    log('path status', ok, status, path and #path)
    if path then for i, p in ipairs(path) do if i <= 8 then log('  ', p) end end end
end
return {
    engineHandlers = {
        onFrame = function()
            -- how high is the tent lining's floor above the land?
            if done.tent and t > 10 and not done.floor then
                done.floor = true
                for _, site in ipairs(snap.sites) do
                    if site.kind == 'tent' then
                        local c = site.pos
                        for _, off in ipairs({ { 0, 0 }, { 100, 50 }, { -120, 80 }, { 0, -200 } }) do
                            local x, y = c.x + off[1], c.y + off[2]
                            local land = core.land.getHeightAt(util.vector3(x, y, 0), self.cell)
                            local from = util.vector3(x, y, land + 200)
                            local r = nearby.castRenderingRay(from, util.vector3(x, y, land - 200))
                            log(string.format('floor at (%d,%d): land %.0f, hit %.0f, floor is %.0f above the land (%s)', off[1], off[2], land, r.hit and r.hitPos.z or -1,
                                r.hit and (r.hitPos.z - land) or -1, r.hitObject and r.hitObject.recordId or 'land'))
                        end
                    end
                end
            end
        end,
        onUpdate = function(dt)
            t = t + dt
            local hp = types.Actor.stats.dynamic.health(self)
            if hp.current < hp.base then hp.current = hp.base end
            once('tp', 1, function() dbg({ cmd = 'tp', pos = util.vector3(-904, -56848, 1400), lookAt = util.vector3(-904, -56248, 1400) }) end)
            once('found', 4, function() core.sendGlobalEvent('TMW_Found', { yaw = 0, pos = util.vector3(-904, -56248, 1300) }) end)
            once('tent', 6, function()
                local p = snap.storePos
                dbg({ cmd = 'build', kind = 'tent', pos = util.vector3(p.x + 1000, p.y - 1500, p.z), built = true })
            end)
            once('walkto', 8, function()
                local p = snap.storePos
                dbg({ cmd = 'tp', pos = util.vector3(p.x + 1000, p.y - 1500, p.z + 100), lookAt = util.vector3(p.x + 1000, p.y - 1300, p.z) })
            end)
            once('scan', 9, function() scan('doorway', 'tent') end)
            local function look(tx, ty, tz)
                local p = snap.storePos
                local target = util.vector3(p.x + tx, p.y + ty, p.z + tz)
                local cam = camera.getPosition()
                local d = target - cam
                camera.setYaw(math.atan2(d.x, d.y))
                camera.setPitch(math.atan2(cam.z - target.z, util.vector2(d.x, d.y):length()))
            end
            once('fp', 2, function()
                I.Camera.disableModeControl('tent')
                camera.setMode(camera.MODE.FirstPerson)
            end)
            once('things', 7, function()
                local p = snap.storePos
                dbg({ cmd = 'build', kind = 'bed', pos = util.vector3(p.x + 1000, p.y - 1350, p.z), built = true })
                dbg({ cmd = 'build', kind = 'chest', pos = util.vector3(p.x + 1150, p.y - 1450, p.z), built = true })
                dbg({ cmd = 'build', kind = 'lantern', pos = util.vector3(p.x + 850, p.y - 1450, p.z), built = true })
                dbg({ cmd = 'build', kind = 'bookshelf', pos = util.vector3(p.x + 400, p.y - 2300, p.z), built = true })
            end)
            if t > 10 and t < 15 then look(1000, -1350, 80) end
            once('shot1', 13, function() debug.takeScreenshot() end)
            once('out', 15, function()
                local p = snap.storePos
                dbg({ cmd = 'tp', pos = util.vector3(p.x + 1000, p.y - 2150, p.z + 100), lookAt = util.vector3(p.x + 1000, p.y - 1500, p.z) })
            end)
            if t > 16 and t < 21 then look(1000, -1650, 80) end
            once('shot2', 19, function() debug.takeScreenshot() end)
            once('shelf', 21, function()
                local p = snap.storePos
                dbg({ cmd = 'tp', pos = util.vector3(p.x + 400, p.y - 2600, p.z + 100), lookAt = util.vector3(p.x + 400, p.y - 2300, p.z) })
            end)
            if t > 22 and t < 27 then look(400, -2300, 80) end
            once('shot3', 25, function() debug.takeScreenshot() end)
            once('quit', 27, function() core.quit() end)
        end,
    },
    eventHandlers = { TMW_State = function(s) snap = s end },
}
