import Foundation

/// One world in play: everything that happens in it, and nothing about how
/// it is drawn.
///
/// Carved out of `GameViewController` so the same game can run behind more
/// than one front end — RealityKit on the Mac, SDL and OpenGL everywhere
/// else. The front end owns the window, the scene and the screens; it
/// feeds this a frame's input, steps it, and then reads back whatever it
/// needs to draw: the player, the mobs, the camera, the HUD.
///
/// Anything the simulation wants of the front end — a screen opened, the
/// view's held stacks handed back before a save — goes through a request
/// field or a closure rather than a call into UI code.
final class GameSession {
    /// A screen the simulation wants opened — set by a right-click on a
    /// table or a chest, taken by the front end at the end of the frame.
    enum ScreenRequest {
        case crafting(gridSize: Int)
        case chest(Chest)
    }

    /// Set when something in play asks for a screen; the front end clears
    /// it by taking it with `takeScreenRequest`.
    var screenRequest: ScreenRequest?

    func takeScreenRequest() -> ScreenRequest? {
        defer { screenRequest = nil }
        return screenRequest
    }

    /// The block the crosshair is on, for the front end's outline.
    var highlightTarget: (x: Int, y: Int, z: Int)?

    /// Bumped on every death. The front end drops every mob it is drawing
    /// when this moves, so nothing is left standing over the spot the
    /// player died on.
    var respawnCount = 0

    /// Called just before a save captures the inventory, so a screen still
    /// holding stacks on its cursor or in its grid can hand them back.
    var willCaptureSave: (() -> Void)?
    /// Called with how each write went: nil for landed, the error otherwise.
    var onSaveResult: ((String?) -> Void)?

    /// Chosen on the start screen and fixed for the life of the world.
    let mode: GameMode

    /// What this world is called. Shown in the window title, written into
    /// every save, and what the start menu puts on the Continue card.
    let worldName: String

    /// The one file this world writes to, for its whole life. Nil when
    /// there is no disk to write to — `BLOCKHAVEN_NO_SAVE=1` — which is the
    /// single condition that makes every save here a no-op.
    let fileURL: URL?

    let world: World
    /// The save this world was reopened from, applied in `viewDidLoad`
    /// once the scene exists, then dropped: the journal already lives in
    /// `World` and a second copy of it would sit here for the whole run.
    /// Nil for a new world.
    var restored: WorldSave?
    let inventory = Inventory()
    /// What is inside every chest in this world. Kept beside the world
    /// rather than in it: a block is a byte, and twenty-seven stacks do
    /// not fit in a byte. Keyed by cell, so a chest whose chunk streams out
    /// from under it still remembers what it was holding.
    var chests = ChestStore()
    /// Every furnace's fire, kept beside the world the same way — a
    /// furnace's ore, fuel and clock are three numbers and a slot each, and
    /// none of them fit in the one byte a block is.
    var furnaces = FurnaceStore()
    /// Every lever's cell and what it currently reaches — the only piece of
    /// this game that reacts to itself rather than to the player. A lever
    /// and a length of wire are both ordinary blocks and save with the
    /// world for free; this is the index that lets a toggle find what it
    /// touches without scanning every loaded chunk for it.
    var signals = SignalNetwork()
    /// Every planted crop's clock — see `CropStore`. Wheat stages are
    /// ordinary blocks and save with the world for free; this is only the
    /// timer, rebuilt on load the same way `signals` rebuilds its index.
    var crops = CropStore()
    /// Every hopper's cooldown — see `HopperStore`. Rebuilt on load the
    /// same way `signals` and `crops` are, by walking the journal once.
    var hoppers = HopperStore()
    /// Every planted sapling's clock — see `SaplingStore`. Rebuilt on load
    /// the same way `crops` is: the block saves for free, only its timer
    /// does not.
    var saplings = SaplingStore()
    /// A sapling's chance of falling out of a broken leaf block — thin on
    /// purpose, the same reason the original's own odds are thin: a whole
    /// canopy of leaves rolls this over and over, so thin is still enough
    /// wood to matter, and a felled tree does not hand back a guaranteed
    /// replacement of itself.
    static let saplingDropChance: Double = 0.12
    var player: PlayerController
    var stats = PlayerStats()
    /// Where the player is looking, and the bob and shake on top of it.
    var camera = CameraState()
    /// The day/night and weather clock. The front end paints it; this only
    /// ever reads and advances it.
    let sky = SkyClock()
    var mining = MiningState()
    /// Seconds until the next swing can land. Separate from `MiningState`
    /// because a swing is an instant event and mining is a held one.
    var attackCooldown: Double = 0
    var fizzlers: FizzlerManager
    /// A second, ranged population — same night, same darkness gate, same
    /// distance ramp as the fizzlers, a different shape of threat.
    var skeletons: SkeletonManager
    /// Lit TNT. Not owned by the fizzlers, though a fizzler can light it:
    /// TNT exists in worlds that have no fizzlers at all.
    let fuses = FuseManager()
    var minecarts = MinecartManager()
    var toastText: String?
    var toastTimer: Double = 0
    var animals: AnimalManager
    /// Drop counts come off the world's own stream, so a given world rolls
    /// the same run of them every time it's played.
    var dropRNG: SeededGenerator

    /// The crafting table the open screen belongs to, if any — used to
    /// close the screen when the player walks away from it.
    var openTablePosition: (x: Int, y: Int, z: Int)?

    /// The first corner a mason's line has marked, waiting on a second
    /// right-click to become a box. Cleared the instant the box is formed
    /// — only the box itself, `masonRegion`, survives to meet a placement.
    var masonAnchor: (x: Int, y: Int, z: Int)?
    /// A marked box waiting for the next material placed to fill it.
    var masonRegion: RegionFill.Box?

    /// The first corner a blueprint has marked, waiting on a second
    /// right-click to become a box — only meaningful while nothing has been
    /// captured yet, the mirror of `masonAnchor`.
    var blueprintAnchor: (x: Int, y: Int, z: Int)?
    /// The last captured shape, if any. Unlike `masonRegion` this survives
    /// being used — a blueprint is a stamp, not a one-shot mark, so it stays
    /// good for as many more right-clicks as the player wants until they
    /// break something to clear it and capture a different one.
    var blueprintCapture: RegionFill.Blueprint?
    var lastSelectedSlot = -1
    var itemNameTimer: Double = 0
    var itemNameToast: String?
    var damageFlashTimer: Double = 0
    var thermalTickAccumulator: Double = 0
    static let thermalInterval: Double = 1.0
    var gravityTickAccumulator: Double = 0
    static let gravityInterval: Double = 0.5

    /// How far the eye reaches, for blocks and for mobs alike.
    static let reach: CGFloat = 5.5
    /// Seconds between landed hits. The attack button is a held state, so
    /// without this holding it would be a machine gun.
    static let attackInterval: Double = 0.4
    /// Fizzlers, animals and skeletons are numbered independently, so
    /// animal and skeleton ids are shifted into their own ranges for the
    /// one cast that sees all three. A hit at or above `skeletonIDBase`
    /// belongs to `skeletons`, at or above `animalIDBase` (and below that)
    /// to `animals`, otherwise to `fizzlers`.
    static let animalIDBase = 1 << 20
    static let skeletonIDBase = 2 << 20

    /// Seconds of play between autosaves.
    static let autosaveInterval: Double = 30
    var autosaveTimer: Double = 0
    /// Writes are serialised, so one can't overtake another and so the
    /// save at termination lands after everything queued before it.
    static let saveQueue = DispatchQueue(label: "blockhaven.save", qos: .utility)

    /// A world that has never been saved. Its file is claimed here rather
    /// than at the first save, so the name on the card and the name on disk
    /// are decided by the same act.
    ///
    /// `seed` is nil for every harness path, which leaves `World` on its
    /// fixed default — the snapshot battery, the streaming benchmark and
    /// the frame log all compare runs against each other and would measure
    /// nothing if the terrain moved underneath them. The start menu passes
    /// a real one: two worlds that generate the same landscape are not two
    /// worlds, and a list of them is a list of copies.
    convenience init(newWorld mode: GameMode, name: String, seed: UInt64? = nil) {
        self.init(
            mode: mode,
            name: name,
            fileURL: WorldSave.isEnabled ? WorldCatalog.availableURL(for: name) : nil,
            seed: seed,
            restoring: nil
        )
    }

    /// The demo world: the three landmarks, the railway and the coaster.
    ///
    /// `fileURL` is nil unconditionally, and that single nil is the whole
    /// of "it resets when you start it". Nothing is written, so there is
    /// nothing to load, so every start builds the site again from the same
    /// seed. Which means it can be dug up, blown up and ridden off the end
    /// of, and the next person to open it gets it whole — which is what a
    /// demo has to be, and what a saved world can never be.
    convenience init(demoWorld: Void = ()) {
        self.init(
            mode: .creative,
            name: L10n.t("Demo World", "Demovärld"),
            fileURL: nil,
            seed: DemoWorld.seed,
            restoring: nil,
            demo: true
        )
    }

    /// Reopens a world from the catalogue. The journal goes in through
    /// `World`'s initialiser rather than being replayed afterwards, because
    /// chunks start generating from the first frame and each one applies
    /// the journal as it lands.
    convenience init(entry: WorldCatalog.Entry, save: WorldSave) {
        self.init(
            mode: save.mode,
            name: save.name,
            fileURL: WorldSave.isEnabled ? entry.url : nil,
            seed: nil,
            restoring: save
        )
    }

    init(
        mode: GameMode,
        name: String,
        fileURL: URL?,
        seed: UInt64?,
        restoring save: WorldSave?,
        demo: Bool = false
    ) {
        self.mode = mode
        self.worldName = name
        self.fileURL = fileURL
        self.restored = save
        if let save {
            let journal = save.editJournal
            world = World(seed: save.seed, edits: journal)
            // Levers are ordinary blocks and load with everything else —
            // this just rebuilds the index of where they are, by walking
            // the same journal that just built the world, rather than
            // scanning every chunk that streams in afterward.
            for (coord, entries) in journal {
                for (index, block) in entries where block == .leverOff || block == .leverOn
                    || block == .pressurePlateOff || block == .pressurePlateOn
                    || (block.isCrop && block != .wheatStage3) || block == .hopper
                    || block.isSapling || block.isDetectorRail || block.isSignalTorch
                    || block == .daylightSensor || block == .signalLamp || block == .signalLampLit {
                    let plane = Chunk.width * Chunk.depth
                    let y = index / plane
                    let remainder = index % plane
                    let z = remainder / Chunk.width
                    let x = remainder % Chunk.width
                    let worldX = coord.x * Chunk.width + x, worldZ = coord.z * Chunk.depth + z
                    if block.isCrop {
                        // A stage's own clock is not what was saved — only
                        // the stage was — so every unripe planting resumes
                        // from the start of its current stage rather than
                        // wherever it happened to be when the world was
                        // last closed.
                        crops.planted(at: CropStore.Key(worldX, y, worldZ))
                    } else if block.isSapling {
                        // Same forgiveness as a crop above: only the block
                        // survived the save, not how far its clock had
                        // banked, so a reloaded sapling resumes its wait
                        // from the start rather than wherever it was.
                        saplings.planted(at: SaplingStore.Key(worldX, y, worldZ))
                    } else if block == .hopper {
                        hoppers.hopperPlaced(at: HopperStore.Key(worldX, y, worldZ))
                    } else if block.isPressurePlate {
                        signals.platePlaced(at: SignalNetwork.Key(worldX, y, worldZ))
                    } else if block.isDetectorRail {
                        signals.detectorPlaced(at: SignalNetwork.Key(worldX, y, worldZ))
                    } else if block.isSignalTorch {
                        signals.torchPlaced(at: SignalNetwork.Key(worldX, y, worldZ))
                    } else if block == .daylightSensor {
                        signals.daylightSensorPlaced(at: SignalNetwork.Key(worldX, y, worldZ))
                    } else if block == .signalLamp || block == .signalLampLit {
                        signals.lampPlaced(at: SignalNetwork.Key(worldX, y, worldZ))
                    } else {
                        signals.leverPlaced(at: SignalNetwork.Key(worldX, y, worldZ))
                    }
                }
            }
        } else if let seed {
            world = World(seed: seed)
        } else {
            world = World()
        }
        // Before anything generates. The site goes in through the edit
        // journal, which is exactly what a player's own building does, so
        // chunks pick it up as they stream in and no chunk has to exist
        // yet for it to be written.
        if demo { DemoWorld.build(in: world) }
        player = PlayerController(
            spawn: save?.playerPosition ?? (demo ? DemoWorld.spawn : world.spawnPosition())
        )
        fizzlers = FizzlerManager(mode: mode, seed: world.seed)
        skeletons = SkeletonManager(mode: mode, seed: world.seed &* 0x2545F4914F6CDD1D)
        animals = AnimalManager(mode: mode, seed: world.seed)
        dropRNG = SeededGenerator(seed: world.seed &* 0x2545F4914F6CDD1D &+ 0xD10D)
        if demo {
            // The chunk has to be generated before the cart can go on it.
            // The track is in the edit journal but not yet in any chunk,
            // and `place` reads the world, where an ungenerated cell reads
            // as air and a cart cannot be stood on air.
            world.forceGenerate(
                World.chunkCoord(forWorldX: DemoWorld.cartCell.x, worldZ: DemoWorld.cartCell.z)
            )
            minecarts.place(at: DemoWorld.cartCell, in: world)
        }
        GameSession.logLifecycle("built world \"\(name)\" (\(mode.rawValue)) seed \(world.seed)")
    }

