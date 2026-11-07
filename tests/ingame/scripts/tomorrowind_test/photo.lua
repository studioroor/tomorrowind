-- Dev-only: photographs models side-on, hanging in the air out at sea, and
-- measures the boards of bare shelves. Edit MODELS / SHELVES.
local core = require('openmw.core')
local camera = require('openmw.camera')
local util = require('openmw.util')
local self = require('openmw.self')
local types = require('openmw.types')
local nearby = require('openmw.nearby')
local debug = require('openmw.debug')
local I = require('openmw.interfaces')

local MODELS = { 'x/ex_hlaalu_b_01', 'x/ex_hlaalu_b_04', 'x/ex_hlaalu_b_03', 'x/ex_hlaalu_b_06', 'x/ex_hlaalu_b_07', 'x/ex_hlaalu_b_10',
    'x/ex_hlaalu_b_13', 'x/ex_hlaalu_b_17', 'x/ex_common_building_01', 'x/ex_de_shack_03', 'x/ex_de_shack_05', 'x/ex_de_shack_04', 'x/ex_de_shack_02' }
local SHELVES = { 'f/furn_com_bookshelf_02', 'f/furn_com_bookshelf_01', 'f/furn_de_bookshelf_01', 'f/furn_de_bookshelf_02' }
local Y, SPACING, Z = 270000, 3000, 20
local t, stage, i, nextT = 0, 0, 0, 0
local function log(...) print('[PHOTO]', ...) end
local function shelfX(n) return (n - (#SHELVES + 1) / 2) * 500 end
return {
    engineHandlers = {
        onFrame = function()
            if stage == 2 then
                stage = 3
                for n, m in ipairs(SHELVES) do
                    local x0 = shelfX(n)
                    for _, dx in ipairs({ 20, -25 }) do
                        local hits, z = {}, Y and 200 or 200
                        local rays = 0
                        while rays < 30 do
                            rays = rays + 1
                            local r = nearby.castRenderingRay(util.vector3(x0 + dx, Y + 1500, z), util.vector3(x0 + dx, Y + 1500, -300))
                            if not r.hit or r.hitPos.z < -200 then break end
                            hits[#hits + 1] = string.format('%.0f', r.hitPos.z - Z)
                            z = r.hitPos.z - 4
                        end
                        log(m, 'dx', dx, 'hits relative to origin:', table.concat(hits, ' '))
                    end
                end
            end
            if i > 0 and i <= #MODELS then
                local x = (i - (#MODELS + 1) / 2) * SPACING
                camera.setMode(camera.MODE.Static)
                camera.setStaticPosition(util.vector3(x, Y - 1700, 1200))
                camera.setYaw(0)
                camera.setPitch(0)
            end
        end,
        onUpdate = function(dt)
            t = t + dt
            local hp = types.Actor.stats.dynamic.health(self)
            if hp.current < hp.base then hp.current = hp.base end
            if stage == 0 and t > 2 then
                stage = 1
                I.Camera.disableModeControl('photo')
                camera.setMode(camera.MODE.FirstPerson)
                core.sendGlobalEvent('GAL_Spawn', { views = { { x = 0, spacing = 500, models = SHELVES } }, y = Y + 1500 })
                core.sendGlobalEvent('GAL_Tp', { pos = util.vector3(0, Y + 1100, 30) })
                nextT = t + 3
            elseif stage == 1 and t >= nextT then
                local cam = camera.getPosition()
                camera.setYaw(0); camera.setPitch(0)
                stage = 2
                nextT = t + 1
            elseif stage == 3 and t >= nextT then
                stage = 4
                core.sendGlobalEvent('GAL_Spawn', { views = { { x = 0, spacing = SPACING, models = MODELS, z = 1200 } }, y = Y })
                nextT = t + 1
            elseif stage == 4 and t >= nextT then
                if i > 0 then log('shot', i - 1, MODELS[i]); debug.takeScreenshot() end
                i = i + 1
                if i > #MODELS + 1 then core.quit() return end
                nextT = t + 1.6
                if i <= #MODELS then
                    local x = (i - (#MODELS + 1) / 2) * SPACING
                    core.sendGlobalEvent('GAL_Tp', { pos = util.vector3(x, Y - 1200, 2) })
                end
            end
        end,
    },
}
