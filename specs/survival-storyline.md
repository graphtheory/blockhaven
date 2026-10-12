# The Sleeping Garden

Blockhaven's survival storyline: a home, a signal, a rocket, and a garden on
the Moon that has been waiting for someone to bring it a seed.

Status: implemented — all six slices below are in the game. `Game/Story.swift`
holds the state and KEEPER's lines, `World/StoryBuilder.swift` builds the
places, `Game/StoryDirector.swift` runs it, and `BLOCKHAVEN_CHECK_STORY=1`
plays it from the first radio to the last seed.

## The story in six pictures

1. **A light on the Moon.** From the first night, one point on the Moon blinks.
   Three short, one long. Nobody tells you what it is.
2. **The station.** Within a short walk of spawn is a small ruined building
   with a broken radio and a map of the Moon on the wall. The radio blinks in
   the same rhythm. Fix it and it says: `GROUND LINK LOST. NURSERY DORMANT.`
3. **The three pieces.** The radio can hear three other old machines in the
   world: one on a spire, one in a vault, one in a wreck. Each holds a part
   of how people once got to the Moon. Get all three and you can build a
   rocket.
4. **The launch.** You build the pad, you build the rocket, you fill the
   crate, you press the button. The world drops away. The Moon fills the
   window.
5. **The garden.** Low gravity, no air, a cabin you can breathe in. The light
   you saw from home is the beacon of a buried greenhouse, and a voice called
   KEEPER has been blinking it for a very long time. It needs three things:
   light, water, and one living plant.
6. **Home.** When the garden wakes, it gives you a seed that grows nowhere
   else. You take it home and plant it by your door. From then on, the light
   on the Moon shines steady instead of blinking — and from the Moon, a small
   light shines back from your home world.

Nothing counts down. Nothing burns your house while you are away. The danger
is the night, the Moon, and your own planning.

## Rules

1. **Building is the progression.** A sealed room, a wired lamp, a watered
   field, and a launch pad are the story beats. There are no quest items that
   do nothing but unlock the next quest.
2. **Reuse the game.** Every lunar problem is answered by a mechanic the game
   already has, with at most a new block or a new constant in front of it.
   If a chapter needs a new system, the chapter is wrong.
3. **The way home is never lost.** Death, a broken rocket, a dismantled cabin,
   a quit mid-flight: all of them leave the player somewhere safe with a
   known way back. Cargo can be left behind; the player cannot.
4. **Every lead is visible.** The blinking Moon, a lit spire on a ridge, a
   radio that points. Nothing hides behind a random drop or a wiki.
5. **The sandbox wins ties.** A player who ignores the story for a week of
   building loses nothing. A player who tunnels around a puzzle has solved it.

## Backstory (what KEEPER knows, told in short lines)

The Gardeners kept a chain of ground stations and one greenhouse under the
Moon's surface, where they stored seeds of plants that no longer grow wild.
A solar storm burned out the lunar power grid. They sealed the seed vault,
went home, and meant to come back. They didn't. The vault held; the
greenhouse around it died. KEEPER, the greenhouse's caretaker machine, has
kept the beacon blinking ever since, asking anyone to bring light, water,
and something alive.

The player has no backstory. They are someone who lives here. KEEPER never
says who the Gardeners were or where they went; that is a sequel's mystery,
and this arc ends whole without it.

KEEPER speaks in lines of at most a dozen words, in capitals, through the
radio and the garden's panels. It is patient, slightly literal, and glad.
Every line ships in English and Swedish (`L10n.t`).

## Chapters

### 1. A home

**Goal:** be able to leave and come back.

The player does what survival already asks: shelter, torches, tools, a bed,
food, a chest. Nothing is checked. A cave, a tent, a tower all count.

The **survey station** is a new guaranteed landmark: a small roofless stone
room, placed on the ruin lattice but forced to exist within a few hundred
blocks of spawn (the compass can point to it once it is seen). Inside: a
**radio** block, blinking; a wall of `sandstoneCarved` arranged as a Moon
map with a mark on it; a chest with a compass and a note.

The radio is repaired by placing a `glowCrystal` beside it. Then it speaks.

**Done when:** the radio has spoken. **Gives:** the radio now points — like
the compass — at the nearest of the three machines in chapter 2.

New: one landmark, one block (`radio`, three states: dark, blinking, lit),
one HUD line for KEEPER's text, a blinking dot on the Moon in `SkyController`.

### 2. The three pieces

**Goal:** collect navigation, cabin, and engine, in any order.

| Piece | Where | What it costs today | What you learn |
|---|---|---|---|
| Navigation | the top of a **spire** | the climb; the beacon is already visible for miles | "THE MOON IS 1 LIGHT-SECOND AWAY. AIM FOR THE BLINK." |
| Cabin | inside a **vault** | a diamond pickaxe to open obsidian | "AIR STAYS IN A ROOM WITH NO HOLES." |
| Engine | inside a **wreck** | the air timer, or buckets and patience | "ICE IS FUEL. SO IS SUNLIGHT." |