    /// Reconstructs indexed world and signal network state from edit journal entries upon world load/restore.
    nonisolated static func registerJournalIndex(
        from journal: [ChunkCoord: [Int: BlockType]],
        signals: SignalNetwork,
        crops: CropStore? = nil,
        saplings: SaplingStore? = nil,
        hoppers: HopperStore? = nil
    ) {
        for (coord, entries) in journal {
            for (index, block) in entries where block == .leverOff || block == .leverOn
                || block == .pressurePlateOff || block == .pressurePlateOn
                || (block.isCrop && block != .wheatStage3) || block == .hopper
                || block.isSapling || block.isDetectorRail || block.isSignalTorch
                || block == .daylightSensor || block == .signalLamp || block == .signalLampLit {
                let plane = Chunk.width * Chunk.depth
                let y = index / plane
                let remainder = index % plane
                let z = remainder / Chunk.width
                let x = remainder % Chunk.width
                let worldX = coord.x * Chunk.width + x, worldZ = coord.z * Chunk.depth + z
                if block.isCrop {
                    crops?.planted(at: CropStore.Key(worldX, y, worldZ))
                } else if block.isSapling {
                    saplings?.planted(at: SaplingStore.Key(worldX, y, worldZ))
                } else if block == .hopper {
                    hoppers?.hopperPlaced(at: HopperStore.Key(worldX, y, worldZ))
                } else if block.isPressurePlate {
                    signals.platePlaced(at: SignalNetwork.Key(worldX, y, worldZ))
                } else if block.isDetectorRail {
                    signals.detectorPlaced(at: SignalNetwork.Key(worldX, y, worldZ))
                } else if block.isSignalTorch {
                    signals.torchPlaced(at: SignalNetwork.Key(worldX, y, worldZ))
                } else if block == .daylightSensor {
                    signals.daylightSensorPlaced(at: SignalNetwork.Key(worldX, y, worldZ))
                } else if block == .signalLamp || block == .signalLampLit {
                    signals.lampPlaced(at: SignalNetwork.Key(worldX, y, worldZ))
                } else {
                    signals.leverPlaced(at: SignalNetwork.Key(worldX, y, worldZ))
                }
            }
        }
    }

    /// Brings a restored world's state back — or hands a new one its kit —
    /// and generates the ground under the player. Run once, by the front
    /// end, after it has built its scene and before the first frame.
    func start() {
        // A restored world brings its own everything: the palette and the
        // starter kit are what a world is given when it has no history.
        if let restored {
            inventory.restore(slots: restored.inventorySlots, selectedHotbarSlot: restored.selectedSlot)
            chests = restored.chestStore
            furnaces = restored.furnaceStore
            // The journal pass above already registered every hopper block
            // it found. This layers back the two things a block byte cannot
            // carry: which way the hopper points, and the single item it may
            // have been holding when the world closed. Merged rather than
            // swapped in, so a hopper in the journal that predates the save
            // format keeps its entry and simply has no facing — exactly how
            // it behaved before facings existed.
            let savedHoppers = restored.hopperStore
            for key in savedHoppers.allKeys {
                hoppers.hopperPlaced(at: key, facing: savedHoppers.facing(at: key))
                hoppers.setItem(savedHoppers.item(at: key), at: key)
            }
            minecarts.restore(restored.restoredMinecarts)
            animals.restore(restored.restoredAnimals)
            // The lever index was rebuilt above; this syncs the wire and
            // door caches to what is actually in the loaded journal, so a
            // door left open by a lever that has since gone missing closes
            // rather than staying open with nothing tracking it.
            signals.recompute(world: world, fuses: fuses)
            stats.restore(health: restored.health, hunger: restored.hunger, air: restored.air,
                          equippedChestplate: restored.equippedChestplate)
            camera.reset(yaw: CGFloat(restored.yaw), pitch: CGFloat(restored.pitch))
            sky.setTimeOfDay(restored.timeOfDay)
            sky.setWeatherDayIndex(restored.weatherDayIndex ?? 0)
            bedSpawn = restored.bedSpawn
            pendingGraveKeys = restored.pendingGraveKeys
        } else if mode == .creative {
            inventory.grantCreativeKit()
        } else {
            inventory.grantStarterKit()
        }

        // Generate the spawn neighbourhood synchronously so the player
        // doesn't fall through an empty world on the first frames.
        primeSpawnChunks()
        // `BLOCKHAVEN_TIME=0.7` starts at night — the only practical way to
        // test fizzler spawning without waiting out a day cycle.
        if let start = Double(ProcessInfo.processInfo.environment["BLOCKHAVEN_TIME"] ?? "") {
            sky.setTimeOfDay(start)
        }
        // Put the eye where the player is before any frame draws. Play moves
        // it every frame, but a screen open on the very first one — a pause,
        // a harness — would otherwise look out from the world's origin.
        camera.update(dt: 0, eyePosition: player.eyePosition, horizontalSpeed: 0, isGrounded: true)
        restored = nil
    }

    /// Builds the chunks immediately around spawn up front, then drops the
    /// player onto the surface.
    func primeSpawnChunks() {
        let center = playerChunk()
        for dz in -2...2 {
            for dx in -2...2 {
                world.forceGenerate(ChunkCoord(x: center.x + dx, z: center.z + dz))
            }
        }
        player.resolveSpawnOverlap(world: world)
    }

    func playerChunk() -> ChunkCoord {
        World.chunkCoord(forWorldX: Int(floor(player.position.x)), worldZ: Int(floor(player.position.z)))
    }
    /// `BLOCKHAVEN_BENCH_WALK=1` flies the player forward on a slow curve.
    ///
    /// Standing still is the one thing that does *not* exercise the code
    /// this game can stutter in: after the spawn flood nothing generates,
    /// nothing meshes and nothing unloads, so a frame log taken at rest
    /// measures an idle renderer. Flying covers about 0.7 chunks a second,
    /// which keeps generation, meshing and unloading all running for as
    /// long as the measurement lasts.
    /// `BLOCKHAVEN_BENCH_BLAST=1` stands the player back from the demo
    /// world's dynamite Burj Khalifa and lights it, then reports how long
    /// the tower took to come down with a renderer actually attached.
    ///
    /// The headless check measures the same collapse in simulated seconds,
    /// which is the honest number for "is the chain the right length" and
    /// exactly the wrong one for "does it feel slow": the simulation step is
    /// clamped, so a frame that runs long does not drop the collapse, it
    /// stretches it. This is the measurement that notices that.
    static let benchmarksBlast = ProcessInfo.processInfo.environment["BLOCKHAVEN_BENCH_BLAST"] == "1"
    var blastBenchTimer: Double = 0
    var blastBenchLit = false
    var blastBenchMoved = false
    var blastBenchElapsed: Double = 0
    var blastBenchReported = false

    func driveBenchmarkBlast(dt: Double) {
        guard !blastBenchReported else { return }

        if !blastBenchLit {
            blastBenchTimer += dt
            let site = DemoWorld.dynamiteBurjSite

            // Stand back from the tower first and give the streamer time to
            // bring it in. Scanning the moment the player arrives finds
            // nothing: an unloaded chunk reads as air, so the tower is not
            // there yet however solidly it is written in the journal.
            if !blastBenchMoved, blastBenchTimer >= 3 {
                player.position = Vector3(
                    CGFloat(site.x + 55), CGFloat(DemoWorld.deck + 2), CGFloat(site.z)
                )
                blastBenchMoved = true
                return
            }
            guard blastBenchMoved, blastBenchTimer >= 12 else { return }

            var lit = false
            search: for y in DemoWorld.deck...(Chunk.height - 1) {
                for dz in -28...28 {
                    for dx in -28...28
                    where world.block(worldX: site.x + dx, y: y, worldZ: site.z + dz) == .tnt {
                        fuses.light(
                            atX: site.x + dx, y: y, z: site.z + dz,
                            in: world, fuse: FuseManager.litFuse
                        )
                        lit = true
                        break search
                    }
                }
            }
            StandardError.write(
                Data("[blast-bench] \(lit ? "lit the tower" : "found no TNT to light")\n".utf8)
            )
            blastBenchLit = lit
            blastBenchReported = !lit
            return
        }

        blastBenchElapsed += dt
        guard fuses.primed.isEmpty else { return }
        blastBenchReported = true
        StandardError.write(
            Data("[blast-bench] tower down after \(String(format: "%.2f", blastBenchElapsed))s of simulated time\n".utf8)
        )
    }

    static let benchmarksWalk = ProcessInfo.processInfo.environment["BLOCKHAVEN_BENCH_WALK"] == "1"

    func driveBenchmarkWalk(_ input: inout InputSnapshot) {
        if !player.isFlying, mode.allowsFlight {
            player.isFlying = true
            player.velocity.y = 0
        }
        input.forwardDown = true
        // A slow curve rather than a straight line, so the ring of chunks
        // being loaded keeps changing shape instead of marching in one
        // direction the scheduler can get comfortable with.
        camera.applyLook(dx: 1.1, dy: 0, sensitivity: GameSettings.mouseSensitivity)
    }
    // MARK: - Play mode

    func updatePlay(dt: Double, input: InputSnapshot) {
        if input.lookDX != 0 || input.lookDY != 0 {
            camera.applyLook(dx: input.lookDX, dy: input.lookDY, sensitivity: GameSettings.mouseSensitivity)
        }

        // Hotbar selection: number keys are absolute, the wheel is relative
        // and wraps.
        if let slot = input.hotbarSelection {
            inventory.selectedHotbarSlot = slot - 1
        }
        if input.hotbarScroll != 0 {
            var next = (inventory.selectedHotbarSlot + input.hotbarScroll) % Inventory.hotbarSize
            if next < 0 { next += Inventory.hotbarSize }
            inventory.selectedHotbarSlot = next
        }
        if inventory.selectedHotbarSlot != lastSelectedSlot {
            lastSelectedSlot = inventory.selectedHotbarSlot
            if let name = inventory.heldItem?.displayName {
                itemNameToast = name
                itemNameTimer = 1.6
            }
        }

        if input.toggleFlyRequested, mode.allowsFlight {
            player.isFlying.toggle()
            if player.isFlying { player.velocity.y = 0 }
        }
        if input.jumpRequested, !player.isFlying {
            player.jump()
        }

        // Riding a cart suspends the player's own physics — they are not
        // walking, falling or colliding, and `updateMinecarts` puts them
        // wherever the cart went. Only the movement is skipped: the camera,
        // the mobs and the carts themselves all still have to run, which is
        // why this is a branch around one block rather than an early return
        // out of the frame.
        let riding = minecarts.ridingID != nil

        player.isSneaking = input.sneakDown
        player.isSprinting = input.sprintDown && input.forwardDown && !input.sneakDown

        let previousPosition = player.position
        let move = riding
            ? Vector3.zero
            : PlayerController.moveDirection(input: input, cameraYaw: camera.yaw)
        let fallDamage = riding ? 0 : player.step(
            dt: CGFloat(dt),
            moveDirection: move,
            // Q and E climb and drop alongside space and shift. Two pairs
            // rather than one because the hands that fly are not always the
            // hands that walk: space-and-shift is a thumb and a little
            // finger, Q-and-E is the two fingers already on W.
            wantsUp: input.jumpDown || input.flyUpDown,
            wantsDown: input.sneakDown || input.flyDownDown,
            world: world
        )
        // Creative simulates the same physics but nothing that can hurt
        // you, so health and hunger just stay where they started.
        if mode.hasSurvivalStats {
            if fallDamage > 0 {
                stats.takeDamage(fallDamage, mitigable: true)
                damageFlashTimer = 0.35
            }

            let travelled = Double((player.position - previousPosition).length())
            let previousHealth = stats.health
            stats.update(
                dt: dt,
                distanceMoved: player.isFlying ? 0 : travelled,
                isSprinting: player.isSprinting,
                isSubmerged: player.isSubmerged,
                isInLava: player.isInLava
            )
            if stats.health < previousHealth { damageFlashTimer = 0.35 }
            if stats.isDead { respawn() }
        }

        camera.update(
            dt: dt,
            eyePosition: player.eyePosition,
            horizontalSpeed: player.horizontalSpeed,
            isGrounded: player.isGrounded
        )

        updateTargeting(dt: dt, input: input)
        FrameProfiler.measure(.mobs) {
            updateFizzlers(dt: dt)
            updateSkeletons(dt: dt)
            updateFuses(dt: dt)
            updateMinecarts(dt: dt, input: input)
            updateAnimals(dt: dt)
            updateFurnaces(dt: dt)
            updateCrops(dt: dt)
            updateHoppers(dt: dt)
            updatePressurePlates()
            updateDetectorRails()
            updateSignalTorches(dt: dt)
            updateDaylightSensors()
            updateSaplings(dt: dt)
            updateThermal(dt: dt)
            updateGravity(dt: dt)
            world.disturbance.tick(dt: dt)
        }
    }

    /// Checks every known plate against where the player actually is,
    /// every frame — the one signal source that cannot wait for a block
    /// edit to tell the network something changed, because nothing edited
    /// a block; a player just walked. The flood fill this can trigger
    /// still only runs on an actual press or release, not every frame —
    /// see `SignalNetwork.updatePlates`.
    func updatePressurePlates() {
        guard !signals.plateCells.isEmpty else { return }
        signals.updatePlates(world: world, fuses: fuses) { key in
            OccupancyQuery.isOccupied(
                cell: key,
                player: player,
                fizzlers: fizzlers,
                skeletons: skeletons,
                animals: animals
            )
        }
    }

    /// The same poll as `updatePressurePlates`, run against every detector
    /// rail instead of every plate: a cart arriving or leaving is the
    /// signal, and `minecarts.cartID(at:)` is the same cheap lookup a
    /// hopper already makes to ask "is a cart parked here."
    func updateDetectorRails() {
        guard !signals.detectorCells.isEmpty else { return }
        signals.updateDetectors(world: world, fuses: fuses) { key in
            minecarts.cartID(at: (key.x, key.y, key.z)) != nil
        }
    }

