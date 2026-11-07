-- Runtime records (OpenMW 0.52+): tools, building activators, decorations
-- and one NPC record per settler. Records created with world.createRecord
-- are stored in the save game; we remember their generated ids in the
-- global script's saved state.
--
-- Global context only.

local world = require('openmw.world')
local types = require('openmw.types')

local defs = require('scripts.tomorrowind.defs')

local R = {}

-- Tools are one-handed on purpose: in the one-handed attack animation the
-- "chop hit" key (where damage happens) sits in a gap the worker script
-- skips, so swinging can never hurt anyone. Damage is zero anyway.
local TOOLS = {
    pick = { template = "miner's pick", name = 'Colony Pick', type = 'AxeOneHand' },
    hoe = { template = "miner's pick", name = 'Colony Hoe', type = 'AxeOneHand' },
    axe = { template = 'iron war axe', name = 'Colony Axe', type = 'AxeOneHand' },
    hammer = { template = 'iron club', name = 'Colony Mallet', type = 'BluntOneHand' },
}

local function weaponRecord(spec)
    local base = types.Weapon.records[spec.template]
    assert(base, 'missing vanilla weapon ' .. spec.template)
    return world.createRecord(types.Weapon.createRecordDraft({
        template = base,
        name = spec.name,
        type = types.Weapon.TYPE[spec.type],
        weight = 10, value = 5,
        chopMinDamage = 0, chopMaxDamage = 0,
        slashMinDamage = 0, slashMaxDamage = 0,
        thrustMinDamage = 0, thrustMaxDamage = 0,
    })).id
end

local function activatorRecord(name, model)
    return world.createRecord(types.Activator.createRecordDraft({ name = name, model = model })).id
end

-- The object type behind a building: chests open and gates swing like the
-- real thing, everything else is an activator that opens the colony panel.
local function buildingType(d)
    if d.objectType == 'container' then return types.Container end
    if d.objectType == 'door' then return types.Door end
    return types.Activator
end

local function buildingRecord(look)
    if look.objectType == 'container' then
        return world.createRecord(types.Container.createRecordDraft({
            name = look.name, model = look.model, weight = look.capacity or 200,
        })).id
    elseif look.objectType == 'door' then
        local base = types.Door.records[look.template]
        assert(base, 'missing vanilla door ' .. tostring(look.template))
        return world.createRecord(types.Door.createRecordDraft({ template = base, name = look.name })).id
    end
    return activatorRecord(look.name, look.model)
end

-- A uniform piece: copy of a vanilla clothing/armour item, renamed and
-- made valuable enough that NPC auto-equip always prefers it.
local function uniformRecord(piece)
    for _, T in ipairs({ types.Clothing, types.Armor }) do
        local base = T.records[piece.template]
        if base then
            return world.createRecord(T.createRecordDraft({
                template = base, name = piece.name, value = defs.uniform.value,
            })).id
        end
    end
    error('missing vanilla item ' .. piece.template)
end

