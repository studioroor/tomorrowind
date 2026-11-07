-- Dev-only: a full colony day with furnishings, for logs and screenshots.
-- Run: TEST_CONTENT=day.omwscripts SHOTS="..." tools/playtest.sh <out> Pelagiad
local core = require('openmw.core')
local camera = require('openmw.camera')
local util = require('openmw.util')
local self = require('openmw.self')
local types = require('openmw.types')
local nearby = require('openmw.nearby')
local I = require('openmw.interfaces')
local debug = require('openmw.debug')

local t, snap = 0, nil
local done = {}
local function log(...) print('[TMW-DAY]', ...) end
local function once(key, at, fn)
    if not done[key] and t >= at then
        done[key] = true
        local ok, err = pcall(fn)
        if not ok then log('ERROR in', key, err) end
    end
end
local function dbg(e) core.sendGlobalEvent('TMW_Debug', e) end
local function offset(dx, dy, dz)
    local p = snap.storePos
    return util.vector3(p.x + dx, p.y + dy, p.z + (dz or 0))
end
local function ground(x, y)
    return core.land.getHeightAt(util.vector3(x, y, 0), self.cell)
end
local holdFrom, holdAt
local function aim()
    if not holdAt then return end
    local target = type(holdAt) == 'function' and holdAt() or holdAt
    if not target then return end
    local cam = camera.getPosition()
    local d = target - cam
    camera.setYaw(math.atan2(d.x, d.y))
    camera.setPitch(math.atan2(cam.z - target.z, util.vector2(d.x, d.y):length()))
end
local shotN = 0
local function shot(key)
    shotN = shotN + 1
    log('shot', shotN, key, 't=', t)
    debug.takeScreenshot()
end
-- move, aim, and take a screenshot once everything has settled
local function view(key, at, from, target, shotDelay)
    once(key, at, function()
        local f = from()
        dbg({ cmd = 'tp', pos = f, lookAt = f + util.vector3(0, 1, 0) })
        holdAt = target
        log('view', key, 't=', t, 'hour=', snap.hour)
    end)
    once(key .. '_shot', at + (shotDelay or 3), function() shot(key) end)
end
local function atGround(dx, dy, lift)
    local p = offset(dx, dy)
    return util.vector3(p.x, p.y, ground(p.x, p.y) + (lift or 0))
end
local function workerDoing(pattern)
    for _, w in ipairs(snap and snap.workers or {}) do
        if w.status:find(pattern) and w.obj and w.obj:isValid() then return w end
    end
end
local function summary()
    if not snap or not snap.founded then return end
    log(string.format('--- t=%.0f %02d:%02d %s pop=%d/%d food=%d wood=%d', t, math.floor(snap.hour), math.floor((snap.hour % 1) * 60),
        snap.period, snap.pop, snap.beds, snap.stock.food, snap.stock.wood))
    for _, w in ipairs(snap.workers) do
        log(string.format('  %-18s %-14s %-36s fed=%.2f enabled=%s', w.name, w.job:sub(1, 14), w.status, w.fed, tostring(w.obj and w.obj.enabled)))
    end
end
local nextSummary = 8
local nextTent

local CLUSTER = {
    { 'campfire', 0, -900 }, { 'bookshelf', 280, -1000 }, { 'table', -280, -1000 }, { 'chest', 500, -900 },
    { 'bench', -500, -900 }, { 'chair', -170, -1100 }, { 'lamppost', 170, -720 }, { 'lantern', -170, -720 },
    { 'bed', -760, -1050 }, { 'bedroll', -760, -850 }, { 'tent', 1000, -1500 },
}

