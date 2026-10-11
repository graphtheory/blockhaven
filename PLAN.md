# Finishing plan

Written 2026-08-23 after the RealityKit port; updated 2026-08-24 after the
plan was executed. Everything below was verified against the code and,
where the display allowed, against the running game.

## Done (2026-08-24)

**Phase 1 — frustration.** An app menu exists, so ⌘Q quits. Esc opens a
pause screen (Resume / mouse sensitivity / Quit) that freezes the world
and the clock. Fullscreen is a borderless window with
`hideMenuBar`/`hideDock`, so the menu bar no longer reveals on hover;
`BLOCKHAVEN_WINDOWED=1` keeps a titled window. The inventory shows a
"You can make" panel driven by `RecipeBook.craftable`, and a one-time HUD
hint names `E` and the crafting table.

**Phase 2 — combat.** Fizzlers have health, take sword-tier damage with
knockback and a red hurt flash, and die (taking a mid-fuse explosion with
them, after a 0.35s dying window so the kill reads). `Mobs/MobRaycast`
lets left click hit mobs before blocks, on a 0.4s swing cooldown; hitting
a mob doesn't mine the block behind it. Kills drop gunpowder in survival.
A diamond sword exists and crafts.

**Animals** (added by request, not in the original plan). Pigs, cows and
sheep: procedural skins, box-model entities with a walk bob, calm
wander AI with a flee burst when hurt, spawning in both modes near the
player. They share the combat path and drop porkchop/beef/mutton/wool;
food is eaten with right click and feeds hunger (survival only).

**Phase 3 — persistence.** The edit journal records every `setBlock` and
replays after generation and decoration, so player builds survive chunk
unload — the vanishing-builds bug is fixed. A versioned JSON save (~1 KB:
seed + journal diff + player/inventory/stats/time) writes atomically to
`~/Library/Application Support/Blockhaven/` every 30s of play, on
pause, and once on quit by any path; corrupt files load as nil. The start
menu gains Continue. Mobs respawn rather than persist.
`BLOCKHAVEN_NO_SAVE=1` disables both directions for test runs.

**Phase 4 — shaders, mostly.** Enabling the fog shader exposed that it
had never drawn a correct pixel (see README's shader section for the two
bugs); both fixed, and it now ships on by default with distance fog plus
animated water. A square sun and moon ride the day/night arc and a
filtered cloud dome drifts overhead. The snapshot harness reports
honestly now — its off-screen window was never scheduled for rendering;
it sits on-screen but unobtrusive and produces reproducible PNGs
(pig, cow, sheep and fizzlers included).

**Phase 5 — smooth ambient occlusion, and a mesher that keeps up.**
Chunks are `LowLevelMesh` now, carrying a per-vertex colour: each corner's
occlusion relative to its face's average, multiplied back in by
`blockSurface`, so inside corners darken smoothly instead of a block at a
time. The atlas still supplies the face average, which is what leaves the
shaderless fallback looking exactly as it did. The mesher flattens the
3×3 chunk neighbourhood into one padded byte volume first, which took a
chunk from 3.9 ms to 0.42 ms and took the visible stutter out of the
first second of a new world.

**Phase 6 — performance, where the child actually plays.** Measured first:
fullscreen at native 3440×1440 was already holding 97–100 fps on a 100 Hz
display, the same as a 1280×800 window, so **no render-scale control was
added** — there was no frame being missed to win back. What the frame rate
could not show is where the CPU went, so two honest instruments went in:
a per-phase breakdown in the frame log (worst frame, plus ms per second in
`stream`/`gather`/`mesh`/`upload`/`mobs`/`sky`/`hud`) and
`BLOCKHAVEN_BENCH_STREAM`, which runs the streaming loop headless and
reports ms *per frame*, independent of the refresh rate.

