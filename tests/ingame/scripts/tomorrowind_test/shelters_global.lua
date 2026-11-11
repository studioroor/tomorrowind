-- Dev-only: the shelters scene's helper. Activates things as the player.
local world = require('openmw.world')
return {
    eventHandlers = {
        SHT_Activate = function(e) e.obj:activateBy(world.players[1]) end,
    },
}