    /// A signal torch has nothing outside itself to poll — no foot, no
    /// cart, just whichever way `isPowered` currently reads its own
    /// neighbours — so this is the one of the four that never needs a
    /// caller-supplied predicate, only a clock to pace it.
    func updateSignalTorches(dt: Double) {
        signals.updateTorches(world: world, fuses: fuses, dt: dt)
    }

    /// Updates daylight sensors against the current solar elevation and sky openness.
    func updateDaylightSensors() {
        guard !signals.daylightSensorCells.isEmpty else { return }
        signals.updateDaylightSensors(world: world, timeOfDay: sky.timeOfDay, fuses: fuses)
    }

    /// Counts every hopper's cooldown down, and spends it on one transfer
    /// each time it lands — the store keeps the clock, `HopperStore.transfer`
    /// is the only place that ever moves an item because of it, and this is
    /// only the loop that calls it once per hopper per landed interval.
    ///
    /// A powered hopper holds its cooldown at zero instead of counting it
    /// down, so the instant a lever cuts power the very next frame's
    /// landed check fires immediately rather than waiting out whatever was
    /// left of an interval it was never allowed to spend. This is the one
    /// thing wire reaches beyond a door and a stick of TNT: a valve on a
    /// belt, which is what turns a line of hoppers into something a player
    /// can actually batch, gate or sort rather than a pipe that only ever
    /// runs.
    func updateHoppers(dt: Double) {
        for key in Array(hoppers.cooldown.keys) {
            let remaining = (hoppers.cooldown[key] ?? 0) - dt
            guard remaining <= 0 else {
                hoppers.setCooldown(remaining, at: key)
                continue
            }
            guard !signals.isPowered(at: SignalNetwork.Key(key.x, key.y, key.z)) else {
                hoppers.setCooldown(0, at: key)
                continue
            }
            let moved = HopperStore.transfer(
                at: key,
                world: world,
                chests: chests,
                furnaces: furnaces,
                minecarts: &minecarts,
                hoppers: hoppers,
                direction: hoppers.facing(at: key),
                signals: signals
            )
            // Only a hopper that actually passed something along is making
            // any noise. This used to fire on every tick of every hopper,
            // so a deliberately locked bank — or one with nothing to carry
            // — still pumped threat into the chunk it sat in.
            if moved {
                world.recordDisturbance(
                    atWorldX: key.x,
                    worldZ: key.z,
                    amount: DisturbanceTracker.hopperTransferCost,
                    ceiling: DisturbanceTracker.machineryCeiling
                )
            }
            hoppers.setCooldown(HopperStore.transferInterval, at: key)
        }
    }

    /// Grows every tracked planting one frame's worth of daylight, and
    /// advances the block itself wherever `CropStore` says a stage ripened
    /// — the same split as `updateFurnaces`: the store keeps the clock,
    /// this is the only place that ever writes the world.
    func updateCrops(dt: Double) {
        for key in crops.tick(dt: dt, world: world, isRaining: sky.isRaining) {
            let current = world.block(worldX: key.x, y: key.y, worldZ: key.z)
            guard current.isCrop, current != .wheatStage3,
                  let next = BlockType(rawValue: current.rawValue + 1) else { continue }
            world.setBlock(worldX: key.x, y: key.y, worldZ: key.z, to: next)
        }
    }

    /// Grows every tracked sapling one frame's worth of daylight, and where
    /// `SaplingStore` says one matured, replaces it with a real tree — the
    /// same split `updateCrops` uses: the store keeps the clock, this is
    /// the only place that ever touches the world.
    func updateSaplings(dt: Double) {
        for key in saplings.tick(dt: dt, world: world, isRaining: sky.isRaining) {
            growTree(at: key)
        }
    }

    /// Turns one matured sapling into the tree its species builds, asking
    /// `WorldGenerator` for exactly the blocks a wild tree of that shape
    /// would have — the same builder chunk generation itself calls, so a
    /// grown sapling is never a second, different description of a canopy.
    ///
    /// Only ever writes into air or another tree's own leaves: a sapling
    /// planted hard against a wall or under a low roof grows into whatever
    /// room it actually finds rather than erasing what a player built
    /// around it.
    func growTree(at key: SaplingStore.Key) {
        let current = world.block(worldX: key.x, y: key.y, worldZ: key.z)
        guard current.isSapling else { return }
        let species: WorldGenerator.TreeSpecies = current == .birchSapling ? .birch
            : current == .spruceSapling ? .spruce : .oak
        world.setBlock(worldX: key.x, y: key.y, worldZ: key.z, to: .air)
        for placement in world.generator.treeBlocks(
            atX: key.x, groundY: key.y - 1, z: key.z, species: species
        ) {
            let target = world.block(worldX: placement.x, y: placement.y, worldZ: placement.z)
            guard target == .air || target.isLeaf else { continue }
            world.setBlock(worldX: placement.x, y: placement.y, worldZ: placement.z, to: placement.block)
        }
    }

    /// Ticks thermal dynamics (freezing/melting) periodically across chunks loaded around the player.
    func updateThermal(dt: Double) {
        thermalTickAccumulator += dt
        guard thermalTickAccumulator >= GameSession.thermalInterval else { return }
        thermalTickAccumulator = 0
        let center = World.chunkCoord(forWorldX: Int(player.position.x), worldZ: Int(player.position.z))
        for dz in -2...2 {
            for dx in -2...2 {
                world.randomTickThermal(in: ChunkCoord(x: center.x + dx, z: center.z + dz), samples: 16)
            }
        }
    }

    /// Ticks granular falling gravity periodically across chunks loaded around the player.
    func updateGravity(dt: Double) {
        gravityTickAccumulator += dt
        guard gravityTickAccumulator >= GameSession.gravityInterval else { return }
        gravityTickAccumulator = 0
        let center = World.chunkCoord(forWorldX: Int(player.position.x), worldZ: Int(player.position.z))
        for dz in -2...2 {
            for dx in -2...2 {
                world.randomTickGravity(in: ChunkCoord(x: center.x + dx, z: center.z + dz), samples: 8)
            }
        }
    }

    /// Burns every furnace's fire down: catches new fuel, cooks whatever
    /// ore is waiting, and — the one thing a player watching from across
    /// the room can actually see — swaps the block between `furnace` and
    /// `furnaceLit` exactly when the fire catches or goes out.
    func updateFurnaces(dt: Double) {
        // Burning furnaces are tallied per chunk and recorded once at the
        // end, because how loud a chunk's machinery is allowed to get scales
        // with how many machines are running — and a call made from inside
        // this loop can only ever speak for one of them.
        var burning: [ChunkCoord: (count: Int, x: Int, z: Int)] = [:]
        for (key, var state) in furnaces.furnaces {
            let litChanged = state.tick(dt: dt)
            furnaces.set(state, at: key)
            if state.isBurning {
                let coord = World.chunkCoord(forWorldX: key.x, worldZ: key.z)
                if let seen = burning[coord] {
                    burning[coord] = (count: seen.count + 1, x: seen.x, z: seen.z)
                } else {
                    burning[coord] = (count: 1, x: key.x, z: key.z)
                }
            }
            guard litChanged else { continue }
            let current = world.block(worldX: key.x, y: key.y, worldZ: key.z)
            guard current == .furnace || current == .furnaceLit else { continue }
            world.setBlock(
                worldX: key.x, y: key.y, worldZ: key.z,
                to: state.isBurning ? .furnaceLit : .furnace
            )
        }

        for (_, site) in burning {
            world.recordDisturbance(
                atWorldX: site.x,
                worldZ: site.z,
                amount: DisturbanceTracker.furnaceBurnRate * dt * Double(site.count),
                ceiling: DisturbanceTracker.machineryCeiling * Double(site.count)
            )
        }
    }

    /// Applies what a settle did to whoever was standing under it, and
    /// hands back the scenery it crushed on the way down.
    ///
    /// Three call sites carried a verbatim copy of the damage half — a
    /// blast, a shaped block pulled out from under a pile, and a granular
    /// block placed by hand — which is three places to edit the day a
    /// settle grows a fourth consequence. It grew one here.
    func applySettle(_ result: GranularTick.SettleResult) {
        if !result.moves.isEmpty {
            var statsOpt: PlayerStats? = mode.hasSurvivalStats ? stats : nil
            var fizzlersOpt: FizzlerManager? = fizzlers
            var skeletonsOpt: SkeletonManager? = skeletons
            var animalsOpt: AnimalManager? = animals
            _ = GranularTick.applyCrushingDamage(
                moves: result.moves,
                player: player,
                playerStats: &statsOpt,
                fizzlers: &fizzlersOpt,
                skeletons: &skeletonsOpt,
                animals: &animalsOpt
            )
            if let s = statsOpt { stats = s }
            if let c = fizzlersOpt { fizzlers = c }
            if let sk = skeletonsOpt { skeletons = sk }
            if let a = animalsOpt { animals = a }
        }

        // Rails, wire, levers, plates and flowers a fall went through come
        // back instead of vanishing. Only from here, where a player did the
        // thing that started the fall: the ambient tick settles columns
        // nobody is standing near, and a rail appearing in your bag from
        // across the world would read worse than the rail being gone.
        guard mode.collectsDrops else { return }
        for wreck in result.destroyed {
            guard let drop = wreck.block.drop else { continue }
            inventory.add(ItemStack(drop, count: 1))
        }
    }

    /// What an explosion does to the player and the camera, whoever set it
    /// off. The blast itself has already rewritten the blocks and the world
    /// has already marked the chunks; this is the half that is felt.
    func applyExplosion(_ explosion: FizzlerManager.Explosion) {
        if explosion.playerDamage > 0, mode.hasSurvivalStats {
            stats.takeDamage(explosion.playerDamage, mitigable: true)
            damageFlashTimer = 0.55
        }
        camera.addShake(0.55)
        world.recordDisturbance(
            atWorldX: Int(explosion.centre.x),
            worldZ: Int(explosion.centre.z),
            amount: DisturbanceTracker.explosionPulse
        )
        let radius = Int(ceil(FuseManager.blastRadius)) + 1
        let settleRes = world.settleGranular(
            around: (Int(explosion.centre.x), Int(explosion.centre.y), Int(explosion.centre.z)),
            radius: radius
        )
        applySettle(settleRes)
    }

    /// The world bookkeeping a blast leaves behind: stores whose block is
    /// gone, and a signal network that has to be re-read.
    ///
    /// Every one of these walks a whole store or floods the whole network,
    /// and not one of them depends on *which* blast ran — so this runs once
    /// for the frame rather than once per explosion. That distinction is the
    /// difference between the demo world's dynamite Burj Khalifa falling
    /// over and appearing to hang: it goes off in twenty thousand blasts,
    /// several hundred of them in a single frame, and re-flooding every
    /// signal source in the world that many times per frame drove the frame
    /// long enough that the clamped simulation step ran the collapse in slow
    /// motion.
    func sweepAfterExplosions() {
        // A blast takes whole cells at once and never goes through
        // `breakBlock`, so the chests it destroyed are swept up here
        // instead. Left alone, the next chest placed on that cell would
        // open full of somebody else's things.
        chests.prune { world.block(worldX: $0.x, y: $0.y, worldZ: $0.z) != .chest }
        furnaces.prune { key in
            let block = world.block(worldX: key.x, y: key.y, worldZ: key.z)
            return block != .furnace && block != .furnaceLit
        }
        signals.prune(world: world)
        // A blast can open a gap in a run of wire or take out a lever
        // outright; either way what is still standing has to be
        // re-evaluated rather than left showing whatever it lit before.
        signals.recompute(world: world, fuses: fuses)
        crops.prune { key in !world.block(worldX: key.x, y: key.y, worldZ: key.z).isCrop }
        saplings.prune { key in !world.block(worldX: key.x, y: key.y, worldZ: key.z).isSapling }
        hoppers.prune { key in world.block(worldX: key.x, y: key.y, worldZ: key.z) != .hopper }
    }

    /// Burns down every lit fuse. Separate from the fizzlers because TNT
    /// goes off in worlds with no fizzlers in them — creative, and the demo
    /// world — and because a chain has to keep running after the fizzler
    /// that started it is gone.
    func updateFuses(dt: Double) {
        let explosions = fuses.update(dt: dt, world: world, playerEye: player.eyePosition)
        for explosion in explosions { applyExplosion(explosion) }
        if !explosions.isEmpty { sweepAfterExplosions() }
    }

    /// Steps the fizzler population and reflects it into the scene.
    func updateFizzlers(dt: Double) {
        let explosions = fizzlers.update(
            dt: dt,
            playerEye: player.eyePosition,
            // Fizzlers ignore a creative player entirely, so they never
            // light a fuse at someone who can't be hurt.
            playerIsTargetable: mode.hasSurvivalStats,
            isNight: sky.isNight,
            isRaining: sky.isRaining,
            world: world
        )

        for explosion in explosions {
            // A fizzler that went off beside a stack of dynamite lights it.
            fuses.lightChain(explosion.ignited, in: world)
            applyExplosion(explosion)
        }
        if !explosions.isEmpty { sweepAfterExplosions() }

    }


    /// Steps the skeleton population and reflects it into the scene. Same
    /// shape as `updateFizzlers`, minus the blast: a landed shot is just
    /// player damage and a flash, not a crater and a chain to light.
    func updateSkeletons(dt: Double) {
        let shots = skeletons.update(
            dt: dt,
            playerEye: player.eyePosition,
            playerIsTargetable: mode.hasSurvivalStats,
            isNight: sky.isNight,
            isRaining: sky.isRaining,
            world: world
        )

        for shot in shots {
            guard mode.hasSurvivalStats else { continue }
            stats.takeDamage(shot.damage, mitigable: true)
            // Lighter than an explosion's flash — an arrow is chip damage,
            // not the reason to reach for the door.
            damageFlashTimer = 0.35
        }

    }