-- Every uniform piece in defs, keyed by its template id.
local function uniformPieces()
    local list = {}
    for _, piece in pairs(defs.uniform.base) do list[#list + 1] = piece end
    for _, job in pairs(defs.uniform.jobs) do
        for _, piece in pairs(job) do list[#list + 1] = piece end
    end
    return list
end

local function staticRecord(model)
    return world.createRecord(types.Static.createRecordDraft({ model = model })).id
end

local function sameModel(a, b)
    return a and b and a:lower():gsub('\\', '/') == b:lower():gsub('\\', '/')
end

-- Creates whatever is missing in `ids` (the saved table) and returns it.
function R.ensure(ids)
    ids = ids or {}
    ids.tools = ids.tools or {}
    ids.buildings = ids.buildings or {}
    ids.decor = ids.decor or {}
    ids.uniform = ids.uniform or {}
    for key, spec in pairs(TOOLS) do
        if not ids.tools[key] then ids.tools[key] = weaponRecord(spec) end
    end
    -- a record is remade if defs now use another model (older saves)
    ids.looks = ids.looks or {}
    for kind, d in pairs(defs.buildings) do
        local id = ids.buildings[kind]
        local r = id and buildingType(d).records[id]
        if not r or not sameModel(r.model, d.model) then
            ids.buildings[kind] = buildingRecord(d)
        end
        -- the other models to choose from
        for i = 2, #(d.variants or {}) do
            local look = defs.look(kind, i)
            ids.looks[kind] = ids.looks[kind] or {}
            local vid = ids.looks[kind][i]
            local vr = vid and buildingType(d).records[vid]
            if not vr or not sameModel(vr.model, look.model) then
                ids.looks[kind][i] = buildingRecord(look)
            end
        end
    end
    if not ids.construction then
        ids.construction = activatorRecord('Construction Site', defs.constructionModel)
    end
    if not ids.constructionSmall then
        ids.constructionSmall = activatorRecord('Materials', defs.smallConstructionModel)
    end
    for _, piece in ipairs(uniformPieces()) do
        if not ids.uniform[piece.template] then ids.uniform[piece.template] = uniformRecord(piece) end
    end
    for key, model in pairs(defs.decorModels) do
        if not ids.decor[key] then ids.decor[key] = staticRecord(model) end
    end
    -- what comes up out of the ground during construction, per model
    ids.risingLooks = ids.risingLooks or {}
    for kind, d in pairs(defs.buildings) do
        if not d.small or d.rises then
            for i = 1, math.max(1, #(d.variants or {})) do
                local look = defs.look(kind, i)
                ids.risingLooks[kind] = ids.risingLooks[kind] or {}
                local r = ids.risingLooks[kind][i] and types.Static.records[ids.risingLooks[kind][i]]
                if not r or not sameModel(r.model, look.model) then
                    ids.risingLooks[kind][i] = staticRecord(look.model)
                end
            end
        end
    end
    return ids
end

---------------------------------------------------------------------------
-- settlers

local MALE = { 'Dravil', 'Fadase', 'Teris', 'Golven', 'Ralen', 'Bralyn', 'Athyn', 'Mivul', 'Drals',
    'Velas', 'Neldyn', 'Sathis', 'Uvren', 'Garyn', 'Llevel', 'Ondres', 'Tedril', 'Faves' }
local FEMALE = { 'Ilvi', 'Merys', 'Nalvyna', 'Selvil', 'Tirasa', 'Athyna', 'Dalvesa', 'Llaros',
    'Nerile', 'Ravela', 'Sedris', 'Tilisu', 'Uvela', 'Varona', 'Edras', 'Fathasa', 'Mils', 'Ienas' }
local SURNAMES = { 'Aryon', 'Sadri', 'Llethan', 'Omani', 'Hlervu', 'Rethan', 'Indaram', 'Drethan',
    'Orvas', 'Alen', 'Seran', 'Vedam', 'Andas', 'Dren', 'Hlaalu', 'Sarethi', 'Ules', 'Venim',
    'Arethan', 'Belvayn', 'Darys', 'Girith', 'Llervu', 'Romoren' }

local function pick(list) return list[math.random(#list)] end

local function bodyPart(isMale, part, maxIndex)
    -- vanilla Dunmer heads/hair: b_n_dark elf_<m|f>_<head|hair>_NN
    for _ = 1, 10 do
        local id = string.format('b_n_dark elf_%s_%s_%02d', isMale and 'm' or 'f', part, math.random(maxIndex))
        if types.BodyPart == nil or types.BodyPart.records[id] then return id end
    end
    return string.format('b_n_dark elf_%s_%s_01', isMale and 'm' or 'f', part)
end

-- Creates a new, unique settler NPC record. Returns record id and name.
function R.newSettler()
    local isMale = math.random() < 0.5
    local name = pick(isMale and MALE or FEMALE) .. ' ' .. pick(SURNAMES)
    local base = types.NPC.records['assumanu mantiti'] -- a vanilla Dunmer miner (autocalc commoner)
    assert(base, 'missing vanilla NPC template')
    local rec = world.createRecord(types.NPC.createRecordDraft({
        template = base,
        name = name,
        isMale = isMale,
        class = 'commoner',
        head = bodyPart(isMale, 'head', isMale and 16 or 10),
        hair = bodyPart(isMale, 'hair', isMale and 26 or 24),
    }))
    return rec.id, name
end

return R
