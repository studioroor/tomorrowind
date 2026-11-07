-- Dev-only: moves the player for the scout scene.
local world = require('openmw.world')
local util = require('openmw.util')
return { eventHandlers = { SCOUT_Tp = function(e)
    world.players[1]:teleport('', e.pos, { onGround = true })
end } }
