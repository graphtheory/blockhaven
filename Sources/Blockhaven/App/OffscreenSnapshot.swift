#if canImport(AppKit)
import AppKit
import RealityKit
import Combine

/// Headless visual verification: builds a world, meshes the chunks around
/// a viewpoint, renders it, and writes one PNG.
///
/// SceneKit could do this with no window at all through `SCNRenderer`.
/// RealityKit has no offscreen renderer, so this drives a real window
/// placed far off the visible desktop, waits for it to actually draw, and
/// then snapshots the view. That still avoids needing macOS screen
/// recording permission, which capturing the live window would.
///
/// This used to be blamed for rendering zero frames on anything beyond the
/// simplest materials. Measured, not guessed: an off-screen window here
/// reports `occlusionState == .visible` (logged in the give-up path below),
/// and `orderFrontRegardless()` plus `NSApp.setActivationPolicy(.accessory)`
/// in `main.swift` are enough to make RealityKit schedule updates on it —
/// the harness reliably renders textured, multi-part entities like
/// fizzlers and animals at this window position. The zero-frame failure
/// this was blamed for reproduces instead with `BLOCKHAVEN_CUSTOM_SHADER=1`,
/// and it isn't zero frames either: the `CustomMaterial` surface shader
/// renders solid black in the *live* windowed app too, so that was a
/// shader bug wearing this harness as a disguise.
///
/// The block shader is *opt-in* here, not absent. By default
/// `MaterialLibrary` gives a snapshot the `UnlitMaterial` path, because most
/// of what this harness checks — atlas addressing, mob models, UI overlays —
/// is clearer without fog, water or a bloom pass on top of it. Setting
/// `BLOCKHAVEN_SNAPSHOT_CUSTOM_SHADER=1` renders the capture through the real
/// `blockSurface` shader *and* installs the post-processing pass, which is
/// how fog falloff, water and the daylight grade get verified.
///
/// Launch with `BLOCKHAVEN_SNAPSHOT=/path.png`. Optional knobs:
///   `BLOCKHAVEN_SNAPSHOT_YAW`    degrees, world bearing of the camera
///   `BLOCKHAVEN_SNAPSHOT_PITCH`  degrees, positive looks up
///   `BLOCKHAVEN_SNAPSHOT_TIME`   time of day, 0…1 (0.25 = noon)
///   `BLOCKHAVEN_SNAPSHOT_POS`    "x,y,z" eye position override
///   `BLOCKHAVEN_SNAPSHOT_UI`     "hud", "inventory", "table", "creative", "chest",
///        "creativebook", "book", "book2x2" or "pause" over the render; "menu", "worlds" or
///        "naming" instead of it
///   `BLOCKHAVEN_SNAPSHOT_RADIUS` chunks of world to build
///   `BLOCKHAVEN_SNAPSHOT_SIZE`   "WxH" pixels, default 1600x1000
///   `BLOCKHAVEN_SNAPSHOT_ATLAS`  dump the texture sheet instead
///   `BLOCKHAVEN_SNAPSHOT_FIZZLERS` stand a mob lineup in front of the camera
///   `BLOCKHAVEN_SNAPSHOT_ARMOR`  "iron" or "diamond" previews the worn-
///        chestplate HUD icon, over `_UI=hud`
///   `BLOCKHAVEN_SNAPSHOT_REGRADE` time of day to jump to after meshing
///   `BLOCKHAVEN_SNAPSHOT_CUSTOM_SHADER` 1 to render the real block shader,
///        which also switches the post-processing pass on
///   `BLOCKHAVEN_SNAPSHOT_REVEAL` 1 to build every chunk's buried half too
///   `BLOCKHAVEN_SNAPSHOT_EDITS`  blocks to place before meshing; see below
///   `BLOCKHAVEN_SNAPSHOT_HOUSE`  1, or "open", to build the showcase house
///        on levelled ground near the camera; see `ShowcaseHouse`
///   `BLOCKHAVEN_SNAPSHOT_DEMO`   1 to capture the demo world — its own seed,
///        its landmarks and its railway; see `DemoWorld`
///
/// A capture builds the *surface* half of each chunk and nothing else,
/// which is what the live game does for a chunk nobody has revealed, and
/// which makes this harness the acceptance test for the whole buried-face
/// scheme: a camera standing in the open has to produce the pixels it
/// produced before the split existed, or the classifier is culling
/// something visible. `BLOCKHAVEN_SNAPSHOT_REVEAL=1` builds both halves,
/// which is what a camera standing inside a cave needs — without it an
/// underground capture is a picture of the sky, because every wall around
/// it is geometry the live game would only have built on being asked.
///
/// `BLOCKHAVEN_POSTFX_DUMP=/path.png` replaces the capture below with one
/// taken from inside the post-process callback; see `PostProcessing`. That
/// only works when the pass is actually installed, which needs
/// `BLOCKHAVEN_SNAPSHOT_CUSTOM_SHADER=1` and not `BLOCKHAVEN_POSTFX=0` — if it
/// isn't, this falls back to the normal capture and says so, rather than
/// standing down in favour of a dump that will never fire.
enum OffscreenSnapshot {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["BLOCKHAVEN_SNAPSHOT"] != nil
    }
}