Then five fixes. Chunk geometry moved to a background queue, leaving the
loop only the neighbourhood copy and the RealityKit upload — with a
per-chunk `revision` so a build that was in flight when the player broke a
block is discarded rather than drawn over the fresh one, and with player
edits meshed synchronously so a broken block still vanishes on the click.
Tree placement moved onto the generation queue. `chunksReadyToMesh` stopped
rescanning all ~240 loaded chunks (and allocating a neighbour array per
chunk) every frame in favour of a maintained dirty set. And the sky stopped
asking `ARView.cameraTransform` for a position the game already knew and
stopped blending `NSColor`s through ColorSync on every frame for values
read a few times a second. Finally the chunk generation queue dropped from
`.userInitiated` to `.utility`: concurrent and eight wide, it had been
putting eight high-priority threads against the one with a frame deadline.

Streaming now costs the loop 0.035 ms a frame against 0.30 ms before, worst
on-loop frame 0.25–1.0 ms against 8.7–11.2 ms, and generation got *further*
ahead for the QoS drop rather than behind (231 chunks meshed over 900
frames instead of 226). Meshing was confirmed *not* to be what limits
terrain arrival — the budget of 2 chunks a frame clears eight times the
rate chunks generate at — so it was left alone. Nothing about the picture
moved: against the parent commit at t=0.5 the unlit fallback is
byte-identical and the shader path differs in 74 of 1,600,000 pixels, all
by exactly 1/255.

**Buried-face culling (2026-08-25).** Three quarters of every frame's
geometry was cave wall. `ChunkMesher` now classifies each opaque face as
surface or buried — surface being air that is sky-open, or connected to
sky-open air within twelve blocks of the chunk — and a chunk builds only
its surface half until an edit, the player's eye going underground, or the
targeting raycast asks to see inside it. Radius 7 spawn capture: 1,737,216
vertices to 484,928. Ten test cameras render byte-identically to the
pre-split binary; the eleventh has its eye in a cave and matches once its
buried half is built. See README's "Most of the world is never drawn" for
why the flood has no step limit and why the padding is twelve.

**Render distance (2026-08-25).** The headroom above got spent: 7 chunks to
**10**, a 112-block horizon to 160. The measurement said 10 rather than 12.
On-loop streaming goes 0.115 → 0.149 → 0.191 ms a frame across 7/10/12 and
per-chunk build cost is flat, so the loop would carry any of them; what
decided it was the picture and a number that could not be taken. Diffed
pixel by pixel, 7 → 10 changes 28.2% of a view from the air and 14.1% from
the ground, while 10 → 12 changes 9.5% and 1.0% — half the return per
vertex, and from the ground almost none, because the fog has already
finished before the render edge. The live 3440×1440 check that would have
justified 12 was unusable: it reported 9 fps, and so did the control run at
distance 7, because with no user at the machine macOS throttles an
unfocused window to ~8.7 Hz. So 10 is the one with margin — 975,340
vertices, 44% under the geometry this renderer was already shipping at.
`BLOCKHAVEN_RENDER_DISTANCE=<chunks>` (2–14) takes the other measurement when
someone is sitting at the machine; 12 is a one-word change if it holds.

**Phase 7 — many worlds, and a way back to the menu.** Worlds are now one
JSON file each under `saves/`, named by the player at creation (trimmed,
capped at 24, duplicates allowed — the file name carries a random suffix so
two "Twin"s never collide). `WorldSave` gained `name` and `lastPlayed`
without a version bump: the decoder is hand-written so a file missing them
still loads, dated by its own mtime and called "My World". A legacy
`world.json` is copied into the catalogue once, at launch, and then never
written again; a `saves/.migrated` file written after the copy lands is the
idempotence marker, so a failed copy is retried and a harness run that
creates `saves/` on its way past can't cancel the migration. The start menu leads
with Continue by name, and grows a load-a-world list at two worlds; the
pause screen grows Save & Main Menu — which refuses to leave when the save
didn't reach the disk, since the live world is the only copy of the session
at that point — and needed `GameViewController` to
gain a real teardown (scene subscription, post-process callback, mesh queue,
pointer capture, chunk entities), so menu → world → menu cycles release the
old world instead of leaving it ticking. A world started from the menu now
gets a random seed — `World`'s fixed default stays for every harness path,
which all compare runs against each other. `BLOCKHAVEN_SAVE_DIR` moves the
whole save directory; `BLOCKHAVEN_SCRIPT` walks the menus through their own
callbacks so the flows can be tested without a person at the keyboard.

