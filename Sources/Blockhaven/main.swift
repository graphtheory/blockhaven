import Foundation
#if canImport(AppKit)
import AppKit
#endif

#if os(Windows)
CrashLog.install()
GameVersion.announce()
#endif

// A harness run speaks English: the checks, scripts and snapshots print
// their transcripts through the same localized strings the player sees, so
// without this a Swedish choice persisted by the family machine would
// quietly turn "2 hours ago" into "för 2 timmar sedan" in every transcript.
// `overwrite: 0` keeps an explicit BLOCKHAVEN_LANGUAGE as it is — which is
// exactly how the Swedish menu gets shot on purpose.
if StreamBenchmark.isRequested || ShapedBlockCheck.isRequested
    || HouseBlockCheck.isRequested || AxolotlCheck.isRequested
    || AnimalCheck.isRequested || VegetationCheck.isRequested
    || LightCheck.isRequested || TntCheck.isRequested || PetCheck.isRequested
    || RailCheck.isRequested || DemoCheck.isRequested
    || FurnaceCheck.isRequested || SignalCheck.isRequested
    || SensorCheck.isRequested || SensorStressCheck.isRequested || ThermalCheck.isRequested || ThermalStressCheck.isRequested || ThermalEdgeStressCheck.isRequested
    || GravityCheck.isRequested || GravityStressCheck.isRequested || ConveyorCheck.isRequested || ConveyorStressCheck.isRequested
    || IndustryCheck.isRequested || IndustryStressCheck.isRequested
    || RuinCheck.isRequested || CropCheck.isRequested || DangerCheck.isRequested
    || BreedCheck.isRequested || HopperCheck.isRequested || WeatherCheck.isRequested
    || OreCheck.isRequested || HomesteadCheck.isRequested || BucketCheck.isRequested
    || MigrationCheck.isRequested
    || WaterFlowCheck.isRequested || CompassCheck.isRequested || SaplingCheck.isRequested
    || LavaCheck.isRequested || SkeletonCheck.isRequested || SkeletonStressCheck.isRequested || MasonCheck.isRequested
    || CavernCheck.isRequested || ArmorCheck.isRequested || BlueprintCheck.isRequested
    || VaultCheck.isRequested || SpireCheck.isRequested || WreckCheck.isRequested
    || GraveCheck.isRequested || SaveAllCheck.isRequested
    || ProcessInfo.processInfo.environment["BLOCKHAVEN_MODE"] != nil {
    setEnvironment("BLOCKHAVEN_LANGUAGE", "en", overwrite: false)
}
#if canImport(AppKit)
if RecipeBookCheck.isRequested || CreativeCheck.isRequested || SurvivalCheck.isRequested
    || OffscreenSnapshot.isRequested || MenuScript.isRequested {
    setEnvironment("BLOCKHAVEN_LANGUAGE", "en", overwrite: false)
}
#endif

// The terrain probe is a survey, not a check: it prints the generator's
// surface heights over a rectangle and exits, which is the first question
// every siting of a new landmark asks.
if TerrainProbe.isRequested { TerrainProbe.run() }

#if canImport(AppKit)
if AssetBake.isRequested { AssetBake.run() }
if AssetBake.isCheckRequested { AssetBake.check() }
#endif

// The streaming benchmark never opens a window — it is pure world code —
// so it runs and exits before `NSApplication` is ever touched. That is what
// lets it be measured on a machine whose screen is locked or asleep.
if StreamBenchmark.isRequested { StreamBenchmark.run() }

// Same deal for the shaped-block walk-into-it check: a `World` and a
// `PlayerController` and nothing else, so it needs no window either.
if ShapedBlockCheck.isRequested { ShapedBlockCheck.run() }

// And for the other half of those blocks — placing, opening, sleeping,
// breaking, saving. Also windowless: none of those rules live in the view
// controller.
if HouseBlockCheck.isRequested { HouseBlockCheck.run() }

// And for the axolotl, whose whole rule is which cells it may be in. Also
// a `World` and a mob and nothing else.
if AxolotlCheck.isRequested { AxolotlCheck.run() }

// And for what the rest of the animals gained — a shoal that gathers, a
// chicken that beats its way down, a herd that arrives together, and
// nothing standing on a treetop. Same deal: worlds and mobs, no window.
if AnimalCheck.isRequested { AnimalCheck.run() }

// And for what grows: the generator over a slab of real world, counted.
// Pure world code again — the trees and the ground cover are decided on the
// generation queue and never touch a renderer.
if VegetationCheck.isRequested { VegetationCheck.run() }

// And for the one thing in this world that makes its own light. Worlds and
// arrays, no window: the last line does run the mesher, but building
// vertices is arithmetic and needs no device.
if LightCheck.isRequested { LightCheck.run() }

// And for the chain: a stick of TNT lighting the next rather than simply
// destroying it. Worlds and a fuse manager, no window.
if TntCheck.isRequested { TntCheck.run() }

// And for the promise a tamed animal makes: still there later, keeping up,
// and staying put when told.
if PetCheck.isRequested { PetCheck.run() }

