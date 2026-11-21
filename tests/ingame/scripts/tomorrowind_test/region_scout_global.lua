-- Dev-only: what stands around a spot, for region_scout.lua.
local world = require('openmw.world')
local types = require('openmw.types')
local util = require('openmw.util')

local function isTree(id)
    id = id:lower()
    return id:find('tree') ~= nil and not id:find('stump') and not id:find('branch') and not id:find('parts')
end

return { eventHandlers = { RS_Count = function(e)
    local p, r = e.pos, e.r
    local gx, gy = math.floor(p.x / 8192), math.floor(p.y / 8192)
    local trees, kinds, built, doors, npcs, cells, houses = 0, {}, {}, 0, 0, 0, 0
    local town = e.town or r
    for dx = -1, 1 do
        for dy = -1, 1 do
            local okC, cell = pcall(world.getExteriorCell, gx + dx, gy + dy)
            if okC and cell then
                cells = cells + 1
                local function each(t, fn, reach)
                    local ok, list = pcall(cell.getAll, cell, t)
                    for _, o in ipairs(ok and list or {}) do
                        if util.vector2(o.position.x - p.x, o.position.y - p.y):length() <= (reach or r) then fn(o) end
                    end
                end
                -- a town, a manor or a stronghold within `town`
                each(types.Static, function(o)
                    local id = o.recordId:lower()
                    if id:find('^ex_') and (id:find('house') or id:find('manor') or id:find('hlaalu_b') or id:find('common_b')
                        or id:find('shack') or id:find('tower') or id:find('stronghold') or id:find('velothi') or id:find('imp_')) then
                        houses = houses + 1
                    end
                end, town)
                each(types.Static, function(o)
                    local id = o.recordId:lower()
                    if isTree(id) then
                        trees = trees + 1
                        kinds[id] = (kinds[id] or 0) + 1
                    elseif id:find('^ex_') or id:find('^furn_') then
                        local k = id:gsub('_%d+$', '')
                        built[k] = (built[k] or 0) + 1
                    end
                end)
                each(types.Door, function() doors = doors + 1 end, town)
                each(types.NPC, function() npcs = npcs + 1 end)
            end
        end
    end
    local tk, bk = {}, {}
    for k, n in pairs(kinds) do tk[#tk + 1] = k .. '=' .. n end
    for k, n in pairs(built) do bk[#bk + 1] = k .. '=' .. n end
    table.sort(tk)
    table.sort(bk)
    print(string.format('[RS] count %s: cells=%d trees=%d doors=%d houses=%d npcs=%d | trees: %s | built: %s',
        e.name, cells, trees, doors, houses, npcs, table.concat(tk, ' '), table.concat(bk, ' ')))
    world.players[1]:sendEvent('RS_Counted', { name = e.name, trees = trees, doors = doors, houses = houses })
end } }