## Done (2026-08-25)

Four asks in one sitting, none of them in the plan above.

**A world with things living in it.** Seven animal kinds now, up from
four: chicken, cod and squid join the pigs, cows, sheep and axolotls.
Everybody gained walking legs — the quadrupeds had never animated theirs,
which turns out to be the single largest "alive" win per line of code in
the whole file — and everybody spawns as a group rather than one at a
time, with per-kind ceilings so a lucky roll can't fill the budget with
eight squid. Cod shoal properly (`Animal.Shoal`, cohesion 2.0 /
alignment 0.6 / separation 1.8, measured to close a scattered school from
14.93 to 4.24 blocks mean gap without collapsing it — minimum spacing
holds at 0.51), squid jet in pulses, chickens flutter down at a capped
-2.6 blocks/s instead of falling. Two silent traps were waiting here:
`isAquatic` was `self == .axolotl` and is now an exhaustive switch, and
the axolotl's gill and belly materials were keyed on morph only, so a new
kind would have quietly worn axolotl skin. `BLOCKHAVEN_CHECK_ANIMALS=1`
covers the eight claims a screenshot can't.

**Trees and ground cover.** Three species — oak, birch, spruce, chosen by
biome — plus tall grass, poppies, dandelions, cornflowers, dead bushes and
cactus, at densities that make grass ground cover and flowers a find (the
check asserts better than 4:1). Plants are crossed slabs with the four end
faces and the downward faces hidden, ~40% off their vertex count. This is
what exposed the shader bug: `CustomMaterial.opacityThreshold` does not
discard when a surface shader supplies opacity, so every plant rendered as
a solid fog-coloured rectangle. `discard_fragment()` in `blockSurface`
fixes it; nothing had caught it before because every opaque-pass tile the
game had ever drawn was fully opaque. `BLOCKHAVEN_CHECK_PLANTS=1` generates
23×23 chunks, walks out to find the nearest desert (255 blocks in the
default seed) and asserts nothing is rooted in mid-air.

**Q and E fly up and down.** E still opens the inventory; the toggle is
suppressed while flying with E held, and Tab opens the inventory too so
there is always a key that only ever means "bag".

**Clouds with volume.** The flat slab is now a heightfield — each cell
gets a stack of up to seven levels from how far its density cleared the
threshold, plus a lattice jitter — with flat bases, stepped side walls and
a widened face brightness spread (1.0 / 0.79 / 0.60). uv0.x carries the
fraction of deck height so the shader can darken the undersides.
46,962 triangles, 17 ms to build.

Along the way, a pre-existing release-only heap corruption: `Inventory
.restore` looped `slots[index] = restored[index]` while `restored` very
often aliased the same buffer, which made `BLOCKHAVEN_CHECK_BOOK` read back
a `grass×0` stack out of zeroed memory. Confirmed against a clean
worktree at HEAD before touching it. Assigning the array whole fixes it.

## Done (2026-08-25, later the same day)

Five more asks, in one run: chain-detonating TNT lit by a torch, a railway
that becomes a roller coaster, tameable pets, and a demo world with
historical landmarks in it that resets every time it is opened.

**Block light.** The first light *source* in the game — everything before
it was a property of where a face sits relative to the sky. the original's
flood fill, including the two-sweep removal that is the half people get
wrong: strictly-dimmer cells are darkened, equal-or-brighter ones are
collected and re-spread, because those are being fed by a second lamp. It
cost no new vertex data — the shade word's top byte was free, so torchlight
went in the alpha lane as `torch<<24` and the shader adds
`kTorchColor * torch² * 1.45`. Squaring it is what stops fifteen linear
steps reading as a flat wash. That lane is only free because
`smoothShading == MaterialLibrary.usesCustomShader`; if those two ever come
apart it breaks as invisible blocks rather than as a compile error.

