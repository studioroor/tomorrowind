-- Dev-only: settlers in a house: sleeping, using furniture, building, coming and
-- going, and everyone back outside after you leave.
-- Run: TEST_CONTENT=people.omwscripts SHOTS="" tools/playtest.sh <out> Pelagiad
local core = require('openmw.core')
local camera = require('openmw.camera')
local util = require('openmw.util')
local self = require('openmw.self')
local types = require('openmw.types')
local debug = require('openmw.debug')
local I = require('openmw.interfaces')
local v3 = util.vector3
local VILLAGE = v3(-2504, -55848, 1300)
local t, snap = 0, nil
local done = {}
local shotN = -1
local function log(...) print('[TMW-PPL]', ...) end
local function once(key, at, fn)
    if not done[key] and t >= at then
        done[key] = true
        local ok, err = pcall(fn)
        if not ok then log('ERROR in', key, err) end
    end
end
local function dbg(e) core.sendGlobalEvent('TMW_Debug', e) end
local function shot(key) shotN = shotN + 1; log('shot', shotN, key, 't=', t); debug.takeScreenshot() end
local function land(dx, dy)
    local p = v3(VILLAGE.x + dx, VILLAGE.y + dy, 0)
    return v3(p.x, p.y, core.land.getHeightAt(p, self.cell))
end
local HOUSE = { 1000, 1300 }
local function roster(tag)
    local inside, out = {}, 0
    for _, w in ipairs(snap.workers) do
        local cellName = w.obj and w.obj:isValid() and w.obj.cell and w.obj.cell.name or '?'
        if cellName == 'Tomorrowind Interiors' then
            inside[#inside + 1] = string.format('%s[%s z=%.0f]', w.name, w.status, w.obj.position.z)
        else out = out + 1 end
    end
    log(tag, string.format('%02d:%02d', math.floor(snap.hour), math.floor(snap.hour % 1 * 60)), 'inside', #inside, 'outside', out, table.concat(inside, '; '))
end
-- a camera in the room that always looks at the first person in it
local camOn = false
local function roomCam()
    if not camOn then return end
    local o = v3(math.floor(self.position.x / 15000 + 0.5) * 15000, 0, self.position.z + 150)
    camera.setMode(camera.MODE.Static)
    local target
    for _, w in ipairs(snap.workers) do
        if w.obj and w.obj:isValid() and w.obj.cell and w.obj.cell.name == 'Tomorrowind Interiors' and w.status ~= 'Heading out' then target = w.obj.position break end
    end
    target = target or (o + v3(0, 200, -60))
    local pos = o + v3(-150, 70, 0)
    camera.setStaticPosition(pos)
    local d = target + v3(0, 0, 40) - pos
    camera.setYaw(math.atan2(d.x, d.y))
    camera.setPitch(math.atan2(pos.z - target.z - 40, util.vector2(d.x, d.y):length()))
end

return {
    engineHandlers = {
        onUpdate = function(dt)
            t = t + dt
            local hp = types.Actor.stats.dynamic.health(self)
            if hp.current < hp.base then hp.current = hp.base end
            if snap and snap.founded then roomCam() end
            once('ui', 1, function()
                I.Camera.disableModeControl('ppl')
                dbg({ cmd = 'tp', pos = VILLAGE + v3(0, -600, 1000), lookAt = VILLAGE })
            end)
            once('found', 3.5, function() core.sendGlobalEvent('TMW_Found', { yaw = 0, pos = land(0, 0) }) end)
            once('setup', 5, function()
                dbg({ cmd = 'debug', on = true })
                dbg({ cmd = 'give', amounts = { food = 120, wood = 150, ore = 40, ingot = 30 } })
                dbg({ cmd = 'spawn', n = 8 })
                dbg({ cmd = 'build', kind = 'house', variant = 2, pos = land(HOUSE[1], HOUSE[2]), built = true })
            end)
            once('in', 7, function() dbg({ cmd = 'enter' }) end)
            -- furniture, built from inside so the crew comes in through the door
            local function place(key, at, kind, dx, dy)
                once(key, at, function()
                    local p = self.position
                    self:sendEvent('TMW_DebugPlace', { kind = kind, at = v3(p.x + dx, p.y + dy, p.z) })
                end)
                once(key .. 'c', at + 0.8, function() self:sendEvent('TMW_DebugPlace', { confirm = true }) end)
            end
            once('work', 8.5, function() dbg({ cmd = 'hour', hour = 10 }) end)
            place('p1', 10, 'bookshelf', -170, 300)
            once('stage', 12, function()
                dbg({ cmd = 'sitestate', kind = 'bookshelf', delivered = 1, progress = 0 })
                camOn = true
            end)
            once('b0', 15, function() roster('crew arriving'); shot('crew arriving') end)
            once('b1', 20, function() roster('building'); shot('crew building') end)
            once('b2', 23, function() roster('almost built'); dbg({ cmd = 'finish' }) end)
            once('b3', 26, function() roster('built'); shot('crew heading out') end)
            -- the rest appears finished: the evening and the night
            once('more', 29, function()
                camOn = false
                camera.setMode(camera.MODE.FirstPerson)
            end)
            place('p2', 30, 'bed', 60, 150)
            place('p3', 31.5, 'table', -60, 330)
            place('p4', 33, 'bedroll', 170, 280)
            once('fin', 35, function() dbg({ cmd = 'finish' }); camOn = true end)
            once('eve', 36, function() dbg({ cmd = 'hour', hour = 19.3 }) end)
            once('e1', 41, function() roster('evening'); shot('evening') end)
            once('e2', 47, function() roster('evening2'); shot('evening 2') end)
            once('night', 49, function() dbg({ cmd = 'hour', hour = 23.8 }) end)
            once('n1', 55, function() roster('night'); shot('night') end)
            once('quit_', 56, function() dbg({ cmd = 'hour', hour = 19.2 }) end)
            once('n2', 61, function() roster('next evening') end)
            once('talkcheck', 62, function()
                for _, w in ipairs(snap.workers) do
                    if w.obj.cell and w.obj.cell.name == 'Tomorrowind Interiors' then
                        log('status of', w.name, w.status, 'enabled', w.obj.enabled)
                    end
                end
            end)
            once('out', 63, function() camOn = false; camera.setMode(camera.MODE.FirstPerson); dbg({ cmd = 'leave' }) end)
            once('o1', 65, function() roster('after leaving'); log('player cell', self.cell.name) end)
            once('work2', 66, function() dbg({ cmd = 'hour', hour = 9 }) end)
            once('o2', 78, function()
                roster('next morning')
                for _, w in ipairs(snap.workers) do log('  ', w.name, w.status, 'enabled', w.obj.enabled) end
                log('done')
                core.quit()
            end)
        end,
    },
    eventHandlers = { TMW_State = function(s) snap = s end },
}
