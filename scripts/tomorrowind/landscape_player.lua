-- The landscaping tool, on OpenTW only (docs/opentw.md). L toggles it.
--   Up / Down (hold)  raise / lower the ground at the crosshair (Shift: slower)
--   Left / Right      pick the tool: Level, or paint with a texture
--   Enter             use it: level the ground to the height at the crosshair, or paint
--   Z / X             smaller / larger brush
-- Edits go to the global script (scripts/tomorrowind/landscape.lua), which
-- applies them and keeps them in the save.
local core = require('openmw.core')
local input = require('openmw.input')
local camera = require('openmw.camera')
local ui = require('openmw.ui')
local util = require('openmw.util')
local self = require('openmw.self')
local I = require('openmw.interfaces')
local defs = require('scripts.tomorrowind.defs')

local cfg = defs.landscape
local TOOLS = { { name = 'Level' } }
for _, t in ipairs(cfg.textures) do TOOLS[#TOOLS + 1] = { name = 'Paint: ' .. t.name, tex = t.id } end

local engine = false -- can this engine change the land? (told by the global script)
local on = false
local tool, radius = 1, cfg.brush.radius
local raise, sendIn = 0, 0

local function groundHeight(x, y)
    local ok, h = pcall(core.land.getHeightAt, util.vector3(x, y, 0), self.cell)
    return ok and h or nil
end

-- Where the view ray meets the land (steps along the ray, so the player's
-- own body can't block it).
local function aim()
    if not self.cell or not self.cell.isExterior then return nil end
    local from = camera.getPosition()
    local dir = camera.viewportToWorldVector(util.vector2(0.5, 0.5))
    local t = 0
    while t < 6000 do
        t = t + 32
        local p = from + dir * t
        local h = groundHeight(p.x, p.y)
        if h and p.z <= h then return util.vector3(p.x, p.y, h) end
    end
end

local function status()
    ui.showMessage(string.format('Landscaping: %s, brush %d. Up/Down raise/lower, Left/Right tool, Enter use, Z/X size, L done.',
        TOOLS[tool].name, radius))
end

local function send(op)
    core.sendGlobalEvent('TMW_Landscape', op)
end

local function use()
    local p = aim()
    if not p then return ui.showMessage('Aim at open ground.') end
    local t = TOOLS[tool]
    if t.tex then
        send({ k = 'paint', x = p.x, y = p.y, r = radius, tex = t.tex })
    else
        send({ k = 'flatten', x = p.x, y = p.y, r = radius, h = p.z, f = radius * 0.6 })
    end
end

return {
    engineHandlers = {
        onKeyPress = function(key)
            if I.UI.getMode() then return end
            if key.code == input.KEY.L then
                -- on stock OpenMW the key does nothing: the engine isn't out yet
                if not engine then return end
                on = not on
                raise = 0
                if on then status() else ui.showMessage('Landscaping done.') end
                return
            end
            if not on then return end
            if key.code == input.KEY.RightArrow then
                tool = tool % #TOOLS + 1
                status()
            elseif key.code == input.KEY.LeftArrow then
                tool = (tool - 2) % #TOOLS + 1
                status()
            elseif key.code == input.KEY.Z then
                radius = math.max(cfg.brush.min, math.floor(radius / 1.25))
                status()
            elseif key.code == input.KEY.X then
                radius = math.min(cfg.brush.max, math.floor(radius * 1.25))
                status()
            elseif key.code == input.KEY.Enter or key.code == input.KEY.NP_Enter then
                use()
            end
        end,
        onFrame = function(dt)
            if not on or I.UI.getMode() then return end
            local dir = (input.isKeyPressed(input.KEY.UpArrow) and 1 or 0) - (input.isKeyPressed(input.KEY.DownArrow) and 1 or 0)
            raise = raise + dir * cfg.brush.speed * (input.isShiftPressed() and 0.2 or 1) * dt
            sendIn = sendIn - dt
            -- a few edits a second while a key is held: each one redraws the land
            if sendIn <= 0 and math.abs(raise) >= 1 then
                sendIn = 0.15
                local p = aim()
                if p then send({ k = 'raise', x = p.x, y = p.y, r = radius * 0.5, h = raise, f = radius * 0.5 }) end
                raise = 0
            end
        end,
    },
    eventHandlers = {
        TMW_LandscapeEngine = function(available) engine = available end,
        -- scripted tests
        TMW_LandscapeTest = function(e)
            engine, on = true, e.on ~= false
            if e.tool then tool = e.tool end
            if e.radius then radius = e.radius end
            if e.use then use() end
        end,
    },
}
