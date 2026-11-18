-- Dev-only (OpenTW test): saves the game mid-run, then loads that save.
local menu = require('openmw.menu')
local core = require('openmw.core')
local t0, saved, loaded
return {
    engineHandlers = {
        onFrame = function()
            if menu.getState() ~= menu.STATE.Running then return end
            t0 = t0 or core.getRealTime()
            local t = core.getRealTime() - t0
            if not saved and t > 20 then
                saved = true
                print('[OPENTW] saving')
                menu.saveGame('opentwtest', 'opentwtest')
            elseif saved and not loaded and t > 26 then
                loaded = true
                -- the slot id is a generated file name: find it by description
                local dir = menu.getCurrentSaveDir()
                for slot, info in pairs(menu.getSaves(dir)) do
                    if info.description == 'opentwtest' then
                        print('[OPENTW] loading', dir, slot)
                        menu.loadGame(dir, slot)
                    end
                end
            end
        end,
    },
}
