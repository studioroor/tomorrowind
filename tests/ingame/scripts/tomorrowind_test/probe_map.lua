-- Dev-only: an ASCII map of the meadow around VILLAGE: trees and rocks (#),
-- steep ground (/), water (~). One cell = 150 units; north is up.
local core = require('openmw.core')
local util = require('openmw.util')
local self = require('openmw.self')
local nearby = require('openmw.nearby')
local v3 = util.vector3
local VILLAGE = v3(-2504, -55848, 1300)
local t, row, lines = 0, nil, {}
local STEP, N = 150, 24
return { engineHandlers = { onUpdate = function(dt)
    t = t + dt
    if t < 2 then return end
    if t < 3 then core.sendGlobalEvent('TMW_Debug', { cmd = 'tp', pos = VILLAGE + v3(0, 0, 1500), lookAt = VILLAGE + v3(0, 100, 0) }) return end
    if t < 6 then return end
    row = row or N
    if row < -N then
        print('[MAP] x from ' .. (-N * STEP) .. ' to ' .. (N * STEP) .. ', y from ' .. (N * STEP) .. ' (top) down')
        for _, l in ipairs(lines) do print('[MAP] ' .. l) end
        core.quit()
        row = -1e9
        return
    end
    local l = {}
    for col = -N, N do
        local p = v3(VILLAGE.x + col * STEP, VILLAGE.y + row * STEP, 0)
        local g = core.land.getHeightAt(p, self.cell)
        local ch = '.'
        if g < 0 then ch = '~'
        else
            local gx = core.land.getHeightAt(p + v3(75, 0, 0), self.cell) - core.land.getHeightAt(p - v3(75, 0, 0), self.cell)
            local gy = core.land.getHeightAt(p + v3(0, 75, 0), self.cell) - core.land.getHeightAt(p - v3(0, 75, 0), self.cell)
            if math.sqrt(gx * gx + gy * gy) > 75 then ch = '/' end
            local r = nearby.castRay(v3(p.x, p.y, g + 2500), v3(p.x, p.y, g + 40), { collisionType = nearby.COLLISION_TYPE.World })
            if r.hit then ch = '#' end
        end
        if col == 0 and row == 0 then ch = 'O' end
        l[#l + 1] = ch
    end
    lines[#lines + 1] = string.format('%5d ', row * STEP) .. table.concat(l)
    row = row - 1
end } }
