-- Game data for the colony: resources, buildings, timings.
-- Pure data, shared by the simulation core and the OpenMW layer.
-- Durations are simulation seconds (real-time seconds at normal speed);
-- hunger and arrivals are in game hours.

local defs = {}

-- Verbose diagnostics in openmw.log (stuck workers, swings, placement rays).
defs.debug = false

defs.resources = {
    food  = { name = 'Food' },
    wood  = { name = 'Timber' },
    ore   = { name = 'Raw Ore' },
    ingot = { name = 'Iron Ingot' },
}
defs.resourceOrder = { 'food', 'wood', 'ore', 'ingot' }

defs.startingStock = { food = 30, wood = 40, ore = 0, ingot = 0 }
defs.startingWorkers = 3

defs.carryAmount = 5          -- max units a hauler carries per trip
defs.walkSpeed = 110          -- units/s, used to estimate trips when off-screen

defs.hunger = {
    decayPerHour = 1 / 12,    -- fully fed -> empty in 12 waking game hours: about 3 meals a day
    eatBelow = 0.5,           -- go eat when fed drops below this
    hungryBelow = 0.25,       -- below this: works at reduced speed
    hungrySpeed = 0.5,
    mealFood = 3,             -- Food per meal
    mealBelow = 0.8,          -- in free time, have a meal below this
    asleepFactor = 0.25,      -- hunger grows this much slower while asleep
    mealHours = 0.25,         -- how long a meal by the campfire takes
}

-- The working day, in hours of the game clock. Guards keep watch around the
-- clock; everyone else works, has free time and sleeps. Prisoners are locked
-- up outside working hours.
defs.schedule = {
    wake = 6,         -- free time until work starts
    workStart = 7,
    workEnd = 18,     -- free time until bed
    sleep = 22,
    -- Everyone keeps their own hours: early birds and night owls are shifted
    -- by up to `chronotype` hours (work a bit less), plus a personal `noise`.
    -- Keep wake before workStart and all hours clear of noon and midnight.
    chronotype = 0.75,
    noise = 0.25,
    -- Some people get hungry sooner than others.
    appetite = 0.1,
    -- Free time activities last longer or shorter than their nominal hours.
    leisureSpread = 0.3,
}

-- What idle settlers do (relative chances). Laborers and builders with no
-- construction to do: lend a hand or potter about at work, and relax in free
-- time. `helping` is real work at a production site with room left.
defs.downtime = {
    work = { helping = 5, tidy = 2, chat = 2, stroll = 2, leisure = 1, indoors = 1 },
    free = { leisure = 6, chat = 3, stroll = 2, indoors = 3 },
    tidySeconds = { 12, 25 },
    chatSeconds = { 18, 40 },
    strollSeconds = { 15, 35 },
    indoorsHours = { 0.3, 0.8 },
}

-- Sometimes settlers say something when they start on a task. `lines` is keyed
-- by the task's label, then its kind; the voice is a vanilla sigh or grumble.
defs.utter = {
    chance = 0.3,
    cooldown = 40,      -- seconds between remarks by the same settler
    voiceChance = 0.5,
    range = 1800,       -- bubbles show within this distance
    seconds = 4,
    lines = {
        Miner = { "This ore won't dig itself.", 'Back down to the vein.', 'My back aches already.' },
        Woodcutter = { 'Plenty of timber left.', 'Stand clear!', 'Good wood, this.' },
        Farmer = { 'The saltrice needs tending.', 'Mud up to the knees again.', 'A good crop this year.' },
        Smelter = { 'Time to stoke the forge.', 'Hot work, this.', 'Good iron, if the ore holds out.' },
        haul = { 'Heavy load.', 'Coming through!', 'Where does this go again?' },
        build = { "Let's get this up.", 'Hand me that hammer.', 'This will stand a hundred years.' },
        eat = { 'At last, some food.', 'I could eat a guar.', 'Saltrice again?' },
        sleep = { 'My bed is calling.', 'What a day.', 'Good night, all.' },
        shelter = { 'Get inside, quickly!', 'We are under attack!', 'Run!' },
        fight = { 'For the colony!', 'You picked the wrong settlement.' },
        tidy = { 'This place could use some tidying.', 'I may as well make myself useful.' },
        stroll = { 'A little walk will do me good.', 'Fine day for it.' },
        indoors = { 'I think I will put my feet up.', 'Time for a little rest inside.' },
        gather = { 'I may as well lend a hand.' },
        salvage = { 'Waste not, want not.', 'Plenty of good timber in this lot.' },
        trade = { 'Fresh goods, good prices!', 'Let us see what this fetches.', 'Everything has its price.' },
        ['Resting by the campfire'] = { 'A warm fire is all I need.', 'Is there room by the fire?' },
        ['Reading a book'] = { 'Now, where was I?', 'I must finish that chapter.' },
        ['Having a drink and a chat'] = { 'I could use a drink.', 'Pour me one, will you?' },
        ['Taking a break'] = { 'Oh, my aching feet.', 'Just for a moment.' },
    },
}

