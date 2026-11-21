-- Dev-only: maps a spot for laying out a trailer set: the land height on a
-- grid, and every object around (set_map_global.lua). tools/set_map.py draws it.
-- Run: SET_X=.. SET_Y=.. is not possible in Lua: edit CENTRE below.
--   TEST_CONTENT=set_map.omwscripts SHOTS="" tools/playtest.sh <out> Pelagiad
local core = require('openmw.core')
local util = require('openmw.util')
local self = require('openmw.self')
local types = require('openmw.types')
local v3 = util.vector3

local CENTRE = v3(45056, -69632, 0) -- the middle of cell (5, -9), east of Vivec
local R, STEP = 3200, 100

local t, row = 0, nil
local function dbg(e) core.sendGlobalEvent('TMW_Debug', e) end

return { engineHandlers = {
    onUpdate = function(dt)
        if dt <= 0 then return end
        t = t + dt
        local hp = types.Actor.stats.dynamic.health(self)
        if hp.current < hp.base then hp.current = hp.base end
        if t < 1 then return end
        if t < 2 then
            dbg({ cmd = 'tp', pos = CENTRE + v3(0, -500, 3000), lookAt = CENTRE })
            t = 2
            return
        end
        if t < 7 then return end
        if not row then
            print(string.format('[SM] centre %.0f %.0f r %d step %d', CENTRE.x, CENTRE.y, R, STEP))
            core.sendGlobalEvent('SM_Objects', { pos = CENTRE, r = R })
            row = -R
        end
        -- a few rows a frame
        for _ = 1, 4 do
            if row > R then
                if t > 12 then core.quit() end
                return
            end
            local parts = {}
            for x = -R, R, STEP do
                local h = core.land.getHeightAt(v3(CENTRE.x + x, CENTRE.y + row, 0), self.cell)
                parts[#parts + 1] = string.format('%.0f', h)
            end
            print('[SM] row ' .. row .. ' ' .. table.concat(parts, ' '))
            -- the ground texture every 200: roads and paths are their own
            if row % 200 == 0 then
                local tex = {}
                for x = -R, R, 200 do
                    local ok, tx = pcall(core.land.getTextureAt, v3(CENTRE.x + x, CENTRE.y + row, 0), self.cell)
                    tex[#tex + 1] = ok and tx and tostring(tx):gsub('.*[/\\]', ''):gsub('%.dds$', ''):gsub('%.tga$', '') or '?'
                end
                print('[SM] tex ' .. row .. ' ' .. table.concat(tex, ' '))
            end
            row = row + STEP
        end
    end,
} }
