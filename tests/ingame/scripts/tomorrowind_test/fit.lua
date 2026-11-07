-- Dev-only: placement features (bending walls, height, model choice), talking,
-- how smoothly buildings rise, and measurements for fitting furniture.
-- Run: TEST_CONTENT=fit.omwscripts SHOTS="" tools/playtest.sh <out> Pelagiad
local core = require('openmw.core')
local camera = require('openmw.camera')
local util = require('openmw.util')
local self = require('openmw.self')
local types = require('openmw.types')
local nearby = require('openmw.nearby')
local debug = require('openmw.debug')
local I = require('openmw.interfaces')
local defs = require('scripts.tomorrowind.defs')

local t, snap = 0, nil
local done = {}
local holdAt
local shotN = -1
local function log(...) print('[TMW-FIT]', ...) end
local function once(key, at, fn)
    if not done[key] and t >= at then
        done[key] = true
        local ok, err = pcall(fn)
        if not ok then log('ERROR in', key, err) end
    end
end
local function dbg(e) core.sendGlobalEvent('TMW_Debug', e) end
local function shot(key) shotN = shotN + 1; log('shot', shotN, key, 't=', t); debug.takeScreenshot() end
local function offset(dx, dy, dz)
    local p = snap.storePos
    return util.vector3(p.x + dx, p.y + dy, p.z + (dz or 0))
end
local function atGround(dx, dy, lift)
    local p = offset(dx, dy)
    return util.vector3(p.x, p.y, core.land.getHeightAt(p, self.cell) + (lift or 0))
end
local function go(from, target)
    dbg({ cmd = 'tp', pos = from, lookAt = from + util.vector3(0, 1, 0) })
    holdAt = target
end
local function aim()
    local target = type(holdAt) == 'function' and holdAt() or holdAt
    if not target then return end
    local cam = camera.getPosition()
    local d = target - cam
    camera.setYaw(math.atan2(d.x, d.y))
    camera.setPitch(math.atan2(cam.z - target.z, util.vector2(d.x, d.y):length()))
end
local SHELVES = { { 1, -300 }, { 2, 0 }, { 3, 300 }, { 4, 600 } }
local SHELF_Y = -1100
local fps = { n = 0, t = 0 }

