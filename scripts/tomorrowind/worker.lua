-- Local script on each colony worker NPC.
-- Executes one step at a time as ordered by the global script and reports
-- back with TMW_StepDone. Knows nothing about the colony economy.

local self = require('openmw.self')
local core = require('openmw.core')
local types = require('openmw.types')
local util = require('openmw.util')
local nearby = require('openmw.nearby')
local anim = require('openmw.animation')
local I = require('openmw.interfaces')
local defs = require('scripts.tomorrowind.defs')

local Actor = types.Actor
local SLOT = Actor.EQUIPMENT_SLOT

local SWING_GROUP = 'weapononehand'
local SWING_INTERVAL = 1.7
local ARRIVE_DIST = 90
local STUCK_CHECK = 2.5
local STUCK_MOVE = 25
local STUCK_LIMIT = 4
local GOTO_TIMEOUT = 90

local wid
local cur        -- current step (from global) + runtime fields
local wakeT      -- prisoners: seconds until they come round
local debugOn = defs.debug

local function flat(v) return util.vector3(v.x, v.y, 0) end
local function dist2d(a, b) return (flat(a) - flat(b)):length() end

local function agentBounds()
    local ok, b = pcall(Actor.getPathfindingAgentBounds, self)
    return ok and b or nil
end

local function snapToNav(p)
    local ok, nav = pcall(nearby.findNearestNavMeshPosition, p, {
        agentBounds = agentBounds(),
        searchAreaHalfExtents = util.vector3(400, 400, 600),
    })
    if ok and nav then return nav end
    return p
end

-- Point at `standoff` from `center`, on the side the worker comes from,
-- rotated by the worker's slot so several workers spread around a site.
local function approachPoint(center, standoff, slotAngle)
    local from = flat(self.position) - flat(center)
    local base = from:length() > 1 and math.atan2(from.x, from.y) or 0
    local a = base + (slotAngle or 0)
    local p = center + util.vector3(math.sin(a) * standoff, math.cos(a) * standoff, 0)
    return snapToNav(p)
end

-- Queued (scripted) animations hold an actor in place like mwscript's
-- PlayGroup, so make sure none are left before walking anywhere.
local function clearScripted()
    pcall(anim.clearAnimationQueue, self, true)
end

local function travel(dest)
    clearScripted()
    I.AI.startPackage({ type = 'Travel', destPosition = dest, cancelOther = true })
end

local function finish(extra)
    if not cur then return end
    local msg = { actor = self.object, wid = wid, token = cur.token }
    if extra then for k, v in pairs(extra) do msg[k] = v end end
    cur = nil
    core.sendGlobalEvent('TMW_StepDone', msg)
end

local function equipTool(toolId)
    if not toolId then return end
    local eq = Actor.getEquipment(self)
    local current = eq[SLOT.CarriedRight]
    if current and current.recordId == toolId then return end
    eq[SLOT.CarriedRight] = toolId
    pcall(Actor.setEquipment, self, eq)
end

local function setStance(stance)
    pcall(Actor.setStance, self, stance)
end

-- Signed angle (radians) the worker must turn to face `target`.
local function yawError(target)
    local fwd = self.rotation * util.vector3(0, 1, 0)
    local dir = target - self.position
    local diff = math.atan2(dir.x, dir.y) - math.atan2(fwd.x, fwd.y)
    while diff > math.pi do diff = diff - 2 * math.pi end
    while diff < -math.pi do diff = diff + 2 * math.pi end
    return diff
end

local function turnTowards(target, dt)
    if not target then return end
    local diff = yawError(target)
    local step = 4 * dt
    self.controls.yawChange = math.max(-step, math.min(step, diff))
end

local function swing()
    if not anim.hasGroup(self, SWING_GROUP) then return end
    -- Two halves of the chop, skipping the "chop hit" key in between so
    -- the swing can never damage anyone.
    anim.clearAnimationQueue(self, false)
    anim.playQueued(self, SWING_GROUP, { startKey = 'chop start', stopKey = 'chop min hit', loops = 0 })
    anim.playQueued(self, SWING_GROUP, { startKey = 'chop large follow start', stopKey = 'chop large follow stop', loops = 0 })
end