    /// Rolls every cart, and carries the player along when they are in one.
    func updateMinecarts(dt: Double, input: InputSnapshot) {
        // The rider's own throttle. The same keys that would walk them
        // along if they were on their feet, since walking is what they are
        // trying to do and the cart is what happens instead.
        let throttle: CGFloat = (input.forwardDown ? 1 : 0) - (input.backDown ? 1 : 0)
        minecarts.drive(throttle: throttle, cameraYaw: camera.yaw, dt: dt)

        if let seat = minecarts.update(dt: dt, world: world) {
            // The rider goes wherever the cart went. Their own physics are
            // not run at all while they are aboard — a cart is on rails and
            // the player in it is not falling, walking or colliding.
            player.recall(to: seat)
        }
    }


    /// Steps the animal population and reflects it into the scene, then
    /// lands whatever a defending wolf actually bit — the same
    /// `fizzlers.damage`/`skeletons.damage` entry points the player's own
    /// sword already calls in `swingAt`, on a wolf's own bite instead of a
    /// swing. A fizzler a wolf brings down pays out gunpowder exactly as
    /// one the player killed directly would; a skeleton pays out nothing,
    /// matching `swingAt`'s own discarded result for one.
    ///
    /// A bitten skeleton bites back — the same distance-scaled
    /// `SkeletonManager.shotDamage` an arrow costs the player, not the flat
    /// `Skeleton.shotDamage` constant underneath it, or a wolf sent after a
    /// skeleton four spires out would take exactly the same retaliation a
    /// wolf at spawn does while the player standing beside it takes far
    /// more from the identical skeleton's arrows — the "distance costs
    /// more" rule iteration 39 built and iteration 43 extended to loot,
    /// silently not extended to a pet's own risk. A fizzler never
    /// retaliates: its only weapon is a fuse timed and centred on the
    /// player specifically, and giving it a second target is a bigger
    /// change than "a dog that fights can also lose." Sending a wolf after
    /// a skeleton is a real wager now, not a free kill — the fight was
    /// already lost for the wolf's owner before this, since nothing could
    /// turn on it.
    func updateAnimals(dt: Double) {
        let threats = fizzlers.fizzlers.filter { !$0.value.isDead }.map {
            AnimalManager.Threat(id: $0.key, isFizzler: true, position: $0.value.position)
        } + skeletons.skeletons.filter { !$0.value.isDead }.map {
            AnimalManager.Threat(id: $0.key, isFizzler: false, position: $0.value.position)
        }
        let bitten = animals.update(dt: dt, playerEye: player.eyePosition, world: world, threats: threats)
        for bite in bitten {
            let threat = bite.threat
            let knockback = Vector3.zero
            if threat.isFizzler {
                let killed = fizzlers.damage(id: threat.id, amount: Animal.biteDamage, knockback: knockback)
                if killed, mode.collectsDrops { inventory.add(ItemStack(.gunpowder, count: 1)) }
            } else {
                _ = skeletons.damage(id: threat.id, amount: Animal.biteDamage, knockback: knockback)
                let distanceFromSpawn = (player.eyePosition - world.spawnPosition()).length()
                let retaliation = SkeletonManager.shotDamage(distanceFromSpawn: distanceFromSpawn)
                _ = animals.damage(id: bite.wolfID, amount: retaliation, knockback: knockback)
            }
        }
    }


    /// Raycast from the eye, then drive attacking / mining / placing /
    /// interacting off whatever it found.
    func updateTargeting(dt: Double, input: InputSnapshot) {
        attackCooldown = max(0, attackCooldown - dt)

        let hit = VoxelRaycast.cast(
            from: player.eyePosition,
            direction: camera.lookDirection,
            maxDistance: GameSession.reach,
            world: world
        )

        // A mob standing in front of the block takes the swing instead. Only
        // worth casting for while the button is actually down.
        let attacking = input.attackDown && input.pointerCaptured
        var mobHit: MobRayHit?
        if attacking {
            mobHit = MobRaycast.cast(
                from: player.eyePosition,
                direction: camera.lookDirection,
                maxDistance: hit?.distance ?? GameSession.reach,
                targets: mobTargets()
            )
        }

        // Pre-warm: the block being mined is about to be gone, and removing
        // it exposes whatever was behind it — faces the classifier called
        // buried. Asking for that chunk's hidden half now gets it built on
        // the mesh queue, about half a millisecond, while the player is
        // still holding the button. It costs nothing to ask twice; `reveal`
        // is a set insert after the first time.
        //
        // What this is *not* is the thing that keeps creative mode's flat
        // 0.05 s mining from showing the gap. `World.setBlock` reveals the
        // chunk it writes to and marks it urgent, `updatePlay` runs before
        // `streamChunks` in the same tick, and `urgentChunksToMesh` is the
        // first thing `streamChunks` does — so the break frame rebuilds the
        // mined chunk with `.all` before anything is drawn, pre-warm or no
        // pre-warm. That rebuild is what closes the gap.
        //
        // The pre-warm is the hedge for the frames where it does not. Once
        // the break lands the chunk is dirty, and `chunksNeedingBuried`
        // deliberately skips dirty chunks — from that moment the only route
        // to the hidden half is the full rebuild. If the urgent pass is
        // already spending its budget of four on other edits, a fizzler
        // crater being the way that happens, the rebuild slips to
        // `chunksReadyToMesh` and arrives a frame or two later; a chunk
        // warmed while it was still clean is already drawing its hidden half
        // by then. Ordinary mining never gets there: `BLOCKHAVEN_BENCH_MINE=5`
        // measures 1.38 urgent rebuilds per break against a budget of 4.
        //
        // Gated on the button being held, not on the raycast hitting
        // something. Pointing at a block is what a player does every frame
        // they are walking — the crosshair sits on the ground — and reveal
        // is sticky until the chunk unloads, so firing on the bare hit
        // revealed chunk after chunk for nothing and gave the culling back a
        // chunk at a time. Holding the button leaves the warm enough room to
        // land — 0.05 s is five frames at 100 Hz, the build is one of them
        // and runs off the frame at four chunks a frame, and survival mining
        // is seconds rather than frames — and nothing is broken if it does
        // not, per the paragraph above.
        if attacking, let hit {
            world.reveal(World.chunkCoord(forWorldX: hit.blockX, worldZ: hit.blockZ))
        }

        let target = hit.map { (x: $0.blockX, y: $0.blockY, z: $0.blockZ) }
        let broke = mining.update(
            dt: dt,
            target: target,
            block: hit?.block,
            tool: inventory.heldItem,
            // Passing false here resets the mining progress, which is what
            // stops the player chewing through a block by aiming at the
            // fizzler standing in front of it.
            isMining: attacking && mobHit == nil,
            fixedTime: mode.fixedMiningTime
        )

        if let mobHit { swingAt(mobHit) }
        if broke, let hit { breakBlock(hit) }
        if input.useRequested { use(hit) }
        if input.pickBlockRequested, let hit { pickBlock(hit) }

        highlightTarget = target
    }

    /// Every mob the swing could land on, fizzlers, animals and skeletons in
    /// one list so a single cast picks whichever of them is actually
    /// nearest.
    func mobTargets() -> [MobRayTarget] {
        var targets = fizzlers.fizzlers.filter { !$0.value.isDead }.map {
            MobRayTarget(
                id: $0.key,
                position: $0.value.position,
                halfWidth: Fizzler.halfWidth,
                height: Fizzler.height
            )
        }
        targets.append(contentsOf: animals.animals.filter { !$0.value.isDead }.map {
            MobRayTarget(
                id: $0.key + GameSession.animalIDBase,
                position: $0.value.position,
                halfWidth: $0.value.kind.halfWidth,
                height: $0.value.kind.height
            )
        })
        targets.append(contentsOf: skeletons.skeletons.filter { !$0.value.isDead }.map {
            MobRayTarget(
                id: $0.key + GameSession.skeletonIDBase,
                position: $0.value.position,
                halfWidth: Skeleton.halfWidth,
                height: Skeleton.height
            )
        })
        return targets
    }

    /// Lands one melee hit, on the cooldown rather than every frame the
    /// button is held.
    func swingAt(_ mob: MobRayHit) {
        guard attackCooldown <= 0 else { return }
        attackCooldown = GameSession.attackInterval

        // Knockback runs along the flattened look direction, so a hit shoves
        // the mob away from the player rather than into the ground.
        let look = camera.lookDirection
        let knockback = Vector3(look.x, 0, look.z)
        let damage = swingDamage()

        // A landed blow wears the sword — and only the sword. Swinging a
        // pickaxe at a pig is not what a pickaxe is for, and charging the
        // player for it would make the tool they need for stone the thing
        // they lost to a chicken.
        if inventory.heldItem?.toolClass == .sword { wearHeldTool() }

        if mob.id >= GameSession.skeletonIDBase {
            let id = mob.id - GameSession.skeletonIDBase
            _ = skeletons.damage(id: id, amount: damage, knockback: knockback)
            return
        }

        if mob.id >= GameSession.animalIDBase {
            let id = mob.id - GameSession.animalIDBase
            guard let kind = animals.damage(id: id, amount: damage, knockback: knockback) else { return }
            grantDrops(for: kind)
            return
        }

        let killed = fizzlers.damage(id: mob.id, amount: damage, knockback: knockback)
        guard killed, mode.collectsDrops else { return }
        inventory.add(ItemStack(.gunpowder, count: 1))
    }

    /// What a killed animal leaves behind. Creative has every item on tap
    /// already, so drops are survival-only, exactly as block drops are.
    func grantDrops(for kind: AnimalKind) {
        guard mode.collectsDrops else { return }
        switch kind {
        case .pig:
            inventory.add(ItemStack(.porkchop, count: Int.random(in: 1...2, using: &dropRNG)))
        case .cow:
            inventory.add(ItemStack(.beef, count: Int.random(in: 1...2, using: &dropRNG)))
        case .sheep:
            inventory.add(ItemStack(.mutton, count: 1))
            inventory.add(ItemStack(.wool, count: 1))
        case .chicken:
            inventory.add(ItemStack(.chicken, count: 1))
            inventory.add(ItemStack(.feather, count: Int.random(in: 1...2, using: &dropRNG)))
        case .cod:
            inventory.add(ItemStack(.rawCod, count: 1))
        case .squid:
            inventory.add(ItemStack(.inkSac, count: Int.random(in: 1...2, using: &dropRNG)))
        case .axolotl, .wolf:
            // Nothing. Neither is livestock, and a pet that pays out when
            // you kill it is a pet somebody will test that on.
            break
        }
    }

    /// Spends a use of whatever is in hand, in the mode where that is a
    /// rule. A tool that runs out says so: it leaves the hand mid-job, and
    /// a hotbar slot that silently emptied is a player wondering what they
    /// did wrong.
    func wearHeldTool() {
        guard mode.wearsTools else { return }
        let held = inventory.heldStack
        guard let broken = inventory.wearHeldTool() else {
            // Five uses left, once. Sooner is a warning nobody acts on;
            // later is a warning that arrives with the tool already gone.
            //
            // Swedish names an item after the noun rather than in front of
            // it here, because "your" would have to agree with a gender
            // this game does not record — "ditt träsvärd" but "din
            // stenhacka" — and a line that is wrong half the time is worse
            // than one that is plain.
            if let held, let left = held.usesLeft, left == 6 {
                showToast(L10n.t(
                    "Your \(held.type.displayName.lowercased()) is nearly worn out",
                    "Verktyget är nästan utslitet: \(held.type.displayName.lowercased())"
                ), seconds: 3)
            }
            return
        }
        showToast(L10n.t(
            "Your \(broken.displayName.lowercased()) broke",
            "Verktyget gick sönder: \(broken.displayName.lowercased())"
        ), seconds: 3)
    }

    /// Half-hearts per swing. Only swords count as weapons — swinging a
    /// pickaxe at a fizzler is swinging a fist with extra steps.
    func swingDamage() -> Int {
        guard let item = inventory.heldItem, item.toolClass == .sword else { return 1 }
        switch item.toolTier {
        case .hand, .wood: return 4
        case .stone: return 5
        case .iron: return 6
        case .diamond: return 7
        }
    }