/// Drives the whole snapshot as an app delegate, because RealityKit needs a
/// live window and run loop to render at all.
final class SnapshotAppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var gameView: GameView!
    private var hudView: HUDView?
    private var inventoryView: InventoryView?
    private var pauseView: PauseMenuView?
    private let worldAnchor = AnchorEntity(world: .zero)
    private var world: World!
    private var camera: FirstPersonCamera!
    private var frameSubscription: (any Cancellable)?
    /// Held so the lineup isn't deallocated before the capture.
    private var fizzlerEntities: [FizzlerEntity] = []
    private var skeletonEntities: [SkeletonEntity] = []
    private var animalEntities: [AnimalEntity] = []
    private var framesRendered = 0
    /// Which rendered frame the capture is taken on. Twelve is enough for
    /// RealityKit to have everything on the GPU; a run asking for
    /// `BLOCKHAVEN_POSTFX_TIME=1` renders for several seconds instead, or
    /// the once-a-second timing report would never get to fire.
    private let captureFrame = PostProcessing.logsGPUTime ? 300 : 12

    private let environment = ProcessInfo.processInfo.environment
    /// True once `PostProcessing.install` has actually hung a callback on
    /// the view — which is what decides whether a requested dump can ever
    /// land.
    private var postFXInstalled = false

    /// Capture size. `BLOCKHAVEN_SNAPSHOT_SIZE=WxH` overrides the default;
    /// anything unparseable or smaller than 320x200 falls back to it, so a
    /// typo produces the usual shot rather than a degenerate window.
    private let size: CGSize = {
        let fallback = CGSize(width: 1600, height: 1000)
        guard let raw = ProcessInfo.processInfo.environment["BLOCKHAVEN_SNAPSHOT_SIZE"] else {
            return fallback
        }
        let parts = raw.lowercased().split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2, parts[0] >= 320, parts[1] >= 200 else { return fallback }
        return CGSize(width: parts[0], height: parts[1])
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let outputPath = environment["BLOCKHAVEN_SNAPSHOT"] ?? "/tmp/blockhaven.png"

        // `BLOCKHAVEN_SNAPSHOT_ATLAS=1` dumps the texture sheet instead of
        // rendering. Wrong-looking blocks are almost always an atlas
        // addressing bug, and this separates "sheet drawn wrong" from
        // "UVs point at the wrong slot".
        if environment["BLOCKHAVEN_SNAPSHOT_ATLAS"] != nil {
            writeImage(TextureAtlas.image, to: outputPath)
        }

        // The menu screens are pure Core Graphics and need no world, so they
        // capture without RealityKit ever starting up.
        if let image = drawMenuScreen(environment["BLOCKHAVEN_SNAPSHOT_UI"]) {
            writeImage(image, to: outputPath)
        }

        let yawDegrees = Double(environment["BLOCKHAVEN_SNAPSHOT_YAW"] ?? "") ?? 35
        let pitchDegrees = Double(environment["BLOCKHAVEN_SNAPSHOT_PITCH"] ?? "") ?? -12
        let timeOfDay = Double(environment["BLOCKHAVEN_SNAPSHOT_TIME"] ?? "") ?? 0.22

        // `BLOCKHAVEN_SNAPSHOT_DEMO=1` captures the demo world instead of
        // the default one. It needs its own seed rather than an edit list,
        // because the site is placed against that seed's terrain — and it
        // is the only way to look at the landmarks at all, since they are
        // built nowhere else.
        let demoSite = environment["BLOCKHAVEN_SNAPSHOT_DEMO"] != nil
        // `BLOCKHAVEN_SNAPSHOT_STORY=moon` shoots the Moon with its landing
        // pad and the Sleeping Garden built; `=home` the home world with the
        // survey station and the three sites, and the beacon lit on the Moon.
        let storyShot = environment["BLOCKHAVEN_SNAPSHOT_STORY"]
        if storyShot == "moon" {
            world = World(seed: GameSession.moonSeed(for: World().seed), kind: .moon)
        } else {
            world = demoSite ? World(seed: DemoWorld.seed) : World()
        }
        // How much world this capture builds, in chunks. `_RADIUS` is the
        // explicit cheap-capture override and wins whenever it is set;
        // otherwise a run that asked for a render distance gets the one it
        // asked for, already clamped, sitting in `world.renderDistance`. A
        // capture with neither stays at 4, which is what keeps an unadorned
        // snapshot a second rather than most of a minute — but it is *not*
        // the distance the game ships at, so anything being judged against
        // the real horizon (fog falloff, haze, vertex counts) has to say
        // which distance it wants. See the README.
        //
        // Both are parsed, not merely tested for presence. `World` falls
        // back to the *shipping* distance when `_RENDER_DISTANCE` will not
        // parse, so testing this one for `nil` alone gave a typo a
        // 317-chunk capture where 49 was asked for — six times the geometry
        // and a picture that cannot be compared against any other in the
        // battery, with nothing on stderr to say why. Garbage falls back to
        // 4 like every other setting read here.
        let radius = Int(environment["BLOCKHAVEN_SNAPSHOT_RADIUS"] ?? "")
            ?? (Int(environment["BLOCKHAVEN_RENDER_DISTANCE"] ?? "") != nil ? world.renderDistance : 4)
        world.renderDistance = radius
        // Match the fog to the slice of world this capture actually builds,
        // otherwise the horizon edge shows through the haze.
        MaterialLibrary.setRenderDistance(blocks: Float(radius * Chunk.width))
        let sky = SkyController()
        sky.setTimeOfDay(timeOfDay)
        // `BLOCKHAVEN_SNAPSHOT_WEATHER=rain|clear` forces the day counter
        // `isRaining` reads, independent of `_TIME` — the two are otherwise
        // entangled on a freshly booted clock (day index always starts at
        // zero), so this is the only way to shoot the same time of day wet
        // and dry for comparison.
        switch environment["BLOCKHAVEN_SNAPSHOT_WEATHER"] {
        case "rain": sky.setWeatherDayIndex(0)
        case "clear": sky.setWeatherDayIndex(1)
        default: break
        }

        // The site goes in before anything is generated, so the ring of
        // chunks below arrives with it already in the journal.
        if demoSite { DemoWorld.build(in: world) }
        switch storyShot {
        case "moon":
            sky.clock.isLunar = true
            sky.clock.beaconSteady = true
            _ = StoryBuilder.buildMoonLanding(world)
            _ = StoryBuilder.buildGarden(world)
        case "home":
            sky.clock.beaconSteady = true
            let spawn = world.spawnPosition()
            let site = StoryBuilder.stationSite(world, spawn: (Int(spawn.x), Int(spawn.z)))
            let station = StoryBuilder.buildStation(world, at: site)
            StandardError.write(Data("[snapshot] station radio at \(station.radio.x),\(station.radio.y),\(station.radio.z)\n".utf8))
            for (name, radio) in [
                ("spire", StoryBuilder.buildSpire(world, near: site)),
                ("vault", StoryBuilder.buildVault(world, near: site)),
                ("wreck", StoryBuilder.buildWreck(world, near: site)),
            ] {
                StandardError.write(Data("[snapshot] \(name) radio at \(radio.x),\(radio.y),\(radio.z)\n".utf8))
            }
        default:
            break
        }

        // Choose the eye first so the right chunks get built.
        var eye = (demoSite ? DemoWorld.spawn : world.spawnPosition())
            + Vector3(0, PlayerController.standingEyeHeight, 0)
        var eyeExplicit = false
        if let spec = environment["BLOCKHAVEN_SNAPSHOT_POS"] {
            let parts = spec.split(separator: ",").compactMap { Double($0) }
            if parts.count == 3 {
                eye = Vector3(CGFloat(parts[0]), CGFloat(parts[1]), CGFloat(parts[2]))
                eyeExplicit = true
            }
        }

        let center = World.chunkCoord(forWorldX: Int(floor(eye.x)), worldZ: Int(floor(eye.z)))
        // One extra ring of data so the outermost meshed chunks still cull
        // their seam faces against real neighbours.
        for dz in -(radius + 1)...(radius + 1) {
            for dx in -(radius + 1)...(radius + 1) {
                world.forceGenerate(ChunkCoord(x: center.x + dx, z: center.z + dz))
            }
        }

        // `BLOCKHAVEN_SNAPSHOT_HOUSE=1` (or `=open`) builds the showcase
        // house near the camera before anything is meshed — the same
        // `World.setBlock` the scripted edits below use, just with the
        // coordinates written as loops instead of by hand.
        if let houseMode = environment["BLOCKHAVEN_SNAPSHOT_HOUSE"] {
            ShowcaseHouse.build(in: world, doorOpen: houseMode == "open")
        }

        applyScriptedEdits(eye: eye)
        // `BLOCKHAVEN_SNAPSHOT_POUR="x,y,z"` runs `WaterFlow.spread` from a
        // cell the edits above already placed a water source at — the
        // scripted edits themselves only ever call `World.setBlock`
        // directly, the same as a structure builder, so a source placed by
        // one sits exactly where it was put until something asks it to
        // spread the way a bucket actually would.
        if let spec = environment["BLOCKHAVEN_SNAPSHOT_POUR"] {
            let parts = spec.split(separator: ",").compactMap { Int($0) }
            if parts.count == 3 {
                WaterFlow.spread(from: (parts[0], parts[1], parts[2]), world: world)
            }
        }

        // The demo's spawn is a paved plaza that was put there on purpose,
        // so it is not re-derived from the terrain the way a default
        // capture's is.
        if !eyeExplicit, !demoSite {
            var player = PlayerController(spawn: world.spawnPosition())
            player.resolveSpawnOverlap(world: world)
            eye = player.eyePosition
        }

        window = NSWindow(
            contentRect: NSRect(origin: CGPoint(x: -20000, y: -20000), size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        gameView = GameView(frame: NSRect(origin: .zero, size: size))
        window.contentView = gameView
        window.orderFrontRegardless()

        gameView.environment.background = .color(sky.skyColor)
        gameView.scene.addAnchor(worldAnchor)

        // Post-processing rides with the custom shader, not on its own. The
        // default snapshot is a geometry and texture check — atlas
        // addressing, mob models, UI overlays — and a bloom pass sitting on
        // top of that would only make those harder to read.
        if environment["BLOCKHAVEN_SNAPSHOT_CUSTOM_SHADER"] == "1" {
            postFXInstalled = PostProcessing.install(on: gameView)
        }

        camera = FirstPersonCamera()
        camera.attach(to: worldAnchor)
        var pose = CameraState()
        pose.reset(
            yaw: CGFloat(yawDegrees) * .pi / 180,
            pitch: CGFloat(pitchDegrees) * .pi / 180
        )
        pose.update(dt: 0, eyePosition: eye, horizontalSpeed: 0, isGrounded: true)
        camera.apply(pose)
        sky.apply(view: gameView, eye: SIMD3<Float>(eye))

        var meshed = 0
        var gatherSeconds = 0.0
        var buildSeconds = 0.0
        var uploadSeconds = 0.0
        var vertexCount = 0
        var buriedCount = 0
        var buriedTranslucentCount = 0
        var brightestTorch: UInt32 = 0
        let smooth = MaterialLibrary.usesCustomShader
        // A snapshot builds the *surface* half of every chunk and nothing
        // else, exactly like the live game does for a chunk nobody has
        // revealed. That is deliberate and it is the acceptance test for
        // the whole buried-culling scheme: a camera standing in the open
        // must produce the same pixels it did before the split existed.
        // `BLOCKHAVEN_SNAPSHOT_REVEAL=1` builds both halves, which is how a
        // camera inside a cave gets something to look at.
        let wanted: ChunkMesher.FaceSet =
            environment["BLOCKHAVEN_SNAPSHOT_REVEAL"] == "1" ? .all : .surface
        // The three stages are timed apart because the live game splits
        // them across threads: gather and upload stay on the frame, build
        // does not, so knowing which is which is knowing what a chunk
        // actually costs the render loop.
        for chunk in world.chunksReadyToMesh(around: center) {
            var mark = CFAbsoluteTimeGetCurrent()
            let neighbourhood = ChunkMesher.gatherNeighbourhood(chunk: chunk, in: world)
            gatherSeconds += CFAbsoluteTimeGetCurrent() - mark

            mark = CFAbsoluteTimeGetCurrent()
            let data = ChunkMesher.buildMeshData(
                from: neighbourhood, smoothShading: smooth, faces: wanted
            )
            buildSeconds += CFAbsoluteTimeGetCurrent() - mark
            // The brightest lamp light that made it into a vertex, reported
            // below. A capture of a lit structure that comes back with zero
            // here has the light in the world and not in the picture, which
            // is a distinction nothing else in the harness can draw — the
            // render just looks a bit dark, and "a bit dark" at night is
            // what it is supposed to look like.
            for buffer in [data.opaque, data.buried, data.translucent].compactMap({ $0 }) {
                for vertex in buffer.vertices {
                    brightestTorch = max(brightestTorch, vertex.shade >> 24)
                }
            }
            vertexCount += data.vertexCount
            buriedCount += data.buriedVertexCount
            buriedTranslucentCount += data.buriedTranslucentVertexCount

            mark = CFAbsoluteTimeGetCurrent()
            let origin = SIMD3<Float>(Float(chunk.originX), 0, Float(chunk.originZ))
            for buffer in [data.opaque, data.buried] {
                guard let buffer, let mesh = ChunkMesher.makeMesh(from: buffer) else { continue }
                let entity = ModelEntity(mesh: mesh, materials: [MaterialLibrary.opaqueBlocks])
                entity.position = origin
                worldAnchor.addChild(entity)
                MaterialLibrary.track(entity, translucent: false)
            }
            if let buffer = data.translucent, let mesh = ChunkMesher.makeMesh(from: buffer) {
                let entity = ModelEntity(mesh: mesh, materials: [MaterialLibrary.translucentBlocks])
                entity.position = origin
                worldAnchor.addChild(entity)
                MaterialLibrary.track(entity, translucent: true)
            }
            uploadSeconds += CFAbsoluteTimeGetCurrent() - mark

            world.markMeshed(chunk)
            meshed += 1
        }
        let per = 1000 / Double(max(1, meshed))
        let meshLine = String(
            format: "[snapshot] meshed %d chunks · %d vertices"
                + " (%@, %d buried, %d buried translucent) · per chunk:"
                + " gather %.2f ms · build %.2f ms · upload %.2f ms"
                + " · brightest lamp %d/255 · smooth %@\n",
            meshed, vertexCount, wanted == .all ? "revealed" : "surface only",
            buriedCount, buriedTranslucentCount,
            gatherSeconds * per, buildSeconds * per, uploadSeconds * per,
            brightestTorch, smooth ? "yes" : "no"
        )
        StandardError.write(Data(meshLine.utf8))

        installUIOverlay()
        installMobLineup(eye: eye, yawDegrees: yawDegrees)
        installAnimalPortrait(eye: eye, yawDegrees: yawDegrees, pitchDegrees: pitchDegrees)

        // `BLOCKHAVEN_SNAPSHOT_REGRADE=<t>` jumps the clock *after* the world
        // is meshed and re-applies the grade, which is the one thing a
        // normal snapshot cannot check: the live game meshes chunks once and
        // then re-grades them for hours of game time. Shoot the same view
        // twice — `TIME=t` against `TIME=x REGRADE=t` — and the two should
        // be identical. They were not before `MaterialLibrary.track`: the
        // sky moved and the terrain stayed at the daylight it was built in.
        if let later = Double(environment["BLOCKHAVEN_SNAPSHOT_REGRADE"] ?? "") {
            sky.setTimeOfDay(later)
            sky.apply(view: gameView, eye: SIMD3<Float>(eye))
        }

        // The post-process pass reads the sun's place in camera space from
        // here. Nothing moves in a snapshot, so publishing it once — after
        // any regrade has settled the clock — is enough.
        PostProcessing.publishSun(timeOfDay: sky.timeOfDay, camera: camera.cameraEntity)

        // Wait for RealityKit to actually put frames on screen before
        // capturing — the first frame has nothing uploaded to the GPU yet.
        frameSubscription = gameView.scene.subscribe(to: SceneEvents.Update.self) { [weak self] _ in
            guard let self else { return }
            framesRendered += 1
            if framesRendered == captureFrame {
                frameSubscription = nil
                // `ARView.snapshot` does see the post-process pass, so the
                // normal path below is enough to check it. But when
                // `BLOCKHAVEN_POSTFX_DUMP` asks for a capture taken from
                // inside the render callback, that path owns the file and
                // the exit, and this one stands down.
                //
                // Only when the callback is actually there, though. A dump
                // asked for without `BLOCKHAVEN_SNAPSHOT_CUSTOM_SHADER=1`, or
                // with `BLOCKHAVEN_POSTFX=0`, used to stand this path down in
                // favour of a dump that could never fire: nothing was
                // written and the run exited 2 after twenty seconds.
                if PostProcessing.isDumpRequested && postFXInstalled {
                    startDumpWatchdog()
                } else {
                    if PostProcessing.isDumpRequested {
                        let note = "[snapshot] BLOCKHAVEN_POSTFX_DUMP asked for, but the post-process"
                            + " pass is not installed (needs BLOCKHAVEN_SNAPSHOT_CUSTOM_SHADER=1 and"
                            + " not BLOCKHAVEN_POSTFX=0) — capturing normally instead\n"
                        StandardError.write(Data(note.utf8))
                    }
                    capture(to: outputPath)
                }
            }
        }

        // Don't hang forever if the scene never draws — report how far it
        // got and bail, so a stalled renderer looks like a failure rather
        // than a wedged process.
        // A timing run has five hundred frames to render, not twelve, so it
        // gets proportionally longer before this calls the renderer dead.
        let patience: TimeInterval = PostProcessing.logsGPUTime ? 60 : 20
        Timer.scheduledTimer(withTimeInterval: patience, repeats: false) { [weak self] _ in
            guard let self, frameSubscription != nil else { return }
            // occlusionState is the thing to check first if this ever fires
            // again: a window the compositor considers not `.visible` is
            // exactly the condition that stops RealityKit scheduling
            // updates. Measured `.visible` (8192) for the off-screen
            // position this harness uses; if that regresses on some other
            // machine or OS version, this line is the evidence, not a guess.
            let message = "[snapshot] gave up after \(Int(patience))s — only \(framesRendered) frames rendered, "
                + "occlusionState=\(window.occlusionState.rawValue)\n"
            StandardError.write(Data(message.utf8))
            exit(2)
        }
    }

    /// A dump writes its file from a command-buffer completion handler and
    /// exits there. If that never lands, this stops the process wedging.
    private func startDumpWatchdog() {
        Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { _ in
            StandardError.write(Data("[snapshot] postfx dump never landed\n".utf8))
            exit(2)
        }
    }

    /// `BLOCKHAVEN_SNAPSHOT_FIZZLERS=1` stands a row of fizzlers in front of
    /// the camera at increasing fuse stages, one skeleton just past them,
    /// plus every land animal there is off to one side, so mob rendering —
    /// models, procedural skins, hurt tint — can be checked without waiting
    /// for nightfall or a spawn to wander into view. Everything here uses
    /// `UnlitMaterial` the same way
    /// the live game does for mobs, so it exercises geometry and textures,
    /// not the block shader (see the file header).
    @MainActor
    private func installMobLineup(eye: Vector3, yawDegrees: Double) {
        guard environment["BLOCKHAVEN_SNAPSHOT_FIZZLERS"] != nil else { return }

        let yaw = CGFloat(yawDegrees) * .pi / 180
        let forward = Vector3(sin(yaw), 0, cos(yaw))
        let right = Vector3(-forward.z, 0, forward.x)
        let swells: [Double] = [0, 0, 0.45, 0.8, 0.97]

        for (index, swell) in swells.enumerated() {
            let offset = CGFloat(index) - CGFloat(swells.count - 1) / 2
            let spot = groundedSpot(eye + forward * 7 + right * (offset * 1.6), eye: eye)
            let entity = FizzlerEntity()
            // Face the camera, so the lineup shows the face texture.
            entity.place(position: spot, facing: yaw + .pi, swell: swell)
            worldAnchor.addChild(entity.root)
            fizzlerEntities.append(entity)
        }

        // One skeleton, in the same open ground the fizzler row stands on
        // rather than straight ahead into whatever terrain happens to sit
        // on the camera's own bearing — the whole point of it is reading
        // as a different silhouette in the same frame as the fizzlers.
        let skeletonOffset = CGFloat(swells.count - 1) / 2 + 1.8
        let skeletonSpot = groundedSpot(eye + forward * 7 + right * skeletonOffset, eye: eye)
        let skeletonEntity = SkeletonEntity()
        skeletonEntity.place(position: skeletonSpot, facing: yaw + .pi)
        worldAnchor.addChild(skeletonEntity.root)
        skeletonEntities.append(skeletonEntity)

        // Strung out along one clear bearing to the left, at increasing
        // distance rather than side by side — spawn terrain at the default
        // eye position puts a tree trunk dead ahead and rising ground to
        // the right, and this bearing is the gap between them that stays
        // open at any depth, verified against an actual render rather than
        // picked by eye.
        //
        // Built from `allCases` rather than written out, so a kind added
        // later cannot be silently missing from the one shot whose job is
        // to answer "are the mobs rendering". The swimmers are left out
        // because this bearing is dry land — they belong to the portrait,
        // which can put them where they live.
        let kinds = AnimalKind.allCases.filter { !$0.isAquatic }
        for (index, kind) in kinds.enumerated() {
            let depth: CGFloat = 5.5 + CGFloat(index) * 2.5
            let spot = groundedSpot(eye + forward * depth - right * (depth * 1.05), eye: eye)
            let entity = AnimalEntity(kind: kind)
            entity.place(position: spot, facing: yaw + .pi)
            worldAnchor.addChild(entity.root)
            animalEntities.append(entity)
        }
    }

    /// `BLOCKHAVEN_SNAPSHOT_ANIMAL=<kind>` puts one animal right on the
    /// camera's line of sight, close enough to fill the frame, so a model
    /// can be looked at rather than squinted at across a field. The lineup
    /// above answers "are the mobs rendering"; this answers "is that the
    /// right shape".
    ///
    ///   `BLOCKHAVEN_SNAPSHOT_ANIMAL`       `pig`, `cow`, `sheep`, `axolotl`
    ///   `BLOCKHAVEN_SNAPSHOT_ANIMAL_POSE`  `swim` hovers it with the tail
    ///        swung over; `land` stands it on the ground mid-stride.
    ///        Only the axolotl has either; everything else stands still.
    ///   `BLOCKHAVEN_SNAPSHOT_ANIMAL_DIST`  blocks from the eye, default 1.5
    ///   `BLOCKHAVEN_SNAPSHOT_ANIMAL_TURN`  degrees off face-on, default 40,
    ///        which is the three-quarter view that shows a face and a
    ///        profile in the one picture.
    ///   `BLOCKHAVEN_SNAPSHOT_ANIMAL_DROP`  blocks below the sight line, for
    ///        sinking a swimmer under the surface of a pond without having
    ///        to solve for the pitch that would have put it there.
    ///   `BLOCKHAVEN_SNAPSHOT_ANIMAL_RARE=1` the rare colour, where the kind
    ///        has one — which is the only way to see a cyan axolotl on
    ///        purpose rather than waiting for one spawn in ten.
    @MainActor
    private func installAnimalPortrait(eye: Vector3, yawDegrees: Double, pitchDegrees: Double) {
        guard let name = environment["BLOCKHAVEN_SNAPSHOT_ANIMAL"] else { return }
        // From `allCases`, not a hand-written map: the map this replaces
        // had to be edited before a new animal could be photographed at
        // all, which put the one instrument that can see a new model behind
        // a line somebody had to remember to write.
        let wanted = name.lowercased()
        guard let kind = AnimalKind.allCases.first(where: { $0.identifier == wanted }) else {
            let known = AnimalKind.allCases.map(\.identifier).sorted().joined(separator: ", ")
            fail("no animal called \"\(name)\" — try \(known)")
        }

        let distance = CGFloat(Double(environment["BLOCKHAVEN_SNAPSHOT_ANIMAL_DIST"] ?? "") ?? 1.5)
        let turn = Double(environment["BLOCKHAVEN_SNAPSHOT_ANIMAL_TURN"] ?? "") ?? 40
        // Defaults to whichever pose the animal actually holds: a chicken
        // photographed swimming has its wings thrown out like a gull, which
        // is a picture of the harness rather than of the bird.
        let pose = environment["BLOCKHAVEN_SNAPSHOT_ANIMAL_POSE"]
            ?? (kind.isAquatic ? "swim" : "land")
        let yaw = CGFloat(yawDegrees) * .pi / 180
        let pitch = CGFloat(pitchDegrees) * .pi / 180

        // Straight down the barrel: the same forward the camera is looking
        // along, pitch included, so the subject lands in the middle of the
        // frame whatever angle the shot was set up at.
        let sight = Vector3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch))
        var subject = eye + sight * distance
        // The entity's origin is its feet, so drop it by half its height to
        // put the body — not the toes — on the sight line.
        subject.y -= kind.height / 2
        subject.y -= CGFloat(Double(environment["BLOCKHAVEN_SNAPSHOT_ANIMAL_DROP"] ?? "") ?? 0)

        let rare = environment["BLOCKHAVEN_SNAPSHOT_ANIMAL_RARE"] == "1"
        // More than one is the only way to photograph a shoal at all: the
        // thing worth looking at about a cod is what six of them do, and
        // one cod on its own is a picture of the bug.
        let count = max(1, min(12, Int(environment["BLOCKHAVEN_SNAPSHOT_ANIMAL_COUNT"] ?? "") ?? 1))
        let facing = yaw + .pi + CGFloat(turn) * .pi / 180

        for index in 0..<count {
            let entity = AnimalEntity(kind: kind, morph: rare ? .rare : .common)
            // A loose spiral out from the subject rather than a row, so the
            // group reads as a group from any bearing and no two members
            // land in the same cell. The first is exactly where a single
            // portrait would have put it, so `_COUNT=1` is unchanged.
            let turnOut = Double(index) * 2.4
            let reach = CGFloat(Double(index).squareRoot()) * kind.halfWidth * 3.2
            var spot = subject
                + Vector3(CGFloat(cos(turnOut)) * reach, 0, CGFloat(sin(turnOut)) * reach)
            spot.y += CGFloat(index % 3) * kind.height * 0.6

            if pose == "land" {
                spot = groundedSpot(spot, eye: eye)
                entity.poseWalking(1.0)
            } else {
                entity.poseSwimming(0.55 + Float(index) * 0.7)
            }
            entity.place(position: spot, facing: facing + CGFloat(index) * 0.18)
            worldAnchor.addChild(entity.root)
            animalEntities.append(entity)
        }

        StandardError.write(Data(
            String(format: "[snapshot] %@ portrait ×%d, %@ pose, at (%.2f, %.2f, %.2f)\n",
                   name, count, pose, subject.x, subject.y, subject.z).utf8
        ))
    }

    /// Drops a point onto the ground under it, starting a few blocks above
    /// the eye so it works whether the terrain there is higher or lower
    /// than the camera.
    ///
    /// A tree is not ground. Leaves and trunks are solid, so a plain "first
    /// solid thing below" walk stops on the canopy — and the spawn camera
    /// stands under a tree, so that is the default. The subject ends up
    /// three blocks over the eye, out of frame, and the capture comes back
    /// as an empty picture with no error: exactly what a mob that failed to
    /// render looks like, from the one instrument that is supposed to tell
    /// the difference.
    private func groundedSpot(_ point: Vector3, eye: Vector3) -> Vector3 {
        var spot = point
        let x = Int(floor(spot.x)), z = Int(floor(spot.z))
        var y = Int(floor(eye.y)) + 3
        while y > 1, !isGround(worldX: x, y: y - 1, worldZ: z) { y -= 1 }
        spot.y = CGFloat(y)
        return spot
    }

    /// Solid, and part of the landscape rather than of a tree standing on
    /// it. Snow and sand count; leaves and logs do not.
    private func isGround(worldX x: Int, y: Int, worldZ z: Int) -> Bool {
        switch world.block(worldX: x, y: y, worldZ: z) {
        case .leaves, .log: return false
        case let block: return block.isSolid
        }
    }

    /// Puts blocks in the world before it is meshed, so a capture can show
    /// something that is not terrain.
    ///
    /// Everything the game builds — stairs, doors, panes, beds, a whole
    /// house — arrives by a player edit, and a snapshot has no player. So
    /// this drives the same `World.setBlock` the game's own edits go
    /// through, from a line of environment.
    ///
    ///   `BLOCKHAVEN_SNAPSHOT_EDITS="x,y,z,block; x,y,z,block; …"`
    ///   `BLOCKHAVEN_SNAPSHOT_EDITS=@/path/to/file` reads the same syntax
    ///        from a file, one edit per line, `#` starting a comment —
    ///        which is how anything bigger than a doorway gets built.
    ///
    /// `g<n>` is resolved *per line*, against the ground as it stands when
    /// that line runs — so a script that lowers a column changes what every
    /// later `g` in it means. Digging a pond is the case that bites: water
    /// is not solid, so filling a column top-down moves the ground out from
    /// under the next line. Fill each column bottom-up instead.
    ///
    /// `block` is the `BlockType` case name, so `oakStairsEast`,
    /// `oakDoorLowerNorthOpen`, `glassPane`. Each coordinate is either an
    /// absolute cell, `~n` for n cells from the camera's own cell, or — for
    /// y only — `gn` for n cells above the ground in that column, which is
    /// what lets one script build the same house wherever the terrain
    /// happens to put it.
    ///
    /// A line that will not parse ends the run. A capture whose subject
    /// silently failed to appear is a picture of the thing being tested not
    /// being tested.
    private func applyScriptedEdits(eye: Vector3) {
        guard var spec = environment["BLOCKHAVEN_SNAPSHOT_EDITS"] else { return }
        if spec.hasPrefix("@") {
            let path = String(spec.dropFirst())
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
                fail("could not read scripted edits from \(path)")
            }
            spec = text
        }

        let eyeCell = (
            x: Int(floor(eye.x)), y: Int(floor(eye.y)), z: Int(floor(eye.z))
        )

        /// An absolute cell, or one relative to the camera's own.
        func offset(_ text: Substring, from origin: Int) -> Int? {
            guard text.hasPrefix("~") else { return Int(text) }
            let rest = text.dropFirst()
            if rest.isEmpty { return origin }
            guard let delta = Int(rest) else { return nil }
            return origin + delta
        }

        /// The first free cell over whatever the ground is in this column,
        /// plus an offset.
        func aboveGround(x: Int, z: Int, plus delta: Int) -> Int {
            var top = Chunk.height - 1
            while top > 0, !world.block(worldX: x, y: top, worldZ: z).isSolid { top -= 1 }
            return top + 1 + delta
        }

        var placed = 0
        for rawEntry in spec.split(whereSeparator: { $0 == ";" || $0 == "\n" }) {
            let entry = rawEntry.prefix { $0 != "#" }
                .trimmingCharacters(in: .whitespaces)
            if entry.isEmpty { continue }
            let fields = entry.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)[...]
            }
            guard fields.count == 4 else { fail("edit \"\(entry)\" is not x,y,z,block") }
            guard let x = offset(fields[0], from: eyeCell.x),
                  let z = offset(fields[2], from: eyeCell.z) else {
                fail("edit \"\(entry)\" has a coordinate that will not parse")
            }
            let y: Int
            if fields[1].hasPrefix("g") {
                let rest = fields[1].dropFirst()
                guard let delta = rest.isEmpty ? 0 : Int(rest) else {
                    fail("edit \"\(entry)\" has a ground offset that will not parse")
                }
                y = aboveGround(x: x, z: z, plus: delta)
            } else if let absolute = offset(fields[1], from: eyeCell.y) {
                y = absolute
            } else {
                fail("edit \"\(entry)\" has a coordinate that will not parse")
            }
            guard let block = BlockType.named(String(fields[3])) else {
                fail("edit \"\(entry)\" names no block called \"\(fields[3])\"")
            }
            world.setBlock(worldX: x, y: y, worldZ: z, to: block)
            placed += 1
        }
        StandardError.write(
            Data("[snapshot] scripted edits: \(placed) blocks placed\n".utf8)
        )
    }

    private func fail(_ message: String) -> Never {
        StandardError.write(Data("[snapshot] \(message)\n".utf8))
        exit(2)
    }

    /// Renders one of the menu screens, or nil if this run wants something
    /// else.
    ///
    /// These are ordinary `NSView`s drawn straight into an image: none of
    /// them needs a world, a window or a GPU, so they capture in
    /// milliseconds rather than after a minute of meshing. They are drawn
    /// by calling `draw` directly, which is exactly why the field on the
    /// naming panel is Core Graphics and not an `NSTextField` — a subview
    /// would be invisible here.
    ///
    /// What they show comes off the real catalogue, so pointing a capture
    /// at a `BLOCKHAVEN_SAVE_DIR` full of worlds is how the multi-world
    /// screens get shot with real rows in them rather than invented ones.
    /// Reading it is all this does: a capture writes a PNG and nothing else,
    /// migration included — that belongs to the game's own launch.
    ///   `BLOCKHAVEN_SNAPSHOT_UI=menu`    the start menu
    ///   `BLOCKHAVEN_SNAPSHOT_UI=worlds`  the load-a-world list
    ///   `BLOCKHAVEN_SNAPSHOT_UI=naming`  the naming panel over the cards
    /// with `BLOCKHAVEN_SNAPSHOT_HOVER=<n>` lighting a card or a list row,
    /// and `BLOCKHAVEN_SNAPSHOT_NAME=<text>` filling the name field.
    private func drawMenuScreen(_ mode: String?) -> NSImage? {
        let bounds = NSRect(origin: .zero, size: size)
        let hover = Int(environment["BLOCKHAVEN_SNAPSHOT_HOVER"] ?? "")

        func startMenu() -> StartMenuView {
            let worlds = WorldCatalog.entries()
            let menu = StartMenuView(frame: bounds)
            menu.continueWorld = worlds.first
            menu.worldCount = worlds.count
            menu.previewHover(hover)
            return menu
        }

        var layers: [NSView] = []
        switch mode {
        case "menu":
            layers = [startMenu()]
        case "worlds":
            let list = WorldListView(frame: bounds, worlds: WorldCatalog.entries())
            list.previewSelection(hover ?? 0)
            layers = [list]
        case "naming":
            let modeName = environment["BLOCKHAVEN_SNAPSHOT_NAME_MODE"] ?? "survival"
            let panel = NewWorldNameView(
                frame: bounds,
                mode: GameMode(rawValue: modeName) ?? .survival
            )
            if let typed = environment["BLOCKHAVEN_SNAPSHOT_NAME"] { panel.setTypedName(typed) }
            // Over the cards, because that is where it lives — a capture of
            // the panel on black would not show that the menu is still
            // behind it waiting to be gone back to.
            layers = [startMenu(), panel]
        default:
            return nil
        }

        let image = NSImage(size: size)
        image.lockFocus()
        for layer in layers { layer.draw(layer.bounds) }
        image.unlockFocus()
        return image
    }

    /// Optionally overlays the HUD or an inventory screen, rendered into
    /// the snapshot the same way the live game composites them.
    private func installUIOverlay() {
        guard let mode = environment["BLOCKHAVEN_SNAPSHOT_UI"] else { return }
        let inventory = Inventory()
        // `_UI=creative` shows the palette a creative world actually opens
        // with, which is the only way to check that a newly added item
        // reaches the player at all — and the only way to look at its icon
        // without playing to the point of holding one.
        if mode.hasPrefix("creative") {
            inventory.grantCreativeKit()
        } else {
            inventory.grantStarterKit()
            // Worn, because a fresh tool draws no durability bar and a
            // capture of the hotbar is the only way to look at one. Three
            // depths, so the green-to-red ramp is visible across them.
            inventory[0] = ItemStack(.woodenSword, wear: 40)
            inventory[1] = ItemStack(.woodenPickaxe, wear: 20)
            inventory[2] = ItemStack(.stoneAxe, wear: 124)
            // A few extra stacks so the main grid isn't blank in the capture.
            inventory.add(ItemStack(.cobblestone, count: 48))
            inventory.add(ItemStack(.dirt, count: 64))
            inventory.add(ItemStack(.log, count: 12))
            inventory.add(ItemStack(.coal, count: 7))
            inventory.add(ItemStack(.ironIngot, count: 3))
            inventory.add(ItemStack(.diamond, count: 2))
        }

        // `_UI=book` opens the recipe book over the 3×3 table screen, and
        // `_UI=book2x2` over the 2×2 one — which is the shot that shows the
        // house and tool rows greyed out, the thing the book is for.
        // `BLOCKHAVEN_SNAPSHOT_HOVER=<n>` puts the cursor on row n (headings
        // count as rows) so the hover note can be seen, and
        // `BLOCKHAVEN_SNAPSHOT_SCROLL=<points>` scrolls the list down.
        if mode.hasPrefix("book") {
            inventory.add(ItemStack(.sand, count: 16))
            inventory.add(ItemStack(.wool, count: 6))
            inventory.add(ItemStack(.rawIron, count: 4))
            inventory.add(ItemStack(.rawGold, count: 2))
        }

        switch mode {
        case "inventory", "table", "creative", "creativebook", "book", "book2x2", "chest":
            // `_UI=chest` fills one with a bit of everything, because an
            // empty chest is a picture of twenty-seven empty squares.
            var chest: Chest?
            if mode == "chest" {
                let filled = Chest()
                filled.add(ItemStack(.cobblestone, count: 64))
                filled.add(ItemStack(.oakStairs, count: 12))
                filled.add(ItemStack(.torch, count: 30))
                filled.add(ItemStack(.diamond, count: 3))
                filled.add(ItemStack(.ironPickaxe))
                chest = filled
            }
            let screen = InventoryView(
                frame: NSRect(origin: .zero, size: size),
                inventory: inventory,
                gridSize: (mode == "inventory" || mode == "book2x2" || mode == "chest") ? 2 : 3,
                creative: mode.hasPrefix("creative"),
                chest: chest
            )
            if mode.hasPrefix("book") {
                screen.previewBook(
                    hover: Int(environment["BLOCKHAVEN_SNAPSHOT_HOVER"] ?? ""),
                    scroll: CGFloat(Double(environment["BLOCKHAVEN_SNAPSHOT_SCROLL"] ?? "") ?? 0)
                )
            }
            if mode == "creativebook" { screen.toggleBook() }
            if mode.hasPrefix("creative") {
                screen.previewPalette(
                    hover: Int(environment["BLOCKHAVEN_SNAPSHOT_HOVER"] ?? ""),
                    scroll: CGFloat(Double(environment["BLOCKHAVEN_SNAPSHOT_SCROLL"] ?? "") ?? 0)
                )
            }
            inventoryView = screen
        case "pause":
            // The pause screen dims whatever is behind it, so unlike the
            // start menu it is only honest composited over a real render.
            let pause = PauseMenuView(frame: NSRect(origin: .zero, size: size))
            // `_WARNING=1` shows the screen as it looks when a save has just
            // failed — the one state of this panel that can't be reached by
            // pressing Esc, and so the one that would otherwise ship
            // unlooked-at.
            if environment["BLOCKHAVEN_SNAPSHOT_WARNING"] != nil {
                pause.warning = GameViewController.saveFailureMessage
            }
            if let hover = Int(environment["BLOCKHAVEN_SNAPSHOT_HOVER"] ?? "") {
                pause.previewSelection(hover)
            }
            pauseView = pause
        case "hud":
            let hud = HUDView(frame: NSRect(origin: .zero, size: size))
            var state = HUDView.State()
            state.hotbar = (0..<Inventory.hotbarSize).map { inventory[$0] }
            state.selectedSlot = 0
            state.debugText = "Blockhaven — snapshot (RealityKit)\nHUD preview"
            state.itemName = inventory[0]?.type.displayName
            // `_COMPASS="<degrees>,<distance>"` previews the dial without
            // needing a live bed/spawn and a walk to test it against.
            // A trailing `,grave` previews the needle pointing at an
            // unclaimed grave instead of home, without needing a real
            // death first.
            if let spec = environment["BLOCKHAVEN_SNAPSHOT_COMPASS"] {
                let tokens = spec.split(separator: ",").map { String($0) }
                let parts = tokens.compactMap { Double($0) }
                if parts.count >= 2 {
                    inventory[0] = ItemStack(.compass)
                    state.compassBearing = CGFloat(parts[0] * .pi / 180)
                    state.compassDistance = CGFloat(parts[1])
                    state.compassTargetsGrave = tokens.contains("grave")
                    state.itemName = ItemType.compass.displayName
                    state.hotbar[0] = inventory[0]
                }
            }
            // `_ARMOR=iron` or `=diamond` previews the worn-chestplate icon
            // without needing a live equip gesture to test it against.
            if let tier = environment["BLOCKHAVEN_SNAPSHOT_ARMOR"] {
                state.equippedChestplate = tier == "diamond" ? .diamondChestplate
                    : tier == "iron" ? .ironChestplate : nil
            }
            hud.update(state)
            hudView = hud
        default:
            break
        }
    }

    /// Captures the rendered frame and composites any AppKit overlay on
    /// top, since `ARView.snapshot` only sees the RealityKit content.
    private func capture(to path: String) {
        gameView.snapshot(saveToHDR: false) { [weak self] image in
            guard let self else { return }
            guard let image else {
                StandardError.write(Data("[snapshot] ARView.snapshot returned nil\n".utf8))
                exit(1)
            }
            self.writeImage(self.compositeOverlays(over: image), to: path)
        }
    }

    /// Encodes an image as PNG, reports where it went, and ends the run —
    /// every snapshot path finishes here.
    private func writeImage(_ image: NSImage, to path: String) -> Never {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            StandardError.write(Data("[snapshot] could not encode PNG\n".utf8))
            exit(1)
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            print("[snapshot] wrote \(path)")
            exit(0)
        } catch {
            StandardError.write(Data("[snapshot] write failed: \(error)\n".utf8))
            exit(1)
        }
    }

    private func compositeOverlays(over base: NSImage) -> NSImage {
        let overlays: [NSView] = [inventoryView, hudView, pauseView].compactMap { $0 }
        guard !overlays.isEmpty else { return base }

        let result = NSImage(size: size)
        result.lockFocus()
        base.draw(in: NSRect(origin: .zero, size: size))
        for overlay in overlays {
            // Draw the view's own Core Graphics output into this image.
            overlay.draw(overlay.bounds)
        }
        result.unlockFocus()
        return result
    }
}
#endif