---------------------------------------------------------------------------
-- step handlers: start(step) and update(step, dt) -> true when finished

local handlers = {}

handlers['goto'] = {
    start = function(s)
        s.dest = approachPoint(s.center, s.standoff or 100, s.slotAngle)
        s.elapsed, s.checkT, s.stuck = 0, 0, 0
        s.lastPos = self.position
        travel(s.dest)
    end,
    update = function(s, dt)
        s.elapsed = s.elapsed + dt
        local d = dist2d(self.position, s.dest)
        local toCenter = dist2d(self.position, s.center)
        local standoff = s.standoff or 100
        if d < ARRIVE_DIST or toCenter < standoff + 40 then
            I.AI.removePackages('Travel')
            return true
        end
        if s.elapsed > GOTO_TIMEOUT then
            finish({ teleport = s.dest })
            return false
        end
        s.checkT = s.checkT + dt
        if s.checkT >= STUCK_CHECK then
            s.checkT = 0
            local moved = dist2d(self.position, s.lastPos)
            s.lastPos = self.position
            local pkg = I.AI.getActivePackage()
            local travelling = pkg and pkg.type == 'Travel'
            -- The AI often stops a little short when the target is next to
            -- collision (rocks, walls). Close enough counts as arrived.
            if (not travelling or moved < STUCK_MOVE) and (d < ARRIVE_DIST * 3 or toCenter < standoff + 160) then
                I.AI.removePackages('Travel')
                return true
            end
            if moved < STUCK_MOVE or not travelling then
                s.stuck = s.stuck + 1
                if debugOn then print(string.format('[Tomorrowind] %s stuck #%d: d=%.0f toCenter=%.0f standoff=%.0f moved=%.0f travelling=%s stance=%s lower=%s swingPlaying=%s',
                    tostring(wid), s.stuck, d, toCenter, standoff, moved, tostring(travelling),
                    tostring(Actor.getStance(self)), tostring(anim.getActiveGroup(self, anim.BONE_GROUP.LowerBody)),
                    tostring(anim.isPlaying(self, SWING_GROUP)))) end
                if s.stuck >= STUCK_LIMIT then
                    finish({ teleport = s.dest })
                    return false
                end
                -- try a different spot around the target
                s.dest = approachPoint(s.center, s.standoff or 100, (s.slotAngle or 0) + s.stuck * 0.8)
                travel(s.dest)
            else
                s.stuck = 0
            end
        end
        return false
    end,
}

handlers['work'] = {
    start = function(s)
        I.AI.removePackages()
        equipTool(s.tool)
        setStance(Actor.STANCE.Weapon)
        s.phase, s.t, s.worked, s.swingT = 'draw', 0, 0, 0
    end,
    update = function(s, dt)
        s.t = s.t + dt
        turnTowards(s.center, dt)
        if s.phase == 'draw' then
            if s.t >= 1.0 then s.phase, s.t = 'swing', SWING_INTERVAL end
        elseif s.phase == 'swing' then
            s.worked = s.worked + dt
            s.swingT = s.swingT + dt
            if s.swingT >= SWING_INTERVAL then
                s.swingT = 0
                swing()
                s.swings = (s.swings or 0) + 1
                s.checkSwing = 0.4
            end
            if s.checkSwing then
                s.checkSwing = s.checkSwing - dt
                if s.checkSwing <= 0 then
                    s.checkSwing = nil
                    if s.swings == 1 then
                        if debugOn then print(string.format('[Tomorrowind] %s swing check: facingError=%.0fdeg playing=%s weapon=%s stance=%s',
                            tostring(wid), math.deg(s.center and yawError(s.center) or 0), tostring(anim.isPlaying(self, SWING_GROUP)),
                            tostring(Actor.getEquipment(self, SLOT.CarriedRight) and Actor.getEquipment(self, SLOT.CarriedRight).recordId),
                            tostring(Actor.getStance(self)))) end
                    end
                end
            end
            if s.worked >= (s.duration or 5) then
                clearScripted()
                setStance(Actor.STANCE.Nothing)
                s.phase, s.t = 'sheathe', 0
            end
        elseif s.phase == 'sheathe' then
            if s.t >= 0.9 then return true end
        end
        return false
    end,
}