    func breakBlock(_ hit: VoxelRayHit) {
        // Breaking anything while holding a blueprint that already carries
        // a captured shape discards that shape instead of the block aimed
        // at — the only way to let go of one copy and mark a different
        // structure, since right-click on this tool is already spoken for
        // by marking and stamping.
        if inventory.heldItem == .blueprint, blueprintCapture != nil {
            blueprintCapture = nil
            showToast(L10n.t("Blueprint cleared", "Ritning rensad"), seconds: 3)
            return
        }

        // A box is waiting from a mason's line, and this is an ordinary
        // break — the same reversal a placement already gets, mirrored: it
        // clears the whole box instead of the one cell it would otherwise
        // take. `isBulkFillable` is the same guard the fill side uses, so a
        // mark spanning a stocked chest or a live wire clears neither by
        // accident — a chest keeps what a player put in it even when the
        // box around it doesn't survive. Costs the held tool one use per
        // cell, same as breaking each one by hand would, and stops the
        // moment the tool would rather than clearing on credit.
        if let region = masonRegion {
            let tier = inventory.heldItem?.toolTier ?? .hand
            let availableUses = mode.wearsTools
                ? (inventory.heldStack?.usesLeft ?? RegionFill.maxVolume)
                : RegionFill.maxVolume
            var signalTouched = false
            let cleared = RegionFill.clear(
                region, world: world,
                playerOverlaps: { [player] x, y, z in player.overlaps(blockX: x, y: y, z: z) },
                availableUses: availableUses
            ) { cleared, x, y, z in
                if cleared.isWire || cleared.isSignalRelay { signalTouched = true }
                if cleared.isSignalTorch {
                    signals.torchRemoved(at: SignalNetwork.Key(x, y, z))
                    signalTouched = true
                }
                if mode.collectsDrops, let drop = cleared.drop,
                   !(cleared.requiresTool && tier < cleared.minimumTier) {
                    inventory.add(ItemStack(drop, count: 1))
                }
            }
            for _ in 0..<cleared { wearHeldTool() }
            if signalTouched { signals.recompute(world: world, fuses: fuses) }
            showToast(
                cleared > 0
                    ? L10n.t("Cleared \(cleared) blocks", "Rensade \(cleared) block")
                    : L10n.t("Nothing to clear", "Inget att rensa"),
                seconds: 3
            )
            masonRegion = nil
            return
        }

        let block = hit.block
        // A chest goes back into the bag with everything in it. If it
        // won't all fit, the chest stays standing and says so: a container
        // that empties itself into thin air is the one way this game could
        // lose something a player deliberately put somewhere.
        if block == .chest {
            let key = ChestStore.Key(hit.blockX, hit.blockY, hit.blockZ)
            // A ruin's chest is stocked the first time anything touches
            // it, opened or broken outright — breaking it unopened is the
            // obvious thing to do with a chest you mean to keep, and it
            // must not be the one way to walk off with nothing.
            let chest = stockedChest(at: key)
            if !chest.isEmpty {
                guard freeInventorySlots() >= chest.contents.count + 1 else {
                    showToast(L10n.t(
                        "Empty the chest first \u{2014} your bag is full",
                        "Töm kistan först \u{2014} ditt förråd är fullt"
                    ), seconds: 3)
                    return
                }
                for stack in chest.contents { inventory.add(stack) }
            }
            chests.remove(at: key)
            // Creative collects no drops, so the chest itself is handed
            // back only in survival — the palette has another one.
            world.setBlock(worldX: hit.blockX, y: hit.blockY, worldZ: hit.blockZ, to: .air)
            if mode.collectsDrops { inventory.add(ItemStack(.chest, count: 1)) }
            wearHeldTool()
            return
        }
        // A furnace gives back whatever was in it, the same promise the
        // chest makes and for the same reason: ore, fuel and a half-smelted
        // batch are all things a player put there on purpose.
        if block == .furnace || block == .furnaceLit {
            let key = FurnaceStore.Key(hit.blockX, hit.blockY, hit.blockZ)
            let state = furnaces.state(at: key)
            var contents: [ItemStack] = []
            if let ore = state.oreType, state.oreCount > 0 { contents.append(ItemStack(ore, count: state.oreCount)) }
            if let fuel = state.fuelType, state.fuelCount > 0 { contents.append(ItemStack(fuel, count: state.fuelCount)) }
            if let output = state.outputType, state.outputCount > 0 {
                contents.append(ItemStack(output, count: state.outputCount))
            }
            guard freeInventorySlots() >= contents.count + 1 else {
                showToast(L10n.t(
                    "Empty the furnace first \u{2014} your bag is full",
                    "Töm ugnen först \u{2014} ditt förråd är fullt"
                ), seconds: 3)
                return
            }
            for stack in contents { inventory.add(stack) }
            furnaces.remove(at: key)
            world.setBlock(worldX: hit.blockX, y: hit.blockY, worldZ: hit.blockZ, to: .air)
            if mode.collectsDrops { inventory.add(ItemStack(.furnace, count: 1)) }
            wearHeldTool()
            return
        }
        // A door or a bed is one object in two cells: breaking either half
        // takes both, back to back through the ordinary edit path, and
        // still yields the single item it was placed from. Leaving the
        // other half behind would leave a floating door top nothing could
        // be done with.
        for cell in ShapedPlacement.removalCells(
            of: block, at: (x: hit.blockX, y: hit.blockY, z: hit.blockZ), world: world
        ) {
            world.setBlock(worldX: cell.x, y: cell.y, worldZ: cell.z, to: .air)
            if cell.y + 1 < Chunk.height && world.block(worldX: cell.x, y: cell.y + 1, worldZ: cell.z).hasGravity {
                let settleRes = world.settleGranular(atWorldX: cell.x, y: cell.y, worldZ: cell.z)
                applySettle(settleRes)
            }
        }

        // Pulling a rail out of the middle of a line leaves the two ends
        // pointing at a gap. Re-resolving turns them into the stubs they
        // now are, which is both correct and the visible cue that the track
        // is broken there.
        if block.isRail {
            RailNetwork.refresh(
                around: (x: hit.blockX, y: hit.blockY, z: hit.blockZ),
                preferring: ShapedPlacement.facing(fromYaw: camera.yaw), in: world
            )
            // A booster taken out was the whole reason a wired stretch of
            // track was inert-or-not; whatever the network still reaches
            // has to be told it is gone.
            if block.isBooster { signals.recompute(world: world, fuses: fuses) }
        }

        // A lever, a plate or a detector rail taken out stops being a
        // source; a wire taken out may have cut off whatever was still
        // reaching past it. Either way the network downstream has to be
        // told, not left showing power it no longer has.
        if block.isLever || block.isWire || block.isPressurePlate || block.isDetectorRail
            || block.isSignalTorch || block.isSignalRelay
            || block == .daylightSensor || block == .signalLamp || block == .signalLampLit {
            if block.isLever {
                signals.leverRemoved(at: SignalNetwork.Key(hit.blockX, hit.blockY, hit.blockZ))
            } else if block.isPressurePlate {
                signals.plateRemoved(at: SignalNetwork.Key(hit.blockX, hit.blockY, hit.blockZ))
            } else if block.isDetectorRail {
                signals.detectorRemoved(at: SignalNetwork.Key(hit.blockX, hit.blockY, hit.blockZ))
            } else if block.isSignalTorch {
                signals.torchRemoved(at: SignalNetwork.Key(hit.blockX, hit.blockY, hit.blockZ))
            } else if block == .daylightSensor {
                signals.daylightSensorRemoved(at: SignalNetwork.Key(hit.blockX, hit.blockY, hit.blockZ))
            } else if block == .signalLamp || block == .signalLampLit {
                signals.lampRemoved(at: SignalNetwork.Key(hit.blockX, hit.blockY, hit.blockZ))
            }
            signals.recompute(world: world, fuses: fuses)
        }

        // A crop taken out — ripe or not — stops ticking toward anything.
        if block.isCrop {
            crops.remove(at: CropStore.Key(hit.blockX, hit.blockY, hit.blockZ))
        }

        // A sapling taken out stops growing — there is nothing half-grown
        // to lose, the same as a crop before its first stage.
        if block.isSapling {
            saplings.remove(at: SaplingStore.Key(hit.blockX, hit.blockY, hit.blockZ))
        }

        // A hopper taken out stops pulling and pushing, and hands back
        // whatever was still in its buffer. That buffer is invisible — a
        // hopper pointed at a full chest sits on one item indefinitely with
        // nothing on screen to say so — so breaking it used to destroy a
        // stack the player had no way of knowing was in there.
        if block == .hopper {
            let buffered = hoppers.hopperRemoved(at: HopperStore.Key(hit.blockX, hit.blockY, hit.blockZ))
            if mode.collectsDrops, let buffered, buffered.count > 0 {
                inventory.add(buffered)
            }
        }

        // Every block broken costs the tool in your hand one of its uses.
        // Bare hands cost nothing, which is the whole reason the ladder
        // has a bottom rung: you can always mine dirt, and you cannot
        // always mine stone.
        wearHeldTool()
        world.recordDisturbance(
            atWorldX: hit.blockX,
            worldZ: hit.blockZ,
            amount: DisturbanceTracker.blockBreakCost
        )

        // Leaves are almost nothing to break, but not quite nothing: this
        // is the one chance the whole game gives to walk away from a
        // felled tree with the seed of another one. `block.drop` stays nil
        // for leaves — a pure fact about a block type has no way to roll
        // dice — so the chance is taken here, off the same `dropRNG` an
        // animal's own loot count already uses.
        if mode.collectsDrops, block.isLeaf,
           Double.random(in: 0..<1, using: &dropRNG) < GameSession.saplingDropChance {
            let sapling: ItemType = block == .birchLeaves ? .birchSapling
                : block == .spruceLeaves ? .spruceSapling : .sapling
            inventory.add(ItemStack(sapling, count: 1))
        }

        // Creative already has every block on tap, so breaking one just
        // removes it. In survival, drops respect the tool requirement:
        // mining stone bare-handed still clears the block but yields
        // nothing.
        guard mode.collectsDrops, let drop = block.drop else { return }
        let tier = inventory.heldItem?.toolTier ?? .hand
        if block.requiresTool, tier < block.minimumTier { return }
        inventory.add(ItemStack(drop, count: 1))
    }

    /// Right-click: open a crafting table, eat what's in hand, or place the
    /// held block. Eating comes before placing because food has no
    /// `placedBlock` and would otherwise fall out of the guard below, and
    /// it works with nothing in front of you at all.
    /// Puts a line on the HUD for a moment. Not the crafting hint, which is
    /// a one-time thing tied to a setting: this is a transient answer to
    /// "what just happened", and the only feedback taming has.
    func showToast(_ text: String, seconds: Double = 2) {
        toastText = text
        toastTimer = seconds
    }

    /// A right-click that lands on an animal before it lands on a block:
    /// feeding one to tame it, or telling a tamed one to sit.
    ///
    /// Returns true when it did something, so `use` knows to stop. Cast
    /// separately from the attack ray because that one is only cast while
    /// the attack button is down, and this is the other button.
    func useOnMob(_ hit: VoxelRayHit?) -> Bool {
        let mob = MobRaycast.cast(
            from: player.eyePosition,
            direction: camera.lookDirection,
            maxDistance: hit?.distance ?? GameSession.reach,
            targets: mobTargets()
        )
        guard let mob, mob.id >= GameSession.animalIDBase else { return false }
        let id = mob.id - GameSession.animalIDBase
        guard let animal = animals.animals[id] else { return false }

        // Already yours: right-click sits it down, or stands it up.
        if animal.isTamed {
            animals.toggleSit(id)
            let sitting = animals.animals[id]?.isSitting == true
            showToast(sitting
                ? L10n.t("Staying here", "Stannar här")
                : L10n.t("Following you", "Följer dig"))
            return true
        }

        // Not tameable: a herd animal takes wheat instead, and offers a
        // pairing rather than a leash — the harvest from farming going
        // somewhere besides the furnace and the player's own belly, into a
        // second system this game already had every other piece of.
        if !animal.kind.isTameable, inventory.heldItem == .wheat {
            guard animals.feedForBreeding(id) else { return false }
            if mode.consumesPlacedBlocks { inventory.consumeHeldOne() }
            showToast(L10n.t("Looking for a mate", "Letar efter en partner"), seconds: 3)
            return true
        }

        // Not yours yet: feeding it makes it yours, if it is the sort that
        // can be. Any meat will do — there are no bones in this game, and a
        // taming item a player cannot get is a feature that does not exist.
        guard animal.kind.isTameable,
              let held = inventory.heldItem, held.foodValue != nil else { return false }
        guard animals.feed(id) else { return false }
        if mode.consumesPlacedBlocks { inventory.consumeHeldOne() }
        showToast(L10n.t("It follows you now", "Den följer dig nu"), seconds: 3)
        return true
    }

