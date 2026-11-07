-- Dev-only: the living colony: board, labels, rising buildings, downtime,
-- leaving and coming back, traffic through a tent door.
-- Run: TEST_CONTENT=life.omwscripts SHOTS="" tools/playtest.sh <out> Pelagiad
local core = require('openmw.core')
local camera = require('openmw.camera')
local util = require('openmw.util')
local self = require('openmw.self')
local types = require('openmw.types')
local debug = require('openmw.debug')
local I = require('openmw.interfaces')
local defs = require('scripts.tomorrowind.defs')

local t, snap = 0, nil
local done = {}
local holdAt
local shotN = -1
local function log(...) print('[TMW-LIFE]', ...) end
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
local function siteOf(kind)
    for _, s in ipairs(snap.sites) do if s.kind == kind then return s end end
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
local function summary()
    if not snap or not snap.founded then return end
    log(string.format('--- t=%.0f %02d:%02d pop=%d/%d food=%d wood=%d ore=%d ingot=%d', t, math.floor(snap.hour), math.floor((snap.hour % 1) * 60),
        snap.pop, snap.beds, snap.stock.food, snap.stock.wood, snap.stock.ore, snap.stock.ingot))
    for _, w in ipairs(snap.workers) do log('  ', w.name, '|', w.job:sub(1, 12), '|', w.status) end
end
local nextSummary = 10

