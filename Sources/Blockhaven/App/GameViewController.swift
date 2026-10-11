#if canImport(AppKit)
import AppKit
import RealityKit
import Combine

/// The Mac front end for one world: a RealityKit view, the AppKit screens
/// over it, and the per-frame loop that steps a `GameSession` off
/// RealityKit's scene update event and then draws what it did.
///
/// Everything that happens *in* the world lives in `GameSession`, shared
/// with the SDL front end. What lives here is the scene graph, the screens
/// and the window.
final class GameViewController: NSViewController {
    let session: GameSession

    var mode: GameMode { session.mode }
    var worldName: String { session.worldName }
    var fileURL: URL? { session.fileURL }

    private let gameView: GameView
    private let hudView = HUDView()
    private var inventoryView: InventoryView?
    private var pauseView: PauseMenuView?

    private var world: World { session.world }
    private let camera = FirstPersonCamera()
    private let sky: SkyController
    private let highlight = BlockHighlight()
    private var streamer: ChunkStreamer!

    private var minecartEntities: [Int: MinecartEntity] = [:]
    private var primedEntities: [Int: PrimedTntEntity] = [:]
    /// One entity per live fizzler, keyed by the manager's stable ids.
    private var fizzlerEntities: [Int: FizzlerEntity] = [:]
    /// One entity per live skeleton, keyed by the manager's stable ids.
    private var skeletonEntities: [Int: SkeletonEntity] = [:]
    /// One entity per live animal, keyed by the manager's stable ids.
    private var animalEntities: [Int: AnimalEntity] = [:]
    /// The session's death count as of the last sync — see
    /// `GameSession.respawnCount`.
    private var seenRespawns = 0

    /// Everything the game adds to the scene hangs off this anchor.
    private let worldAnchor = AnchorEntity(world: .zero)

    private var updateSubscription: (any Cancellable)?
    private var frameTimes: [Double] = []
    private var showDebug = false

    /// A world that has never been saved. See `GameSession.init(newWorld:)`.
    convenience init(newWorld mode: GameMode, name: String, seed: UInt64? = nil) {
        self.init(session: GameSession(newWorld: mode, name: name, seed: seed))
    }

    /// The demo world: the three landmarks, the railway and the coaster.
    convenience init(demoWorld: Void = ()) {
        self.init(session: GameSession(demoWorld: ()))
    }

    /// Reopens a world from the catalogue.
    convenience init(entry: WorldCatalog.Entry, save: WorldSave) {
        self.init(session: GameSession(entry: entry, save: save))
    }