Each site gets a story variant: the same generator, plus a `radio` block in
it and a `plaque` with one line. Picking up the radio's **core** (an item)
records the piece permanently — the journal, not the item, is the progress.
The three sites already exist and already cost the right things; the arc
only has to make one of each reachable and marked. If a site is unreachable
(no ocean deep enough, no mountain tall enough), the station's radio names a
fallback from the next region out.

**Done when:** three cores recorded. **Gives:** recipes for the launch pad,
the rocket, the suit, and the Moon kit (air maker, grow lamp).

New: a `plaque` block (one line, readable by looking at it), a `core` item, a
journal page in the pause menu listing the three pieces, radio bearings.

### 3. The rocket

**Goal:** stand on the Moon.

A **launch pad** is a 5×5 of any solid block with a `padCore` in the centre.
The **rocket** is placed on it as one shaped multi-block (cabin, tank, three
legs; the same trick `ShapedBlocks` uses for beds and doors, taller). It is
built from iron, glass, and `meteorIron`, a new ore that exists only near the
three sites so the trip to each is also the mining trip.

Fuel is `ice` (there is ice in every snowy biome and on every mountain top
once thermal freezing exists) smelted in a furnace into a `fuelCell`. One
cell out, one cell back; the return cell is loaded before launch and cannot
be taken out again on the Moon.

Looking at the rocket shows a checklist, item by item: rocket complete, suit
worn, two cells, a crate with soil, wheat seeds, and a Moon kit. Anything
missing is named. Press to launch; a short skippable sequence; the lunar
world loads with the rocket standing on a pad.

**Done when:** standing on the Moon. **Gives:** a second world in the same
save, and a rocket that goes both ways.

New: `padCore`, the rocket shape, `meteorIron`, `fuelCell`, the checklist
panel, a second `World` inside one save folder with shared inventory and
journal, a launch/land transition.

### 4. A second home

**Goal:** one room you can take your helmet off in.

The Moon's surface drains the existing `air` stat the way water does; the
suit (a chestplate-slot item) multiplies `maxAir` by six. Inside the
rocket's cabin, air refills. The first thing the player sees from the pad:
ice glinting in a shadowed crater, the mouth of a lava-tube, and on the far
rim, the blink.

A **breathable room** is an enclosed volume (flood-fill from an **air
maker**, stop at solids and glass, give up past 256 cells) whose air maker is
powered. Power is the signal network: a `daylightSensor` on the roof wired
to the air maker is a solar panel. At lunar night the sensor goes dark; a
signal torch holds the latch, or the player builds a bigger room. Looking at
an air maker shows SEALED / LEAK / NO POWER. A room that fails gives the
player thirty seconds before the suit takes over.

Regolith (new block: `moonDust`, drops as itself, smelts into `moonBrick`)
is the free building material. Gravity is a constant in `PlayerController`
set per world; falls hurt by landing speed, not by blocks fallen.

**Done when:** standing in a sealed, powered room with the suit off. The
bed in that room is the lunar spawn. **Gives:** longer trips, local brick,
and KEEPER's panel at the garden door, which lists its three faults.

New: `air` drain outdoors, suit item, `airMaker` block with a sealed-volume
check, `moonDust`/`moonBrick`, gravity per world, one HUD readout for air
and seal state.

### 5. Wake the garden

**Goal:** fix three things, in any order, with what the game already does.

| Fault | Fix | Mechanic that already exists |
|---|---|---|
| NO LIGHT | Find the collector on the ridge (a buried bank of daylight sensors), dig it out, run wire down into the garden's lamp terminal. | `daylightSensor` → `wire` → `signalLamp`. Plain wire has a reach limit; the relay extends it. |
| NO WATER | Fill the reservoir. Buckets of melted ice, or stack ice in the channel next to a lit lamp and let thermal do it. | `bucket`, `ice`, `ThermalQuery` thaw. Water in the open on the Moon freezes; water under a roof does not. |
| NOTHING GROWS | Seal the nursery hall, power it, till a bed, plant the wheat you brought, and get one stalk to full height. | farmland, hydration, crops under light ≥ 9 in darkness — subterranean farming works today. |

Each fix is visibly permanent: a dark hall lights, a dry channel fills, a
bed turns green. Each is recorded in the journal when it first succeeds, so
breaking it later is the player's problem, not the story's.

One hostile: the **sentry**, a lunar maintenance machine that treats powered
blocks as faults and shoots at whoever stands near them. It is a skeleton
with a different skin and a different trigger: it does not spawn in the dark,
it spawns near wire. Walls block it like anything else; so does switching
the wire off. It never enters a sealed room and never breaks blocks.

**Done when:** three faults cleared. **Gives:** the inner door opens.

New: the garden landmark itself (the biggest piece of content in the arc: a
lunar `Landmarks` extension), the sentry skin and spawn rule, lunar freezing
rule, three journal entries. No new mechanics.

### 6. Answer the signal

**Goal:** bring one plant home.