return {
    engineHandlers = {
        onUpdate = function(dt)
            t = t + dt
            local hp = types.Actor.stats.dynamic.health(self)
            if hp.current < hp.base then hp.current = hp.base end
            aim()
            once('cam', 1, function()
                I.Camera.disableModeControl('life')
                camera.setMode(camera.MODE.FirstPerson)
                dbg({ cmd = 'tp', pos = util.vector3(-904, -56848, 1400), lookAt = util.vector3(-904, -56248, 1400) })
            end)
            once('found', 3, function() core.sendGlobalEvent('TMW_Found', { yaw = 0, pos = util.vector3(-904, -56248, 1300) }) end)
            once('debug', 4, function() dbg({ cmd = 'debug', on = true }) end)
            once('setup', 5, function()
                dbg({ cmd = 'give', amounts = { ore = 60, wood = 200, ingot = 20, food = 80 } })
                dbg({ cmd = 'build', kind = 'lumber', pos = offset(-900, -1000), built = true })
                dbg({ cmd = 'build', kind = 'mine', pos = offset(1000, -300), built = true })
                dbg({ cmd = 'build', kind = 'campfire', pos = offset(0, -900), built = true })
                dbg({ cmd = 'build', kind = 'table', pos = offset(-300, -1000), built = true })
                dbg({ cmd = 'build', kind = 'bookshelf', pos = offset(300, -1000), built = true })
                -- a pile of blueprints: only one label may show
                for i = -3, 3 do dbg({ cmd = 'build', kind = 'chair', pos = offset(i * 120, -600), built = false }) end
            end)
            once('crowd', 6, function() dbg({ cmd = 'spawn', n = 6 }) end)
            once('assign', 7, function() core.sendGlobalEvent('TMW_Assign', { wid = snap.workers[1].id, target = siteOf('mine').id }) end)
            once('view_labels', 9, function() go(atGround(0, -950, 80), function() return atGround(0, -600, 40) end) end)
            once('shot_labels', 12, function() shot('blueprints: one label') end)
            -- the board
            once('view_board', 15, function()
                local b = siteOf('board')
                log('board at', b.pos, 'yaw', b.yaw)
                go(b.pos + util.vector3(0, -300, 80), b.pos + util.vector3(0, 0, 170))
            end)
            once('shot_board', 18, function() shot('board up close') end)
            once('activate_board', 19, function() dbg({ cmd = 'activate', kind = 'board' }) end)
            once('ledger_shot', 20.5, function() log('ui mode', I.UI.getMode()); shot('ledger from the board') end)
            once('ledger_close', 22, function() self:sendEvent('TMW_DebugLedger', { open = false }) end)
            -- a rising building
            once('house', 24, function()
                local g = atGround(1300, -2000)
                dbg({ cmd = 'build', kind = 'house', pos = g, built = false, leveled = true, radius = 570 })
            end)
            once('view_house', 25, function() go(atGround(1300, -3400, 80), atGround(1300, -2000, 200)) end)
            once('h1', 27, function() dbg({ cmd = 'sitestate', kind = 'house', delivered = 1, progress = 0.05 }) end)
            once('sh1', 29.5, function() shot('rising 5%') end)
            once('h2', 30, function() dbg({ cmd = 'sitestate', kind = 'house', delivered = 1, progress = 0.45 }) end)
            once('sh2', 32.5, function() shot('rising 45%') end)
            once('h3', 33, function() dbg({ cmd = 'sitestate', kind = 'house', delivered = 1, progress = 0.85 }) end)
            once('sh3', 35.5, function() shot('rising 85%') end)
            once('h4', 36, function() dbg({ cmd = 'finish' }) end)
            once('sh4', 38.5, function() shot('built') end)
            -- walls
            once('walls', 39, function()
                for i = 0, 3 do dbg({ cmd = 'build', kind = 'wall', pos = offset(-1400 + i * 2 * defs.buildings.wall.segment.half, -1500), built = true }) end
            end)
            once('view_wall', 40, function() go(atGround(-1400 + 252 * 1, -1900, 80), atGround(-1400 + 252 * 1 + 126, -1500, 90)) end)
            once('sh_wall', 43, function() shot('stone walls') end)
            -- settlers talking: look at the first pair we can find
            if t > 44 and t < 57 and not done.chatSeen then
                for _, w in ipairs(snap.workers) do
                    if w.status:find('Chatting') and w.obj:isValid() and (w.obj.position - self.position):length() > 1 then
                        done.chatSeen = t
                        local p = w.obj.position
                        go(p + util.vector3(180, -180, 60), function() return w.obj.position + util.vector3(0, 0, 90) end)
                        log('watching', w.name, w.status)
                        done.chatWid = w.id
                        break
                    end
                end
            end
            if done.chatSeen then
                once('say', done.chatSeen + 2, function() dbg({ cmd = 'say', wid = done.chatWid, voice = 'chat' }) end)
                once('sh_chat', done.chatSeen + 3, function() shot('chatting') end)
            end
            -- leave
            once('before_away', 58, function()
                summary()
                dbg({ cmd = 'build', kind = 'bench', pos = offset(0, -1300), built = false })
                log('leaving; stock ore', snap.stock.ore, 'wood', snap.stock.wood)
            end)
            once('away', 59, function()
                holdAt = nil
                dbg({ cmd = 'tp', pos = util.vector3(-22000, -14000, 1500), lookAt = util.vector3(-22000, -13000, 1500) })
            end)
            once('away_check', 90, function() summary() end)
            once('back', 92, function()
                dbg({ cmd = 'tp', pos = util.vector3(-904, -56848, 1400), lookAt = util.vector3(-904, -56248, 1400) })
            end)
            once('after_away', 97, function()
                summary()
                local b = siteOf('bench')
                log('bench', b and b.built, b and b.status)
            end)
            -- traffic through a tent door
            once('tent', 98, function() dbg({ cmd = 'build', kind = 'tent', pos = offset(1000, -1500), built = true }) end)
            once('tentstuff', 100, function()
                dbg({ cmd = 'build', kind = 'bed', pos = offset(1000, -1400), built = false })
                dbg({ cmd = 'build', kind = 'bedroll', pos = offset(850, -1500), built = false })
                dbg({ cmd = 'build', kind = 'chest', pos = offset(1150, -1500), built = false })
                dbg({ cmd = 'build', kind = 'bookshelf', pos = offset(1000, -1250), built = false })
                log('tent furniture placed')
            end)
            once('view_door', 101, function() go(atGround(1000, -2300, 80), atGround(1000, -1800, 60)) end)
            once('sh_door', 108, function() shot('tent door traffic') end)
            once('sh_door2', 118, function() shot('tent door traffic 2') end)
            if t >= nextSummary then
                nextSummary = nextSummary + 12
                summary()
            end
            once('quit', 125, function()
                summary()
                for _, s in ipairs(snap.sites) do
                    if s.small and not s.built then log('unbuilt', s.name, s.status) end
                end
                log('done')
                core.quit()
            end)
        end,
    },
    eventHandlers = { TMW_State = function(s) snap = s end },
}
