-- Player half of the OpenTW terraform test: collision and navmesh checks
-- (nearby is only available to local scripts), and the camera.
local nearby = require('openmw.nearby')
local camera = require('openmw.camera')
local core = require('openmw.core')
local util = require('openmw.util')
local v3 = util.vector3

local pending

return {
    engineHandlers = {
        onUpdate = function()
            -- give the navmesh a moment to rebuild the changed tiles
            if pending and core.getRealTime() > pending.at then
                local e = pending
                pending = nil
                local r = nearby.castRay(v3(e.hill.x, e.hill.y, 6000), v3(e.hill.x, e.hill.y, -4000),
                    { collisionType = nearby.COLLISION_TYPE.HeightMap })
                local status, path = nearby.findPath(e.from, v3(e.mound.x, e.mound.y, e.moundH))
                local last = path and path[#path]
                core.sendGlobalEvent('TT_ProbeResult', {
                    rayZ = r.hit and r.hitPos.z or nil, hillH = e.hillH, moundH = e.moundH, moundBefore = e.moundBefore,
                    pathZ = last and last.z or nil, status = status,
                })
            end
        end,
    },
    eventHandlers = {
        TT_Probe = function(e)
            e.at = core.getRealTime() + 1.5
            pending = e
        end,
        TT_Look = function(pitch) camera.setPitch(pitch) end,
    },
}