local function pause(seconds)
    return {
        start = function(s)
            I.AI.removePackages()
            s.t = 0
        end,
        update = function(s, dt)
            s.t = s.t + dt
            return s.t >= (s.duration or seconds)
        end,
    }
end

handlers['take'] = pause(1.2)
handlers['store'] = pause(1.2)
handlers['supply'] = pause(1.5)
handlers['eat'] = pause(4)

handlers['idle'] = {
    start = function(s)
        s.t = 0
        if s.center and dist2d(self.position, s.center) > 700 then
            s.phase = 'walk'
            s.dest = approachPoint(s.center, s.standoff or 200, s.slotAngle)
            travel(s.dest)
        else
            s.phase = 'wander'
            I.AI.startPackage({ type = 'Wander', distance = 300, cancelOther = true })
        end
    end,
    update = function(s, dt)
        s.t = s.t + dt
        if s.phase == 'walk' and (dist2d(self.position, s.dest) < 150 or s.t > 40) then
            s.phase = 'wander'
            I.AI.startPackage({ type = 'Wander', distance = 300, cancelOther = true })
        end
        return s.t >= (s.duration or 10)
    end,
}

-- Guards: fight the given enemy until it is dead, knocked out or gone.
handlers['fight'] = {
    start = function(s)
        clearScripted()
        s.t = 0
        if s.targetObj and s.targetObj:isValid() then
            I.AI.startPackage({ type = 'Combat', target = s.targetObj, cancelOther = true })
        end
    end,
    update = function(s, dt)
        s.t = s.t + dt
        local t = s.targetObj
        if not t or not t:isValid() or Actor.isDead(t) then return true end
        if Actor.stats.dynamic.fatigue(t).current < 0 then
            I.AI.removePackages('Combat') -- don't beat an unconscious enemy
            return true
        end
        if s.t > 120 then return true end
        local pkg = I.AI.getActivePackage()
        s.logT = (s.logT or 0) - dt
        if debugOn and s.logT <= 0 then
            s.logT = 3
            print(string.format('[Tomorrowind] %s fight: target=%s dist=%.0f pkg=%s stance=%s targetHp=%.0f targetFatigue=%.0f',
                tostring(wid), t.recordId, (t.position - self.position):length(), pkg and pkg.type or 'none',
                tostring(Actor.getStance(self)), Actor.stats.dynamic.health(t).current, Actor.stats.dynamic.fatigue(t).current))
        end
        if not pkg or pkg.type ~= 'Combat' then
            I.AI.startPackage({ type = 'Combat', target = t, cancelOther = true })
        end
        return false
    end,
}

---------------------------------------------------------------------------

---------------------------------------------------------------------------
-- carrying and clothing

local CARRY_VFX = 'tmw_carry'
local carrying -- model currently shown in hand

-- Show the carried resource in the settler's hand (or nothing).
local function showCarry(model)
    if model == carrying then return end
    if carrying then pcall(anim.removeVfx, self, CARRY_VFX) end
    carrying = nil
    if model then
        local ok, err = pcall(anim.addVfx, self, model, {
            boneName = defs.carryBone, loop = true, vfxId = CARRY_VFX, useAmbientLighting = false,
        })
        if ok then carrying = model end
        if debugOn then print('[Tomorrowind] ' .. tostring(wid) .. ' carry ' .. model .. ' ok=' .. tostring(ok) .. ' ' .. tostring(err or '')) end
    end
end

local pendingWear, pendingT -- items given this frame arrive next frame
local wornCheckT