    func use(_ hit: VoxelRayHit?) {
        // A chestplate isn't placed or consumed — right-clicking it swaps
        // whatever's currently worn into the hand instead, the same
        // "becomes a different thing in the same slot" gesture a bucket
        // already uses to fill with water. Comes before everything else in
        // here: what's worn doesn't care what's being looked at.
        if let held = inventory.heldItem, held.isArmor {
            let previous = stats.equip(held)
            inventory[inventory.selectedHotbarSlot] = previous.map { ItemStack($0) }
            showToast(L10n.t("Equipped", "Utrustad"), seconds: 2)
            return
        }
        // The other half of that swap: an empty hand takes off whatever's
        // worn rather than doing nothing, the way an empty right-click
        // would otherwise be a dead gesture here.
        if inventory.heldItem == nil, stats.equippedChestplate != nil {
            let previous = stats.equip(nil)
            inventory[inventory.selectedHotbarSlot] = previous.map { ItemStack($0) }
            showToast(L10n.t("Unequipped", "Avutrustad"), seconds: 2)
            return
        }
        // An animal in front of the block takes the right-click, so a wolf
        // standing against a wall can still be fed.
        if useOnMob(hit) { return }

        // Already in a cart: right-click gets out again.
        if minecarts.ridingID != nil {
            if let stand = minecarts.dismount() { player.recall(to: stand) }
            return
        }
        // A cart within reach takes the click before anything else does.
        if let hit, let id = minecarts.nearest(
            to: Vector3(CGFloat(hit.blockX) + 0.5, CGFloat(hit.blockY) + 0.5, CGFloat(hit.blockZ) + 0.5),
            within: 1.6
        ) {
            minecarts.ride(id)
            showToast(L10n.t("Right-click to get out", "Högerklicka för att kliva ur"), seconds: 3)
            return
        }
        // Putting a cart down on a rail.
        if let hit, inventory.heldItem == .minecart {
            let cell = hit.block.isRail
                ? (x: hit.blockX, y: hit.blockY, z: hit.blockZ)
                : (x: hit.placeX, y: hit.placeY, z: hit.placeZ)
            if minecarts.place(at: cell, in: world) != nil {
                if mode.consumesPlacedBlocks { inventory.consumeHeldOne() }
                return
            }
        }

        // A torch to a stick of dynamite, before anything else looks at
        // either. It has to come first: TNT is an ordinary cube, so without
        // this the held torch would simply be placed against its face, and
        // the most natural gesture in the game would build a lamp next to
        // the bomb instead of lighting it.
        if let hit, hit.block == .tnt, inventory.heldItem == .torch {
            fuses.light(atX: hit.blockX, y: hit.blockY, z: hit.blockZ,
                        in: world, fuse: FuseManager.litFuse)
            return
        }
        if let hit, hit.block == .furnace || hit.block == .furnaceLit {
            handleFurnaceInteract(at: (x: hit.blockX, y: hit.blockY, z: hit.blockZ))
            return
        }
        // A hoe to grass or dirt turns it to farmland, the one tool
        // interaction in the game that transforms a block rather than
        // breaking, opening or lighting it. Only from open air above: a
        // furrow cut under a wall would have nothing growing in it anyway.
        if let hit, inventory.heldItem == .hoe, hit.block == .grass || hit.block == .dirt,
           world.block(worldX: hit.blockX, y: hit.blockY + 1, worldZ: hit.blockZ) == .air {
            if world.setBlock(worldX: hit.blockX, y: hit.blockY, worldZ: hit.blockZ, to: .farmland) {
                return
            }
        }
        // A bucket against standing water (or lava) becomes a water (or lava)
        // bucket in the same slot — the one interaction in the game that turns
        // an item into a different item outright, rather than placing,
        // breaking or consuming it.
        //
        // Water and lava are transparent to ordinary picking so mining and
        // block placement can aim through them, exactly as the original does.
        // Filling a bucket is the one interaction that stops at fluid rather
        // than sailing through it, so it casts with fluid included instead of
        // relying on the general pick hit (which skips fluids, either landing
        // on the floor beneath or returning nil over deep water).
        if inventory.heldItem == .bucket {
            let fluidHit = VoxelRaycast.cast(
                from: player.eyePosition,
                direction: camera.lookDirection,
                maxDistance: GameSession.reach,
                world: world
            ) { $0.occupiesCell || $0.isFluid }
            if let fluidHit, let filledItem = BucketInteraction.fillFluid(at: (fluidHit.blockX, fluidHit.blockY, fluidHit.blockZ), world: world) {
                inventory[inventory.selectedHotbarSlot] = ItemStack(filledItem)
                return
            }
        }
        if let hit, hit.block.isInteractive {
            let cell = (x: hit.blockX, y: hit.blockY, z: hit.blockZ)
            if hit.block.isDoor {
                swingDoor(at: cell)
                return
            }
            if hit.block.isBed {
                sleep(in: cell)
                return
            }
            if hit.block.isLever {
                throwLever(at: cell)
                return
            }
            openTablePosition = cell
            if hit.block == .chest {
                screenRequest = .chest(stockedChest(at: ChestStore.Key(cell.x, cell.y, cell.z)))
            } else {
                screenRequest = .crafting(gridSize: 3)
            }
            return
        }
        if eatHeldFood() { return }
        guard let hit, let item = inventory.heldItem else { return }

        // A mason's line places nothing itself — the first right-click
        // marks one corner, the second marks the opposite one and turns
        // them into a box, and the very next material placed fills it, or
        // the very next block broken clears it. Marking the same corner
        // twice cancels the mark rather than trying to fill a box with no
        // volume.
        if item == .masonLine {
            let cell = (x: hit.placeX, y: hit.placeY, z: hit.placeZ)
            if let anchor = masonAnchor {
                masonRegion = (anchor.x == cell.x && anchor.y == cell.y && anchor.z == cell.z)
                    ? nil : RegionFill.region(from: anchor, to: cell)
                masonAnchor = nil
                showToast(masonRegion != nil
                    ? L10n.t(
                        "Marked — place to fill it, break to clear it",
                        "Markerat — placera för att fylla, bryt för att rensa"
                    )
                    : L10n.t("Mark cancelled", "Markering avbruten"), seconds: 3)
            } else {
                masonAnchor = cell
                showToast(L10n.t("First corner marked", "Första hörnet markerat"), seconds: 3)
            }
            return
        }

        // A blueprint marks corners the same way a mason's line does, but
        // closing the box captures its contents on the spot rather than
        // waiting on a separate placement — a mark *is* the capture for
        // this tool. Once something is captured, right-click no longer
        // marks at all: it stamps that same shape again, anchored on
        // whatever cell an ordinary placement would have landed on, billed
        // per cell against whichever material that cell actually needs —
        // still the one "aim and act" gesture, just spending a whole design
        // instead of one block, and good for as many stamps as the player
        // wants until `breakBlock` clears it.
        if item == .blueprint {
            let cell = (x: hit.placeX, y: hit.placeY, z: hit.placeZ)
            if let capture = blueprintCapture {
                var signalTouched = false
                let placed = RegionFill.stamp(
                    capture, at: cell, world: world,
                    playerOverlaps: { [player] x, y, z in player.overlaps(blockX: x, y: y, z: z) },
                    available: { block in
                        guard mode.consumesPlacedBlocks else { return RegionFill.maxVolume }
                        guard let stampItem = ItemType.blockItem(for: block) else { return 0 }
                        return inventory.count(of: stampItem)
                    }
                ) { block, x, y, z in
                    if mode.consumesPlacedBlocks, let stampItem = ItemType.blockItem(for: block) {
                        inventory.remove(stampItem, count: 1)
                    }
                    if block.isWire || block.isSignalRelay { signalTouched = true }
                    if block.isSignalTorch {
                        signals.torchPlaced(at: SignalNetwork.Key(x, y, z))
                        signalTouched = true
                    }
                }
                if signalTouched { signals.recompute(world: world, fuses: fuses) }
                showToast(
                    placed > 0
                        ? L10n.t("Stamped \(placed) blocks", "Stämplade \(placed) block")
                        : L10n.t("Nothing to stamp", "Inget att stämpla"),
                    seconds: 3
                )
                return
            }

            if let anchor = blueprintAnchor {
                blueprintAnchor = nil
                if anchor.x == cell.x, anchor.y == cell.y, anchor.z == cell.z {
                    showToast(L10n.t("Mark cancelled", "Markering avbruten"), seconds: 3)
                } else {
                    let captured = RegionFill.capture(RegionFill.region(from: anchor, to: cell), world: world)
                    if captured.cells.isEmpty {
                        showToast(L10n.t("Nothing to capture", "Inget att fånga"), seconds: 3)
                    } else {
                        blueprintCapture = captured
                        showToast(
                            L10n.t("Captured — right-click to stamp it", "Fångat — högerklicka för att stämpla"),
                            seconds: 3
                        )
                    }
                }
            } else {
                blueprintAnchor = cell
                showToast(L10n.t("First corner marked", "Första hörnet markerat"), seconds: 3)
            }
            return
        }

        // A water bucket empties into whatever the player is aiming at —
        // the same placement target every other item uses — and comes
        // back as an empty bucket in the same slot instead of
        // disappearing. No `placedBlock` mapping handles this: an item
        // that survives its own placement is the one thing that path was
        // never built for.
        if item == .waterBucket {
            let overlaps = player.overlaps(blockX: hit.placeX, y: hit.placeY, z: hit.placeZ)
            if BucketInteraction.empty(at: (hit.placeX, hit.placeY, hit.placeZ), world: world, playerOverlaps: overlaps) {
                inventory[inventory.selectedHotbarSlot] = ItemStack(.bucket)
            }
            return
        }
        if item == .lavaBucket {
            let overlaps = player.overlaps(blockX: hit.placeX, y: hit.placeY, z: hit.placeZ)
            if BucketInteraction.empty(fluid: .lava, at: (hit.placeX, hit.placeY, hit.placeZ), world: world, playerOverlaps: overlaps) {
                inventory[inventory.selectedHotbarSlot] = ItemStack(.bucket)
            }
            return
        }

        // Stairs, doors, beds and panes decide what to place from where the
        // player is standing, and a door or a bed is two cells — so they go
        // through `ShapedPlacement`, which answers with the whole placement
        // or with nothing.
        if ShapedPlacement.places(item) {
            placeShaped(item, at: (x: hit.placeX, y: hit.placeY, z: hit.placeZ))
            return
        }

        guard let block = item.placedBlock else { return }

        // A box is waiting from a mason's line, and this placement is an
        // ordinary material that's allowed to fill one — so it fills the
        // whole box instead of the one cell it would otherwise take,
        // spending only as much of the stack as the box actually needs
        // and stopping the moment the stack runs out.
        if let region = masonRegion, block.isBulkFillable {
            let available = mode.consumesPlacedBlocks ? inventory.count(of: item) : RegionFill.maxVolume
            let placed = RegionFill.fill(
                region, with: block, world: world,
                playerOverlaps: { [player] x, y, z in player.overlaps(blockX: x, y: y, z: z) },
                available: available
            )
            if placed > 0, mode.consumesPlacedBlocks { inventory.remove(item, count: placed) }
            // A filled run of wire or relay joins a live circuit on the
            // spot, the same as one placed by hand — see the comment by
            // the single-cell placement below. A filled run of torches
            // needs the same `torchPlaced` every hand-placed one gets;
            // `fill` doesn't hand back which cells it actually touched, so
            // this re-scans the box itself rather than trusting `placed`'s
            // count — cheap, since the box is already capped at
            // `RegionFill.maxVolume`.
            //
            // A lamp needs exactly the same registration a torch does:
            // `lampPlaced` is what puts it in `lampCells`, and a run filled
            // without it sits inert forever — standing in a live circuit,
            // wired to it, and never once answering it.
            if placed > 0, block.isWire || block.isSignalRelay {
                signals.recompute(world: world, fuses: fuses)
            } else if placed > 0, block.isSignalTorch || block.isSignalLamp {
                for y in region.minY...region.maxY {
                    for z in region.minZ...region.maxZ {
                        for x in region.minX...region.maxX {
                            let filled = world.block(worldX: x, y: y, worldZ: z)
                            if filled.isSignalTorch {
                                signals.torchPlaced(at: SignalNetwork.Key(x, y, z))
                            } else if filled.isSignalLamp {
                                signals.lampPlaced(at: SignalNetwork.Key(x, y, z))
                            }
                        }
                    }
                }
                signals.recompute(world: world, fuses: fuses)
            }

            // Sand and gravel drawn in bulk fall like sand and gravel placed
            // by hand. `fill` writes its cells straight into the world, so
            // without this a mason-drawn wall of sand simply hangs there —
            // and nothing else would come for it either, since the ambient
            // tick only samples a handful of columns per chunk per tick.
            if placed > 0, block.isGranular {
                let spanX = region.maxX - region.minX
                let spanY = region.maxY - region.minY
                let spanZ = region.maxZ - region.minZ
                world.settleGranular(
                    around: (
                        (region.minX + region.maxX) / 2,
                        (region.minY + region.maxY) / 2,
                        (region.minZ + region.maxZ) / 2
                    ),
                    radius: max(spanX, max(spanY, spanZ)) / 2 + 2
                )
            }
            showToast(
                placed > 0
                    ? L10n.t("Filled \(placed) blocks", "Fyllde \(placed) block")
                    : L10n.t("Nothing to fill", "Inget att fylla"),
                seconds: 3
            )
            masonRegion = nil
            return
        }
        // A plant needs ground under it. Nothing else in the game does, and
        // a poppy hanging in mid-air is the one placement that would read
        // as the game being broken rather than as the player being silly.
        // A crop is stricter still: only farmland will root it, which is
        // the entire reason to till in the first place — a seed that took
        // root anywhere would make the hoe pointless.
        if block.isCrop {
            let under = world.block(worldX: hit.placeX, y: hit.placeY - 1, worldZ: hit.placeZ)
            guard BlockType.cropCanRootOn(under) else { return }
        } else if block.isPlant {
            let under = world.block(worldX: hit.placeX, y: hit.placeY - 1, worldZ: hit.placeZ)
            guard BlockType.plantCanRootOn(under) else { return }
        } else if block.isPressurePlate {
            // Floating in mid-air, a plate would still work exactly as
            // well — nothing about the signal it throws needs a floor —
            // but a switch nothing can stand on to press is a joke of a
            // switch, the same reasoning a crop needs farmland for.
            guard world.block(worldX: hit.placeX, y: hit.placeY - 1, worldZ: hit.placeZ).isSolid else { return }
        }
        // Never place inside yourself, and never replace an occupied cell.
        guard !player.overlaps(blockX: hit.placeX, y: hit.placeY, z: hit.placeZ) else { return }
        guard ShapedPlacement.isReplaceable(
            (x: hit.placeX, y: hit.placeY, z: hit.placeZ), world
        ) else { return }
        guard world.setBlock(worldX: hit.placeX, y: hit.placeY, worldZ: hit.placeZ, to: block) else { return }
        if mode.consumesPlacedBlocks { inventory.consumeHeldOne() }
        if block.hasGravity {
            let settleRes = world.settleGranular(atWorldX: hit.placeX, worldZ: hit.placeZ)
            applySettle(settleRes)
        }
        // A lever, a plate or a length of wire dropped next to a live
        // circuit should join it on the spot, not wait for someone to
        // throw a switch.
        if block.isLever || block.isWire || block.isPressurePlate || block.isSignalTorch || block.isSignalRelay
            || block == .daylightSensor || block == .signalLamp || block == .signalLampLit {
            if block.isLever {
                signals.leverPlaced(at: SignalNetwork.Key(hit.placeX, hit.placeY, hit.placeZ))
            } else if block.isPressurePlate {
                signals.platePlaced(at: SignalNetwork.Key(hit.placeX, hit.placeY, hit.placeZ))
            } else if block.isSignalTorch {
                signals.torchPlaced(at: SignalNetwork.Key(hit.placeX, hit.placeY, hit.placeZ))
            } else if block == .daylightSensor {
                signals.daylightSensorPlaced(at: SignalNetwork.Key(hit.placeX, hit.placeY, hit.placeZ))
            } else if block == .signalLamp || block == .signalLampLit {
                signals.lampPlaced(at: SignalNetwork.Key(hit.placeX, hit.placeY, hit.placeZ))
            }
            signals.recompute(world: world, fuses: fuses)
        }
        if block.isCrop {
            crops.planted(at: CropStore.Key(hit.placeX, hit.placeY, hit.placeZ))
        }
        if block.isSapling {
            saplings.planted(at: SaplingStore.Key(hit.placeX, hit.placeY, hit.placeZ))
        }
        if block == .hopper {
            let key = HopperStore.Key(hit.placeX, hit.placeY, hit.placeZ)
            let facing: BlockFacing?
            if hit.normal.y == 1 || hit.normal.y == -1 {
                facing = nil
            } else if hit.normal.x == 1 {
                facing = .west
            } else if hit.normal.x == -1 {
                facing = .east
            } else if hit.normal.z == 1 {
                facing = .north
            } else if hit.normal.z == -1 {
                facing = .south
            } else {
                facing = nil
            }
            hoppers.hopperPlaced(at: key, facing: facing)
        }
    }