**TNT.** A torch lights it, and the blast lights its neighbours on a
scattered 0.10–0.55 s fuse — uniform delays detonate a wall as one flat
thump. `survivesHardness` is 8, which is exactly the line that leaves
obsidian standing, so a room can be lined against a blast. TNT is reported
as *not destroyed* by its own carve, because it is being lit rather than
removed and a chain that eats its own links never fires.

**Rails.** Twelve cases, and a resolver that is the actual feature: laying
a rail beside another turns *the one already there* to meet it, or a line is
a row of stubs. It is a coaster rather than a tram because a slope trades
height for speed both ways. The consequence, measured: a four-block drop
leaves a cart at 8.4 blocks/s and climbing four back needs 9.4, so a rise
can never be as tall as the drop that fed it — which is what a real coaster
is, and boosters are how you put the height back. Friction 0.12/s sets the
other number a track builder needs: a cart coasts about seventy-nine blocks
from a booster and then stops.

Three real bugs came out of the checks rather than out of playing: a cart
ran off the end of a line and was deleted as derailed (a straight rail names
both ends whether or not there is track beyond them) taking the player with
it; `snapToCell` took its height from the cart's cell rather than the rail's
and floated it a block above the track on every descent; and twelve rail
cases mapping to one palette item flooded `prefix(36)` and evicted stairs,
doors, panes and beds from the creative inventory.

A fourth was found while building the demo: a cart entering a T-junction
across the rail parked there for ever, because `exitDirection` returned nil
in the one case its own comment said it handled.

**Pets.** Wolves, `isTameable`, fed to tame. `recallDistance` is 12 — past
that a lost pet is picked up and set down on a ring of eight cells around
you. That is the original's rule and the reason is the same: nothing here does
pathfinding, and a dog stuck behind a two-block rise for the rest of the
session is worse than a dog that reappears. The first cut used 22 and the
check caught a pet frozen with its x pinned at 11.35 for a whole run. Tamed
animals skip the despawn sweep.

**The demo world.** Neuschwanstein, the Hagia Sophia and the Eiffel Tower
on a flattened deck, a 476-cell railway loop round all three with a
three-block coaster hill on the north side, and a spur into a lit plaza with
a cart waiting on it. It resets because `GameViewController(demoWorld:)`
passes `fileURL: nil` — there is no code path that could write a save, so
there is nothing to load. Written through `World.setBlock`, so it lands in
the edit journal and replays as chunks stream in, the same path a player's
own building takes.

Two things there were only found by counting. The rail resolver reads the
world, and an ungenerated chunk reads as air — so laying five hundred cells
into an empty world resolved every one to the same straight rail, no corners
and no slopes, and a cart ran to the first bend and stopped. And a booster
landing on a corner breaks the loop, because there is no powered curve and
the resolver lays a straight along one link instead.

Also, while here: a rider could not move a parked cart at all. Movement
input is suspended while riding, so there was no way to start, no way to
choose a direction and no way off short of getting out. `W`/`S` now push
the cart at up to 4.5 blocks/s, in whichever direction the rider is
*looking* — a stopped cart still has a heading, and a rider who has to guess
it sets off backwards half the time.

**The world got taller, and two things came out of it.** `Chunk.height` is
192, raised from 128 so a 120-block landmark could stand on ground near sea
level. It was cheap for a reason worth remembering: `Chunk.index` does not
mention height, so no saved world was invalidated, and terrain generation
loops to the surface rather than to the ceiling, so only meshing and the
light flood pay. The trap was the other direction — `surfaceHeight` clamped
at `Chunk.height - 14`, so raising the ceiling would have lifted every
clamped mountain under every existing save by sixty-four blocks. Those are
now pinned constants.

**The demo check passed a tower nobody could climb — twice.** First it
counted whether *a* stair existed at every height in the footprint, which
four staircases in four separate legs satisfy without a single continuous
route. Replacing that with a reachability flood over standable cells looked
like the careful fix and was not: it moved a point one block up between
neighbouring cells, and a whole block up is exactly the rise
`PlayerController.stepHeight` refuses — a tread is climbed in two half-block
steps, which a cell-to-cell flood cannot represent — while a point, having
no width, fits on a one-column tread that no body fits on. It passed this
tower on a day a real body could not get up it.