// And for the track: that a line joins itself up, and that a drop pays for
// the rise after it, which is the whole difference between a coaster and a
// slide.
if RailCheck.isRequested { RailCheck.run() }
if DemoCheck.isRequested { DemoCheck.run() }

// The recipe book lays items out on the crafting grid, which is arithmetic
// over an `Inventory` and a `CraftingGrid` — no window either, even though
// half of what it checks is the geometry of rows on screen.
#if canImport(AppKit)
if RecipeBookCheck.isRequested { RecipeBookCheck.run() }
#endif

// And the creative palette, the chest and the two scrolling panels: the
// half of the inventory screen that is arithmetic rather than pixels.
#if canImport(AppKit)
if CreativeCheck.isRequested { CreativeCheck.run() }
#endif

// And what survival costs: tools that wear out, and a body that runs down.
#if canImport(AppKit)
if SurvivalCheck.isRequested { SurvivalCheck.run() }
#endif

// And the first process rather than menu conversion in the game: a
// furnace that only cooks while lit, only stays lit while fed, and says
// which of those is true through the block itself. Worlds and a state
// struct, no window.
if FurnaceCheck.isRequested { FurnaceCheck.run() }

// And the one thing that reacts to itself: a lever's on/off carried
// through wire to a door and a stick of TNT. Worlds and a signal graph,
// no window.
if SignalCheck.isRequested { SignalCheck.run() }

// And the celestial and active signal sensors: daylight sensor solar power,
// signal lamp lighting and unspreading, and mob-actuated pressure plates.
if SensorCheck.isRequested { SensorCheck.run() }
if SensorStressCheck.isRequested { SensorStressCheck.run() }

// And the thermal microclimates & subterranean farming: water freezing in snowy biomes
// and alpine altitudes, thermal radiance melting/preventing freeze, and crop/sapling growth under artificial block light.
if ThermalCheck.isRequested { ThermalCheck.run() }
if ThermalStressCheck.isRequested { ThermalStressCheck.run() }
if ThermalEdgeStressCheck.isRequested { ThermalEdgeStressCheck.run() }

// And the demo world's one destructible landmark: how long a single lit
// fuse takes to bring the dynamite Burj Khalifa down.
if DemolitionCheck.isRequested { DemolitionCheck.run() }

// And granular gravity: sand and gravel falling into air and water, and blast crater collapse.
if GravityCheck.isRequested { GravityCheck.run() }
if GravityStressCheck.isRequested { GravityStressCheck.run() }

// And horizontal pipeline logistics: inter-hopper conveyors, signal locking, and lava bucket super-fuel.
if ConveyorCheck.isRequested { ConveyorCheck.run() }
if ConveyorStressCheck.isRequested { ConveyorStressCheck.run() }

// And the grand integration of Wave 9: physical resonance, thermal microclimates,
// horizontal logistics pipelines, subterranean agriculture, granular gravity,
// diurnal skeleton burning, and industrial disturbance threat escalation.
if IndustryCheck.isRequested { MainActor.assumeIsolated { IndustryCheck.run() } }
if IndustryStressCheck.isRequested { MainActor.assumeIsolated { IndustryStressCheck.run() } }

// And the one thing a fresh world puts out there to be curious about
// rather than to fight or farm. Worlds and a generator, no window.
if RuinCheck.isRequested { RuinCheck.run() }

// And the one thing that grows because time passed rather than because a
// player placed it. Worlds and a growth clock, no window.
if CropCheck.isRequested { CropCheck.run() }

// And the one thing that makes distance itself mean something rather than
// just time to cross. Worlds and a fizzler manager, no window.
if DangerCheck.isRequested { DangerCheck.run() }

// And the one thing that turns a harvest into a herd. Worlds and an
// animal manager, no window.
if BreedCheck.isRequested { BreedCheck.run() }

// And the one thing that moves an item without a hand on it. Worlds, a
// chest store and a furnace store, no window.
if HopperCheck.isRequested { HopperCheck.run() }

// And the one thing that makes a night worse and a field faster with the
// same reading of the same clock. Worlds, a fizzler manager and a growth
// clock, no window.
if WeatherCheck.isRequested { WeatherCheck.run() }

// And the one thing mining itself asks a player to notice: whether a find
// was alone or the edge of something bigger. Pure generator arithmetic, no
// window.
if OreCheck.isRequested { OreCheck.run() }

// And the one thing no other check proves: that a mined vein, a
// hopper-fed furnace, a growing crop and a scaled-down doorstep all run
// at once in the same session without stepping on each other.
// `assumeIsolated` rather than a plain call: this file's top level runs on
// the main thread but is not statically main-actor code, and `run()` needs
// to be — see its own doc comment.
if HomesteadCheck.isRequested { MainActor.assumeIsolated { HomesteadCheck.run() } }

// And the one item that carries a piece of the world rather than mining,
// placing or eating it. Worlds and a crafting grid, no window.
if BucketCheck.isRequested { BucketCheck.run() }
if MigrationCheck.isRequested { MigrationCheck.run() }

