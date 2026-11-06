-- Attached to an NPC that attacks the colony while a stockade has room.
-- Blows that would take them below `knockoutBelow` of their health drain
-- fatigue instead, so they collapse unconscious rather than die. Once
-- knocked out, the global script turns them into a prisoner.

local self = require('openmw.self')
local core = require('openmw.core')
local types = require('openmw.types')
local I = require('openmw.interfaces')

local defs = require('scripts.tomorrowind.defs')

local Actor = types.Actor
local reported = false

if I.Combat then
    I.Combat.addOnHitHandler(function(attack)
        if reported or not attack.successful or not attack.damage then return end
        local dmg = attack.damage.health
        if not dmg or dmg <= 0 then return end
        local hp = Actor.stats.dynamic.health(self)
        local floor = hp.base * defs.defense.knockoutBelow
        if hp.current - dmg < floor then
            local allowed = math.max(0, hp.current - floor)
            attack.damage.health = allowed
            attack.damage.fatigue = (attack.damage.fatigue or 0) + (dmg - allowed) * 4 + 20
        end
    end)
end

return {
    engineHandlers = {
        onUpdate = function()
            if reported then return end
            if Actor.stats.dynamic.fatigue(self).current < 0 and not Actor.isDead(self) then
                reported = true
                core.sendGlobalEvent('TMW_Subdued', { actor = self.object })
            end
        end,
    },
}
