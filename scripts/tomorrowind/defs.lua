-- Game data for the colony: resources, buildings, timings.
-- Pure data, shared by the simulation core and the OpenMW layer.
-- Durations are simulation seconds (real-time seconds at normal speed);
-- hunger and arrivals are in game hours.

local defs = {}

-- Verbose diagnostics in openmw.log (stuck workers, swings, placement rays).
defs.debug = false

defs.resources = {
    food  = { name = 'Saltrice' },
    wood  = { name = 'Timber' },
    ore   = { name = 'Raw Ore' },
    ingot = { name = 'Iron Ingot' },
}
defs.resourceOrder = { 'food', 'wood', 'ore', 'ingot' }

defs.startingStock = { food = 20, wood = 30, ore = 0, ingot = 0 }
defs.startingWorkers = 3

defs.carryAmount = 5          -- max units a hauler carries per trip
defs.walkSpeed = 110          -- units/s, used to estimate trips when off-screen

defs.hunger = {
    decayPerHour = 1 / 6,     -- fully fed -> empty in 6 game hours
    eatBelow = 0.5,           -- go eat when fed drops below this
    hungryBelow = 0.25,       -- below this: works at reduced speed
    hungrySpeed = 0.5,
}

defs.arrival = {
    everyHours = 1,           -- a newcomer may arrive this often
    minFood = 4,              -- ...but only if there is food to spare
}

defs.buildWorkPerTrip = 10    -- seconds of building per builder visit

-- Building on slopes. The floor level sits `levelAt` of the way from the
-- lowest to the highest ground under the footprint: the uphill side sinks
-- into the slope, the downhill side rests on timber pilings.
defs.slope = {
    levelAt = 0.4,
    hiddenDepth = 40,        -- gap a building's own mesh hides
    maxBurial = 220,         -- minimum allowed sinking into a slope...
    burialPerHeight = 0.35,  -- ...or this fraction of the building's height
    woodPerUnit = 1 / 20,    -- foundation timber per unit of gap
    workPerUnit = 1 / 4,     -- extra builder seconds per unit of gap
    pilingHalfHeight = 290,  -- ex_de_docks_piling.nif is centred, 580 tall (measured in game)
}

