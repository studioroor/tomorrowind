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
| Activate a settler | Open their row in the ledger (job, status, Talk) |
| Activate a building | Open the overview with that building |
| **Z / X** | Rotate a building while placing |
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
| Woodcutter's Camp | free | 3 woodcutters → Timber |
| Saltrice Paddy | 6 Timber | 3 farmers → Saltrice (food) |
| Ore Vein | 10 Timber | 3 miners → Raw Ore |
| Smelter | 10 Timber, 6 Ore | 2 smelters turn 2 Ore → 1 Iron Ingot |
| Hlaalu House | 20 Timber, 4 Ingots | +4 beds |
| Storehouse | (founding) | stockpile, 4 beds |

- Settlers eat Saltrice from the storehouse every few game hours. If they get
  hungry they work at half speed, and if they're starving they stop working.
- When beds are free and there is food to spare, newcomers arrive about once
  per game hour.
- Work continues while you're away or resting. Off-screen settlers are
  simulated at the same rates.

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
  global.lua        connects the core to the world: spawns settlers and
                    buildings, sends each settler its next step, save/load
  worker.lua        on each settler: walk (navmesh + stuck recovery),
                    swing tools, wait, wander; reports when a step is done
  player.lua        ledger UI and freeform placement (raycast, slope,
                    overlap and reachability checks)
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

## Tests

```sh
luajit tests/run.lua              # simulation core
tools/playtest.sh /tmp/tmw-run    # scripted in-game run (sandboxed config)
```
