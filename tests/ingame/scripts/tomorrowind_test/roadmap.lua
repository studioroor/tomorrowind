-- Dev-only: a map of the ground textures around a spot, to find the roads
-- (for placing shots: settlers walk on the road, houses stand beside it).
-- Logs a letter per texture on a grid, north up, and which texture is which.
-- Run: TEST_CONTENT=roadmap.omwscripts SHOTS="" tools/playtest.sh <out> Pelagiad
local core = require('openmw.core')
local util = require('openmw.util')
local self = require('openmw.self')

local v3 = util.vector3
local VILLAGE = v3(-2504, -55848, 1300)
local CENTER = v3(VILLAGE.x + 1100 - 1500, VILLAGE.y - 350 - 700, 0) -- in front of the poster camera
local HALF, STEP = 3000, 100
local t, done = 0, {}
local function log(...) print('[ROADMAP]', ...) end

local function texture(x, y)
    local ok, tex = pcall(core.land.getTextureAt, v3(x, y, 0), self.cell)
    if not ok then return 'ERR:' .. tostring(tex) end
    return tostring(tex)
end

return {
    engineHandlers = {
        onUpdate = function(dt)
            t = t + dt
            if t > 2 and not done.tp then
                done.tp = true
                core.sendGlobalEvent('TMW_Debug', { cmd = 'tp', pos = v3(CENTER.x, CENTER.y, 1800), lookAt = VILLAGE })
            end
            if t > 6 and done.tp and not done.map then
                done.map = true
                local letters, legend, next = {}, {}, 65
                log(string.format('center %.0f %.0f, %d units per letter, north up', CENTER.x, CENTER.y, STEP))
                for y = CENTER.y + HALF, CENTER.y - HALF, -STEP do
                    local row = {}
                    for x = CENTER.x - HALF, CENTER.x + HALF, STEP do
                        local tex = texture(x, y)
                        if not letters[tex] then
                            letters[tex] = string.char(next)
                            legend[#legend + 1] = letters[tex] .. ' = ' .. tex
                            next = next + 1
                            if next == 91 then next = 97 end
                        end
                        row[#row + 1] = letters[tex]
                    end
                    log('|' .. table.concat(row) .. '|')
                end
                for _, l in ipairs(legend) do log(l) end
            end
            if t > 9 then core.quit() end
        end,
    },
}
