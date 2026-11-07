-- Slope analysis for building placement. Pure Lua: takes ground heights
-- sampled across a building's footprint, decides the floor level and what
-- foundation it needs. Terrain itself can't be changed at runtime in
-- OpenMW, so "leveling" means sinking into the slope + pilings below.

local defs = require('scripts.tomorrowind.defs')

local T = {}

-- How deep a building may sink into a slope: taller buildings can hide
-- more of their uphill wall in the hillside.
function T.maxBurial(buildingHeight)
    return math.max(defs.slope.maxBurial, (buildingHeight or 0) * defs.slope.burialPerHeight)
end

-- heights: list of ground heights under the footprint (any order)
-- buildingHeight: optional, raises the burial limit for tall buildings
-- raise: optional, moves the floor up (or down) from where it would go
-- returns { ok, reason, level, low, high, depth, burial, wood, work }
function T.analyze(heights, buildingHeight, raise)
    local cfg = defs.slope
    local low, high = math.huge, -math.huge
    for _, h in ipairs(heights) do
        if h < low then low = h end
        if h > high then high = h end
    end
    if low == math.huge then return { ok = false, reason = 'look at open ground' } end
    local spread = high - low
    local level = low + spread * cfg.levelAt + (raise or 0)
    local r = {
        low = low, high = high, level = level,
        burial = high - level,
        depth = math.max(0, level - low - cfg.hiddenDepth),
    }
    r.wood = r.depth > 0 and math.ceil(r.depth * cfg.woodPerUnit) or 0
    r.work = r.depth > 0 and math.ceil(r.depth * cfg.workPerUnit) or 0
    if low < -20 then
        r.ok, r.reason = false, 'under water'
    elseif r.burial > T.maxBurial(buildingHeight) and (raise or 0) >= 0 then
        r.ok, r.reason = false, 'too steep'
    else
        r.ok = true
    end
    return r
end

-- Sample offsets (dx, dy) covering a circular footprint of radius r:
-- the centre plus two rings of 8.
function T.samplePoints(r)
    local pts = { { 0, 0 } }
    for _, f in ipairs({ 0.5, 0.95 }) do
        for i = 0, 7 do
            local a = i * math.pi / 4
            pts[#pts + 1] = { math.sin(a) * r * f, math.cos(a) * r * f }
        end
    end
    return pts
end

return T
