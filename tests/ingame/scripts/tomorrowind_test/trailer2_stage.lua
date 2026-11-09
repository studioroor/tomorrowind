-- Dev-only: the 0.2 trailer's set, to arrange by hand before filming. Builds
-- the village and the bridge set, then leaves you to it: move, delete and
-- place things with the mod's own tools (building finishes at once, and the
-- storehouse and treasury stay full). Every couple of seconds the bridge set
-- is written to the log; tools/stage_trailer.sh turns the last one into
-- trailer2_layout.lua when you quit.
local core = require('openmw.core')
local util = require('openmw.util')
local self = require('openmw.self')
local types = require('openmw.types')
local nearby = require('openmw.nearby')
local ui = require('openmw.ui')
local SET = require('scripts.tomorrowind_test.trailer2_set')

local v3 = util.vector3
local VILLAGE = SET.VILLAGE
local snap
local t, nextFinish, nextExport, lastExport = 0, 0, 0, nil
local done = {}
local function log(...) print('[STAGE]', ...) end
local function dbg(e) core.sendGlobalEvent('TMW_Debug', e) end
local function land(dx, dy, lift)
    local p = v3(VILLAGE.x + dx, VILLAGE.y + dy, 0)
    return v3(p.x, p.y, core.land.getHeightAt(p, self.cell) + (lift or 0))
end
local function roofAt(p)
    local r = nearby.castRay(v3(p.x, p.y, p.z + 3000), v3(p.x, p.y, p.z - 200), { collisionType = nearby.COLLISION_TYPE.World })
    return r.hit and r.hitPos or p
end
local function once(key, at, fn)
    if not done[key] and t >= at then
        done[key] = true
        local ok, err = pcall(fn)
        if not ok then log('error in', key, err) end
    end
end
local ctx = { dbg = dbg, land = land, roofAt = roofAt, log = log }

-- the bridge set as Lua, one piece per line
local function export()
    local lines = {}
    for _, s in ipairs(snap.sites) do
        if s.built and SET.inSet(s) then
            lines[#lines + 1] = string.format("{ '%s', %s, %.1f, %.1f, %.1f, %.4f },", s.kind,
                s.variant and tostring(s.variant) or 'nil', s.pos.x, s.pos.y, s.pos.z, s.yaw or 0)
        end
    end
    local text = table.concat(lines, '\n')
    if text == lastExport then return end
    lastExport = text
    print('[STAGE-LAYOUT] BEGIN')
    for _, l in ipairs(lines) do print('[STAGE-LAYOUT] ' .. l) end
    print('[STAGE-LAYOUT] END')
end

return {
    engineHandlers = {
        onUpdate = function(dt)
            if dt <= 0 then return end
            t = t + dt
            local hp = types.Actor.stats.dynamic.health(self)
            if hp.current < hp.base then hp.current = hp.base end
            once('tp', 1, function() dbg({ cmd = 'tp', pos = VILLAGE + v3(0, -600, 1000), lookAt = VILLAGE }) end)
            once('found', 4, function()
                core.sendGlobalEvent('TMW_Found', { yaw = 0, pos = land(0, 0, 0) })
                dbg({ cmd = 'quiet', on = true })
            end)
            once('village', 6, function()
                for _, it in ipairs(SET.village) do
                    dbg({ cmd = 'build', kind = it[1], pos = land(it[2], it[3]), variant = it[4], yaw = it[5], built = true })
                end
                SET.buildSet(1, ctx)
            end)
            once('bridge', 7.5, function() SET.buildSet(2, ctx) end)
            once('look', 8, function()
                -- beside the set, looking at it
                local c = SET.setCentre
                dbg({ cmd = 'tp', pos = land(c[1] + 1100, c[2] - 300, 60), lookAt = land(c[1], c[2], 300) })
                ui.showMessage('Staging the bridge set. Look at a house, the bridge or the stairs and press M to move it '
                    .. '(Z/X turn, Up/Down height, Enter to put it down). Building finishes at once. Quit when it looks right.')
                log(SET.layout and 'started from trailer2_layout.lua' or 'started from the default layout')
            end)
            if not done.look or not snap or not snap.founded then return end
            if t >= nextFinish then
                nextFinish = t + 1
                dbg({ cmd = 'finish' })
                local top = {}
                for res, low in pairs({ wood = 200, ore = 100, ingot = 50, food = 100 }) do
                    if (snap.stock[res] or 0) < low then top[res] = low end
                end
                dbg({ cmd = 'give', amounts = top, gold = (snap.gold or 0) < 2000 and 2000 or nil })
            end
            if t >= nextExport then
                nextExport = t + 2
                export()
            end
        end,
    },
    eventHandlers = { TMW_State = function(s) snap = s end },
}