-- Buildings.
--   cost:   materials delivered by haulers before building can start
--   work:   seconds of builder work to finish once materials are in
--   beds:   worker capacity added
--   job/slots/cycle/output/input: production jobs
--   tool/anim: what workers swing while working there
--   sound:  played each time a worker's tool strikes (Sound record id,
--           with a random pitch in [pitch[1], pitch[2]])
--   scale:  model scale (the vanilla meshes come in odd sizes). Keep every
--           scale within 0.5..2: saved objects are clamped to that on load.
--   workFx: shown while someone works there (the smelter's fire)
defs.buildings = {
    storehouse = {
        name = 'Storehouse', model = 'meshes/x/ex_de_shack_02.nif', cost = {}, work = 0, beds = 4,
        founding = true, footprint = 350,
    },
    lumber = {
        -- a chopping stump with a stack of logs beside it
        name = "Woodcutter's Camp", model = 'meshes/f/flora_treestump_wg_02.nif', scale = 0.5,
        cost = {}, work = 10,
        job = 'Woodcutter', slots = 3, cycle = 10, output = { wood = 2 },
        tool = 'axe', footprint = 250, decor = 'lumber',
        sound = { id = 'Light Armor Hit', pitch = { 0.6, 0.75 }, volume = 0.9 },
    },
    farm = {
        name = 'Saltrice Paddy', model = 'meshes/o/flora_saltrice_02.nif', cost = { wood = 6 }, work = 15,
        job = 'Farmer', slots = 3, cycle = 16, output = { food = 2 },
        tool = 'hoe', footprint = 300,
        decor = 'farm',
        sound = { id = 'Body Fall Small', pitch = { 1.2, 1.5 }, volume = 0.6 },
    },
    mine = {
        name = 'Ore Vein', model = 'meshes/o/contain_rock_ebony_01.nif', cost = { wood = 10 }, work = 20,
        job = 'Miner', slots = 3, cycle = 12, output = { ore = 2 },
        tool = 'pick', footprint = 200,
        sound = { id = 'Heavy Armor Hit', pitch = { 0.75, 0.95 }, volume = 0.8 },
    },
    smelter = {
        name = 'Smelter', model = 'meshes/f/furn_de_forge_01.nif', cost = { wood = 10, ore = 6 }, work = 30,
        job = 'Smelter', slots = 2, cycle = 14, input = { ore = 2 }, output = { ingot = 1 },
        tool = 'hammer', footprint = 200,
        sound = { id = 'Repair', pitch = { 0.95, 1.1 }, volume = 0.9 },
        decor = 'smelter',
        -- vanilla smithies put a coal bed and a fire light in this forge
        -- at these offsets (measured from Morrowind.esm)
        workFx = { light = 'light_fire_nosmoke_128', offset = { 0, -8, 76 } },
    },
    guardpost = {
        name = 'Guard Post', model = 'meshes/f/furn_banner_hlaalu_01.nif',
        cost = { wood = 10, ingot = 2 }, work = 20,
        job = 'Guard', slots = 2, guard = true, footprint = 120,
    },
    stockade = {
        name = 'Stockade', model = 'meshes/x/ex_de_shack_01.nif',
        cost = { wood = 24, ingot = 2 }, work = 30,
        cells = 4, footprint = 350, decor = 'stockade',
    },
    house = {
        name = 'Hlaalu House', model = 'meshes/x/ex_hlaalu_b_01.nif', cost = { wood = 20, ingot = 4 }, work = 40,
        beds = 4, footprint = 700,
    },
}
defs.buildOrder = { 'lumber', 'farm', 'mine', 'smelter', 'house', 'guardpost', 'stockade' }

-- Defense
defs.defense = {
    shelterSeconds = 10,      -- settlers wait this long in the storehouse per check
    patrolIdle = 6,           -- guards pause this long at each patrol stop
    knockoutBelow = 0.4,      -- with a stockade, enemies below this health fraction get knocked out
    colonyRadius = 3000,      -- attacks within this range of the storehouse raise the alarm
}
defs.guardGear = { 'iron longsword' }
-- jobs prisoners can be put to (forced labour)
defs.prisonerJobs = { Miner = true, Woodcutter = true }

-- What settlers visibly hold while carrying a resource (attached to the hand)
defs.carryModels = {
    wood = 'meshes/m/misc_scrapwood02.nif',
    ore = 'meshes/n/ingred_rawebony_01.nif',
    ingot = 'meshes/n/ingred_scrap_metal_01.nif',
    food = 'meshes/m/misc_wheatbundle00.nif',
}
defs.carryBone = 'Bip01 L Hand'

-- Uniforms: every settler wears the Hlaalu colony shirt; jobs add gear.
-- Each piece is a runtime copy of a vanilla item with a high value, because
-- OpenMW NPCs auto-equip the most valuable clothing whenever their
-- inventory changes. Slots in `managed` are cleared for jobs that don't
-- use them.
defs.uniform = {
    value = 600,
    base = { Shirt = { template = 'common_shirt_02_h', name = 'Hlaalu Colony Shirt' } },
    managed = { 'Helmet', 'Robe', 'Cuirass' },
    jobs = {
        Miner = { Helmet = { template = 'netch_leather_boiled_helm', name = "Miner's Hard Hat" } },
        Woodcutter = { Helmet = { template = 'fur_helm', name = "Woodcutter's Fur Cap" } },
        Smelter = { Helmet = { template = 'imperial_chain_coif_helm', name = "Smelter's Coif" } },
        Farmer = { Robe = { template = 'common_robe_02_h', name = "Farmer's Smock" } },
        Builder = { Helmet = { template = 'netch_leather_helm', name = "Builder's Cap" } },
        Guard = {
            Helmet = { template = 'chitin helm', name = 'Colony Guard Helm' },
            Cuirass = { template = 'chitin cuirass', name = 'Colony Guard Cuirass' },
        },
    },
}

defs.builderTool = 'hammer'
defs.buildSound = { id = 'Light Armor Hit', pitch = { 0.8, 1.0 }, volume = 0.8 }
defs.constructionModel = 'meshes/x/ex_de_scaffold_01.nif'
defs.scaffoldRadius = 163    -- ex_de_scaffold_01.nif half width; scaled up for big buildings
defs.decorModels = {
    saltrice = 'meshes/o/flora_saltrice_01.nif',
    fence = 'meshes/x/furn_com_fence_01.nif',
    piling = 'meshes/x/ex_de_docks_piling.nif',
    log = 'meshes/f/furn_log_01.nif',             -- 54 long; used at double size
    orepile = 'meshes/f/furn_coalpile00.nif',
    metal = 'meshes/n/ingred_scrap_metal_01.nif',
    crate = 'meshes/o/contain_crate_01.nif',
    coals = 'meshes/f/furn_de_firepit_01.nif',
}

-- Materials delivered to a construction site are stacked next to it and
-- used up as the building goes up. `per` units per object, at most `max`.
defs.piles = {
    wood = { model = 'log', per = 2, max = 30, layout = 'logs' },
    ore = { model = 'orepile', per = 3, max = 6, layout = 'heaps' },
    ingot = { model = 'metal', per = 1, max = 12, layout = 'plates' },
    food = { model = 'crate', per = 5, max = 4, layout = 'heaps' },
}

return defs
