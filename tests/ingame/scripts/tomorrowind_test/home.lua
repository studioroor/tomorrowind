-- Dev-only: house doors, rooms and furniture per house, trade and caravans.
-- Run: TEST_CONTENT=home.omwscripts SHOTS="" tools/playtest.sh <out> Pelagiad
local core = require('openmw.core')
local camera = require('openmw.camera')
local util = require('openmw.util')
local self = require('openmw.self')
local types = require('openmw.types')
local debug = require('openmw.debug')
local I = require('openmw.interfaces')
local nearby = require('openmw.nearby')
local defs = require('scripts.tomorrowind.defs')
local interiors = require('scripts.tomorrowind.interiors')

local v3 = util.vector3
local VILLAGE = v3(-2504, -55848, 1300)
local t, snap = 0, nil
local done = {}
local shotN = -1
local function log(...) print('[TMW-HOME]', ...) end
local function once(key, at, fn)
    if not done[key] and t >= at then
        done[key] = true
        local ok, err = pcall(fn)
        if not ok then log('ERROR in', key, err) end
    end
end
local function dbg(e) core.sendGlobalEvent('TMW_Debug', e) end
local function shot(key) shotN = shotN + 1; log('shot', shotN, key, 't=', t); debug.takeScreenshot() end
local function land(dx, dy, lift)
    local p = v3(VILLAGE.x + dx, VILLAGE.y + dy, 0)
    return v3(p.x, p.y, core.land.getHeightAt(p, self.cell) + (lift or 0))
