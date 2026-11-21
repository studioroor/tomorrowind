-- Dev-only: everything that stands around a spot, with its size, for
-- set_map.lua (tools/set_map.py draws it).
local world = require('openmw.world')
local types = require('openmw.types')
local util = require('openmw.util')

return { eventHandlers = { SM_Objects = function(e)
    local p, r = e.pos, e.r
    local gx, gy = math.floor(p.x / 8192), math.floor(p.y / 8192)
    local n = 0
    for dx = -1, 1 do
        for dy = -1, 1 do
            local okC, cell = pcall(world.getExteriorCell, gx + dx, gy + dy)
            if okC and cell then
                for _, t in ipairs({ types.Static, types.Container, types.Activator, types.Door, types.Light }) do
                    local ok, list = pcall(cell.getAll, cell, t)
                    for _, o in ipairs(ok and list or {}) do
                        local q = o.position
                        if o.enabled and util.vector2(q.x - p.x, q.y - p.y):length() <= r then
                            local okB, box = pcall(o.getBoundingBox, o)
                            local rad = okB and box and math.max(box.halfSize.x, box.halfSize.y) or 50
                            print(string.format('[SM] obj %s %.0f %.0f %.0f %.0f', o.recordId, q.x, q.y, q.z, rad))
                            n = n + 1
                        end
                    end
                end
            end
        end
    end
    print('[SM] objects', n)
end } }