Behind the inner door is the seed vault and a lever. Pulling it runs a short
sequence: lamps come on hall by hall, water runs, and the shutters over the
crater roof open on the home world hanging in the sky. If a fault returns
mid-sequence the sequence pauses on that fault and says so; nothing resets.

KEEPER: `NURSERY ACTIVE. TAKE ONE. GROW IT WHERE YOU LIVE.`

The vault gives two seeds. **Lamp bloom** grows into a plant that emits
light (a crop that ends as a `glowCrystal`-strength emitter) and seeds
itself. **Silver reed** grows tall and harvests into a block with a new
finish. Either one planted and grown to full height on the home world ends
the story. The radio at the survey station lights steady. The Moon's blink
becomes a steady point. From the Moon, a point appears on the home world.

Play continues in both worlds. The rocket keeps flying on one cell each way.

New: the lever sequence, two crops, the steady-light sky change, a
completion entry in the journal.

## The Moon

One lunar region, hand-shaped around four places, with ordinary generated
terrain past it. Nothing required is further than a two-tank walk from the
pad.

| Place | Looks like | The decision it poses |
|---|---|---|
| Landing crater | Pale dust, long shadows, the home world overhead. | Build here or carry everything to the garden door. |
| Cold shelf | Shadowed crater floor with exposed ice. | Haul ice, or wire a lamp beside it and melt it in place. |
| Glass ridge | Dark rock, sharp bright `prismGlass` seams, the collector on top. | Walk the exposed rim or tunnel up through the ridge. |
| The garden | A lit beacon, a buried dome, dark halls, sealed seed chambers. | Which fault first, and where the nursery goes. |

Rules, each a constant or a reuse:

- Gravity 40%: jump higher, fall slower, land hard from high.
- No air outside: `air` drains as underwater; suit ×6; refills in any sealed
  room or the rocket cabin. Warnings at half and a quarter; the HUD points
  at the nearest refill.
- Cold: exposed water freezes (the snowy-biome thermal rule, everywhere).
  Crops need a sealed room. Lava tubes are warm.
- Light: the lunar day is long and bright, the night is long and black.
  Sentries hunt near wire; fizzlers and skeletons do not exist here.
- Weather: none. No storms, no rain, no exposure meter.

## Everything new, in one list

| Thing | Kind | Built from |
|---|---|---|
| survey station | landmark | ruin generator + fixed near-spawn placement |
| radio, plaque | blocks | signal lamp (states) + a looked-at text line |
| core | item | — |
| journal page | UI | pause menu panel, like the recipe book |
| meteorIron, fuelCell | ore + item | iron ore rules; furnace recipe |
| padCore, rocket | block + shape | `ShapedBlocks` |
| launch / land | transition | second `World` in the save; shared inventory |
| suit | armor item | chestplate slot; multiplies `maxAir` |
| airMaker | block | signal consumer + bounded flood-fill |
| moonDust, moonBrick, prismGlass | blocks | dirt/brick/glass rules |
| lunar world | generator | flat-ish noise, craters, one hand-placed region |
| the garden | landmark | `Landmarks` helpers (box, disc, dome) |
| sentry | mob | skeleton AI, new skin, spawn near wire |
| lamp bloom, silver reed | crops | wheat stages; one ends as an emitter |
| sky changes | rendering | a dot on the Moon; a dot on the home world |

Nothing on this list is a new simulation. The second world and the sealed
room check are the two pieces of real engineering; everything else is
content.

## Build order

Each slice ends with something playable and is meant to fit in a
burst of a few sessions. Ship each one before starting the next.

1. **The blink.** A blinking dot on the Moon and the survey station with a
   radio that speaks when fixed. No new mechanics. Pays off the moment it is
   in: a mystery in a world that had none.
2. **Three pieces.** Story variants of spire, vault, wreck; cores; the
   journal page; the radio pointing. All existing landmarks.
3. **The rocket.** Pad, rocket, fuel, checklist, and the second world —
   even if the Moon is a flat grey plain with no air rules yet. Standing on
   the Moon and flying back is the milestone.
4. **Air.** Suit, drain, air maker, sealed-room check, gravity. The Moon
   becomes dangerous and the cabin becomes precious.
5. **The garden.** The landmark, the three faults, the sentry.
6. **Home.** The lever, two seeds, the steady light. Credits line.

Slices 1–2 touch nothing the Moon needs. If the Moon never ships, the home
world still has a radio, three marked ruins, and a reason to climb a spire.

## Saves and modes

Old worlds keep their terrain; the survey station appears in unexplored
chunks, and a world already built out around spawn can craft a radio to
pick up the thread. Creative mode has the rocket, the suit, and both seeds
in the palette and no checklist.

A save holds two worlds and one player. Inventory, journal, and the suit
travel; chests, devices, and beds stay with their world. Quitting mid-flight
resumes at the destination with the fuel cell already spent.

## Not in this arc

More planets. Multiplayer. Free-form flying machines. Orbital mechanics.
Villagers. A boss. A countdown. Anything that destroys what the player built
while they were not there.
