-- Dev-only: spawns rows of vanilla models so they can be looked at and measured.
local world = require('openmw.world')
local types = require('openmw.types')
local util = require('openmw.util')
local core = require('openmw.core')
local spawned = {}
local function player() return world.players[1] end
return {
    eventHandlers = {
        GAL_Spawn = function(e)
            -- a studio out at sea: nothing in the way, z = 20 above the water
            for _, v in ipairs(e.views) do
                for i, m in ipairs(v.models) do
                    local rec = world.createRecord(types.Static.createRecordDraft({ model = 'meshes/' .. m .. '.nif' }))
                    local o = world.createObject(rec.id)
                    local x = v.x + (i - 1) * v.spacing - (#v.models - 1) * v.spacing / 2
                    local z = 20
                    if e.onLand then z = core.land.getHeightAt(util.vector3(x, e.y, 0), player().cell) + (e.lift or 0) end
                    o:teleport('', util.vector3(x, e.y, z))
                    spawned[#spawned + 1] = { m = m, o = o }
                end
            end
        end,
        GAL_Dump = function()
            for _, s in ipairs(spawned) do
                local b = s.o:getBoundingBox()
                local c = b.center - s.o.position
                print(string.format('[GAL] %-34s half=(%.0f,%.0f,%.0f) centerOff=(%.0f,%.0f,%.0f)', s.m,
                    b.halfSize.x, b.halfSize.y, b.halfSize.z, c.x, c.y, c.z))
            end
        end,
        GAL_Tp = function(e)
            player():teleport('', e.pos, { rotation = util.transform.rotateZ(0) })
        end,
    },
}
