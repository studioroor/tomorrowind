# Tomorrowind

An OpenMW (**0.52+**) mod about founding and running a House Hlaalu colony:
assign settlers to jobs, mine, farm, smelt, haul and build, and place
buildings anywhere you like.

This is the **core-mechanics prototype**. There is no island or quest yet.
You found the colony wherever you're standing.

## Install

1. In the OpenMW launcher, open **Data Files → Directories** and add this
   folder (`tomorrowind/`).
2. Enable `Tomorrowind.omwscripts` in the content list.

There is no `.esp`: tools, buildings and settlers are created as records at
runtime (OpenMW 0.52 Lua). Every settler is a unique Dunmer with their own
name and face.

## Playing

| Key | |
|---|---|
| **K** | Open / close the Colony Ledger |
| Activate a settler | Talk to them |
| Activate a building | Open the overview with that building |
| Look at a settler | See what they're doing; **K** opens their row in the ledger |
| **Delete** | Remove the furnishing you're looking at |
| **Z / X** | Rotate while placing; a wall or fence that has snapped on bends around the joint |
| **Left / Right** | Next or previous model while placing (houses, tents, chairs, chests...) |
| **Up / Down** | Raise or lower while placing |
| **Enter** | Place the building |
| **Backspace** | Cancel placement |

1. Stand somewhere outdoors and flat, press **K**, then **Found a colony here**.
   A storehouse appears and three settlers walk in.
2. **Build** tab → **Place** → aim at the ground → **Enter**. A
   construction site appears. Unassigned settlers (*laborers*) and *builders*
   haul the materials from the storehouse, then build it.
3. **Workers** tab → use **< >** to give settlers jobs at finished
   buildings.

### The economy

| Building | Cost | Does |
|---|---|---|
| Woodcutter's Camp | free | 3 woodcutters, each about 75 Timber a day |
| Saltrice Paddy | 10 Timber | 3 farmers, each about 60 Saltrice a day (feeds about 6) |
| Ore Vein | 16 Timber | 3 miners, each about 70 Raw Ore a day |
| Smelter | 20 Timber, 8 Ore | 2 smelters, each about 25 Iron Ingots a day from 50 Ore |
| Warehouse | 30 Timber | stores 150 more of everything |
| Hlaalu House | 40 Timber, 8 Ingots | +4 beds |
| Storehouse | (founding) | stores 150 of everything, 4 beds |

These are for a building about 800 units from the storehouse: walking takes up
part of the day, so layout matters. `tests/test_economy.lua` checks this balance.

- **Storage is limited.** With no room, production stops until the stock is used
  or there is a warehouse.
- **Newcomers** arrive every 2 game hours, plus 15 minutes per settler, if there
  is a free bed and enough food: 10, plus 3 per settler.
- Settlers eat 2 Saltrice from the storehouse every few game hours. If they get
  hungry they work at half speed, and if they're starving they stop working.
- **Gathering on demand.** If a construction site needs something the
  storehouse doesn't have, idle laborers and builders go and make it at the
  right building and carry it straight to the site. That works up the chain
  too: if ingots are short and so is ore, they mine ore first. If the colony
  has no building that makes it, the site says so ("needs a Woodcutter's Camp").
- **Construction progress** (materials delivered, leveling and build %)
  shows in the ledger and over the building site you're looking at. You can
  also see it on site: delivered materials are stacked beside the scaffold
  (logs, ore heaps, metal plates) and get used up, on slopes the pilings go in
  one by one, and then the building itself comes up out of the ground, growing
  from 80% to full size.
- **Crews.** Buildings and furnishings take a limited number of settlers at
  once (`maxBuilders`): 2 for a chair, 4 for a tent, no limit for a house.
- **The Colony Board** stands by the storehouse. Look at it up close for a
  summary of stock, what's being built and what everyone is doing. Activate it
  for the ledger.