It now drives `PlayerController.step` along the route the builder publishes.
An approximation of the physics is a second implementation of the physics,
free to drift from the first, and the drift is the bug. The objection —
steering a body means knowing the design — is answered by the builder
publishing the route rather than the check guessing it. Two mutations keep
it honest: full logs for treads fails on the first stride, and a
one-column carve jams at 108 of 206 cells.

**The rail check was slow, and the reason was not the one I published.** I
said the taller world had made `seedLight` sweep a 1.5× volume. Measuring it
properly — building the previous commit at height 128 in a worktree and
running both — the difference is about 3%, inside noise. `/usr/bin/sample`
put 83% of the run in terrain generation and 71% of the *whole run* in
`isCave` alone, which took two ValueNoise samples per cell. The second
sample is now taken only where the first already said "hollow", which is
about a quarter of cells; the intersection is identical because both fields
are pure functions of seed and point. `seedLight` was around 10%, and is now
bounded by a cached `Chunk.ceiling` as well. The check was never fast — it
was new, and I had assumed a regression where there was none.

**Torches lit nothing at night, and every layer tested clean.** The flood
fill was right, the check read 14 at the lamp, and the mesher packed 238 of
255 into the alpha lane — the light was in the world *and* in the geometry
and still not on the screen. The day/night grade is a base-colour tint
applied before the shader, and `light` is a multiplier on it, so a term
added to `light` could only scale darkness. A torch at midnight measured
1.2× the brightness of stone twenty blocks off, with no warmth at all;
dividing the grade back out of the lamp term (capped, and a no-op at noon)
put it at 1.6× and properly warm.

Worth keeping: three layers each verified in isolation composed into
nothing, because what was wrong was the *relationship* between two of them
and no test owned it. The snapshot harness now prints `brightest lamp
N/255`, which is the number that separates "not in the world" from "in the
world, not on the screen".

## Remaining

0. **Narrow the mesher's neighbourhood copy to the occupied span.** Raising
   the world to 192 doubled on-loop streaming, 0.34 → 0.68 ms a frame and
   worst frame 1.80 → 3.47 ms, and nearly all of it is `gather` copying a
   padded volume whose height is the world's — almost all of the added
   volume being empty sky above the terrain. It is 4% of a 60 fps frame and
   drops nothing, so it was worth paying for the tower, but this is the
   lever if streaming ever wants the room back.
1. Greedy meshing, if a future phase ever needs the vertices back. It was
   measured and declined: 38% fewer quads, at the price of a second
   geometry path for the shaderless fallback. See README's "Why there is
   no greedy meshing".
2. Re-run the live 3440×1440 frame check *with a person at the keyboard*,
   at 10 and at 12. It is the only measurement this phase wanted and could
   not get, and it is the difference between shipping 10 and shipping 12.
   While there, watch `sky` in the frame log: `MaterialLibrary.pushToChunks`
   sweeps every tracked chunk on the grade quantum, that count went 149 →
   317 with the distance, and it is the one per-frame cost that scales with
   render distance outside the streaming loop.
3. `upload` — `LowLevelMesh` plus `MeshResource` plus the entity, ~0.09 ms
   a chunk — is still the largest thing chunk streaming leaves on the main
   thread, alongside the neighbourhood copy the classifier's padding grew
   to ~0.09 ms. Both have to be there, but if streaming ever needs to go
   faster, pooling `LowLevelMesh` buffers across remeshes is one lever and
   narrowing the classifier's copy to a bitset is the other.
3. A human should eyeball the sky, fog, and water in motion. Every session
   that has shipped them could only verify stills through the harness, and
   even that needs the display awake: a sleeping screen occludes every
   window and RealityKit then renders zero frames, which is what
   `only 0 frames rendered` in the harness means. `caffeinate -du` is
   enough to get stills back; a moving picture still needs a person.

## Suggested order

Whatever is most fun. Everything above the line is repair-complete;
what's left is addition.
