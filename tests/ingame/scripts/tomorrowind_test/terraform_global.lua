-- OpenTW engine test: runtime terraforming through world.terrain.
-- Builds a hill, a pond, a sand plateau and a cobbled path in the meadow
-- near VILLAGE, then checks heights, textures, collision and the navmesh.
-- Run: OPENMW=<opentw>/openmw TEST_CONTENT=terraform.omwscripts SHOTS="16 22" tools/playtest.sh <out>
local world = require('openmw.world')
local core = require('openmw.core')
local util = require('openmw.util')
local v3 = util.vector3

local VILLAGE = v3(-2504, -55848, 1300)
local t, step = 0, 0
local base, P = nil, {}
local results = { pass = 0, fail = 0 }

local function log(...) print('[TERRA]', ...) end
local function check(ok, what)
    results[ok and 'pass' or 'fail'] = results[ok and 'pass' or 'fail'] + 1
    log((ok and 'PASS ' or 'FAIL ') .. what)
end
local function cell() return world.players[1].cell end
local function h(p) return core.land.getHeightAt(p, cell()) end

local function apply()
    local T = world.terrain
    T.raise(P.hill, 700, 900, 900)
    T.raise(P.mound, 300, 400, 2200) -- gentle enough to walk up
    T.flatten(P.pond, 600, -250, 500)
    T.flatten(P.plateau, 650, P.plateauH, 450)
    T.paint(P.plateau, 750, 'Sand')
    for i = 0, 7 do
        T.paint(base + (P.hill - base) * (i / 7), 230, 'AI_Grass_Cobbles')
    end
end

return {
    engineHandlers = {
        onUpdate = function(dt)
            t = t + dt
            local p = world.players[1]
            if not p then return end
            if step == 0 and t > 2 then
                step = 1
                p:teleport('', VILLAGE, { onGround = true })
            elseif step == 1 and t > 5 then
                step = 2
                if not world.terrain then
                    log('FAIL world.terrain missing: not running on OpenTW')
                    core.quit()
                    return
                end
                log('OpenTW terrain API version', world.terrain.VERSION)
                check(not pcall(world.terrain.raise, v3(1e9, 0, 0), 100, 10), 'a centre far outside the world is refused')
                check(not pcall(world.terrain.flatten, v3(0 / 0, 0, 0), 100, 10), 'a NaN centre is refused')
                check(not pcall(world.terrain.paint, VILLAGE, 100, 'no such texture'), 'an unknown texture is refused')
                base = v3(VILLAGE.x, VILLAGE.y, 0)
                P.hill = base + v3(0, 2600, 0)
                P.pond = base + v3(-2300, 1900, 0)
                P.plateau = base + v3(2100, 1700, 0)
                P.plateauH = h(P.plateau)
                P.path = base + (P.hill - base) * 0.5
                P.mound = base + v3(2600, -1800, 0)
                P.moundH = h(P.mound)
                P.before = { hill = h(P.hill), pond = h(P.pond), plateauEdge = h(P.plateau + v3(500, 0, 0)) }
                P.tex = { core.land.getTextureAt(P.path, cell()) }
                log(string.format('before: hill %.0f pond %.0f plateau %.0f edge %.0f path tex %s',
                    P.before.hill, P.before.pond, P.plateauH, P.before.plateauEdge, tostring(P.tex[1])))
                apply()
            elseif step == 2 and t > 6 then
                step = 3
                local hill, pond, edge = h(P.hill), h(P.pond), h(P.plateau + v3(500, 0, 0))
                log(string.format('after: hill %.0f pond %.0f edge %.0f', hill, pond, edge))
                check(math.abs(hill - (P.before.hill + 900)) < 2, 'hill raised by 900')
                check(math.abs(pond + 250) < 2, 'pond floor at -250 (below sea level)')
                check(math.abs(edge - P.plateauH) < 2, 'plateau flattened to its centre height')
                local tex = core.land.getTextureAt(P.path, cell())
                check(tex and tex:lower():find('cobblestone') ~= nil, 'path painted with cobblestones (' .. tostring(tex) .. ')')
                tex = core.land.getTextureAt(P.plateau, cell())
                check(tex and tex:lower():find('sand') ~= nil, 'plateau painted with sand (' .. tostring(tex) .. ')')
                p:sendEvent('TT_Probe', { hill = P.hill, hillH = hill, mound = P.mound, moundH = h(P.mound),
                    moundBefore = P.moundH, from = base + v3(0, 0, h(base)) })
            elseif step == 3 and t > 8 then
                step = 4
                world.terrain.reset()
            elseif step == 4 and t > 9 then
                step = 5
                check(math.abs(h(P.hill) - P.before.hill) < 1, 'reset restores the hill cell')
                check(math.abs(h(P.pond) - P.before.pond) < 1, 'reset restores the pond cell')
                apply() -- the way a mod replays its edits after loading a save
            elseif step == 5 and t > 10 then
                step = 6
                check(math.abs(h(P.hill) - (P.before.hill + 900)) < 2, 'replayed edits match')
                -- stand back on the path and look up at the hill for the screenshots
                local eye = base + v3(-300, -900, 0)
                p:teleport('', eye + v3(0, 0, h(eye)), { rotation = util.transform.rotateZ(math.atan2(300, 3500)), onGround = true })
                p:sendEvent('TT_Look', -0.12)
            elseif step == 6 and t > 26 then
                step = 7
                log(string.format('done: %d passed, %d failed', results.pass, results.fail))
                core.quit()
            end
        end,
    },
    eventHandlers = {
        TT_ProbeResult = function(e)
            check(e.rayZ and math.abs(e.rayZ - e.hillH) < 20,
                string.format('collision follows the hill (ray hit %s, ground %.0f)', tostring(e.rayZ), e.hillH))
            check(e.pathZ and math.abs(e.pathZ - e.moundH) < 80,
                string.format('navmesh follows the new mound (path end z %s, top %.0f, was %.0f, status %s)',
                    tostring(e.pathZ), e.moundH, e.moundBefore, tostring(e.status)))
        end,
    },
}