    /// Puts the block under the crosshair into the hand — middle-click, or
    /// F. The thing that makes building out of a palette bearable: you see
    /// a block in the wall you want more of, and you point at it instead of
    /// going to look for it among eighty-five cells.
    ///
    /// Already in the hotbar: that slot is simply selected, which is all
    /// The original does and all survival is allowed to do. Otherwise creative
    /// conjures a stack — into an empty slot if there is one, and over the
    /// selected slot if there is not, with whatever it displaced going back
    /// into the bag. If the bag cannot take it, nothing moves: the palette
    /// has another stone, and it does not have the thing the player made.
    func pickBlock(_ hit: VoxelRayHit) {
        guard let item = hit.block.pickItem else { return }

        if let slot = (0..<Inventory.hotbarSize).first(where: { inventory[$0]?.type == item }) {
            inventory.selectedHotbarSlot = slot
            return
        }
        // Survival: only what you are already carrying, brought to hand.
        guard mode == .creative else {
            guard let slot = (Inventory.hotbarSize..<Inventory.totalSize)
                .first(where: { inventory[$0]?.type == item }) else { return }
            let target = (0..<Inventory.hotbarSize).first { inventory[$0] == nil }
                ?? inventory.selectedHotbarSlot
            let displaced = inventory[target]
            inventory[target] = inventory[slot]
            inventory[slot] = displaced
            inventory.selectedHotbarSlot = target
            return
        }

        let empty = (0..<Inventory.hotbarSize).first { inventory[$0] == nil }
        let target = empty ?? inventory.selectedHotbarSlot
        if empty == nil, let displaced = inventory[target] {
            // Emptied first. `add` fills partial stacks of the same type
            // before empty ones, and the slot being emptied is one of
            // them — left in place, a half stack of planks would merge
            // into itself, report success, and then be overwritten.
            inventory[target] = nil
            if let leftover = inventory.add(displaced) {
                inventory[target] = leftover
                return showToast(L10n.t(
                    "No room in your bag for what's in hand",
                    "Ingen plats i förrådet för det du håller"
                ))
            }
        }
        inventory[target] = ItemStack(item, count: item.maxStack)
        inventory.selectedHotbarSlot = target
    }

    /// Right-clicking a furnace: no screen, just held items going in and
    /// coming out, one at a time — the same physical gesture as feeding an
    /// animal or lighting TNT. Ore in one hand, fuel in the other, and an
    /// empty hand collects whatever the fire has finished with.
    func handleFurnaceInteract(at cell: (x: Int, y: Int, z: Int)) {
        let key = FurnaceStore.Key(cell.x, cell.y, cell.z)
        var state = furnaces.state(at: key)
        defer { furnaces.set(state, at: key) }

        if let held = inventory.heldItem {
            if FurnaceRecipe.output(for: held) != nil,
               state.oreType == nil || state.oreType == held, state.oreCount < 64 {
                state.oreType = held
                state.oreCount += 1
                inventory.consumeHeldOne()
                return
            }
            if FurnaceRecipe.burnSeconds(for: held) != nil,
               state.fuelType == nil || state.fuelType == held, state.fuelCount < held.maxStack {
                state.fuelType = held
                state.fuelCount += 1
                inventory.consumeHeldOne()
                return
            }
        }

        if let output = state.outputType, state.outputCount > 0 {
            let leftover = inventory.add(ItemStack(output, count: state.outputCount))
            state.outputCount = leftover?.count ?? 0
            if state.outputCount == 0 { state.outputType = nil }
            return
        }

        if state.fuelType == .bucket, state.fuelCount > 0 {
            let leftover = inventory.add(ItemStack(.bucket, count: state.fuelCount))
            state.fuelCount = leftover?.count ?? 0
            if state.fuelCount == 0 { state.fuelType = nil }
            return
        }

        showToast(L10n.t(
            "Ore in one hand, coal or wood in the other",
            "Malm i ena handen, kol eller ved i den andra"
        ), seconds: 3)
    }

    /// Places one of the shaped blocks, or cleanly does nothing.
    ///
    /// Every cell is tested before any is written: half a door is worse
    /// than no door, and the player would have paid for it either way.
    func placeShaped(_ item: ItemType, at cell: (x: Int, y: Int, z: Int)) {
        guard let edits = ShapedPlacement.edits(
            for: item, at: cell, yaw: camera.yaw, world: world
        ) else { return }
        // Standing in the doorway is the one way to brick yourself in, and a
        // bed placed through your own feet would do the same.
        guard !edits.contains(where: {
            player.overlaps(blockX: $0.x, y: $0.y, z: $0.z)
        }) else { return }
        ShapedPlacement.apply(edits, to: world)
        // A rail joins up with what is already there, and turns what is
        // already there to meet it. Without this the second rail of a line
        // is a stub pointing whichever way the player happened to face.
        if edits.first?.block.isRail == true {
            RailNetwork.refresh(
                around: cell, preferring: ShapedPlacement.facing(fromYaw: camera.yaw), in: world
            )
            // A fresh booster landing beside live wire should join it
            // immediately rather than wait for the next toggle elsewhere.
            if world.block(worldX: cell.x, y: cell.y, worldZ: cell.z).isBooster {
                signals.recompute(world: world, fuses: fuses)
            }
            // A freshly placed detector rail has to register as a source
            // before anything parked on it can throw the network — the
            // same reason a lever or a plate registers the moment it lands.
            if world.block(worldX: cell.x, y: cell.y, worldZ: cell.z).isDetectorRail {
                signals.detectorPlaced(at: SignalNetwork.Key(cell.x, cell.y, cell.z))
                signals.recompute(world: world, fuses: fuses)
            }
        }
        if mode.consumesPlacedBlocks { inventory.consumeHeldOne() }
    }

    /// Right-clicking a door swings both halves together — unless the
    /// closing panel would land inside the player, which would wedge them
    /// in place for good. The test is box-precise where placeShaped's is
    /// cell-granular: standing in the doorway clear of the panel is fine,
    /// and opening can never be refused, because an open door has no
    /// collision boxes at all.
    func swingDoor(at cell: (x: Int, y: Int, z: Int)) {
        guard let edits = ShapedPlacement.doorToggleEdits(at: cell, world: world) else { return }
        guard !edits.contains(where: {
            player.overlaps(boxes: $0.block.collisionBoxes, blockX: $0.x, y: $0.y, z: $0.z)
        }) else { return }
        ShapedPlacement.apply(edits, to: world)
    }

    /// Right-clicking a lever: flips it, and recomputes whatever it
    /// reaches. The one interaction in the game that never touches the
    /// held item at all — a lever answers to the hand that throws it, not
    /// to what that hand is carrying.
    ///
    /// Registers the cell with the network before doing anything else,
    /// unconditionally. Every lever a player places by hand or stamps with
    /// a blueprint already gets registered the moment it lands; this is the
    /// one for a lever nobody registered — one a ruin generated. Reaching
    /// here is proof a hand is actually on it, which is exactly when a
    /// found lever should start counting as wired, not a moment before.
    /// `leverCells` is a set, so registering one already known costs
    /// nothing.
    func throwLever(at cell: (x: Int, y: Int, z: Int)) {
        let block = world.block(worldX: cell.x, y: cell.y, worldZ: cell.z)
        guard block.isLever else { return }
        signals.leverPlaced(at: SignalNetwork.Key(cell.x, cell.y, cell.z))
        world.setBlock(worldX: cell.x, y: cell.y, worldZ: cell.z, to: block == .leverOn ? .leverOff : .leverOn)
        signals.recompute(world: world, fuses: fuses)
    }

    /// Right-clicking a bed: at night it takes you to morning and makes
    /// this where you wake up after dying. By day it says so and nothing
    /// else happens.
    func sleep(in cell: (x: Int, y: Int, z: Int)) {
        guard let outcome = BedInteraction.sleep(at: cell, world: world, isNight: sky.isNight) else {
            return
        }
        switch outcome {
        case .tooEarly:
            showToast(L10n.t("You can only sleep at night", "Du kan bara sova på natten"))
        case .slept(let spawn):
            bedSpawn = spawn
            sleepTimer = GameSession.sleepDuration
            sleepMorningApplied = false
        }
    }

    /// Puts one line in front of the player for a moment, through the same
    /// flash the hotbar uses to name what you just picked up.
    func showToast(_ message: String) {
        itemNameToast = message
        itemNameTimer = 2.0
    }

    /// Where dying puts the player, once they have slept somewhere.
    var bedSpawn: BedSpawn?

    /// Every grave the player hasn't finished emptying — what lets the
    /// compass point at what dying actually cost instead of only ever
    /// home, even after a second death before the first grave was walked
    /// back to.
    var pendingGraveKeys: [ChestStore.Key] = []

    /// Seconds the screen spends dipped through black while the night is
    /// skipped. Short: a six-year-old pressing a bed wants morning, not a
    /// cutscene.
    static let sleepDuration: Double = 1.1
    /// Counts down from `sleepDuration` while a sleep is playing.
    var sleepTimer: Double = 0
    /// Whether this sleep has already moved the clock — the jump happens at
    /// the darkest point, once.
    var sleepMorningApplied = false

    /// Advances the sleep dip, moving the sun at the moment the screen is
    /// fully black so the change is never seen happening.
    func updateSleep(dt: Double) {
        guard sleepTimer > 0 else { return }
        sleepTimer = max(0, sleepTimer - dt)
        let elapsed = GameSession.sleepDuration - sleepTimer
        if !sleepMorningApplied, elapsed >= GameSession.sleepDuration / 2 {
            sleepMorningApplied = true
            sky.setTimeOfDay(BedInteraction.morning)
        }
    }

    /// How black the screen is right now: in over the first half of the
    /// dip, out over the second.
    var sleepFade: CGFloat {
        guard sleepTimer > 0 else { return 0 }
        let half = GameSession.sleepDuration / 2
        let elapsed = GameSession.sleepDuration - sleepTimer
        return CGFloat(elapsed < half ? elapsed / half : sleepTimer / half)
    }

    /// Eats one of the held item if it's food and there's belly room for
    /// it. Creative has no hunger to fill, so nothing is ever consumed
    /// there. Returns true when a meal actually happened.
    func eatHeldFood() -> Bool {
        guard mode.hasSurvivalStats,
              let food = inventory.heldItem?.foodValue,
              stats.hunger < PlayerStats.maxHunger else { return false }
        // Capture the name first: eating the last of a stack empties the
        // slot, and a toast read from heldItem at render time would vanish.
        itemNameToast = inventory.heldItem?.displayName
        stats.feed(food)
        inventory.consumeHeldOne()
        // Reuse the hotbar's name flash as the "you ate that" confirmation.
        itemNameTimer = 1.6
        return true
    }

    func respawn() {
        // Every other cost in this game is a decision made in advance —
        // gear before a vault, air before a wreck. Dying itself cost
        // nothing: the exact same inventory came back with you every
        // time, which made the choice to go deep or go far free of the
        // one stake the original's own death has always carried.
        if mode != .creative,
           let newGrave = Grave.drop(inventory: inventory, chests: chests, world: world, at: player.position) {
            pendingGraveKeys.append(newGrave)
        }
        // A bed slept in is where you wake up. If the bed has since been
        // mined out the point is simply where it was, which is a place the
        // player knows — better than being thrown back to world spawn with
        // no explanation.
        player = PlayerController(spawn: bedSpawn?.position ?? world.spawnPosition())
        player.resolveSpawnOverlap(world: world)
        stats.reset()
        mining.reset()
        // Clear the field, so you don't respawn under the fizzler that just
        // killed you.
        fizzlers.removeAll()
        skeletons.removeAll()
        // Wild animals go with them: they were gathered around the old
        // spawn, and the new one wants its own herd. A tamed pet is not
        // wildlife — it stays right where it was, same as it would if the
        // player had simply walked away, rather than being deleted for
        // dying. Its entity is cleared with the rest and rebuilt next sync
        // from the surviving record, same as any other reconciliation.
        animals.removeAllWild()
        respawnCount += 1
        damageFlashTimer = 0.35
        // Dying used to be a red flash and finding yourself somewhere
        // else. Said out loud it is a thing that happened to you, and the
        // line names where you woke up, because "why am I here" is the
        // next question either way.
        showToast(bedSpawn == nil
            ? L10n.t("You died \u{2014} back at the world spawn",
                     "Du dog \u{2014} tillbaka vid världens startpunkt")
            : L10n.t("You died \u{2014} back at your bed",
                     "Du dog \u{2014} tillbaka vid din säng"),
            seconds: 4)
    }

    /// The chest at a cell, rolling a landmark's loot into it the first time
    /// anything reaches this position — `ChestStore` itself knows nothing
    /// about ruins, vaults, spires, wrecks or seeds, so this is the one
    /// seam where "a chest exists here for the first time" gets to ask the
    /// generator whether that's because a player placed it, a ruin did,
    /// it's the one chest a vault's obsidian shell was ever going to let
    /// anyone reach, it's waiting at the top of a spire for whoever climbed
    /// it, or it's resting on an ocean floor for whoever held their breath.
    func stockedChest(at key: ChestStore.Key) -> Chest {
        let isNew = chests.existing(at: key) == nil
        let chest = chests.chest(at: key)
        if isNew, let loot = world.generator.ruinLoot(atX: key.x, y: key.y, z: key.z) {
            for entry in loot { chest.add(ItemStack(entry.item, count: entry.count)) }
        } else if isNew, let loot = world.generator.vaultLoot(atX: key.x, y: key.y, z: key.z) {
            for entry in loot { chest.add(ItemStack(entry.item, count: entry.count)) }
        } else if isNew, let loot = world.generator.spireLoot(atX: key.x, y: key.y, z: key.z) {
            for entry in loot { chest.add(ItemStack(entry.item, count: entry.count)) }
        } else if isNew, let loot = world.generator.wreckLoot(atX: key.x, y: key.y, z: key.z) {
            for entry in loot { chest.add(ItemStack(entry.item, count: entry.count)) }
        }
        return chest
    }

