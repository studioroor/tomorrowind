-- Terraforming on OpenTW, the OpenMW fork that can change the land at runtime
-- (docs/opentw.md). There the ground under a new building is levelled to its
-- floor and paved, and the landscaping tool (L) raises, lowers, levels and
-- paints the land.
--
-- Plain OpenMW has no world.terrain: then nothing here changes the land and
-- buildings stand on their pilings as before. Edits are still kept, so a save
-- made on OpenTW keeps its landscape when it passes through plain OpenMW.
--
-- The engine forgets terrain edits when a game is loaded, so every edit is
-- recorded here, saved, and replayed after loading.
local world = require('openmw.world')
local util = require('openmw.util')
local defs = require('scripts.tomorrowind.defs')
local roads = require('scripts.tomorrowind.core.roads')

local L = { ops = {}, roads = {} }

function L.available()
    return world.terrain ~= nil
end

local function run(op)
    local T = world.terrain
    local at = util.vector3(op.x, op.y, 0)
    if op.k == 'flatten' then
        T.flatten(at, op.r, op.h, op.f)
    elseif op.k == 'raise' then
        T.raise(at, op.r, op.h, op.f)
    elseif op.k == 'paint' then
        T.paint(at, op.r, op.tex)
    elseif op.k == 'line' then
        T.paintLine(at, util.vector3(op.bx, op.by, 0), op.r, op.tex)
    else
        error('unknown terrain edit ' .. tostring(op.k))
    end
end

-- op: { k = 'flatten' | 'raise' | 'paint', x, y, r, h (height or delta), f (falloff), tex }
function L.apply(op)
    if not L.available() then return false end
    local ok, err = pcall(run, op)
    if not ok then
        print('[Tomorrowind] terrain edit failed: ' .. tostring(err))
        return false
    end
    L.ops[#L.ops + 1] = op
    return true
end

-- A plain copy of an op that came in from the player script.
function L.sanitize(e)
    if type(e) ~= 'table' or type(e.x) ~= 'number' or type(e.y) ~= 'number' or type(e.r) ~= 'number' then return nil end
    local op = { k = e.k, x = e.x, y = e.y, r = e.r, h = tonumber(e.h), f = tonumber(e.f), tex = e.tex }
    if (op.k == 'flatten' or op.k == 'raise') and op.h then return op end
    if op.k == 'paint' and type(op.tex) == 'string' then return op end
end

-- A road from a new building to the nearest road, or to the storehouse.
local function addRoad(c, s, r)
    local cfg = defs.landscape.road
    local store = c and c.storehouse and c.sites[c.storehouse]
    if not store or store.id == s.id or cfg.skip[s.kind] or not world.terrain.paintLine then return end
    local storeDef = defs.buildings[store.kind]
    local centerR = (store.radius or storeDef.footprint) * defs.landscape.paintScale
    local seg = roads.connect(L.roads, store.pos, centerR, s.pos, r * defs.landscape.paintScale, cfg)
    if not seg then return end
    if L.apply({ k = 'line', x = seg.a.x, y = seg.a.y, bx = seg.b.x, by = seg.b.y, r = cfg.width, tex = cfg.texture }) then
        L.roads[#L.roads + 1] = seg
    end
end

-- Level and pave the ground under a newly placed building, and lay a road to
-- the town. Not furnishings, and not indoors.
function L.prepareSite(s, c)
    local d = defs.buildings[s.kind]
    if not L.available() or not d or d.small or s.host then return end
    local cfg = defs.landscape
    local r = s.radius or d.footprint or 200
    -- marks the site so it gets no pilings: the ground is at its floor now
    s.terraformed = L.apply({ k = 'flatten', x = s.pos.x, y = s.pos.y, r = r, h = s.pos.z,
        f = math.max(cfg.minFalloff, r * cfg.falloff) }) or nil
    local tex = cfg.paint[s.kind] or cfg.paint.default
    if tex then L.apply({ k = 'paint', x = s.pos.x, y = s.pos.y, r = r * cfg.paintScale, tex = tex }) end
    addRoad(c, s, r)
end

function L.save()
    return { ops = L.ops, roads = L.roads }
end

-- After loading: the engine starts from the untouched land again.
function L.load(data)
    data = data or {}
    local saved = data.ops or data -- older saves: just the list of edits
    L.ops, L.roads = {}, data.roads or {}
    if not L.available() then
        L.ops = saved
        return
    end
    for _, op in ipairs(saved) do L.apply(op) end
end

return L
