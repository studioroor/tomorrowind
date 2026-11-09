-- Dev-only: the set the 0.2 trailer is filmed on, shared by the trailer scene
-- (trailer2.lua) and the staging scene (trailer2_stage.lua).
--
-- The bridge set (two houses, the stairs and the rope bridge between their
-- roofs) can be arranged by hand: tools/stage_trailer.sh opens the game on the
-- set, you move things with the mod's own tools, and on quitting it writes
-- trailer2_layout.lua, which is then built instead of the default below.
local util = require('openmw.util')
local v3 = util.vector3

local M = {}

M.VILLAGE = v3(-2504, -55848, 1300) -- the meadow by Pelagiad

-- kind, dx, dy, variant, yaw; laid out on open ground (see the probe_map scene)
M.village = {
    { 'house', 400, -1000, 3, 0 }, -- the one that moves: first, so `move` picks it
    { 'lumber', -1200, -1400 }, { 'mine', 1200, -1400 }, { 'smelter', 800, -200 },
    { 'house', -1000, 900, 2, 3.14 }, { 'house', 500, 900, 5, 3.14 }, { 'house', -1700, -100, 4, 1.57 },
    { 'guardpost', 200, -600 },
    { 'campfire', -750, -50 }, { 'bookshelf', -500, 200 }, { 'table', -1000, 100 },
    { 'market', 300, 350, nil, -0.75 }, -- caravans come in from the east, over open ground
    -- a field of each crop, in the clear ground to the north-west
    { 'farm', -2300, 1150, 2 }, { 'farm', -2950, 1150, 4 }, { 'farm', -2300, 550, 3 }, { 'farm', -2950, 550, 1 },
    { 'bench', -900, -220 }, { 'chair', -620, -250 }, { 'chest', -350, 170 }, { 'lamppost', -500, -180 },
    { 'lantern', -1050, -120 }, { 'lantern', -1000, 280 }, { 'lantern', -200, -500 },
}
M.HOME = { -1700, -100 } -- the house we go into: a Hlaalu house with a big room
M.MOVE_TO = { -250, -1450, 0.9 }

-- what belongs to the bridge set (houses only when they aren't the village's)
M.setKinds = { house = true, ropebridge = true, stairs = true, walkway = true }

-- The default bridge set: two houses far enough apart that the shortest
-- bridge just spans the gap, resting a little way onto each roof (a house is
-- 558 deep, the bridge 1036 long), with stairs up the first.
local H1, H2 = { 2850, 2537 }, { 2850, 1063 }
M.setCentre = { 2850, 1800 }

local ok, layout = pcall(require, 'scripts.tomorrowind_test.trailer2_layout')
M.layout = ok and type(layout) == 'table' and #layout > 0 and layout or nil

-- Builds the set in two steps: the bridge is laid onto the roofs once the
-- houses are there (step 2). ctx: { dbg, land, roofAt, log }.
function M.buildSet(step, ctx)
    if M.layout then
        if step == 1 then
            for _, it in ipairs(M.layout) do
                ctx.dbg({ cmd = 'build', kind = it[1], variant = it[2], pos = v3(it[3], it[4], it[5]), yaw = it[6],
                    built = true, leveled = true })
            end
            ctx.log('built the staged layout:', #M.layout, 'pieces')
        end
        return
    end
    local land = ctx.land
    if step == 1 then
        -- floors level for the bridge
        local z = math.min(land(H1[1], H1[2]).z, land(H2[1], H2[2]).z) + 40
        for _, h in ipairs({ H1, H2 }) do
            local g = land(h[1], h[2])
            ctx.dbg({ cmd = 'build', kind = 'house', variant = 4, pos = v3(g.x, g.y, z), built = true, leveled = true })
        end
        ctx.dbg({ cmd = 'build', kind = 'stairs', variant = 4, pos = land(H1[1] - 700, H1[2]), yaw = math.pi / 2, built = true, leveled = true })
    else
        local roof = ctx.roofAt(land(H1[1] + 250, H1[2] - 219))
        ctx.dbg({ cmd = 'build', kind = 'ropebridge', pos = roof + v3(0, -518, 0), yaw = math.pi / 2, built = true, leveled = true })
    end
end

-- Is this snapshot site part of the bridge set?
function M.inSet(s)
    if not M.setKinds[s.kind] or s.host then return false end
    if s.kind ~= 'house' then return true end
    for _, it in ipairs(M.village) do
        if it[1] == 'house' and math.abs(s.pos.x - (M.VILLAGE.x + it[2])) < 5 and math.abs(s.pos.y - (M.VILLAGE.y + it[3])) < 5 then
            return false
        end
    end
    -- the house being moved in the trailer ends up here
    if math.abs(s.pos.x - (M.VILLAGE.x + M.MOVE_TO[1])) < 5 and math.abs(s.pos.y - (M.VILLAGE.y + M.MOVE_TO[2])) < 5 then
        return false
    end
    return true
end

return M