-- Vanilla Dunmer voice lines usable between settlers (files under Sound/).
defs.voice = {
    chat = {
        m = {
            { 'Vo\\d\\m\\Hlo_DM150.mp3', 'How are you?' }, { 'Vo\\d\\m\\Hlo_DM170.mp3', 'So good to see you.' },
            { 'Vo\\d\\m\\Hlo_DM184.mp3', "Go ahead, I'm listening." }, { 'Vo\\d\\m\\Hlo_DM185.mp3', 'I am never too busy for a good talk.' },
            { 'Vo\\d\\m\\Hlo_DM183.mp3', 'Please, join me.' }, { 'Vo\\d\\m\\Hlo_DM147.mp3', 'Is there something you need?' },
            { 'Vo\\d\\m\\Hlo_DM047.mp3', 'What now?' }, { 'Vo\\d\\m\\Hlo_DM084.mp3', 'Go ahead.' },
            { 'Vo\\d\\m\\Hlo_DM000b.mp3', 'Humph.' }, { 'Vo\\d\\m\\Hlo_DM172.mp3', 'Three blessings, sera.' },
            { 'Vo\\d\\m\\Hlo_DM096.mp3', 'What is it, sera?' }, { 'Vo\\d\\m\\Hlo_DM119.mp3', 'Muthsera?' },
        },
        f = {
            { 'Vo\\d\\f\\Hlo_DF150.mp3', 'How are you?' }, { 'Vo\\d\\f\\Hlo_DF147.mp3', 'Is there something you need?' },
            { 'Vo\\d\\f\\Hlo_DF047.mp3', 'What now?' }, { 'Vo\\d\\f\\Hlo_DF096.mp3', 'What is it, sera?' },
            { 'Vo\\d\\f\\Hlo_DF148.mp3', 'Is there something I can do for you?' }, { 'Vo\\d\\f\\Hlo_DF145.mp3', 'May I help you?' },
        },
    },
    grunt = {
        m = { { 'Vo\\d\\m\\Idl_DM003.mp3' }, { 'Vo\\d\\m\\Idl_DM004.mp3' }, { 'Vo\\d\\m\\Idl_DM002.mp3' } },
        f = { { 'Vo\\d\\f\\Idl_DF003.mp3' }, { 'Vo\\d\\f\\Idl_DF004.mp3' }, { 'Vo\\d\\f\\Idl_DF002.mp3' } },
    },
    alarm = {
        m = { { 'Vo\\d\\m\\Fle_DM002.mp3', "I'm being attacked. Help!" } },
        f = { { 'Vo\\d\\f\\Fle_DF002.mp3', "I'm being attacked. Help!" } },
    },
}

-- A building under construction comes up out of the ground, growing from
-- fromScale to full size. It moves in steps of stepPercent: moving an object
-- with collision is not free, every step redoes part of the navmesh.
defs.rise = { fromScale = 0.8, stepPercent = 1 }

-- Placement: how far a building can be moved up or down from where it would
-- go by itself (units), and how fast while holding the key (units/second).
defs.placeRaise = { limit = 500, speed = 150 }

-- The look of a site: its building, with its chosen variant's fields on top.
local looks = {}
function defs.look(kind, variant)
    local d = defs.buildings[kind]
    local v = d.variants and d.variants[variant or 1]
    if not v then return d end
    looks[kind] = looks[kind] or {}
    local l = looks[kind][variant or 1]
    if not l then
        l = setmetatable({}, { __index = function(_, k)
            local own = v[k]
            if own ~= nil then return own end
            return d[k]
        end })
        looks[kind][variant or 1] = l
    end
    return l
end

-- Newcomers arrive more slowly the bigger the colony, and only if there is
-- food to feed everybody for a while.
defs.arrival = {
    everyHours = 2,           -- hours between newcomers...
    perSettler = 0.25,        -- ...plus this for every settler already here
    minFood = 10,             -- food in stock needed...
    foodPerSettler = 3,       -- ...plus this for every settler already here
}

defs.buildWorkPerTrip = 10    -- seconds of building per builder visit

-- Demolishing a building leaves this share of what it cost in a pile on the
-- spot (cancelling one leaves what was delivered); settlers carry it back.
-- Furnishings give everything back at once.
defs.salvage = { share = 0.5 }

-- Moving a finished building: a share of what it cost, plus timber and work
-- for every unit of distance and degree of turn (and a foundation if the new
-- spot needs one).
defs.move = {
    share = 0.15, perUnit = 1 / 150, perDegree = 1 / 15, minWood = 2,
    workShare = 0.3, workPerUnit = 1 / 40, workPerDegree = 1 / 6,
}
defs.awaySummaryAfter = 30    -- seconds away before coming back shows a summary

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

-- Where a building's door is, from vanilla references: offset from the model's
-- origin, turned by degrees; `interior` is a room in interiors.lua.
local function hlaaluDoor(x, y, z, degrees, interior, id)
    return { id = id or 'hlaalu_loaddoor_ 02', offset = { x, y, z }, turn = math.rad(degrees), interior = interior }
