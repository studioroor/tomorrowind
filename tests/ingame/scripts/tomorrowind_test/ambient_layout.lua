-- Dev-only: the village of the ambient footage (ambient.lua films it,
-- ambient_scout.lua tries cameras and maps where people walk).
--
-- Where the roads are comes from the ground textures (roadmap.lua): the main
-- road runs north-south at about x = -2300, and a branch goes east from it
-- towards Pelagiad; its cobbles run along y = -56680. The storehouse stands
-- at the far end of the branch, past the junction, and the work (a farm, an
-- ore vein, a woodcutter's camp by a tree) at the near end: every load is
-- carried down the road.
local L = {}

L.LANE_Y = -56680
L.JUNCTION_X = -2250
L.HOUR = 8.8          -- morning: the sun low in the east-south-east, behind the cameras
L.STORE = { -3250, L.LANE_Y + 60 }

local Y = L.LANE_Y
-- kind, x, y, variant
L.VILLAGE = {
    { 'house', -1900, Y + 820, 4 }, { 'house', -2950, Y + 900, 5 },
    { 'house', -1800, Y - 850, 2 }, { 'house', -3700, Y + 1000, 3 }, { 'house', -3800, Y - 900, 6 },
    { 'market', -2650, Y - 400 }, { 'campfire', -2950, Y - 470 },
    { 'table', -3100, Y - 260 }, { 'bench', -2900, Y - 680 },
    { 'lantern', -1000, Y + 230 }, { 'lantern', -1900, Y + 230 }, { 'lantern', -1900, Y - 230 },
    { 'farm', 500, Y - 480 }, { 'mine', 950, Y + 380 },
}
-- the village is cleared ground: the bushes, rocks and trees in it go
-- (before the colony is founded, so they aren't the colony's trees)
L.CLEAR = { -4300, Y - 1300, -1100, Y + 1400 }
L.CLEAR_PREFIXES = { 'flora_', 'terrain_rock', 'terrain_', 'furn_rock', 'ex_t_rock' }
L.JOBS = { lumber = 3, farm = 3, mine = 3, market = 1 } -- the rest are laborers: they stroll, chat, tidy
L.SETTLERS = 13       -- spawned on top of the three who found the colony

-- facing the lane: straight across it, or (on it, at its end) down it
function L.facing(x, y)
    if math.abs(y - L.LANE_Y) < 150 then
        return x < L.JUNCTION_X and math.pi / 2 or -math.pi / 2
    end
    return math.atan2(0, L.LANE_Y - y)
end

-- A tree near the work end of the road for the woodcutter's camp, and where
-- the camp goes: between the tree and the lane.
function L.campFor(trees)
    local best, bestD
    for _, tr in ipairs(trees or {}) do
        local d = math.sqrt((tr.pos.x - 700) ^ 2 + (tr.pos.y - L.LANE_Y) ^ 2)
        if not tr.felled and tr.pos.x > 0 and d < 2000 and (not bestD or d < bestD) then best, bestD = tr, d end
    end
    if not best then return nil end
    local dy = L.LANE_Y - best.pos.y
    local step = math.abs(dy) > 1 and (dy > 0 and 1 or -1) * math.min(320, math.abs(dy) * 0.6) or 0
    return best, { best.pos.x, best.pos.y + step }
end


L.FILM = { 'road1', 'road3', 'square2', 'wood4' } -- the cameras filmed, in order (see ambient_scene.lua)

return L