- **Work has sound.** Each tool strike plays a sound for that kind of work:
  a thunk on wood, a clang on ore, the anvil at the smelter, a soft thud in
  the paddy. They are set per building in `defs.lua` (`sound = ...`).
- **The smelter's fire** burns, with its crackle, only while someone is
  working the forge.
- Settlers visibly **carry** what they're hauling (planks, ore, scrap metal,
  wheat), and wear a **uniform**: the Hlaalu colony shirt for everyone, plus
  a hard hat for miners, a fur cap for woodcutters, a coif for smelters, a
  smock for farmers, a cap for builders and chitin for guards.
- Work continues while you're away or resting. Off-screen settlers are
  simulated at the same rates, during their working hours, and you get a
  summary when you come back.

### The day

| Hours | |
|---|---|
| 07 to 18 | Work |
| 18 to 22, 06 to 07 | Free time: meals and whatever the colony has to offer |
| 22 to 06 | Sleep: on a bed or bedroll if there's one free, otherwise out of sight inside a house or the storehouse |

Everyone keeps their own hours around these: early birds and night owls, some
hungrier than others. Guards keep watch around the clock, prisoners are locked
up outside working hours, and an alarm wakes everybody. Hunger grows slower
overnight. Change the hours in `defs.schedule`.

With no construction to do, laborers and builders lend a hand at a production
site with room left, tidy up, take a stroll, chat with each other or go inside
for a while (`defs.downtime`). Now and then they say something when they start
on a task (`defs.utter`), shown as a bubble over their head with a vanilla
Dunmer sigh or grumble; chatting settlers use vanilla greetings.

**Look at a settler** to see their name, job, what they're doing and how fed
they are.

### Furnishings

The **Furnish** tab of the ledger has the small things that make a colony a
home: campfires, lamp posts, paper lanterns, chairs, benches, tables,
bookshelves, chests, bedrolls, beds, tents, fences, stone walls and gates.
Laborers and builders make them like anything else, and removing one (look at
it and press **Delete**) gives its materials back.

- **In their free time** settlers use them: they eat and rest by the campfire,
  read a book at the bookshelf, have a drink at the table and take breaks on
  chairs and benches, with what they're using in hand. Each has room for so
  many at a time.
- **Beds and bedrolls** add a bed each, and settlers visibly sleep on them.
- **Tents** can be walked into, and you can place furniture inside.
- **Chests** are real containers. Removing one hands you what's in it.
- **Fences, walls and gates** snap together end to end, and bend around the
  joint with Z and X, keeping the bend for the next piece: walls can curve. Routes go around stone
  walls and through gates, but they don't see fences: settlers who walk into
  one climb over after a few seconds.

### Defense

| Building | Cost | Does |
|---|---|---|
| Guard Post | 15 Timber, 4 Ingots | 2 guard jobs; guards get a sword, chitin armour and training |
| Stockade | 40 Timber, 6 Ingots | holds 4 prisoners |

- When a settler (or you, near the colony) is attacked, the alarm goes up:
  settlers run for the storehouse, guards fight the nearest attacker.
- With room in the stockade, attacking NPCs are **taken alive**: blows that
  would take them below 40% health knock them out instead. They wake up as
  prisoners, without their weapons, locked up in the stockade.
- Put prisoners to **forced labour** in the Ore Vein or Woodcutter's Camp
  from the Workers tab. They don't need beds.
- Creatures, and attackers when the stockade is full, are fought to the death.

### Building on slopes

OpenMW can't change terrain at runtime, so slopes are *leveled* instead:
the building sits level, sunk into the uphill side, and timber pilings
hold up the downhill side. The steeper the spot, the more **foundation
timber** and **leveling work** it needs (shown while placing). Sites show
*Leveling the ground* before *Under construction*. Only ground that would
bury too much of the building is refused (taller buildings may sink deeper).

## How it works

