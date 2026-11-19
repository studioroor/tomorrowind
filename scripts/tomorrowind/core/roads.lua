-- The colony's road network, as straight segments. Pure Lua: decides where
-- the road of a new building goes. Each building gets one road, from the
-- edge of its plot to the nearest point of an existing road, or to the edge
-- of the storehouse's plot (the town centre) when that is nearer.

local R = {}

local function dist(a, b)
    return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2)
end

-- The point of segment a-b closest to p, and its distance to p.
function R.closest(p, a, b)
    local dx, dy = b.x - a.x, b.y - a.y
    local len2 = dx * dx + dy * dy
    local t = 0
    if len2 > 0 then
        t = math.max(0, math.min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
    end
    local q = { x = a.x + dx * t, y = a.y + dy * t }
    return q, dist(p, q)
end

-- roads: list of { a = {x, y}, b = {x, y} }
-- center: the storehouse's position; centerRadius: its plot radius
-- p: the new building's position; r: its plot radius
-- cfg: { minLength, maxLength }
-- Returns the new segment { a = start, b = end }, or nil when the plot
-- already touches a road (or the centre) or the town is too far away.
function R.connect(roads, center, centerRadius, p, r, cfg)
    local toCenter = dist(p, center)
    local target, d = nil, toCenter - centerRadius
    for _, s in ipairs(roads) do
        local q, dq = R.closest(p, s.a, s.b)
        if dq < d then target, d = q, dq end
    end
    if not target then
        if toCenter <= 0 then return nil end
        -- stop at the edge of the storehouse's plot
        local k = centerRadius / toCenter
        target = { x = center.x + (p.x - center.x) * k, y = center.y + (p.y - center.y) * k }
    end
    local len = dist(p, target)
    if len - r < cfg.minLength or len > cfg.maxLength then return nil end
    -- start at the edge of the new plot, heading for the target
    local k = r / len
    local start = { x = p.x + (target.x - p.x) * k, y = p.y + (target.y - p.y) * k }
    return { a = start, b = { x = target.x, y = target.y } }
end

return R