-- wear: slot name -> item record id, or false to take that slot off
local function wear(spec)
    local inv = Actor.inventory(self)
    for _, id in pairs(spec) do
        if id and not inv:find(id) then
            -- not delivered yet: try again shortly
            if debugOn and not pendingWear then
                local have = {}
                for _, item in ipairs(inv:getAll()) do have[#have + 1] = item.recordId end
                print('[Tomorrowind] ' .. tostring(wid) .. ' waiting for ' .. id .. '; has: ' .. table.concat(have, ', '))
            end
            pendingWear, pendingT = spec, 0.25
            return
        end
    end
    pendingWear = nil
    local eq = Actor.getEquipment(self)
    for slotName, id in pairs(spec) do
        local slot = SLOT[slotName]
        if slot then eq[slot] = id or nil end
    end
    local ok, err = pcall(Actor.setEquipment, self, eq)
    if debugOn and not ok then print('[Tomorrowind] ' .. tostring(wid) .. ' wear failed: ' .. tostring(err)) end
    wornCheckT = debugOn and 1 or nil -- equipment changes apply next frame
end

local function logWorn()
    local worn = {}
    for _, item in pairs(Actor.getEquipment(self)) do
        local okName, r = pcall(function() return item.type.record(item).name end)
        worn[#worn + 1] = okName and r and r.name or item.recordId
    end
    table.sort(worn)
    print('[Tomorrowind] ' .. tostring(wid) .. ' wears: ' .. table.concat(worn, ', '))
end

local function stop()
    if cur then cur = nil end
    I.AI.removePackages()
    if Actor.getStance(self) ~= Actor.STANCE.Nothing then setStance(Actor.STANCE.Nothing) end
end

local function onStep(s)
    stop()
    if debugOn then print('[Tomorrowind] ' .. tostring(wid) .. ' step ' .. tostring(s.op) .. ' carryModel=' .. tostring(s.carryModel)) end
    showCarry(s.carryModel)
    local h = handlers[s.op]
    if not h then
        cur = s
        finish()
        return
    end
    cur = s
    h.start(s)
end

local function onUpdate(dt)
    if wornCheckT and dt > 0 then
        wornCheckT = wornCheckT - dt
        if wornCheckT <= 0 then wornCheckT = nil; logWorn() end
    end
    if pendingWear and dt > 0 then
        pendingT = pendingT - dt
        if pendingT <= 0 then wear(pendingWear) end
    end
    if wakeT and dt > 0 then
        wakeT = wakeT - dt
        if wakeT <= 0 then
            wakeT = nil
            local f = Actor.stats.dynamic.fatigue(self)
            if f.current < f.base * 0.3 then f.current = f.base * 0.3 end
        end
    end
    if not cur or dt <= 0 then return end
    local h = handlers[cur.op]
    local s = cur
    if h.update(s, dt) and cur == s then finish() end
end

-- Settlers don't greet (greeting turns them toward the player, away from
-- their work) and never start fights.
local function calm()
    local ai = Actor.stats.ai
    pcall(function()
        ai.hello(self).base = 0
        ai.fight(self).base = 0
        ai.alarm(self).base = 0
        ai.flee(self).base = 0
    end)
end

-- Tell the colony when someone hits this settler.
if I.Combat then
    I.Combat.addOnHitHandler(function(attack)
        local a = attack.attacker
        if a and a.id ~= self.id then
            core.sendGlobalEvent('TMW_Attacked', { victim = self.object, attacker = a })
        end
    end)
end

-- Guard training: enough skill to win a fight against a common bandit.
local function trainAsGuard()
    pcall(function()
        local skills = types.NPC.stats.skills
        local function atLeast(stat, v) if stat.base < v then stat.base = v end end
        atLeast(skills.longblade(self), 45)
        atLeast(skills.lightarmor(self), 35)
        atLeast(skills.block(self), 25)
        atLeast(Actor.stats.attributes.strength(self), 50)
    end)
end

-- A captured enemy: stop fighting, drop weapons, wake up soon.
local function becomePrisoner()
    I.AI.removePackages()
    local eq = Actor.getEquipment(self)
    eq[SLOT.CarriedRight] = nil
    eq[SLOT.CarriedLeft] = nil
    pcall(Actor.setEquipment, self, eq)
    setStance(Actor.STANCE.Nothing)
    wakeT = 4
end

return {
    engineHandlers = {
        onInit = function(data)
            wid = data and data.wid
            calm()
            if data and data.prisoner then becomePrisoner() end
        end,
        onSave = function() return { wid = wid } end,
        onLoad = function(data) wid = data and data.wid end,
        onUpdate = onUpdate,
        onInactive = function() cur = nil end,
        onActive = function() carrying = nil end, -- vfx don't survive unloading
    },
    eventHandlers = {
        TMW_Step = onStep,
        TMW_Stop = stop,
        TMW_SetDebug = function(on) debugOn = on end,
        TMW_TrainGuard = trainAsGuard,
        TMW_Wear = wear,
    },
}