return {
    engineHandlers = {
        onFrame = function()
            -- opening a chest pauses the game, so onUpdate stands still
            if done.openChest and not done.chestDone and I.UI.getMode() == 'Container' then
                done.chestAt = done.chestAt or core.getRealTime()
                if core.getRealTime() - done.chestAt > 1.5 then
                    done.chestDone = true
                    log('ui mode after using the chest:', I.UI.getMode())
                    shot('chest')
                end
            end
            if done.chestDone and not done.chestClosed and core.getRealTime() - done.chestAt > 3 then
                done.chestClosed = true
                I.UI.removeMode('Container')
            end
        end,
        onUpdate = function(dt)
            t = t + dt
            local hp = types.Actor.stats.dynamic.health(self)
            if hp.current < hp.base then hp.current = hp.base end
            aim()
            once('camera_mode', 1, function()
                I.Camera.disableModeControl('day')
                camera.setMode(camera.MODE.FirstPerson)
                dbg({ cmd = 'tp', pos = util.vector3(-904, -56848, 1400), lookAt = util.vector3(-904, -56248, 1400) })
            end)
            once('found', 4, function() core.sendGlobalEvent('TMW_Found', { yaw = 0, pos = util.vector3(-904, -56248, 1300) }) end)
            once('debug', 5, function() dbg({ cmd = 'debug', on = true }) end)
            once('setup', 6, function()
                dbg({ cmd = 'give', amounts = { ore = 40, wood = 100, ingot = 10, food = 60 } })
                for _, it in ipairs(CLUSTER) do
                    dbg({ cmd = 'build', kind = it[1], pos = offset(it[2], it[3]), built = true })
                end
                -- a fence line, a gate and a stone wall
                for i = 0, 2 do dbg({ cmd = 'build', kind = 'fence', pos = offset(-300 + i * 264, -560), built = true }) end
                dbg({ cmd = 'build', kind = 'gate', pos = offset(-300 + 2 * 264 + 132 + 0, -560), built = true })
                for i = 0, 2 do dbg({ cmd = 'build', kind = 'wall', pos = offset(-900 + i * 258, -1350), built = true }) end
            end)
            once('hour_eve', 9, function() dbg({ cmd = 'hour', hour = 18.5 }) end)
            -- a look around
            view('square', 12, function() return atGround(0, -1500, 80) end, function() return atGround(0, -900, 40) end)
            view('lights', 20, function() return atGround(0, -1150, 80) end, function() return atGround(0, -720, 140) end)
            -- wait for somebody to pick up a book, then look at them
            if t > 24 and t < 62 and not done.readerSeen then
                local w = workerDoing('Reading')
                if w then
                    done.readerSeen = true
                    done.readerT = t
                    local p = w.obj.position
                    local fwd = w.obj.rotation * util.vector3(0, 1, 0)
                    local side = util.vector3(fwd.y, -fwd.x, 0)
                    dbg({ cmd = 'tp', pos = p + side * 150 - fwd * 40, lookAt = p })
                    holdAt = function() return w.obj.position + util.vector3(0, 0, 80) end
                    log('reader found', w.name, 't=', t)
                end
            end
            if done.readerT then once('reader_shot', done.readerT + 3, function() shot('reader') end) end
            view('fence', 64, function() return atGround(0, -1000, 80) end, function() return atGround(0, -560, 80) end)
            once('tent_rays', 69, function()
                -- is the tent hollow, and where is its opening?
                local c = atGround(1000, -1500, 60)
                local out = {}
                for a = 0, 330, 30 do
                    local r = math.rad(a)
                    local res = nearby.castRay(c, c + util.vector3(math.sin(r) * 500, math.cos(r) * 500, 0), { collisionType = nearby.COLLISION_TYPE.World })
                    out[#out + 1] = string.format('%d:%s', a, res.hit and string.format('%.0f', (res.hitPos - c):length()) or 'open')
                end
                log('tent rays from inside', table.concat(out, ' '))
            end)
            view('tent', 70, function() return atGround(1000, -2150, 80) end, function() return atGround(1000, -1500, 100) end)
            view('tentin', 75, function() return atGround(1000, -1500, 60) end, function() return atGround(1000, -1300, 60) end)
            view('tentdoor', 78, function() return atGround(1000, -1500, 60) end, function() return atGround(1000, -1700, 60) end, 1.5)
            view('tentwalk', 80.5, function() return atGround(1000, -1500 - 480, 0) end, function() return atGround(1000, -1500, 60) end, 99)
            once('walk_start', 82, function() log('walking into the tent from', self.position) ; done.walking = t end)
            if done.walking and t < done.walking + 6 then
                self.controls.movement = 1
                self.controls.run = true
            elseif done.walking and not done.walked then
                done.walked = true
                self.controls.movement = 0
                local c = atGround(1000, -1500, 0)
                log('after walking: distance to the tent centre', (self.position - c):length(), 'pos', self.position)
            end
            once('hour_night', 90, function() dbg({ cmd = 'hour', hour = 22.2 }) end)
            view('beds', 92, function() return atGround(-500, -950, 80) end, function() return atGround(-760, -950, 30) end, 12)
            once('hour_morning', 106, function() dbg({ cmd = 'hour', hour = 6.2 }) end)
            view('breakfast', 112, function() return atGround(0, -1250, 80) end, function() return atGround(0, -900, 60) end, 4)
            once('hour_work', 119, function() dbg({ cmd = 'hour', hour = 8 }) end)
            once('dump', 121, function() dbg({ cmd = 'fxdump' }) end)
            once('placeFence', 122, function()
                -- aim near the end of the fence line: it must snap on
                self:sendEvent('TMW_DebugPlace', { kind = 'fence', at = atGround(-300 - 264 + 50, -560 + 60) })
            end)
            once('placeConfirm', 124, function() self:sendEvent('TMW_DebugPlace', { confirm = true }) end)
            once('placeBed', 125, function() self:sendEvent('TMW_DebugPlace', { kind = 'bed', at = atGround(1000, -1500) }) end)
            once('placeBedConfirm', 127, function() self:sendEvent('TMW_DebugPlace', { confirm = true }) end)
            once('stash', 128, function() dbg({ cmd = 'stash' }) end)
            once('openChest', 129, function() dbg({ cmd = 'activate', kind = 'chest' }) end)
            once('openGate', 131, function() dbg({ cmd = 'activate', kind = 'gate' }) end)
            once('gateState', 132.5, function()
                for _, s in ipairs(snap.sites) do
                    if s.kind == 'gate' then log('gate state:', types.Door.getDoorState(s.obj), 'open?', types.Door.isOpen(s.obj)) end
                end
            end)
            once('removeChest', 133, function()
                log('saltrice before', types.Actor.inventory(self):countOf('ingred_saltrice_01'))
                dbg({ cmd = 'removekind', kind = 'chest' })
            end)
            once('afterRemove', 134.5, function()
                log('saltrice after removing the chest', types.Actor.inventory(self):countOf('ingred_saltrice_01'))
            end)
            once('dump2', 135, function()
                dbg({ cmd = 'fxdump' })
                for _, s in ipairs(snap.sites) do
                    if s.kind == 'fence' or s.kind == 'bed' then log('placed', s.id, s.kind, s.built, s.pos, 'yaw', s.yaw) end
                end
            end)
            if t >= nextSummary then
                nextSummary = nextSummary + 8
                summary()
            end
            -- a settler walks in through the tent's door to build the bed
            view('tentbed', 136, function() return atGround(1000, -1500 - 700, 60) end, function() return atGround(1000, -1500, 60) end, 30)
            if t > 136 and t < 195 and not done.tentBuilt then
                nextTent = (nextTent or 0) - dt
                if nextTent <= 0 then
                    nextTent = 3
                    for _, s in ipairs(snap.sites) do
                        if s.kind == 'bed' and (s.pos - atGround(1000, -1500, 0)):length() < 100 then
                            local near = {}
                            for _, w in ipairs(snap.workers) do
                                if w.obj and w.obj:isValid() and w.status:find('Bed') then
                                    near[#near + 1] = w.status .. string.format(' d=%.0f', (w.obj.position - s.pos):length())
                                end
                            end
                            log('tent bed', s.built, s.status, table.concat(near, '; '))
                            if s.built then done.tentBuilt = true end
                        end
                    end
                end
            end
            once('quit', 198, function()
                summary()
                log('done')
                core.quit()
            end)
        end,
    },
    eventHandlers = { TMW_State = function(s) snap = s end },
}