// And the one thing a bucket does that a placed block never did on its
// own: find its own way downhill and pool, capped rather than endless.
// Worlds and a flood fill, no window.
if WaterFlowCheck.isRequested { WaterFlowCheck.run() }

// And the one item whose whole job is answering "which way is home" —
// pure bearing arithmetic, no window.
if CompassCheck.isRequested { CompassCheck.run() }

// A sapling's clock, and the tree it grows into — the same builder chunk
// generation itself calls, no window needed to prove either half.
if SaplingCheck.isRequested { SaplingCheck.run() }

// Lava: a real hazard down in the dark, and the one interaction with
// water nobody has to be told about.
if LavaCheck.isRequested { LavaCheck.run() }

// And the second shape of threat: something a wall stops just as
// completely as a fizzler's fuse, at any range, not only up close.
if SkeletonCheck.isRequested { SkeletonCheck.run() }
if SkeletonStressCheck.isRequested { MainActor.assumeIsolated { SkeletonStressCheck.run() } }

// And the tool that turns "place a wall" into "mark a wall": two corners
// and the next material placed fills the box between them. Worlds and a
// pure box-fill function, no window.
if MasonCheck.isRequested { MasonCheck.run() }

// And the one underground find that isn't a resource: a room rather than a
// corridor, standing in the same depth band ore already lives in. Pure
// generator arithmetic, no window.
if CavernCheck.isRequested { CavernCheck.run() }

// And the one thing worn rather than held: a chestplate that blunts a hit,
// a burn or a blast, and does nothing at all against starving or drowning.
// Worlds and a stats struct, no window.
if ArmorCheck.isRequested { ArmorCheck.run() }

// And the mason's line one step further along: a marked box captures
// whatever stood there, in whatever materials it actually used, and every
// later stamp reproduces that shape again — reused `RegionFill` machinery,
// no window.
if BlueprintCheck.isRequested { BlueprintCheck.run() }

// And the first place in the world a diamond pickaxe is what gets a
// player through a wall rather than merely what mines it faster — a small
// sealed room, deep in the same band diamond and lava already share, its
// obsidian shell forced whole regardless of what the cave pass carved
// through that space first. Worlds and a generator, no window.
if VaultCheck.isRequested { VaultCheck.run() }

// And the first thing meant to be seen from far away rather than stumbled
// into up close: a plain stone shaft rising well clear of the peak it
// stands on, capped in a light a sea lantern already knows how to cast.
// Pure generator arithmetic, no window.
if SpireCheck.isRequested { SpireCheck.run() }

// And the first landmark that costs a clock instead of a tool or a walk:
// a chest on a genuinely deep ocean floor, reachable only by spending down
// the air a diver already carries. Worlds and a generator, no window.
if WreckCheck.isRequested { WreckCheck.run() }

// And the one stake every other landmark already had that death itself
// never did: a chest at the spot a player fell, holding what they
// carried. Inventory and chest store, no window.
if GraveCheck.isRequested { GraveCheck.run() }

// And the one thing every other check only ever proved alone: that a
// chest, a furnace, a cart, a pet, a chestplate, a bed and a grave all
// survive being written into the *same* file and read back together, not
// just each on its own. Worlds and every store at once, no window.
if SaveAllCheck.isRequested { SaveAllCheck.run() }

// Worlds and settings saved under the game's earlier name come across
// once, before either front end reads a save. See LegacyMigration.
LegacyMigration.runIfNeeded()

// `BLOCKHAVEN_FRONTEND=sdl` runs the SDL and OpenGL front end on the Mac —
// the one Windows always runs — so it can be played and checked here.
#if canImport(AppKit)
let runsSDL = ProcessInfo.processInfo.environment["BLOCKHAVEN_FRONTEND"] == "sdl"
#else
let runsSDL = true
#endif

// The packaged Mac app is built without SDL (`BLOCKHAVEN_MAC_APP=1`; see
// Package.swift), so it has only the RealityKit front end.
#if canImport(CSDL3)
if runsSDL {
    DebugBuildNotice.warnIfNeeded()
    SDLApp.run()
}
#endif

#if canImport(AppKit)
// Everything above this line either exits or falls through to the game, so
// this is the last moment before a window opens — and the right one to say
// that an unoptimised build is about to look like a broken one. A snapshot
// run is a harness and already knows what it is, so it is left alone.
if !OffscreenSnapshot.isRequested { DebugBuildNotice.warnIfNeeded() }

// A snapshot run takes over the process entirely: RealityKit needs a live
// window and run loop to render, so headless capture is just the app with
// a different delegate that quits once it has written its PNG.
let app = NSApplication.shared
let delegate: NSApplicationDelegate = OffscreenSnapshot.isRequested
    ? SnapshotAppDelegate()
    : AppDelegate()
app.delegate = delegate
app.setActivationPolicy(OffscreenSnapshot.isRequested ? .accessory : .regular)
app.run()
#endif
