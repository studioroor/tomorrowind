-- Dev-only: what the trailer scene needs from a global script.
local core = require('openmw.core')
local world = require('openmw.world')
local types = require('openmw.types')
return {
    eventHandlers = {
        TRL_Sky = function(e)
            local region = world.players[1].cell.region
            for _, w in ipairs(core.weather.records) do
                if w.name:lower() == 'clear' then
                    local ok, err = pcall(core.weather.changeWeather, region, w)
                    if not ok then print('[TRAILER] weather', region, err) end
                end
            end
            if e.timeScale then world.setGameTimeScale(e.timeScale) end
        end,
        -- wildlife would attack the settlers and spoil the shots
        TRL_Clean = function()
            for _, a in ipairs(world.activeActors) do
                if a.type == types.Creature and a:isValid() and a.recordId ~= 'guar_pack' then a:remove() end
            end
        end,
    },
}