    init(session: GameSession) {
        self.session = session
        self.sky = SkyController(clock: session.sky)
        gameView = GameView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800))
        super.init(nibName: nil, bundle: nil)
        streamer = ChunkStreamer(
            world: session.world,
            smoothShading: MaterialLibrary.usesCustomShader,
            install: { [weak self] data, chunk in self?.install(data, into: chunk) },
            unload: { chunk in chunk.removeEntities() }
        )
        session.willCaptureSave = { [weak self] in self?.inventoryView?.returnHeldItems() }
        session.onSaveResult = { [weak self] failure in
            self?.pauseView?.warning = failure == nil ? nil : GameViewController.saveFailureMessage
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    /// Kept under its old name for the checks that call it.
    nonisolated static func registerJournalIndex(
        from journal: [ChunkCoord: [Int: BlockType]],
        signals: SignalNetwork,
        crops: CropStore? = nil,
        saplings: SaplingStore? = nil,
        hoppers: HopperStore? = nil
    ) {
        GameSession.registerJournalIndex(
            from: journal, signals: signals, crops: crops, saplings: saplings, hoppers: hoppers
        )
    }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800))
        container.autoresizingMask = [.width, .height]

        gameView.frame = container.bounds
        gameView.autoresizingMask = [.width, .height]
        container.addSubview(gameView)

        hudView.frame = container.bounds
        hudView.autoresizingMask = [.width, .height]
        container.addSubview(hudView)

        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        gameView.environment.background = .color(sky.skyColor)
        gameView.scene.addAnchor(worldAnchor)

        // Bloom, highlight roll-off and vignette, run on the frame after
        // RealityKit has drawn it. `BLOCKHAVEN_POSTFX=0` opts out.
        PostProcessing.install(on: gameView)

        // Fog has to end where chunks stop being drawn, or the render edge
        // shows through it.
        MaterialLibrary.setRenderDistance(blocks: Float(world.renderDistance * Chunk.width))

        camera.attach(to: worldAnchor)
        highlight.attach(to: worldAnchor)

        session.start()
        streamer.meshReadyChunks(budget: 25, around: session.playerChunk())
        camera.apply(session.camera)
        sky.forgetGrade()
        sky.apply(view: gameView, eye: SIMD3<Float>(session.player.eyePosition))

        // RealityKit's scene update event fires once per rendered frame on
        // the main thread, which is what makes it safe for this to touch
        // the world, the UI and the entity hierarchy directly.
        updateSubscription = gameView.scene.subscribe(to: SceneEvents.Update.self) { [weak self] event in
            self?.tick(dt: event.deltaTime)
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.acceptsMouseMovedEvents = true
        // Whatever is actually on top gets the keyboard. This runs again
        // when the window is restyled — switching between fullscreen and a
        // window does that — and handing focus back to the game while the
        // pause screen is up left that screen drawn but deaf, which is
        // how the button that gets you out of fullscreen managed to break
        // the menu it was on.
        view.window?.makeFirstResponder(pauseView ?? inventoryView ?? gameView)
    }

    // MARK: - Frame loop

    private func tick(dt rawDelta: TimeInterval) {
        guard rawDelta > 0 else { return }
        // Simulation gets a clamped step so one long frame can't teleport
        // the player through a wall — but *measurement* gets the real one.
        // Clamping first capped `worst` at exactly 50.0 ms and floored
        // `averageFPS` at 20, so the instrument built to report stalls could
        // not report a stall: every frame log during a hitch read the same
        // saturated numbers.
        let dt = min(0.05, rawDelta)
        trackFrameRate(rawDelta)

        var input = gameView.input.consumeSnapshot()
        session.driveBenchmarks(&input, dt: dt)

        // E is the inventory key on foot and the descend key in the air, so
        // the request is dropped while flying — otherwise every tap of it
        // to lose height would also throw the inventory open. Tab carries
        // the inventory in both cases, which is what keeps the second job
        // from costing the first.
        let inventoryKeyIsFlying = session.player.isFlying && input.flyDownDown
        if input.toggleInventoryRequested, pauseView == nil, !inventoryKeyIsFlying {
            if inventoryView == nil { openInventory(gridSize: 2) } else { closeInventory() }
        }
        // One Esc does exactly one thing: the branches are exclusive so a
        // single press can't close the inventory and open the pause screen
        // in the same frame.
        if input.escapeRequested {
            if pauseView != nil {
                closePause()
            } else if inventoryView != nil {
                closeInventory()
            } else {
                openPause()
            }
        }
        if input.toggleDebugRequested {
            showDebug.toggle()
        }

        // While the pause screen is up the world holds still — no player
        // step, no mobs, no clock — but rendering and chunk streaming
        // carry on, so it stays a live picture of a stopped world.
        if pauseView == nil {
            if inventoryView != nil {
                if session.tableWalkedAway() { closeInventory() }
            } else {
                session.updatePlay(dt: dt, input: input)
                switch session.takeScreenRequest() {
                case .crafting(let gridSize): openInventory(gridSize: gridSize)
                case .chest(let chest): openChest(chest)
                case nil: break
                }
                FrameProfiler.measure(.mobs) { syncEntities(dt: dt) }
            }
            session.tickAutosave(dt: dt, canWrite: inventoryView == nil)
        }

        FrameProfiler.measure(.stream) {
            streamer.stream(center: session.playerChunk(), eye: session.player.eyePosition)
        }
        if pauseView == nil {
            FrameProfiler.measure(.sky) {
                session.advanceClock(dt: dt)
                sky.follow(view: gameView, eye: SIMD3<Float>(session.player.eyePosition), dt: dt)
                // The post-process pass needs the sun in camera space, and
                // only this thread may ask an entity where it is pointing.
                PostProcessing.publishSun(timeOfDay: sky.timeOfDay, camera: camera.cameraEntity)
            }
        }
        camera.apply(session.camera)
        if inventoryView == nil, pauseView == nil {
            highlight.update(target: session.highlightTarget, progress: session.mining.progress)
        }
        FrameProfiler.measure(.hud) {
            let debug = showDebug ? session.debugText(fps: averageFPS, renderer: "RealityKit") : nil
            hudView.update(session.hudState(dt: dt, debugText: debug))
        }
    }

    /// Takes the *unclamped* frame delta — see `tick`. Everything here is
    /// an instrument, and an instrument that clips is worse than none.
    private func trackFrameRate(_ dt: Double) {
        frameTimes.append(dt)
        if frameTimes.count > 60 { frameTimes.removeFirst() }

        // `BLOCKHAVEN_FRAME_LOG=1` reports the frame rate to stderr once a
        // second. There's no way to screenshot the running app without
        // Screen Recording permission, so this is how "is it actually
        // drawing?" gets answered from a terminal.
        guard GameViewController.logsFrameRate else { return }
        FrameProfiler.recordFrame(delta: dt)
        frameLogTimer += dt
        guard frameLogTimer >= 1 else { return }
        let window = frameLogTimer
        frameLogTimer = 0
        // The frame rate is pinned to the display, so the breakdown — worst
        // frame, and ms of CPU spent per second in each phase — is the part
        // of this line that can actually move.
        let line = "[frames] \(averageFPS) fps · \(FrameProfiler.drain(window: window))"
            + " · fizzlers \(session.fizzlers.fizzlers.count) · skeletons \(session.skeletons.skeletons.count)"
            + " · animals \(session.animals.animals.count)\n"
        StandardError.write(Data(line.utf8))
    }

    private static let logsFrameRate = ProcessInfo.processInfo.environment["BLOCKHAVEN_FRAME_LOG"] == "1"
    private var frameLogTimer: Double = 0

    private var averageFPS: Int {
        guard !frameTimes.isEmpty else { return 0 }
        let mean = frameTimes.reduce(0, +) / Double(frameTimes.count)
        return mean > 0 ? Int((1 / mean).rounded()) : 0
    }

    // MARK: - Entities

    /// Brings the scene in line with the simulation: an entity for every
    /// mob, cart and lit fuse the session has, and none for any it has not.
    private func syncEntities(dt: Double) {
        if session.respawnCount != seenRespawns {
            // Dying clears the field; tamed pets survive in the session and
            // get fresh entities below, same as any other reconciliation.
            seenRespawns = session.respawnCount
            for entity in fizzlerEntities.values { entity.root.removeFromParent() }
            fizzlerEntities.removeAll()
            for entity in skeletonEntities.values { entity.root.removeFromParent() }
            skeletonEntities.removeAll()
            for entity in animalEntities.values { entity.root.removeFromParent() }
            animalEntities.removeAll()
        }
        syncFizzlerEntities()
        syncSkeletonEntities()
        syncPrimedEntities()
        syncMinecartEntities()
        syncAnimalEntities(dt: dt)
    }

    /// Adds an entity for each new fizzler, moves the existing ones, and
    /// drops entities whose fizzler is gone.
    private func syncFizzlerEntities() {
        for (id, fizzler) in session.fizzlers.fizzlers {
            let entity: FizzlerEntity
            if let existing = fizzlerEntities[id] {
                entity = existing
            } else {
                entity = FizzlerEntity()
                worldAnchor.addChild(entity.root)
                fizzlerEntities[id] = entity
            }
            entity.apply(fizzler)
        }

        for (id, entity) in fizzlerEntities where session.fizzlers.fizzlers[id] == nil {
            entity.root.removeFromParent()
            fizzlerEntities[id] = nil
        }
    }

    /// Adds an entity for each new skeleton, moves the existing ones, and
    /// drops entities whose skeleton is gone. Same shape as
    /// `syncFizzlerEntities`.
    private func syncSkeletonEntities() {
        for (id, skeleton) in session.skeletons.skeletons {
            let entity: SkeletonEntity
            if let existing = skeletonEntities[id] {
                entity = existing
            } else {
                entity = SkeletonEntity()
                worldAnchor.addChild(entity.root)
                skeletonEntities[id] = entity
            }
            entity.apply(skeleton)
        }

        for (id, entity) in skeletonEntities where session.skeletons.skeletons[id] == nil {
            entity.root.removeFromParent()
            skeletonEntities[id] = nil
        }
    }

    /// One flashing box per lit fuse, created and dropped as fuses come
    /// and go. Same shape as the fizzler sync above and for the same
    /// reason: the simulation owns the list, the scene follows it.
    /// How many primed sticks are ever drawn at once.
    ///
    /// The simulation runs as many as it likes — the demo world's dynamite
    /// tower peaks at over three thousand primed in the same instant — but
    /// every one of them used to get its own entity in the scene graph,
    /// created and destroyed inside the same second. Three thousand entity
    /// insertions and removals per frame is what took the collapse of that
    /// tower down to one frame a second, and with the simulation step
    /// clamped at 50 ms, a one-fps frame does not drop the collapse: it
    /// stretches it. Ten seconds of falling over became a minute of
    /// watching it.
    ///
    /// Past the nearest hundred they are inside each other and behind the
    /// tower anyway. This is a budget on what gets *drawn*; every stick
    /// still burns its own fuse and goes off on time.
    static let primedEntityBudget = 96

    private func syncPrimedEntities() {
        let drawn = session.drawnFuses(budget: GameViewController.primedEntityBudget)

        var keep = Set<Int>(minimumCapacity: drawn.count)
        for fuse in drawn {
            keep.insert(fuse.id)
            let entity: PrimedTntEntity
            if let existing = primedEntities[fuse.id] {
                entity = existing
            } else {
                entity = PrimedTntEntity()
                worldAnchor.addChild(entity.root)
                primedEntities[fuse.id] = entity
            }
            entity.update(centre: fuse.centre, fraction: fuse.remaining / fuse.total)
        }

        for (id, entity) in primedEntities where !keep.contains(id) {
            entity.removeFromParent()
            primedEntities[id] = nil
        }
    }

    private func syncMinecartEntities() {
        for (id, cart) in session.minecarts.carts {
            let entity: MinecartEntity
            if let existing = minecartEntities[id] {
                entity = existing
            } else {
                entity = MinecartEntity()
                worldAnchor.addChild(entity.root)
                minecartEntities[id] = entity
            }
            entity.update(cart)
        }
        for (id, entity) in minecartEntities where session.minecarts.carts[id] == nil {
            entity.removeFromParent()
            minecartEntities[id] = nil
        }
    }

    /// Adds an entity for each new animal, moves the existing ones, and
    /// drops entities whose animal is gone. `dt` goes through because the
    /// walk bob is animated on the entity rather than in the simulation.
    private func syncAnimalEntities(dt: Double) {
        for (id, animal) in session.animals.animals {
            let entity: AnimalEntity
            if let existing = animalEntities[id] {
                entity = existing
            } else {
                entity = AnimalEntity(kind: animal.kind, morph: animal.morph)
                worldAnchor.addChild(entity.root)
                animalEntities[id] = entity
            }
            entity.apply(animal, dt: dt)
        }

        for (id, entity) in animalEntities where session.animals.animals[id] == nil {
            entity.root.removeFromParent()
            animalEntities[id] = nil
        }
    }

    // MARK: - Inventory screen

    private func openInventory(gridSize: Int) {
        present(InventoryView(
            frame: view.bounds, inventory: session.inventory,
            gridSize: gridSize, creative: mode == .creative
        ))
    }

    /// The same screen with a chest's slots where the crafting grid goes.
    private func openChest(_ chest: Chest) {
        present(InventoryView(
            frame: view.bounds, inventory: session.inventory, gridSize: 2,
            creative: mode == .creative,
            chest: chest
        ))
    }

    private func present(_ screen: InventoryView) {
        screen.autoresizingMask = [.width, .height]
        screen.onClose = { [weak self] in self?.closeInventory() }
        view.addSubview(screen)
        inventoryView = screen
        gameView.uiMode = true
        view.window?.makeFirstResponder(screen)

        session.leftPlay()
        highlight.update(target: nil, progress: 0)
    }

    private func closeInventory() {
        inventoryView?.returnHeldItems()
        inventoryView?.removeFromSuperview()
        inventoryView = nil
        session.closedScreen()
        gameView.uiMode = false
        view.window?.makeFirstResponder(gameView)
        gameView.capturePointer()
    }

    // MARK: - Pause screen

    private func openPause() {
        // Pausing is the one moment the player deliberately stops, which
        // makes it the natural point to put the world on disk.
        save()

        let screen = PauseMenuView(frame: view.bounds)
        screen.autoresizingMask = [.width, .height]
        // An autosave that failed while the player was playing had nowhere
        // to say so. This is the screen that promises the world is saved, so
        // it is the screen that has to take it back.
        if lastSaveFailure != nil { screen.warning = GameViewController.saveFailureMessage }
        screen.onResume = { [weak self] in self?.closePause() }
        screen.onMainMenu = { [weak self] in self?.onReturnToMenu?() }
        screen.onQuit = { NSApp.terminate(nil) }
        screen.isFullscreen = onWindowModeQuery?() ?? true
        screen.onToggleWindow = { [weak self] in
            self?.onToggleWindowMode?()
            screen.isFullscreen = self?.onWindowModeQuery?() ?? true
            // The pointer is loose while this screen is up and the window
            // just moved out from under it, so the hover has to be dropped
            // rather than left lit on a row the cursor is no longer over.
            screen.clearHover()
            // Restyling a window drops its first responder, and the best
            // guess the delegate can make from out there is "the content
            // view" — which is the game underneath. Said from in here it
            // is not a guess: this screen is up, so this screen has the
            // keyboard, or Esc stops closing the menu it is pointed at.
            screen.window?.makeFirstResponder(screen)
        }
        view.addSubview(screen)
        pauseView = screen
        gameView.uiMode = true
        // Without this the screen is drawn but deaf: key events keep going
        // to the game view underneath.
        view.window?.makeFirstResponder(screen)

        session.leftPlay()
        highlight.update(target: nil, progress: 0)
    }

    private func closePause() {
        pauseView?.removeFromSuperview()
        pauseView = nil
        gameView.uiMode = false
        view.window?.makeFirstResponder(gameView)
        gameView.capturePointer()
    }

    // MARK: - Scripted testing

    @discardableResult
    func scriptPlaceMarker(_ block: BlockType = .obsidian) -> String {
        session.scriptPlaceMarker(block)
    }

    func scriptMarkerReport() -> String { session.scriptMarkerReport() }

    func scriptSummary() -> String { session.scriptSummary() }

    /// Opens the pause screen and takes its Save & Main Menu row.
    ///
    /// Through the row's own callback, not around it: the point of a
    /// scripted run is to prove that the button a player presses is wired
    /// to the thing that happens, so pressing it is what the script does.
    func scriptPauseAndReturnToMenu() {
        if pauseView == nil { openPause() }
        guard let handler = pauseView?.onMainMenu else { return }
        handler()
    }

    // MARK: - Leaving

    /// Called when the player asks the pause screen for the main menu. The
    /// delegate saves, tears this controller down and puts the start menu
    /// back — none of which this controller can do to itself, since it is
    /// the thing being taken apart.
    var onReturnToMenu: (() -> Void)?
    /// Swap the game between fullscreen and a window, and read back which
    /// it is. Both belong to whoever owns the window — this controller
    /// owns a world, not a screen.
    var onToggleWindowMode: (() -> Void)?
    var onWindowModeQuery: (() -> Bool)?

    /// Stops everything this controller started, so it can actually be
    /// released.
    ///
    /// A view controller that is merely dropped is not gone: the scene
    /// subscription keeps ticking a world nobody is looking at, the
    /// post-process callback keeps a closure alive on a view that is no
    /// longer on screen, and a captured pointer stays captured — which is
    /// the one of those the player would notice, because the cursor would
    /// still be hidden over the menu they just asked for.
    ///
    /// Safe to call twice: everything here is idempotent, and returning to
    /// the menu and then quitting the app reaches it from two directions.
    func teardown() {
        // Cut the frame loop first. Everything below mutates state `tick`
        // reads, and a frame landing in the middle of it would be reading a
        // world being dismantled underneath it.
        updateSubscription = nil

        // Hand the cursor back before the menu appears, not after.
        gameView.uiMode = true
        gameView.releasePointer()

        session.shutdown()
        for (_, entity) in minecartEntities { entity.removeFromParent() }
        minecartEntities.removeAll()
        for (_, entity) in primedEntities { entity.removeFromParent() }
        primedEntities.removeAll()

        inventoryView?.removeFromSuperview()
        inventoryView = nil
        pauseView?.removeFromSuperview()
        pauseView = nil

        // The post-process pass holds a closure that holds its own Metal
        // pipelines and textures. RealityKit presents its own output again
        // once it is unset.
        gameView.renderCallbacks.postProcess = nil

        // Wait for the mesh queue to go quiet before the entities it is
        // building for go away.
        streamer.shutdown()

        for entity in fizzlerEntities.values { entity.root.removeFromParent() }
        fizzlerEntities.removeAll()
        for entity in skeletonEntities.values { entity.root.removeFromParent() }
        skeletonEntities.removeAll()
        for entity in animalEntities.values { entity.root.removeFromParent() }
        animalEntities.removeAll()
        world.releaseEntities()

        worldAnchor.children.removeAll()
        gameView.scene.removeAnchor(worldAnchor)
    }

    static func logLifecycle(_ message: String) {
        GameSession.logLifecycle(message)
    }

    // MARK: - Saving

    var lastSaveFailure: String? { session.lastSaveFailure }

    @discardableResult
    func save(waitingForCompletion wait: Bool = false) -> Bool {
        session.save(waitingForCompletion: wait)
    }

    static var saveFailureMessage: String { GameSession.saveFailureMessage }

    /// Puts the last save failure in front of the player, on the screen they
    /// asked to leave from. Called when leaving is refused.
    func showSaveFailure() {
        if pauseView == nil { openPause() }
        pauseView?.warning = GameViewController.saveFailureMessage
    }

    // MARK: - Meshing

    /// Hangs one chunk's freshly built geometry in the scene, replacing
    /// whatever was there.
    ///
    /// Only the halves this build actually covers are replaced. That is
    /// what makes revealing a chunk free of flicker: the buried mesh is
    /// built on its own and added beside the surface mesh already on
    /// screen, which is never touched.
    private func install(_ data: ChunkMesher.MeshData, into chunk: Chunk) {
        let origin = SIMD3<Float>(Float(chunk.originX), 0, Float(chunk.originZ))

        func hang(_ buffer: ChunkMesher.Buffer?, translucent: Bool) -> Entity? {
            guard let buffer, let mesh = ChunkMesher.makeMesh(from: buffer) else { return nil }
            let material = translucent
                ? MaterialLibrary.translucentBlocks : MaterialLibrary.opaqueBlocks
            let entity = ModelEntity(mesh: mesh, materials: [material])
            entity.position = origin
            worldAnchor.addChild(entity)
            // Materials are values, so the chunk has to be registered to
            // keep receiving the day/night grade after this frame.
            MaterialLibrary.track(entity, translucent: translucent)
            return entity
        }

        if data.faces.contains(.surface) {
            chunk.removeSurfaceEntities()
            chunk.opaqueEntity = hang(data.opaque, translucent: false)
            chunk.translucentEntity = hang(data.translucent, translucent: true)
        }
        if data.faces.contains(.buried) {
            chunk.removeBuriedEntity()
            chunk.buriedEntity = hang(data.buried, translucent: false)
        }
    }
}
#endif