```
scripts/tomorrowind/
  defs.lua          buildings, resources, timings (tune the game here)
  core/colony.lua   pure-Lua simulation: task planner, reservations,
                    hauling, construction, hunger, arrivals, off-screen sim
  core/terrain.lua  slope analysis: floor level, foundation cost
  records.lua       runtime records: tools, buildings, unique settlers
  captive.lua       on attackers: turns lethal blows into a knockout
  global.lua        connects the core to the world: spawns settlers and
                    buildings, sends each settler its next step, save/load
  worker.lua        on each settler: walk (navmesh + stuck recovery),
                    swing tools, wait, wander, sleep; reports when a step is done
  player.lua        ledger UI, freeform placement (raycast, slope, overlap
                    and reachability checks), hover info
```

- **Task planning.** When a settler is free, the planner picks the most useful
  thing to do: eat if hungry, then their job, otherwise haul materials or build.
  A task is a list of steps (`goto`, `work`, `take`, `store`, `supply`,
  `eat`, `idle`). Effects such as stock changes and building progress happen
  only when a step finishes.
- **Reservations.** Materials are reserved when a task is planned, so two
  haulers never go for the same timber and sites are never over-supplied.
  Cancelling (reassigning, demolishing, reloading) releases everything.
- **Tool swings** reuse the one-handed *chop* attack, played in two halves
  that skip the animation's `Chop Hit` key. A swing can never damage anyone.

## Ideas and bugs

Got an idea or found a bug? [Open an issue](https://github.com/studioroor/tomorrowind/issues).

## Licence

Copyright (C) 2026 Drikus Roor. The code is free software under the GNU General
Public License, version 3: see [LICENSE](LICENSE).

The meshes in `meshes/tomorrowind/` are not covered by that licence. They are
modified copies of meshes from *The Elder Scrolls III: Morrowind* by Bethesda
Softworks, included as a mod for owners of the game. You need your own copy of
Morrowind to play.

## Tests

```sh
luajit tests/run.lua              # simulation core
tools/playtest.sh .playtest/run   # scripted in-game run (sandboxed config)

# other scenes, same harness
TEST_CONTENT=visuals.omwscripts  tools/playtest.sh .playtest/vis   # views for screenshots
TEST_CONTENT=saveload.omwscripts tools/playtest.sh .playtest/sl    # save, reload, compare
TEST_CONTENT=day.omwscripts      tools/playtest.sh .playtest/day   # a day with furnishings (engine screenshots)
TEST_CONTENT=life.omwscripts     tools/playtest.sh .playtest/life  # board, rising, downtime, leaving, door traffic
TEST_CONTENT=fit.omwscripts      tools/playtest.sh .playtest/fit   # bending walls, height, models, talking, rising
TEST_CONTENT=photo.omwscripts    tools/playtest.sh .playtest/photo # bare shelf heights, side-on building photos
TEST_CONTENT=measure.omwscripts  tools/playtest.sh .playtest/size  # log sizes of vanilla models
TEST_CONTENT=tent.omwscripts     tools/playtest.sh .playtest/tent  # doorway rays, tent floor height, views
TEST_CONTENT=gallery.omwscripts  tools/playtest.sh .playtest/gal   # look at vanilla models
TEST_CONTENT=probe.omwscripts    tools/playtest.sh .playtest/probe # measure model sizes
```

The trailer is made here too: `tools/film_trailer.sh .playtest/take` films it
with scripted cameras (the engine saves every frame, no screen recording), and
`tools/make_trailer.py .playtest/take trailer/` cuts it, adding captions in
MysticCards (OpenMW's Morrowind-style font) and sound (needs ffmpeg, Pillow and
numpy; `--music file` replaces the generated music).

`meshes/tomorrowind/` holds the tent, made from the game's own Ashlander tent
by `tools/make_tent_meshes.py` (see the script for what it changes and why).

Runs are silent: the sandbox sets the master volume to 0.