end

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
--   door:   the building can be entered (see hlaaluDoor)
--   maxBuilders: how many settlers haul for and build it at once (no limit if unset)
defs.buildings = {
    storehouse = {
        name = 'Storehouse', model = 'meshes/x/ex_de_shack_02.nif', cost = {}, work = 0, beds = 4,
        founding = true, footprint = 350, storage = 150,
    },
    lumber = {
        -- a chopping stump with a stack of logs beside it
        name = "Woodcutter's Camp", model = 'meshes/f/flora_treestump_wg_02.nif', scale = 0.5,
        cost = {}, work = 10,
        job = 'Woodcutter', slots = 3, cycle = 20, output = { wood = 2 }, maxBuilders = 3,
        tool = 'axe', footprint = 250, decor = 'lumber',
        sound = { id = 'Light Armor Hit', pitch = { 0.6, 0.75 }, volume = 0.9 },
    },
    farm = {
        -- what grows on it is a matter of taste: all of it is food
        name = 'Farm', model = 'meshes/o/flora_saltrice_02.nif', cost = { wood = 10 }, work = 15,
        job = 'Farmer', slots = 3, cycle = 30, output = { food = 2 }, maxBuilders = 4,
        tool = 'hoe', footprint = 300,
        decor = 'farm',
        variants = {
            { label = 'Saltrice Paddy', crop = 'saltrice' },
            { label = 'Wickwheat Field', model = 'meshes/o/flora_wickwheat_01.nif', crop = 'wickwheat' },
            { label = 'Marshmerrow Patch', model = 'meshes/o/flora_marshmerrow_01.nif', crop = 'marshmerrow' },
            { label = 'Ash Yam Field', model = 'meshes/o/flora_ash_yam_01.nif', crop = 'ashyam', scale = 1.8, cropScale = 1.8 },
            { label = 'Hackle-lo Field', model = 'meshes/o/flora_hackle-lo_01.nif', crop = 'hacklelo', scale = 0.55, cropScale = 0.55 },
            { label = 'Kwama Nest', model = 'meshes/o/contain_egg_kwama00.nif', crop = 'kwamaegg' },
        },
        sound = { id = 'Body Fall Small', pitch = { 1.2, 1.5 }, volume = 0.6 },
    },
    mine = {
        name = 'Ore Vein', model = 'meshes/o/contain_rock_ebony_01.nif', cost = { wood = 16 }, work = 20,
        job = 'Miner', slots = 3, cycle = 24, output = { ore = 2 }, maxBuilders = 4,
        tool = 'pick', footprint = 200,
        sound = { id = 'Heavy Armor Hit', pitch = { 0.75, 0.95 }, volume = 0.8 },
    },
    smelter = {
        name = 'Smelter', model = 'meshes/f/furn_de_forge_01.nif', cost = { wood = 20, ore = 8 }, work = 30,
        job = 'Smelter', slots = 2, cycle = 40, input = { ore = 2 }, output = { ingot = 1 }, maxBuilders = 4,
        tool = 'hammer', footprint = 200,
        sound = { id = 'Repair', pitch = { 0.95, 1.1 }, volume = 0.9 },
        decor = 'smelter',
        -- vanilla smithies put a coal bed and a fire light in this forge
        -- at these offsets (measured from Morrowind.esm)
        workFx = { light = 'light_fire_nosmoke_128', offset = { 0, -8, 76 } },
    },
    guardpost = {
        name = 'Guard Post', model = 'meshes/f/furn_banner_hlaalu_01.nif',
        cost = { wood = 15, ingot = 4 }, work = 20,
        job = 'Guard', slots = 2, guard = true, footprint = 120, maxBuilders = 4,
    },
    stockade = {
        name = 'Stockade', model = 'meshes/x/ex_de_shack_01.nif',
        cost = { wood = 40, ingot = 6 }, work = 40,
        cells = 4, footprint = 350, decor = 'stockade', maxBuilders = 6,
    },
    house = {
        -- Hlaalu models: the door sills sit about 70 below the origin, on a solid
        -- plinth that goes into the ground (and shows on the downhill side).
        -- With a door, its beds are the ones in its room: it comes with the bed
        -- the vanilla house had. Without one, `beds` counts.
        name = 'Hlaalu House', model = 'meshes/x/ex_hlaalu_b_01.nif', cost = { wood = 25, ingot = 4 }, work = 60,
        beds = 4, footprint = 700, lift = 80,
        door = hlaaluDoor(14, -4, -17, 92, 'hlaalu_mid'),
        variants = {
            { label = 'Hlaalu House, tall' },
            { label = 'Hlaalu House', model = 'meshes/x/ex_hlaalu_b_04.nif', door = hlaaluDoor(257, -208, 53, 0, 'hlaalu_small') },
            { label = 'Hlaalu House, with stairs', model = 'meshes/x/ex_hlaalu_b_03.nif', door = hlaaluDoor(-383, -183, 26, 0, 'hlaalu_small') },
            { label = 'Hlaalu Manor', model = 'meshes/x/ex_hlaalu_b_06.nif', door = hlaaluDoor(-126, -335, -18, 0, 'hlaalu_large', 'hlaal_loaddoor_01') },
            { label = 'Hlaalu Hall', model = 'meshes/x/ex_hlaalu_b_07.nif', door = hlaaluDoor(-275, -289, -17, 0, 'hlaalu_large') },
            { label = 'Hlaalu Residence', model = 'meshes/x/ex_hlaalu_b_10.nif', door = hlaaluDoor(233, -87, -18, 0, 'hlaalu_mid') },
            { label = 'Hlaalu Tower', model = 'meshes/x/ex_hlaalu_b_13.nif', lift = 420, door = hlaaluDoor(-129, -60, -18, 0, 'hlaalu_mid', 'hlaal_loaddoor_01') },
            { label = 'Hlaalu Terrace', model = 'meshes/x/ex_hlaalu_b_17.nif', door = hlaaluDoor(425, -200, -18, 0, 'hlaalu_mid') },
            { label = 'Timber House', model = 'meshes/x/ex_common_building_01.nif', lift = 250,
              door = hlaaluDoor(125, -100, -150, 0, 'common', 'ex_common_door_01') },
            { label = 'Dunmer Shack', model = 'meshes/x/ex_de_shack_03.nif', lift = 105,
              door = hlaaluDoor(186, -47, -5, 270, 'shack', 'ex_de_shack_door') },
            { label = 'Dunmer Stilt House', model = 'meshes/x/ex_de_shack_05.nif', lift = 370, door = false },
        },
    },
    market = {
        name = 'Market Stall', model = 'meshes/f/furn_de_ex_table_03.nif', lift = 30,
        cost = { wood = 25, ingot = 2 }, work = 25, job = 'Trader', slots = 2, cycle = 8, trade = true,
        footprint = 220, maxBuilders = 4,
        props = {
            { decor = 'cart', offset = { 0, 200, 50 } },
            { decor = 'crate', offset = { -130, 20, 32 } }, { decor = 'crate', offset = { -130, 20, 96 }, turn = 0.5 },
            { decor = 'crate', offset = { 130, -10, 32 }, turn = 0.2 },
            { decor = 'orepile', offset = { 135, 70, -15 }, scale = 0.6 },
        },
    },
    -- a building on its way to a new spot (cost and work are worked out per move)
    move = {
        name = 'Move', model = 'meshes/x/ex_de_scaffold_01.nif', cost = {}, work = 0,
        footprint = 200, moves = true, maxBuilders = 6,
    },
    -- what's left of a demolished building, until it's carried away
    salvage = {
        name = 'Salvage', model = 'meshes/f/furn_crate_open_01.nif', lift = 29,
        cost = {}, work = 0, footprint = 60, salvage = true,
    },
    warehouse = {
        name = 'Warehouse', model = 'meshes/x/ex_de_shack_04.nif', cost = { wood = 30 }, work = 25,
        storage = 150, footprint = 350, lift = 320, maxBuilders = 4,
    },
}
defs.buildOrder = { 'lumber', 'farm', 'mine', 'smelter', 'warehouse', 'market', 'house', 'guardpost', 'stockade' }

