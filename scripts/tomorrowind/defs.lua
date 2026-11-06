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
defs.buildings = {
    storehouse = {
        name = 'Storehouse', model = 'meshes/x/ex_de_shack_02.nif', cost = {}, work = 0, beds = 4,
        founding = true, footprint = 350,
    },
    lumber = {
        name = "Woodcutter's Camp", model = 'meshes/f/furn_log_01.nif', cost = {}, work = 10,
        job = 'Woodcutter', slots = 3, cycle = 10, output = { wood = 2 },
        tool = 'axe', footprint = 200,
    },
    farm = {
        name = 'Saltrice Paddy', model = 'meshes/o/flora_saltrice_02.nif', cost = { wood = 6 }, work = 15,
        job = 'Farmer', slots = 3, cycle = 16, output = { food = 2 },
        tool = 'hoe', footprint = 300,
        decor = 'farm',
    },
    mine = {
        name = 'Ore Vein', model = 'meshes/o/contain_rock_ebony_01.nif', cost = { wood = 10 }, work = 20,
        job = 'Miner', slots = 3, cycle = 12, output = { ore = 2 },
        tool = 'pick', footprint = 200,
    },
    smelter = {
        name = 'Smelter', model = 'meshes/f/furn_de_forge_01.nif', cost = { wood = 10, ore = 6 }, work = 30,
        job = 'Smelter', slots = 2, cycle = 14, input = { ore = 2 }, output = { ingot = 1 },
        tool = 'hammer', footprint = 200,
    },
    house = {
        name = 'Hlaalu House', model = 'meshes/x/ex_hlaalu_b_01.nif', cost = { wood = 20, ingot = 4 }, work = 40,
        beds = 4, footprint = 700,
    },
}
defs.buildOrder = { 'lumber', 'farm', 'mine', 'smelter', 'house' }

defs.builderTool = 'hammer'
defs.constructionModel = 'meshes/x/ex_de_scaffold_01.nif'
defs.decorModels = {
    saltrice = 'meshes/o/flora_saltrice_01.nif',
    piling = 'meshes/x/ex_de_docks_piling.nif',
}

return defs