    /// How many stacks the bag could still take, counted as empty slots —
    /// deliberately pessimistic, since a partial stack of the right item
    /// might take more. "Will it all fit" has to be answered before
    /// anything moves, and this is the answer that cannot be wrong in the
    /// direction that loses items.
    func freeInventorySlots() -> Int {
        (0..<Inventory.totalSize).count { inventory[$0] == nil }
    }

    // MARK: - Scripted testing

    /// A spot a scripted run can plant a block in and look for again.
    ///
    /// Derived from spawn, which is a pure function of the seed, so the
    /// same world puts it in the same place every time it is opened — which
    /// is what makes "is the block still there?" a question a script can
    /// ask after a reload without carrying coordinates between processes.
    /// Three above the spawn column, so it is in open air rather than
    /// inside whatever terrain happens to be there.
    var markerBlock: (x: Int, y: Int, z: Int) {
        let spawn = world.spawnPosition()
        return (Int(floor(spawn.x)), Int(floor(spawn.y)) + 3, Int(floor(spawn.z)))
    }

    /// Places the marker block. Returns what happened, for the transcript.
    @discardableResult
    func scriptPlaceMarker(_ block: BlockType = .obsidian) -> String {
        let spot = markerBlock
        let placed = world.setBlock(worldX: spot.x, y: spot.y, worldZ: spot.z, to: block)
        return "placed \(block) at \(spot.x),\(spot.y),\(spot.z) — accepted: \(placed)"
    }

    /// Reads the marker back.
    func scriptMarkerReport() -> String {
        let spot = markerBlock
        let block = world.block(worldX: spot.x, y: spot.y, worldZ: spot.z)
        return "marker at \(spot.x),\(spot.y),\(spot.z) is \(block)"
    }

    /// Opens the pause screen and takes its Save & Main Menu row.
    ///
    /// Through the row's own callback, not around it: the point of a
    /// scripted run is to prove that the button a player presses is wired
    /// to the thing that happens, so pressing it is what the script does.

    /// One line describing the world in play, for the transcript.
    func scriptSummary() -> String {
        let file = fileURL?.lastPathComponent ?? "(no file — saving is off)"
        return "world \"\(worldName)\" · \(mode.rawValue) · seed \(world.seed)"
            + " · \(world.editJournal.values.reduce(0) { $0 + $1.count }) edits · file \(file)"
    }

    /// `BLOCKHAVEN_LIFECYCLE_LOG=1` prints when a world is built and when it
    /// is finally released. It exists because "did the old world actually
    /// go away?" is otherwise unanswerable from outside the process, and
    /// leaving a world running behind the menu is exactly the bug returning
    /// to the menu invites.
    static let logsLifecycle = ProcessInfo.processInfo.environment["BLOCKHAVEN_LIFECYCLE_LOG"] == "1"

    static func logLifecycle(_ message: String) {
        guard logsLifecycle else { return }
        StandardError.write(Data("[lifecycle] \(message)\n".utf8))
    }

    deinit {
        GameSession.logLifecycle("released world \"\(worldName)\" (\(mode.rawValue))")
    }

    // MARK: - Saving

    /// The live world as a save. Cheap enough to run inside a frame: it
    /// copies the edit journal and the inventory and reads a handful of
    /// numbers. Nothing generated is in it, so its size tracks what the
    /// player built rather than how far they walked.
    func captureSave() -> WorldSave {
        WorldSave(
            seed: world.seed,
            mode: mode,
            name: worldName,
            // Stamped at capture, on the main thread, so it dates the state
            // in the snapshot rather than whenever the write queue got
            // round to it.
            lastPlayed: Date().timeIntervalSince1970,
            edits: world.editJournal,
            position: player.position,
            yaw: camera.yaw,
            pitch: camera.pitch,
            inventory: inventory,
            stats: stats,
            timeOfDay: sky.timeOfDay,
            weatherDayIndex: sky.weatherDayIndex,
            bedSpawn: bedSpawn,
            pendingGraves: pendingGraveKeys,
            chests: chests,
            furnaces: furnaces,
            hoppers: hoppers,
            minecarts: minecarts,
            animals: animals
        )
    }

    /// What stopped the last write, if anything did — a full disk, a save
    /// directory that went read-only, a permissions change. Cleared by the
    /// next write that lands.
    ///
    /// It exists because a failed save used to be a line on stderr and
    /// nothing else, which was survivable only while the sole way out of a
    /// world was quitting. Now that a world can be left with the session
    /// carrying on, "did it actually save?" is a question somebody has to be
    /// able to answer.
    var lastSaveFailure: String?

    /// Captures on the main thread — the snapshot has to be one coherent
    /// frame of state — then encodes and writes on a serial background
    /// queue, so a slow disk shows up as neither a stutter nor a torn save.
    /// Termination has no later to write in, so it waits for the queue.
    ///
    /// Returns whether the world is on disk. Only a waiting save can answer
    /// that honestly; a background one returns true having handed the write
    /// off, and reports a failure through `lastSaveFailure` when it lands.
    /// A run with saving switched off returns true: there is nothing to
    /// write and so nothing to lose.
    @discardableResult
    func save(waitingForCompletion wait: Bool = false) -> Bool {
        // Reset before the guard, or a run with saving off leaves the timer
        // past due and re-enters this every frame for the rest of the run.
        autosaveTimer = 0
        guard WorldSave.isEnabled, let fileURL else { return true }
        // Quitting from the inventory screen reaches here with stacks still
        // held by the view; they are part of the player's inventory in every
        // sense but the one that matters to `captureSave`.
        willCaptureSave?()
        let snapshot = captureSave()
        let write: () -> String? = {
            do {
                try snapshot.save(to: fileURL)
                return nil
            } catch {
                StandardError.write(Data("[save] failed: \(error)\n".utf8))
                return "\(error)"
            }
        }
        if wait {
            let failure = GameSession.saveQueue.sync(execute: write)
            noteSaveResult(failure)
            return failure == nil
        }
        GameSession.saveQueue.async { [weak self] in
            let failure = write()
            DispatchQueue.main.async { self?.noteSaveResult(failure) }
        }
        return true
    }

    /// Records how the last write went, and tells the pause screen if it is
    /// up to hear it.
    func noteSaveResult(_ failure: String?) {
        lastSaveFailure = failure
        onSaveResult?(failure)
    }

    /// What the player is told. The error itself is on stderr, where it is
    /// useful to whoever can fix the disk; what matters on screen is that
    /// the world is still here and still theirs. Computed, not stored, so
    /// it speaks whatever language is set when it is shown.
    static var saveFailureMessage: String {
        L10n.t(
            "Couldn't save this world — it's still open, so nothing is lost",
            "Det gick inte att spara världen — den är fortfarande öppen, så inget är borta"
        )
    }


    /// Walking away from a table (or it being mined out) closes it. Returns
    /// true when the open screen should go.
    func tableWalkedAway() -> Bool {
        guard let table = openTablePosition else { return false }
        let stillThere = world.block(worldX: table.x, y: table.y, worldZ: table.z).isInteractive
        let centre = Vector3(CGFloat(table.x) + 0.5, CGFloat(table.y) + 0.5, CGFloat(table.z) + 0.5)
        let distance = (player.eyePosition - centre).length()
        return !stillThere || distance > 7
    }


    // MARK: - Driving a frame

    /// The benchmarks that steer the player — run before anything reads
    /// the frame's input.
    func driveBenchmarks(_ input: inout InputSnapshot, dt: Double) {
        if GameSession.benchmarksWalk { driveBenchmarkWalk(&input) }
        if GameSession.benchmarksBlast { driveBenchmarkBlast(dt: dt) }
    }

    /// Only play counts towards an autosave, so a world left paused
    /// overnight doesn't write over itself. The inventory screen counts
    /// towards the clock but doesn't write: a stack on the cursor or in the
    /// crafting grid belongs to the view, not the inventory, and capturing
    /// there would file it as gone. The clock is already past due when the
    /// screen closes, so the craft lands on disk the moment those stacks
    /// are back.
    func tickAutosave(dt: Double, canWrite: Bool) {
        autosaveTimer += dt
        if autosaveTimer >= GameSession.autosaveInterval, canWrite { save() }
    }

    /// Moves the sun, and plays out a sleep if one is under way. Runs
    /// whenever the world is not paused — the inventory screen included.
    func advanceClock(dt: Double) {
        updateSleep(dt: dt)
        sky.advance(dt: dt)
    }

    /// Something took the player out of play — a screen opened. Whatever
    /// they were halfway through mining starts over.
    func leftPlay() {
        mining.reset()
        highlightTarget = nil
    }

    /// The open screen closed.
    func closedScreen() {
        openTablePosition = nil
    }

    /// Drops every lit fuse without detonating it, and every cart. A world
    /// you walked out of should not be a world you walk back into holding
    /// a crater.
    func shutdown() {
        fuses.clear()
        minecarts.clear()
    }

    /// Counts the HUD's flashes down and builds what it should draw.
    func hudState(dt: Double, debugText: String?) -> HUDState {
        if itemNameTimer > 0 { itemNameTimer -= dt }
        if damageFlashTimer > 0 { damageFlashTimer -= dt }
        if toastTimer > 0 { toastTimer -= dt }

        var state = HUDState()
        state.hotbar = (0..<Inventory.hotbarSize).map { inventory[$0] }
        state.selectedSlot = inventory.selectedHotbarSlot
        state.health = stats.health
        state.hunger = stats.hunger
        state.air = stats.air
        state.isSubmerged = player.isSubmerged
        state.isInLava = player.isInLava
        state.equippedChestplate = stats.equippedChestplate
        state.showSurvivalBars = mode.hasSurvivalStats
        state.isCreative = mode == .creative
        state.showDamageFlash = damageFlashTimer > 0
        state.itemName = itemNameTimer > 0 ? itemNameToast : nil
        state.toast = toastTimer > 0 ? toastText : nil
        state.debugText = debugText
        state.fadeToBlack = sleepFade
        if inventory.heldItem == .compass {
            let home = bedSpawn?.position ?? world.spawnPosition()
            let target = Grave.compassTarget(
                pendingGraves: pendingGraveKeys, chests: chests, home: home, playerPosition: player.position
            )
            pendingGraveKeys = target.stillPending
            state.compassBearing = Compass.needleAngle(from: player.position, home: target.position, cameraYaw: camera.yaw)
            state.compassDistance = Compass.distance(from: player.position, home: target.position)
            state.compassTargetsGrave = target.isGrave
        }
        return state
    }

    /// The F3 overlay. `renderer` names the front end, so a screenshot says
    /// which one it came from.
    func debugText(fps: Int, renderer: String) -> String {
        let position = player.position
        let chunk = playerChunk()
        let biome = world.generator.biome(x: Int(floor(position.x)), z: Int(floor(position.z)))
        return """
        Blockhaven — \(mode.rawValue.capitalized) — \(fps) fps (\(renderer))
        XYZ: \(String(format: "%.2f / %.2f / %.2f", Double(position.x), Double(position.y), Double(position.z)))
        Chunk: \(chunk.x), \(chunk.z)   Facing: \(GameSession.compassDirection(camera.yaw))
        Biome: \(biome)   Time: \(sky.clockText)
        Chunks loaded: \(world.chunks.count)   revealed: \(world.revealedChunkCount)
        Mode: \(player.isFlying ? "flying" : (player.isInWater ? "swimming" : "walking"))
        E inventory · F3 debug · scroll/1-9 hotbar\(mode.allowsFlight ? " · double-space fly" : "")
        """
    }

    static func compassDirection(_ yaw: CGFloat) -> String {
        // Forward is (sin yaw, cos yaw); +Z is south in this world's frame.
        var degrees = (Double(yaw) * 180 / .pi).truncatingRemainder(dividingBy: 360)
        if degrees < 0 { degrees += 360 }
        switch degrees {
        case 0..<22.5, 337.5..<360: return "south (+Z)"
        case 22.5..<67.5: return "south-east"
        case 67.5..<112.5: return "east (+X)"
        case 112.5..<157.5: return "north-east"
        case 157.5..<202.5: return "north (-Z)"
        case 202.5..<247.5: return "north-west"
        case 247.5..<292.5: return "west (-X)"
        default: return "south-west"
        }
    }

    /// The lit fuses worth drawing: all of them, or the nearest `budget`
    /// when there are more — see `GameViewController.primedEntityBudget`.
    func drawnFuses(budget: Int) -> [FuseManager.Primed] {
        let live = fuses.live
        guard live.count > budget else { return live }
        // Nearest first, so the budget is spent on the ones a player could
        // actually pick out.
        let eye = player.eyePosition
        func distanceSquared(_ fuse: FuseManager.Primed) -> CGFloat {
            let d = fuse.centre - eye
            return d.x * d.x + d.y * d.y + d.z * d.z
        }
        return Array(live.sorted { distanceSquared($0) < distanceSquared($1) }.prefix(budget))
    }

    /// A seed for a brand-new world: random, unless `BLOCKHAVEN_SEED` pins it.
    static func freshSeed() -> UInt64 {
        if let pinned = UInt64(ProcessInfo.processInfo.environment["BLOCKHAVEN_SEED"] ?? "") {
            return pinned
        }
        return UInt64.random(in: 1...UInt64.max)
    }
}