-- Trade: traders at a market stall sell what's above the `keep` level. Every
-- unit sold lowers that resource's price by `pressure`, down to `minFactor`;
-- prices recover by `recover` of the gap per game hour. Caravans pay better and
-- sell what's on your buy list, up to `supply` of each per visit.
defs.trade = {
    prices = { food = 2, wood = 3, ore = 5, ingot = 18 },
    pressure = { food = 0.004, wood = 0.005, ore = 0.008, ingot = 0.03 },
    minFactor = 0.3,
    recover = 0.03,
    buyMarkup = 1.6,
    keep = { food = 50, wood = 40, ore = 20, ingot = 10 },
    step = 10,          -- the ledger's < > change keep and buy levels by this
    caravan = { everyHours = 48, stayHours = 10, sellBonus = 1.25, supply = 30 },
}

-- Furnishings: smaller things that make the colony a home. They use the same
-- construction pipeline as buildings, without scaffolds or foundations, and
-- only show in the ledger while unbuilt (look at one to remove it).
--   small:      marks a furnishing
--   lift:       height of the model's origin above the ground (most vanilla
--               furniture meshes are centred on their origin)
--   props:      extras placed with it: { light = vanilla light id } or
--               { decor = key in decorModels }, offset = { x, y, z },
--               optional turn (radians) and scale
--   interact:   what settlers do with it in their free time: `hours` of game
--               time, `slots` at once, `weight` for how often they choose it,
--               `prop` held in the hand (key in propModels)
--   sleepOn:    settlers visibly sleep on it (beds = 1 adds capacity too)
--   hollow:     other furnishings may be placed inside it
--   objectType: 'container' or 'door' instead of an activator
--   segment:    walls snap end to end: half its length along the local x
--               axis, `at` = where its middle is along that axis
--   variants:   other models to choose from while placing (arrow keys). Each
--               overrides what it needs of model, lift, scale, props, segment,
--               sleepZ; the first is the building's own fields.
--   rises:      comes up out of the ground while built, like a building
--   opensLedger: activating it opens the ledger, looking at it shows a summary
--   group:      which part of the Furnish tab it's in
--   mount:      'surface' (any floor, roof or table you aim at) or 'wall'
--               (whatever wall you aim at); otherwise it stands on the ground
--   depth:      for wall mounts, how far it stands out from the wall
--   anchor:     'end': it starts where you aim and runs forward
--   flat:       other things may stand on it (rugs, cushions)
--   outdoor:    can't be placed inside a house
--   instant/price: bought with treasury gold, there at once (refunded on removal)
-- Books lying on a shelf's boards: three per board, turned to fit its depth.
local function shelfBooks(boards, spread)
    local kinds = { 'bookA', 'bookB', 'bookC' }
    local props = {}
    for row, z in ipairs(boards) do
        for i = 1, 3 do
            local x = ((i + row) % 3 - 1) * spread * 0.8 + (row - 2) * 6
            props[#props + 1] = { decor = kinds[(i + row) % 3 + 1], offset = { x, -7, z + 2.5 }, turn = 1.57, scale = 0.6 }
        end
    end
    return props
end

local function furnishing(t)
    t.small = true
    t.footprint = t.footprint or 60
    t.maxBuilders = t.maxBuilders or 2
    defs.buildings[t.key] = t
    return t.key
end
defs.furnishOrder = {
    furnishing({ key = 'campfire', group = 'Lights', name = 'Campfire', model = 'meshes/f/furn_de_firepit_01.nif',
        lift = 20, cost = { wood = 4 }, work = 5, desc = 'Settlers eat and rest here',
        props = { { light = 'light_fire_nosmoke_128', offset = { 0, 0, 5 } } },
        variants = {
            { label = 'Coal pit' },
            { label = 'Stone ring', model = 'meshes/f/furn_firepit00.nif', lift = 40,
              props = { { light = 'light_fire_nosmoke_128', offset = { 0, 0, 25 } } } },
        },
        interact = { label = 'Resting by the campfire', hours = 1, slots = 6, weight = 4, meal = true } }),
    furnishing({ key = 'lamppost', group = 'Lights', name = 'Lamp Post', model = 'meshes/f/furn_woodpost_01.nif',
        lift = 60, cost = { wood = 6, ingot = 2 }, work = 6, desc = 'Lights up the night',
        props = { { decor = 'lampArm', offset = { 22, 0, 195 } },
                  { light = 'light_de_streetlight_01_223_s', offset = { 53, 0, 221 } } } }),
    furnishing({ key = 'lantern', group = 'Lights', name = 'Paper Lantern', model = 'meshes/f/furn_de_ashl_post.nif',
        lift = 80, cost = { wood = 3 }, work = 3, desc = 'A small warm light',
        props = { { light = 'light_de_paper_lantern_01', offset = { 0, 0, 170 } } },
        variants = {
            { label = 'Round' },
            { label = 'Long', props = { { light = 'light_de_paper_lantern_04', offset = { 0, 0, 170 } } } },
        } }),
    furnishing({ group = 'Furniture', key = 'chair', name = 'Chair', model = 'meshes/f/furn_com_chair_01.nif',
        lift = 45, cost = { wood = 3 }, work = 3, desc = 'Somewhere to take a break',
        interact = { label = 'Taking a break', hours = 0.5, slots = 1, weight = 1 },
        variants = {
            { label = 'Armchair' },
            { label = 'Plain chair', model = 'meshes/f/furn_com_chair_03.nif', lift = 36 },
            { label = 'Dunmer chair', model = 'meshes/f/furn_de_chair_01.nif', lift = 37 },
            { label = 'Dunmer high chair', model = 'meshes/f/furn_de_chair_03.nif', lift = 44 },
            { label = 'Bar stool', model = 'meshes/f/furn_com_stool_01.nif', lift = 19 },
            { label = 'Dunmer stool', model = 'meshes/f/furn_de_stool_01.nif', lift = 22 },
            { label = 'Outdoor stool', model = 'meshes/f/furn_de_ex_stool_02.nif', lift = 19 },
        } }),
    furnishing({ group = 'Furniture', key = 'bench', name = 'Bench', model = 'meshes/f/furn_de_ex_bench_01.nif',
        lift = 19, cost = { wood = 4 }, work = 4, desc = 'Somewhere to take a break',
        interact = { label = 'Taking a break', hours = 0.5, slots = 2, weight = 1 },
        variants = {
            { label = 'Outdoor bench' },
            { label = 'Plain bench', model = 'meshes/f/furn_com_bench_01.nif', lift = 22 },
            { label = 'Short bench', model = 'meshes/f/furn_com_bench_02.nif', lift = 19 },
            { label = 'Dunmer bench', model = 'meshes/f/furn_de_bench_01.nif', lift = 22 },
            { label = 'Long Dunmer bench', model = 'meshes/f/furn_de_bench_03.nif', lift = 23 },
        } }),
    furnishing({ group = 'Furniture', key = 'table', name = 'Table', model = 'meshes/f/furn_de_ex_table_02.nif',
        lift = 32, cost = { wood = 6 }, work = 5, desc = 'For a drink and a chat',
        interact = { label = 'Having a drink and a chat', hours = 0.75, slots = 4, weight = 3, prop = 'cup' },
        variants = {
            { label = 'Outdoor table' },
            { label = 'Long outdoor table', model = 'meshes/f/furn_de_ex_table_03.nif', lift = 30 },
            { label = 'Long table', model = 'meshes/f/furn_com_table_01.nif', lift = 35 },
            { label = 'Round table', model = 'meshes/f/furn_com_table_03.nif', lift = 28 },
            { label = 'Small table', model = 'meshes/f/furn_com_table_05.nif', lift = 28 },
            { label = 'Square Dunmer table', model = 'meshes/f/furn_de_table_01.nif', lift = 29 },
            { label = 'Long Dunmer table', model = 'meshes/f/furn_de_table_03.nif', lift = 35 },
        } }),
    furnishing({ group = 'Furniture', key = 'bookshelf', name = 'Bookshelf', model = 'meshes/f/furn_com_bookshelf_02.nif',
        lift = 91, cost = { wood = 10 }, work = 6, desc = 'Settlers read here',
        -- vanilla shelves come empty, so books lie on the boards (heights above
        -- the ground, measured in game on bare shelves: tests/ingame photo scene)
        props = shelfBooks({ 138, 95, 53 }, 55),
        variants = {
            { label = 'Tall bookshelf' },
            { label = 'Wide bookshelf', model = 'meshes/f/furn_com_bookshelf_01.nif', lift = 94, props = shelfBooks({ 136, 95, 51 }, 55) },
            { label = 'Dunmer bookshelf', model = 'meshes/f/furn_de_bookshelf_01.nif', lift = 76, props = shelfBooks({ 87, 42 }, 65) },
            { label = 'Long Dunmer bookshelf', model = 'meshes/f/furn_de_bookshelf_02.nif', lift = 80, props = shelfBooks({ 76, 28 }, 70) },
        },
        interact = { label = 'Reading a book', hours = 1, slots = 2, weight = 3, prop = 'book' } }),
    furnishing({ group = 'Furniture', key = 'chest', name = 'Chest', model = 'meshes/o/contain_com_chest_01.nif',
        lift = 17, cost = { wood = 8 }, work = 4, desc = 'Stores your things', objectType = 'container', capacity = 400,
        interact = { label = 'Looking through a chest', hours = 0.25, slots = 1, weight = 1 },
        variants = {
            { label = 'Plain chest' },
            { label = 'Banded chest', model = 'meshes/o/contain_com_chest_02.nif', lift = 22 },
            { label = 'Dunmer chest', model = 'meshes/o/contain_de_chest_01.nif', lift = 23 },
            { label = 'Fine Dunmer chest', model = 'meshes/o/contain_de_chest_02.nif', lift = 17 },
            { label = 'Old chest', model = 'meshes/o/contain_chest10.nif', lift = 18 },
            { label = 'Small chest', model = 'meshes/o/contain_chest_small_01.nif', lift = 6 },
        } }),
    furnishing({ group = 'Furniture', key = 'bedroll', name = 'Bedroll', model = 'meshes/f/active_de_bedroll.nif',
        lift = 13, cost = { wood = 8 }, work = 3, beds = 1, sleepOn = true, sleepZ = 26, desc = '+1 bed' }),
    furnishing({ group = 'Furniture', key = 'bed', name = 'Bed', model = 'meshes/f/active_de_bed_01.nif',
        lift = 31, cost = { wood = 14, ingot = 1 }, work = 6, beds = 1, sleepOn = true, sleepZ = 60, desc = '+1 bed',
        variants = {
            { label = 'Dunmer bed' },
            { label = 'Dark Dunmer bed', model = 'meshes/f/active_de_bed_04.nif', lift = 32 },
            { label = 'Wide Dunmer bed', model = 'meshes/f/active_de_bed_05.nif', lift = 33 },
            { label = 'Plain bed', model = 'meshes/f/furn_com_bed_02.nif', lift = 31 },
            { label = 'Rough bed', model = 'meshes/f/furn_com_bed_03.nif', lift = 29 },
            { label = 'Canopy bed', model = 'meshes/f/furn_com_bed_01.nif', lift = 86 },
            -- the beds of the vanilla houses the rooms are copied from
            { label = 'Hlaalu bed', model = 'meshes/f/active_de_bed_11.nif', lift = 32 },
            { label = 'Wide Hlaalu bed', model = 'meshes/f/active_de_bed_16.nif', lift = 33 },
            { label = 'Long Hlaalu bed', model = 'meshes/f/active_de_bed_28.nif', lift = 41 },
            { label = 'Common bed', model = 'meshes/f/furn_com_bed_05.nif', lift = 29 },
        } }),
    -- scaled up so its door is wide enough for the navmesh (routes go through
    -- it): meshes come from tools/make_tent_meshes.py
    furnishing({ key = 'tent', group = 'Structures', name = 'Tent', model = 'meshes/tomorrowind/tent.nif', footprint = 360,
        scale = 1.3, lift = 221, cost = { wood = 20 }, work = 12, hollow = true, rises = true, maxBuilders = 4,
        desc = 'Put beds and furniture inside',
        -- the outside mesh is one-sided: this lines it from the inside
        -- (its floor sits 90 above its origin's expected height: measured in game)
        props = { { decor = 'tentLining', offset = { 0, 0, 131 }, scale = 1.12 } },
        variants = {
            { label = 'Round tent' },
            { label = 'Large tent', model = 'meshes/tomorrowind/tent_large.nif', scale = 1.1, lift = 200,
              props = { { decor = 'tentLargeLining', offset = { 0, 0, 150 }, scale = 1 } } },
        } }),
    furnishing({ key = 'fence', group = 'Structures', name = 'Wooden Fence', model = 'meshes/x/furn_com_fence_02.nif',
        lift = 120, cost = { wood = 3 }, work = 3, segment = { half = 132 }, desc = 'Snaps to walls and fences' }),
    furnishing({ key = 'wall', group = 'Structures', name = 'Stone Wall', model = 'meshes/x/ex_drystonewall_s_01.nif',
        lift = 90, cost = { ore = 4 }, work = 6, segment = { half = 126 }, desc = 'Snaps to walls and fences',
        variants = {
            { label = 'Dry stone' },
            { label = 'Redoran', model = 'meshes/x/ex_redwall_straight_01.nif', lift = 150 },
            { label = 'Hlaalu, tall', model = 'meshes/x/ex_hlaalu_wall_01.nif', lift = 220 },
        } }),
    furnishing({ key = 'gate', group = 'Structures', name = 'Gate', model = 'meshes/x/ex_de_sn_gate.nif', objectType = 'door',
        template = 'ex_de_sn_gate', lift = 80, cost = { wood = 6, ingot = 2 }, work = 6,
        segment = { half = 64, at = 63 }, desc = 'Opens for you and your settlers' }),
    -- on any surface: roofs, ledges, ground. Walkways and bridges start where you
    -- aim and run forward; walkway planks snap together level.
    furnishing({ key = 'walkway', group = 'Structures', name = 'Walkway', model = 'meshes/x/ex_de_shack_plank_01.nif',
        mount = 'surface', outdoor = true, anchor = 'end', lift = 9, cost = { wood = 2 }, work = 3,
        segment = { half = 124, alongY = true, level = true }, desc = 'Planks to walk on, roof to roof',
        variants = {
            { label = 'Plank walkway' },
            { label = 'Short plank walkway', model = 'meshes/x/ex_de_shack_plank_02.nif', segment = { half = 77, alongY = true, level = true } },
            { label = 'Long plank walkway', model = 'meshes/x/ex_de_shack_plank_04.nif', lift = 4, segment = { half = 157, alongY = true, level = true } },
        } }),
    furnishing({ key = 'ropebridge', group = 'Structures', name = 'Rope Bridge', model = 'meshes/x/ex_ropebridge_512_01.nif',
        mount = 'surface', outdoor = true, anchor = 'end', lift = 0, cost = { wood = 10 }, work = 10, footprint = 200,
        segment = { half = 518, level = true }, maxBuilders = 3, desc = 'Spans a gap between two heights',
        variants = {
            { label = 'Rope bridge, 5 yards' },
            { label = 'Rope bridge, 10 yards', model = 'meshes/x/ex_ropebridge_1024_01.nif', cost = { wood = 18 }, segment = { half = 1030, level = true } },
            { label = 'Rope bridge, 20 yards', model = 'meshes/x/ex_ropebridge_2048_01.nif', cost = { wood = 32 }, segment = { half = 2053, level = true } },
        } }),
    furnishing({ key = 'stairs', group = 'Structures', name = 'Stairs', model = 'meshes/x/ex_de_shack_steps_01.nif',
        mount = 'surface', outdoor = true, lift = 143, cost = { wood = 6 }, work = 5, footprint = 160, desc = 'Up to a door or a roof',
        variants = {
            { label = 'Wooden steps' },
            { label = 'Dock steps', model = 'meshes/x/ex_de_docks_steps_01.nif', lift = 78 },
            { label = 'Stone steps', model = 'meshes/x/ex_hlaalu_steps_03.nif', lift = 192, footprint = 220, cost = { ore = 6 } },
            { label = 'Tall stone steps', model = 'meshes/x/ex_hlaalu_steps_05.nif', lift = 320, footprint = 300, cost = { ore = 10 } },
        } }),
    -- lights and ornaments are bought: paid from the treasury, there at once
    furnishing({ key = 'candle', group = 'Lights', name = 'Candles', model = 'meshes/l/light_de_candle_07.nif',
        mount = 'surface', instant = true, price = 8, cost = {}, work = 0, lift = 17, desc = 'On a table, a shelf or the floor',
        props = { { light = 'light_de_candle_07_64', offset = { 0, 0, 0 } } },
        variants = {
            { label = 'Candle cluster' },
            { label = 'Tall candle', model = 'meshes/l/light_de_candle_18.nif', props = { { light = 'light_de_candle_18_64', offset = { 0, 0, 0 } } } },
            { label = 'Red candle', model = 'meshes/l/light_de_candle_red_01.nif', props = { { light = 'light_de_candle_red_01_64', offset = { 0, 0, 0 } } } },
        } }),
    furnishing({ key = 'sconce', group = 'Lights', name = 'Wall Sconce', model = 'meshes/l/light_com_sconce_01.nif',
        mount = 'wall', instant = true, price = 20, cost = {}, work = 0, lift = 0, depth = 6, desc = 'A lamp on the wall',
        props = { { light = 'light_com_sconce_01_77', offset = { 0, 0, 0 } } } }),
    furnishing({ key = 'rug', group = 'Decor', name = 'Rug', model = 'meshes/f/furn_rug_01.nif',
        mount = 'surface', flat = true, instant = true, price = 20, cost = {}, work = 0, lift = 1, desc = 'Underfoot',
        variants = {
            { label = 'Rug, red' }, { label = 'Rug, blue', model = 'meshes/f/furn_rug_02.nif' },
            { label = 'Rug, green', model = 'meshes/f/furn_rug_03.nif' }, { label = 'Rug, brown', model = 'meshes/f/furn_rug_04.nif' },
            { label = 'Large rug', model = 'meshes/f/furn_rug_big_01.nif', price = 40, lift = -2 },
            { label = 'Large rug, patterned', model = 'meshes/f/furn_rug_big_03.nif', price = 40, lift = -2 },
            { label = 'Large rug, runner', model = 'meshes/f/furn_rug_big_05.nif', price = 40, lift = 1 },
            { label = 'Large rug, dark', model = 'meshes/f/furn_rug_big_08.nif', price = 40, lift = -2 },
        } }),
    furnishing({ key = 'tapestry', group = 'Decor', name = 'Tapestry', model = 'meshes/f/furn_de_tapestry_01.nif',
        mount = 'wall', instant = true, price = 40, cost = {}, work = 0, lift = 96, depth = 4, desc = 'For a bare wall',
        variants = {
            { label = 'Dunmer tapestry' }, { label = 'Dunmer tapestry, blue', model = 'meshes/f/furn_de_tapestry_04.nif' },
            { label = 'Dunmer tapestry, gold', model = 'meshes/f/furn_de_tapestry_08.nif' },
            { label = 'Dunmer tapestry, dark', model = 'meshes/f/furn_de_tapestry_12.nif' },
            { label = 'Imperial tapestry', model = 'meshes/f/furn_com_tapestry_01.nif', lift = 90, depth = 3 },
            { label = 'Imperial tapestry, green', model = 'meshes/f/furn_com_tapestry_03.nif', lift = 90, depth = 3 },
        } }),
    furnishing({ key = 'crest', group = 'Decor', name = 'Coat of Arms', model = 'meshes/f/furn_com_coatofarms_01.nif',
        mount = 'wall', instant = true, price = 60, cost = {}, work = 0, lift = 0, depth = 3, scale = 2, desc = 'House colours',
        variants = { { label = 'Shield' }, { label = 'Crest', model = 'meshes/f/furn_com_coatofarms_02.nif' } } }),
    furnishing({ key = 'plant', group = 'Decor', name = 'Plant', model = 'meshes/f/furn_pottedplant.nif',
        mount = 'surface', instant = true, price = 15, cost = {}, work = 0, lift = 16, desc = 'A bit of green',
        variants = {
            { label = 'Potted plant' },
            { label = 'Small planter', model = 'meshes/f/furn_planter_01.nif', lift = 0 },
            { label = 'Planter', model = 'meshes/f/furn_planter_02.nif', lift = 0, price = 25 },
            { label = 'Large planter', model = 'meshes/f/furn_planter_03.nif', lift = 0, price = 35 },
            { label = 'Square planter', model = 'meshes/f/furn_com_planter.nif', lift = 17 },
        } }),
    furnishing({ key = 'urn', group = 'Decor', name = 'Urn', model = 'meshes/o/contain_urn_01.nif',
        mount = 'surface', instant = true, price = 25, cost = {}, work = 0, lift = 49, desc = 'Fine Dunmer pottery',
        variants = {
            { label = 'Urn' }, { label = 'Round urn', model = 'meshes/o/contain_urn_03.nif', lift = 42 },
            { label = 'Tall urn', model = 'meshes/o/contain_urn_05.nif', lift = 57 },
        } }),
    furnishing({ key = 'cushion', group = 'Decor', name = 'Cushion', model = 'meshes/f/furn_cushion_square_01.nif',
        mount = 'surface', flat = true, instant = true, price = 10, cost = {}, work = 0, lift = 0, desc = 'Somewhere soft to sit',
        interact = { label = 'Sitting on a cushion', hours = 0.5, slots = 1, weight = 1 },
        variants = { { label = 'Square cushion' }, { label = 'Round cushion', model = 'meshes/f/furn_cushion_round_01.nif' } } }),
    furnishing({ key = 'shrine', group = 'Decor', name = 'Shrine', model = 'meshes/f/furn_shrine_tribunal_01.nif',
        mount = 'surface', instant = true, price = 150, cost = {}, work = 0, lift = 11, desc = 'Settlers pray here',
        interact = { label = 'Praying at the shrine', hours = 0.5, slots = 1, weight = 2 },
        variants = { { label = 'Shrine of the Tribunal' }, { label = 'Shrine of Vivec', model = 'meshes/f/furn_shrine_vivec_01.nif' } } }),
    furnishing({ key = 'lectern', group = 'Decor', name = 'Lectern', model = 'meshes/f/furn_de_lecturn.nif',
        instant = true, price = 40, cost = {}, work = 0, lift = 58, desc = 'Settlers read here',
        interact = { label = 'Reading at the lectern', hours = 0.75, slots = 1, weight = 2, prop = 'book' } }),
    furnishing({ key = 'loom', group = 'Decor', name = 'Loom', model = 'meshes/f/furn_de_loom_01.nif',
        instant = true, price = 50, cost = {}, work = 0, lift = 52, desc = 'Settlers weave here',
        interact = { label = 'Weaving', hours = 1, slots = 1, weight = 2 },
        variants = { { label = 'Loom' }, { label = 'Spinning wheel', model = 'meshes/f/furn_spinningwheel_01.nif', lift = 21,
            interact = { label = 'Spinning yarn', hours = 1, slots = 1, weight = 2 } } } }),
    furnishing({ key = 'dummy', group = 'Decor', name = 'Practice Dummy', model = 'meshes/f/furn_practice_dummy.nif',
        instant = true, price = 25, cost = {}, work = 0, lift = 95, desc = 'Settlers train here',
        interact = { label = 'Practising with a sword', hours = 0.5, slots = 1, weight = 1 } }),
    furnishing({ key = 'stores', group = 'Decor', name = 'Stores', model = 'meshes/f/furn_de_winerack_01.nif',
        instant = true, price = 30, cost = {}, work = 0, lift = 78, desc = 'Racks and barrels',
        variants = {
            { label = 'Wine rack' }, { label = 'Keg stand', model = 'meshes/f/furn_de_kegstand.nif', lift = 63 },
            { label = 'Cauldron', model = 'meshes/f/furn_com_cauldron_01.nif', lift = 44, price = 20 },
            { label = 'Basket', model = 'meshes/f/furn_basket_01.nif', lift = 8, price = 10 },
            { label = 'Screen', model = 'meshes/f/furn_wallscreen_01.nif', lift = 82 },
        } }),
    -- comes with the colony; can be moved by removing it and building another
    furnishing({ key = 'board', group = 'Structures', name = 'Colony Board', model = 'meshes/f/furn_de_banner_book_01.nif',
        scale = 2, lift = 175, cost = { wood = 4 }, work = 4, opensLedger = true, desc = 'Look at it up close for a colony summary',
        props = { { decor = 'boardPost', offset = { -88, 0, 130 } }, { decor = 'boardPost', offset = { 88, 0, 130 } } } }),
}

-- Held in the hand during an interaction (like carried goods).
defs.furnishGroups = { 'Furniture', 'Lights', 'Decor', 'Structures' }

defs.propModels = {
    book = 'meshes/m/text_octavo_01.nif',
    cup = 'meshes/m/misc_de_goblet_01.nif',
}

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
    food = 'meshes/m/misc_com_wood_bowl_01.nif',
}
defs.carryBone = 'Bip01 L Hand'
-- Sleepers lie this far turned from a bed's own direction: the knockout
-- pose runs along the actor's forward axis, beds along their local x axis.
defs.sleepYaw = math.pi / 2

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
        Trader = { Robe = { template = 'expensive_robe_01', name = "Trader's Robe" } },
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
    wickwheat = 'meshes/o/flora_wickwheat_02.nif',
    marshmerrow = 'meshes/o/flora_marshmerrow_02.nif',
    ashyam = 'meshes/o/flora_ash_yam_02.nif',
    hacklelo = 'meshes/o/flora_hackle-lo_02.nif',
    kwamaegg = 'meshes/o/contain_egg_kwama00.nif',
    fence = 'meshes/x/furn_com_fence_01.nif',
    piling = 'meshes/x/ex_de_docks_piling.nif',
    log = 'meshes/f/furn_log_01.nif',             -- 54 long; used at double size
    orepile = 'meshes/f/furn_coalpile00.nif',
    metal = 'meshes/n/ingred_scrap_metal_01.nif',
    crate = 'meshes/o/contain_crate_01.nif',
    coals = 'meshes/f/furn_de_firepit_01.nif',
    lampArm = 'meshes/x/furn_de_lightpost_01.nif',
    tentLining = 'meshes/tomorrowind/tent_lining.nif',
    tentLargeLining = 'meshes/tomorrowind/tent_large_lining.nif',
    boardPost = 'meshes/x/furn_com_fence_03.nif',
    cart = 'meshes/f/furn_guarcart00.nif',
    bookA = 'meshes/m/text_octavo_01.nif',
    bookB = 'meshes/m/text_quarto_01.nif',
    bookC = 'meshes/m/text_folio_01.nif',
}
defs.smallConstructionModel = 'meshes/f/furn_crate_open_01.nif' -- stands in while a furnishing is being made
defs.smallConstructionLift = 29

-- Materials delivered to a construction site are stacked next to it and
-- used up as the building goes up. `per` units per object, at most `max`.
-- Rooms of different houses are this far apart inside the interior cell.
defs.roomSpacing = 15000

-- Who you find in a house when you're inside, by the chance per game hour.
defs.rooms = { visitChance = 0.35, loungeChance = 0.12, maxPeople = 6 }

defs.piles = {
    wood = { model = 'log', per = 2, max = 30, layout = 'logs' },
    ore = { model = 'orepile', per = 3, max = 6, layout = 'heaps' },
    ingot = { model = 'metal', per = 1, max = 12, layout = 'plates' },
    food = { model = 'crate', per = 5, max = 4, layout = 'heaps' },
}

return defs
