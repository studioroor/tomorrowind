-- Dev-only: measures model bounding boxes and fire light records, then quits.
-- Run: TEST_CONTENT=probe.omwscripts tools/playtest.sh <out>
local world = require('openmw.world')
local types = require('openmw.types')
local util = require('openmw.util')
local core = require('openmw.core')

local MODELS = {
    'meshes/f/furn_log_01.nif', 'meshes/f/furn_log_02.nif', 'meshes/f/furn_log_03.nif', 'meshes/f/furn_log_04.nif',
    'meshes/f/furn_logpile10.nif', 'meshes/f/flora_treestump_wg_01.nif', 'meshes/f/flora_treestump_wg_02.nif',
    'meshes/f/flora_bc_log_01.nif', 'meshes/f/flora_bc_log_02.nif', 'meshes/f/furn_coalpile00.nif',
    'meshes/f/furn_de_forge_01.nif', 'meshes/f/furn_anvil00.nif', 'meshes/o/contain_crate_01.nif',
    'meshes/f/furn_crate_open_01.nif', 'meshes/x/ex_de_docks_piling.nif', 'meshes/x/ex_de_scaffold_01.nif',
    'meshes/f/furn_woodbar_01.nif', 'meshes/n/ingred_scrap_metal_01.nif', 'meshes/m/misc_scrapwood02.nif',
    'meshes/l/light_fire_nosmoke.nif', 'meshes/fire_small.nif', 'meshes/l/light_pitfire00.nif',
}
local LIGHTS = { 'light_fire_small', 'light_pitfire00', 'light_fire', 'light_fire_nosmoke', 'light_fire_nosmoke_128', 'light_fire_nosmoke_177' }

local t, spawned = 0, nil
return {
    engineHandlers = {
        onUpdate = function(dt)
            t = t + dt
            local p = world.players[1]
            if not p then return end
            if not spawned and t > 3 then
                spawned = {}
                for i, m in ipairs(MODELS) do
                    local ok, rec = pcall(function()
                        return world.createRecord(types.Static.createRecordDraft({ model = m }))
                    end)
                    if ok then
                        local o = world.createObject(rec.id)
                        o:teleport(p.cell, p.position + util.vector3(i * 600, 3000, 2000))
                        spawned[#spawned + 1] = { m = m, o = o }
                    else
                        print('[PROBE] fail', m, rec)
                    end
                end
                for _, id in ipairs(LIGHTS) do
                    local r = types.Light.records[id]
                    if r then
                        print(string.format('[PROBE] light %s model=%s radius=%s sound=%s fire=%s carry=%s color=%s',
                            id, r.model, tostring(r.radius), tostring(r.sound), tostring(r.isFire), tostring(r.isCarriable), tostring(r.color)))
                    else
                        print('[PROBE] no light', id)
                    end
                end
            elseif spawned and t > 5 and not spawned.done then
                spawned.done = true
                for _, s in ipairs(spawned) do
                    local b = s.o:getBoundingBox()
                    local c = b.center - s.o.position
                    print(string.format('[PROBE] %-40s half=(%.0f,%.0f,%.0f) centerOff=(%.0f,%.0f,%.0f)', s.m,
                        b.halfSize.x, b.halfSize.y, b.halfSize.z, c.x, c.y, c.z))
                end
                core.quit()
            end
        end,
    },
}