end
local function sites(kind)
    local out = {}
    for _, s in ipairs(snap.sites) do if s.kind == kind then out[#out + 1] = s end end
    return out
end
local function statics(pos, target)
    camera.setMode(camera.MODE.Static)
    camera.setStaticPosition(pos)
    local d = target - pos
    camera.setYaw(math.atan2(d.x, d.y))
    camera.setPitch(math.atan2(pos.z - target.z, util.vector2(d.x, d.y):length()))
end

-- the door checks: one house at a time on the same spot
local VARIANTS = {}
local SPOT = { 1000, 1300 }
local PER = 2.6
local START_DOORS = 7
local AFTER_DOORS = START_DOORS + #VARIANTS * PER + 1

local function doorCheck()
    local i = math.floor((t - START_DOORS) / PER) + 1
    if i < 1 or i > #VARIANTS then return end
    local v = VARIANTS[i]
    local phase = (t - START_DOORS) % PER
    local key = 'dv' .. i
    once(key .. 'b', START_DOORS + (i - 1) * PER, function()
        dbg({ cmd = 'build', kind = 'house', variant = v, pos = land(SPOT[1], SPOT[2]), built = true, yaw = 0 })
    end)
    local h = sites('house')[1]
    if h and h.variant == v and phase > 0.4 then
        local look = defs.look('house', v)
        local d = look.door
        local rot = util.transform.rotateZ(h.yaw)
        local door = h.pos + v3(0, 0, look.lift or 0) + rot * v3(d.offset[1], d.offset[2], d.offset[3])
        local out = util.transform.rotateZ(h.yaw + d.turn) * v3(0, -1, 0)
        statics(door + out * 620 + v3(0, 0, 120), door + v3(0, 0, 20))
        once(key .. 's', START_DOORS + (i - 1) * PER + 1.6, function() shot('door variant ' .. v .. ' ' .. look.label) end)
    end
    once(key .. 'r', START_DOORS + i * PER - 0.25, function() dbg({ cmd = 'removekind', kind = 'house' }) end)
end

local A = AFTER_DOORS
local HOUSE1, HOUSE2, SHACK, TIMBER, BIG = { 1000, 1300 }, { -1000, 1400 }, { 1700, -300 }, { -1700, -300 }, { 100, -1600 }
local function firstPerson() camera.setMode(camera.MODE.FirstPerson) end
local function look(yaw, pitch) camera.setYaw(yaw); camera.setPitch(pitch or 0.15) end

return {
    engineHandlers = {
        onUpdate = function(dt)
            t = t + dt
            local hp = types.Actor.stats.dynamic.health(self)
            if hp.current < hp.base then hp.current = hp.base end
            once('ui', 1, function()
                I.Camera.disableModeControl('home')
                dbg({ cmd = 'tp', pos = VILLAGE + v3(0, -600, 1000), lookAt = VILLAGE })
            end)
            once('found', 3.5, function() core.sendGlobalEvent('TMW_Found', { yaw = 0, pos = land(0, 0, 0) }) end)
            once('setup', 5, function()
                dbg({ cmd = 'debug', on = true })
                dbg({ cmd = 'give', amounts = { food = 100, wood = 100, ore = 40, ingot = 30 } })
            end)
            doorCheck()
            -- rooms: two identical houses and two others
            once('houses', A, function()
                dbg({ cmd = 'build', kind = 'house', variant = 2, pos = land(HOUSE1[1], HOUSE1[2]), built = true })
                dbg({ cmd = 'build', kind = 'house', variant = 2, pos = land(HOUSE2[1], HOUSE2[2]), built = true })
                dbg({ cmd = 'build', kind = 'house', variant = 10, pos = land(SHACK[1], SHACK[2]), built = true })
                dbg({ cmd = 'build', kind = 'house', variant = 9, pos = land(TIMBER[1], TIMBER[2]), built = true })
                dbg({ cmd = 'build', kind = 'house', variant = 4, pos = land(BIG[1], BIG[2]), built = true })
                firstPerson()
            end)
            local function room(name, at, where, n)
                once(name .. '_go', at, function() dbg({ cmd = 'enter', at = land(where[1], where[2]) }) end)
                once(name .. '_log', at + 1.5, function() log(name, 'inside', snap.insideHost, 'at', self.position, 'cell', self.cell.name) end)
                for i = 0, (n or 1) do
                    once(name .. '_look' .. i, at + 1.6 + i * 1.1, function()
                        -- from the middle of the room
                        local h_
                        for _, s in ipairs(snap.sites) do if s.id == snap.insideHost then h_ = s end end
                        local room_ = interiors[defs.look(h_.kind, h_.variant).door.interior]
                        local minx, maxx, miny, maxy, minz = 1e9, -1e9, 1e9, -1e9, 1e9
                        for _, q in ipairs(room_.pieces) do
                            minx, maxx = math.min(minx, q[2]), math.max(maxx, q[2])
                            miny, maxy = math.min(miny, q[3]), math.max(maxy, q[3])
                        end
                        local o = v3(math.floor(self.position.x / defs.roomSpacing + 0.5) * defs.roomSpacing, 0, 0)
                        local c = o + v3((minx + maxx) / 2, (miny + maxy) / 2, self.position.z + 95)
                        local a = i * 2.1
                        camera.setMode(camera.MODE.Static)
                        camera.setStaticPosition(c - v3(math.sin(a) * 170, math.cos(a) * 170, 0))
                        camera.setYaw(a)
                        camera.setPitch(0.18)
                    end)
                    once(name .. '_shot' .. i, at + 2.3 + i * 1.1, function() shot(name .. ' view ' .. i) end)
                end
            end
            local R1 = A + 1
            room('house1', R1, HOUSE1, 2)
            once('place1', R1 + 6, function()
                look(0, 0.55)
                local p = self.position
                self:sendEvent('TMW_DebugPlace', { kind = 'bed', at = v3(p.x + 40, p.y + 130, p.z) })
            end)
            once('place1b', R1 + 7, function() self:sendEvent('TMW_DebugPlace', { confirm = true }) end)
            once('place2', R1 + 7.5, function()
                local p = self.position
                self:sendEvent('TMW_DebugPlace', { kind = 'table', at = v3(p.x - 110, p.y + 170, p.z) })
            end)
            once('place2b', R1 + 8.5, function() self:sendEvent('TMW_DebugPlace', { confirm = true }) end)
            once('sites', R1 + 9.5, function()
                for _, s in ipairs(snap.sites) do if s.host then log('hosted', s.id, s.kind, s.host, s.pos, s.status) end end
            end)
            once('leave1', R1 + 10, function() dbg({ cmd = 'leave' }) end)
            once('leave1log', R1 + 11.5, function() log('left: at', self.position, 'cell', self.cell.name, 'insideHost', tostring(snap.insideHost)) end)
            -- settlers make the furniture while we're outside
            local R2 = R1 + 14
            once('builtcheck', R2 - 0.5, function()
                for _, s in ipairs(snap.sites) do if s.host then log('hosted', s.id, s.kind, 'built', s.built, s.status) end end
            end)
            room('house2_same_model', R2, HOUSE2, 0)
            once('leave2', R2 + 4, function() dbg({ cmd = 'leave' }) end)
            room('house1_again', R2 + 6, HOUSE1, 1)
            once('leave3', R2 + 10, function() dbg({ cmd = 'leave' }) end)
            room('shack', R2 + 12, SHACK, 1)
            once('leave4', R2 + 16, function() dbg({ cmd = 'leave' }) end)
            room('timber', R2 + 18, TIMBER, 1)
            once('leave5', R2 + 22, function() dbg({ cmd = 'leave' }) end)
            room('big', R2 + 24, BIG, 2)
            once('leave6', R2 + 29.5, function() dbg({ cmd = 'leave' }) end)
            -- trade
            local T = R2 + 31
            once('market', T, function()
                dbg({ cmd = 'removekind', kind = 'house' })
                dbg({ cmd = 'build', kind = 'market', pos = land(-400, -1000), built = true, yaw = 0 })
                dbg({ cmd = 'give', gold = 500 })
            end)
            once('trader', T + 1, function()
                core.sendGlobalEvent('TMW_Assign', { wid = snap.workers[1].id, target = sites('market')[1].id })
                log('gold at start', snap.gold)
            end)
            once('marketview', T + 2, function() statics(land(-650, -1500, 200), land(-400, -1000, 60)) end)
            once('marketshot', T + 4, function() shot('market stall') end)
            once('ledger', T + 5, function() firstPerson(); self:sendEvent('TMW_DebugLedger', { open = true, tab = 'trade' }) end)
            once('ledgershot', T + 6, function() shot('trade tab') end)
            once('ledgeroff', T + 7, function() self:sendEvent('TMW_DebugLedger', { open = false }) end)
            once('wants', T + 7.2, function() core.sendGlobalEvent('TMW_TradeSet', { res = 'ingot', want = 60 }) end)
            once('caravan', T + 8, function()
                log('before the caravan: gold', snap.gold, 'ingots', snap.stock.ingot, 'wood price', snap.trade.wood.sell)
                dbg({ cmd = 'caravan' })
            end)
            -- walking in, then at the stall
            if t > T + 9 and t < T + 42 and snap.caravanObj and snap.caravanObj:isValid() then
                local q = snap.caravanObj.position
                statics(q + v3(-420, -520, 260), q + v3(0, 0, 70))
            end
            once('caravanwalk', T + 11, function() shot('caravan arriving') end)
            once('caravanshot', T + 40, function()
                shot('caravan at the stall')
                local m = sites('market')[1]
                log('trader to market', (snap.caravanObj.position - m.pos):length())
                for _, a in ipairs(nearby.actors) do
                    if a.recordId == 'guar_pack' then log('guar to market', (a.position - m.pos):length()) end
                end
                log('caravan here', snap.caravan, 'gold', snap.gold, 'ingots', snap.stock.ingot, 'wood price', snap.trade.wood.sell)
            end)
            once('take', T + 41, function()
                log('player gold before', types.Actor.inventory(self):countOf('gold_001'))
                core.sendGlobalEvent('TMW_Treasury', { amount = 100 })
            end)
            once('take2', T + 42, function()
                log('player gold after taking', types.Actor.inventory(self):countOf('gold_001'), 'treasury', snap.gold)
                core.sendGlobalEvent('TMW_Treasury', { amount = -40 })
            end)
            once('give', T + 43, function()
                log('player gold after giving', types.Actor.inventory(self):countOf('gold_001'), 'treasury', snap.gold)
            end)
            once('demolish', T + 44, function()
                for _ = 1, 5 do dbg({ cmd = 'removekind', kind = 'house' }) end
            end)
            once('after', T + 46, function()
                for _, s in ipairs(snap.sites) do if s.host then log('still hosted', s.id, s.kind, s.host) end end
                log('done')
                core.quit()
            end)
        end,
    },
    eventHandlers = { TMW_State = function(s) snap = s end },
}