return {
    engineHandlers = {
        onFrame = function()
            if done.measure and not done.measured then
                done.measured = true
                -- board heights of each shelf: rays straight down behind where books go
                for _, it in ipairs(SHELVES) do
                    local site
                    for _, s in ipairs(snap.sites) do
                        if s.kind == 'bookshelf' and s.variant == it[1] then site = s end
                    end
                    if site then
                        local look = defs.look('bookshelf', it[1])
                        local base = site.pos
                        local boards = {}
                        local z = base.z + look.lift * 2 + 30
                        for _ = 1, 8 do
                            local from = util.vector3(base.x + 72, base.y, z)
                            local to = util.vector3(base.x + 72, base.y, base.z - 5)
                            local r = nearby.castRenderingRay(from, to)
                            if not r.hit then break end
                            boards[#boards + 1] = string.format('%.0f', r.hitPos.z - base.z)
                            z = r.hitPos.z - 14
                        end
                        log('shelf', it[1], look.model, 'boards above ground:', table.concat(boards, ' '))
                    end
                end
                -- tents: floor height above the land, and which way is open
                for _, s in ipairs(snap.sites) do
                    if s.kind == 'tent' then
                        local c = s.pos
                        local look = defs.look('tent', s.variant)
                        for _, off in ipairs({ { 0, 0 }, { 80, 40 }, { -90, 60 } }) do
                            local x, y = c.x + off[1], c.y + off[2]
                            local land = core.land.getHeightAt(util.vector3(x, y, 0), self.cell)
                            local r = nearby.castRenderingRay(util.vector3(x, y, land + 200), util.vector3(x, y, land - 200))
                            log(string.format('tent %s floor at (%d,%d): %.0f above the land', tostring(s.variant), off[1], off[2], r.hit and r.hitPos.z - land or -999))
                        end
                        local out = {}
                        for a = 0, 345, 15 do
                            local rad = math.rad(a)
                            local from = util.vector3(c.x + math.sin(rad) * 120, c.y + math.cos(rad) * 120, c.z + 70)
                            local to = util.vector3(c.x + math.sin(rad) * 600, c.y + math.cos(rad) * 600, c.z + 70)
                            local r = nearby.castRay(from, to, { collisionType = nearby.COLLISION_TYPE.World })
                            out[#out + 1] = string.format('%d:%s', a, r.hit and string.format('%.0f', (r.hitPos - c):length()) or 'open')
                        end
                        log('tent', tostring(s.variant), look.model, 'radius', s.radius, 'walls:', table.concat(out, ' '))
                    end
                end
            end
            if done.talkAt and not done.talked and core.getRealTime() - done.talkAt > 1 then
                done.talked = true
                log('ui mode after activating a settler:', I.UI.getMode())
                shot('talking')
            end
            if done.talked and not done.talkClosed and core.getRealTime() - done.talkAt > 2.5 then
                done.talkClosed = true
                I.UI.removeMode('Dialogue')
            end
        end,
        onUpdate = function(dt)
            t = t + dt
            local hp = types.Actor.stats.dynamic.health(self)
            if hp.current < hp.base then hp.current = hp.base end
            aim()
            if dt > 0 then fps.n, fps.t = fps.n + 1, fps.t + dt end
            once('cam', 1, function()
                I.Camera.disableModeControl('fit')
                camera.setMode(camera.MODE.FirstPerson)
                dbg({ cmd = 'tp', pos = util.vector3(-904, -56848, 1400), lookAt = util.vector3(-904, -56248, 1400) })
            end)
            once('found', 3, function() core.sendGlobalEvent('TMW_Found', { yaw = 0, pos = util.vector3(-904, -56248, 1300) }) end)
            once('debug', 4, function() dbg({ cmd = 'debug', on = true }) end)
            once('setup', 5, function()
                dbg({ cmd = 'give', amounts = { ore = 100, wood = 100, ingot = 40, food = 60 } })
                for _, it in ipairs(SHELVES) do
                    dbg({ cmd = 'build', kind = 'bookshelf', variant = it[1], pos = offset(it[2], SHELF_Y), built = true })
                end
                dbg({ cmd = 'build', kind = 'tent', variant = 2, pos = offset(1000, -1500), built = true })
            end)
            once('measure', 8, function() end)
            once('view_shelves', 9, function() go(atGround(150, SHELF_Y - 520, 100), atGround(150, SHELF_Y, 80)) end)
            once('sh_shelves', 11.5, function() shot('shelves') end)
            once('view_close', 12, function() go(atGround(0, SHELF_Y - 190, 70), atGround(0, SHELF_Y, 90)) end)
            once('sh_close', 14.5, function() shot('shelf close') end)
            once('view_tent', 15, function() go(atGround(1000, -2200, 100), atGround(1000, -1500, 100)) end)
            once('sh_tent', 17.5, function() shot('large tent') end)
            once('view_tentin', 18, function() go(atGround(1000, -1500, 60), atGround(1000, -1300, 60)) end)
            once('sh_tentin', 20.5, function() shot('large tent inside') end)
            -- bending walls: each new piece turns further around the joint
            once('wall0', 21, function() dbg({ cmd = 'build', kind = 'wall', pos = offset(1000, -700), built = true, yaw = 0 }) end)
            local bend = 0.35
            local function lastWall()
                local w
                for _, s in ipairs(snap.sites) do if s.kind == 'wall' then w = s end end
                return w
            end
            for i = 1, 3 do
                once('bend' .. i, 21.5 + i * 2.5, function()
                    local w = lastWall()
                    local axis = util.transform.rotateZ(w.yaw) * util.vector3(1, 0, 0)
                    local toward = w.pos + axis * 250
                    self:sendEvent('TMW_DebugPlace', { kind = 'wall', at = util.vector3(toward.x, toward.y, w.pos.z), curve = bend })
                end)
                once('bendc' .. i, 22.7 + i * 2.5, function() self:sendEvent('TMW_DebugPlace', { confirm = true }) end)
            end
            once('walls_finish', 31, function()
                dbg({ cmd = 'finish' })
                for _, s in ipairs(snap.sites) do if s.kind == 'wall' then log('wall', s.id, s.pos, 'yaw', s.yaw) end end
            end)
            once('view_curve', 32, function() go(atGround(1500, -1500, 200), atGround(1350, -850, 60)) end)
            once('sh_curve', 34.5, function() shot('curved wall') end)
            -- height and model while placing
            once('place_house', 35, function()
                self:sendEvent('TMW_DebugPlace', { kind = 'house', at = atGround(1500, 300), raise = 120 })
            end)
            once('place_cycle', 37, function() self:sendEvent('TMW_DebugPlace', { cycle = 1 }) end)
            once('place_cycle2', 38.5, function() self:sendEvent('TMW_DebugPlace', { cycle = 1 }) end)
            once('place_shot', 40, function() shot('placing, model 3') end)
            once('place_confirm', 40.5, function() self:sendEvent('TMW_DebugPlace', { confirm = true }) end)
            once('place_log', 42, function()
                for _, s in ipairs(snap.sites) do
                    if s.kind == 'house' then
                        log('house variant', s.variant, 'pos', s.pos, 'land', core.land.getHeightAt(s.pos, self.cell), s.status)
                    end
                end
            end)
            -- talking
            once('talk', 43, function()
                done.talkAt = core.getRealTime()
                dbg({ cmd = 'talk' })
            end)
            -- a real build, watched for how smoothly it rises
            once('fps_base', 46, function() fps.n, fps.t = 0, 0 end)
            once('fps_baseline', 55, function()
                log(string.format('frames per second before building: %.0f', fps.n / fps.t))
                dbg({ cmd = 'spawn', n = 3 })
            end)
            once('view_house', 56, function()
                local h
                for _, s in ipairs(snap.sites) do if s.kind == 'house' then h = s end end
                go(h.pos + util.vector3(-1100, -1300, 200), h.pos + util.vector3(0, 0, 200))
                dbg({ cmd = 'sitestate', kind = 'house', delivered = 1, progress = 0.2 })
                fps.n, fps.t = 0, 0
            end)
            if t > 57 and (done.nextRise or 0) < t then
                done.nextRise = t + 2
                dbg({ cmd = 'risedump' })
            end
            once('sh_rise', 62, function() shot('rising 1') end)
            once('sh_rise2', 66, function() shot('rising 2') end)
            once('sh_rise3', 70, function() shot('rising 3') end)
            once('finish_all', 86, function() dbg({ cmd = 'finish' }) end)
            local function houseSide(dist, up)
                local h
                for _, q in ipairs(snap.sites) do if q.kind == 'house' then h = q end end
                local n = util.transform.rotateZ(h.yaw) * util.vector3(0, -dist, 0)
                return h.pos + n + util.vector3(0, 0, up)
            end
            once('view_front', 88, function() go(houseSide(1100, 100), houseSide(0, 60)) end)
            once('sh_front', 90.5, function() shot('finished house, door side') end)
            once('view_back', 91, function() go(houseSide(-1100, 100), houseSide(0, 60)) end)
            once('sh_back', 93.5, function() shot('finished house, other side') end)
            once('quit', 95, function()
                log(string.format('frames per second during the build: %.0f', fps.n / fps.t))
                log('done')
                core.quit()
            end)
        end,
    },
    eventHandlers = { TMW_State = function(s) snap = s end },
}
