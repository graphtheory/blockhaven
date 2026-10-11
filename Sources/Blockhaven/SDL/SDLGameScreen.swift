#if canImport(CSDL3)
import Foundation
import CSDL3

/// Keyboard and mouse, gathered between frames into the `InputSnapshot`
/// the session reads — the same bindings `GameView` makes on the Mac, by
/// physical key position, so WASD is WASD on any layout.
struct SDLInput {
    var snapshot = InputSnapshot()
    private var lastJumpPress: UInt64 = 0

    /// Everything one frame saw, with the one-shot requests cleared for the
    /// next. Held keys stay held.
    mutating func consume() -> InputSnapshot {
        let taken = snapshot
        snapshot.lookDX = 0
        snapshot.lookDY = 0
        snapshot.useRequested = false
        snapshot.jumpRequested = false
        snapshot.hotbarSelection = nil
        snapshot.hotbarScroll = 0
        snapshot.pickBlockRequested = false
        snapshot.toggleInventoryRequested = false
        snapshot.toggleDebugRequested = false
        snapshot.toggleFlyRequested = false
        snapshot.escapeRequested = false
        snapshot.uiPrimaryClick = false
        snapshot.uiSecondaryClick = false
        return taken
    }

    /// Lets go of every held key — a screen opened, or the window lost focus,
    /// and a key released while nobody was listening must not stay down.
    mutating func releaseHeld() {
        snapshot.forwardDown = false
        snapshot.backDown = false
        snapshot.leftDown = false
        snapshot.rightDown = false
        snapshot.jumpDown = false
        snapshot.sneakDown = false
        snapshot.sprintDown = false
        snapshot.flyUpDown = false
        snapshot.flyDownDown = false
        snapshot.attackDown = false
    }

    mutating func key(_ scancode: SDL_Scancode, down: Bool, isRepeat: Bool) {
        if isRepeat { return }
        switch scancode {
        case SDL_SCANCODE_W, SDL_SCANCODE_UP: snapshot.forwardDown = down
        case SDL_SCANCODE_S, SDL_SCANCODE_DOWN: snapshot.backDown = down
        case SDL_SCANCODE_A, SDL_SCANCODE_LEFT: snapshot.leftDown = down
        case SDL_SCANCODE_D, SDL_SCANCODE_RIGHT: snapshot.rightDown = down
        case SDL_SCANCODE_SPACE:
            snapshot.jumpDown = down
            if down {
                snapshot.jumpRequested = true
                // Double-tap space toggles creative flight, as in the original.
                let now = SDL_GetTicksNS()
                if now - lastJumpPress < 320_000_000 {
                    snapshot.toggleFlyRequested = true
                    lastJumpPress = 0
                } else {
                    lastJumpPress = now
                }
            }
        case SDL_SCANCODE_LSHIFT, SDL_SCANCODE_RSHIFT:
            snapshot.sneakDown = down
            snapshot.uiShiftHeld = down
        case SDL_SCANCODE_LCTRL, SDL_SCANCODE_RCTRL:
            snapshot.sprintDown = down
        case SDL_SCANCODE_Q: snapshot.flyUpDown = down
        case SDL_SCANCODE_E:
            // On foot E opens the inventory, in the air it drops — the
            // session decides which, since only it knows who is flying.
            snapshot.flyDownDown = down
            if down { snapshot.toggleInventoryRequested = true }
        case SDL_SCANCODE_TAB: if down { snapshot.toggleInventoryRequested = true }
        case SDL_SCANCODE_F: if down { snapshot.pickBlockRequested = true }
        case SDL_SCANCODE_F3: if down { snapshot.toggleDebugRequested = true }
        case SDL_SCANCODE_ESCAPE: if down { snapshot.escapeRequested = true }
        case SDL_SCANCODE_1, SDL_SCANCODE_2, SDL_SCANCODE_3, SDL_SCANCODE_4, SDL_SCANCODE_5,
             SDL_SCANCODE_6, SDL_SCANCODE_7, SDL_SCANCODE_8, SDL_SCANCODE_9:
            if down { snapshot.hotbarSelection = Int(scancode.rawValue - SDL_SCANCODE_1.rawValue) + 1 }
        default:
            break
        }
    }
}

/// A world in play: the session, the chunks on the GPU, and the screens
/// that open over it. The SDL counterpart of `GameViewController`, and the
/// same frame in the same order.
final class SDLGameScreen: SDLScreen {
    let session: GameSession
    private let blocks: BlockRenderer
    private let entities: SDLEntityRenderer
    private let sky: SDLSkyRenderer
    private let scene = SceneTarget()
    private let clouds = SDLCloudRenderer()
    private var streamer: ChunkStreamer!
    private let hud = SDLHUD()
    private var input = SDLInput()
    private var pointerCaptured = false

    private var inventory: SDLInventoryScreen?
    private var pause: SDLPauseScreen?

    private var frameTimes: [Double] = []
    private var showDebug = false
    private var clock: Double = 0
    /// `BLOCKHAVEN_SDL_OPEN=inventory|table|pause` opens that screen on the
    /// first frame — for screenshots of screens that otherwise need a key.
    private var harnessOpen = ProcessInfo.processInfo.environment["BLOCKHAVEN_SDL_OPEN"]

    init(session: GameSession, app: SDLApp) {
        self.session = session
        blocks = BlockRenderer(atlas: app.assets.atlas)
        entities = SDLEntityRenderer(app: app)
        sky = SDLSkyRenderer()
        streamer = ChunkStreamer(
            world: session.world,
            smoothShading: true,
            install: { [blocks] data, chunk in blocks.install(data, into: chunk) },
            unload: { chunk in chunk.releaseRendering() }
        )
        session.willCaptureSave = { [weak self] in self?.inventory?.returnHeldItems() }
        session.onSaveResult = { [weak self] failure in
            self?.pause?.warning = failure == nil ? nil : GameSession.saveFailureMessage
        }
        session.start()
        streamer.meshReadyChunks(budget: 25, around: session.playerChunk())
        app.setWindowTitle("Blockhaven — \(session.worldName)")
        capturePointer(app)
    }

    // MARK: - Events

    func handle(_ event: SDL_Event, app: SDLApp) {
        if let pause {
            pause.handle(event, app: app)
            return
        }
        if let inventory {
            inventory.handle(event, app: app)
            if eventType(event) == SDL_EVENT_KEY_DOWN {
                input.key(event.key.scancode, down: true, isRepeat: event.key.repeat)
            }
            return
        }
        switch eventType(event) {
        case SDL_EVENT_KEY_DOWN:
            input.key(event.key.scancode, down: true, isRepeat: event.key.repeat)
        case SDL_EVENT_KEY_UP:
            input.key(event.key.scancode, down: false, isRepeat: false)
        case SDL_EVENT_MOUSE_MOTION:
            if pointerCaptured {
                input.snapshot.lookDX += CGFloat(event.motion.xrel)
                input.snapshot.lookDY += CGFloat(event.motion.yrel)
            }
        case SDL_EVENT_MOUSE_BUTTON_DOWN:
            guard pointerCaptured else {
                capturePointer(app)
                return
            }
            switch Int32(event.button.button) {
            case SDL_BUTTON_LEFT: input.snapshot.attackDown = true
            case SDL_BUTTON_RIGHT: input.snapshot.useRequested = true
            case SDL_BUTTON_MIDDLE: input.snapshot.pickBlockRequested = true
            default: break
            }
        case SDL_EVENT_MOUSE_BUTTON_UP:
            if Int32(event.button.button) == SDL_BUTTON_LEFT { input.snapshot.attackDown = false }
        case SDL_EVENT_MOUSE_WHEEL:
            guard pointerCaptured else { return }
            if event.wheel.y > 0.5 { input.snapshot.hotbarScroll -= 1 }
            if event.wheel.y < -0.5 { input.snapshot.hotbarScroll += 1 }
        case SDL_EVENT_WINDOW_FOCUS_LOST:
            input.releaseHeld()
            releasePointer(app)
        default:
            break
        }
    }

    private func capturePointer(_ app: SDLApp) {
        pointerCaptured = true
        input.snapshot.pointerCaptured = true
        app.setPointerCaptured(true)
    }

    private func releasePointer(_ app: SDLApp) {
        pointerCaptured = false
        input.snapshot.pointerCaptured = false
        input.snapshot.attackDown = false
        app.setPointerCaptured(false)
    }

    // MARK: - Frame

    func frame(dt rawDelta: Double, app: SDLApp) {
        let dt = min(0.05, max(0, rawDelta))
        clock += dt
        trackFrameRate(rawDelta)

        var frameInput = input.consume()
        session.driveBenchmarks(&frameInput, dt: dt)
        if let open = harnessOpen {
            harnessOpen = nil
            switch open {
            case "inventory": openInventory(.crafting(gridSize: 2), app: app)
            case "table": openInventory(.crafting(gridSize: 3), app: app)
            case "pause": openPause(app)
            default: break
            }
        }

        let inventoryKeyIsFlying = session.player.isFlying && frameInput.flyDownDown
        if frameInput.toggleInventoryRequested, pause == nil, !inventoryKeyIsFlying {
            if inventory == nil { openInventory(.crafting(gridSize: 2), app: app) } else { closeInventory(app) }
        }
        if frameInput.escapeRequested {
            if pause != nil {
                closePause(app)
            } else if inventory != nil {
                closeInventory(app)
            } else {
                openPause(app)
            }
        }
        if frameInput.toggleDebugRequested { showDebug.toggle() }

        if pause == nil {
            if inventory != nil {
                if session.tableWalkedAway() { closeInventory(app) }
            } else {
                FrameProfiler.measure(.mobs) { session.updatePlay(dt: dt, input: frameInput) }
                if let request = session.takeScreenRequest() { openInventory(request, app: app) }
            }
            session.tickAutosave(dt: dt, canWrite: inventory == nil)
        }

        FrameProfiler.measure(.stream) {
            streamer.stream(center: session.playerChunk(), eye: session.player.eyePosition)
        }
        if pause == nil { session.advanceClock(dt: dt) }

        render(app: app, dt: dt)

        let debug = showDebug ? session.debugText(fps: averageFPS, renderer: "OpenGL") : nil
        let state = session.hudState(dt: dt, debugText: debug)
        if inventory == nil, pause == nil {
            hud.draw(state, app: app)
        } else {
            var dimmed = state
            dimmed.itemName = nil
            dimmed.toast = nil
            hud.draw(dimmed, app: app)
        }
        inventory?.draw(app: app)
        pause?.draw(app: app)
    }

    private func render(app: SDLApp, dt: Double) {
        let aspect = Float(app.pixelWidth) / Float(max(1, app.pixelHeight))
        let projection = Matrix4.perspective(
            fovYRadians: CameraState.fieldOfViewDegrees * .pi / 180,
            aspect: aspect, near: CameraState.near, far: CameraState.far
        )
        let view = session.camera.viewMatrix
        let eye = SIMD3<Float>(session.camera.eyePosition)

        let grade = session.sky.grade()
        let sunDirection = SDLSkyRenderer.sunDirection(timeOfDay: session.sky.timeOfDay)
        let renderBlocks = Float(session.world.renderDistance * Chunk.width)
        let lighting = BlockRenderer.Lighting(
            daylight: linearFromSRGB(grade.daylight),
            horizon: linearFromSRGB(grade.horizon),
            zenith: linearFromSRGB(grade.zenith),
            sunDirection: sunDirection,
            fogRange: SIMD2(renderBlocks * 0.64, renderBlocks),
            time: Float(clock)
        )

        scene.begin(width: app.pixelWidth, height: app.pixelHeight)
        let horizon = lighting.horizon
        glClearColor(horizon.x, horizon.y, horizon.z, 1)
        glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT)

        sky.draw(view: view, projection: projection, grade: grade, timeOfDay: session.sky.timeOfDay, eye: eye, time: Float(clock))
        blocks.draw(world: session.world, view: view, projection: projection, eye: eye, lighting: lighting)
        entities.draw(session: session, view: view, projection: projection, lighting: lighting, dt: dt,
                      highlight: (inventory == nil && pause == nil) ? session.highlightTarget : nil,
                      miningProgress: session.mining.progress)
        // Last, and writing no depth: translucent, and nothing may hide
        // behind it as far as the god rays' sky test is concerned.
        clouds.draw(view: view, projection: projection, eye: eye, horizonSRGB: grade.horizon,
                    sunDirection: sunDirection, dt: dt)
        // The sun in camera space: the view matrix's rotation is the
        // camera basis' transpose, so this is that rotation applied.
        let sunInView = view * SIMD4<Float>(sunDirection, 0)
        scene.present(sun: PostChain.Sun(
            viewDirection: SIMD3(sunInView.x, sunInView.y, sunInView.z)
                / max(1e-6, (sunInView.x * sunInView.x + sunInView.y * sunInView.y + sunInView.z * sunInView.z).squareRoot()),
            elevation: sunDirection.y,
            projection: projection
        ))
    }

    /// The same `[frames]` line the Mac prints under `BLOCKHAVEN_FRAME_LOG=1`,
    /// so the two front ends can be read against each other.
    private func trackFrameRate(_ dt: Double) {
        frameTimes.append(dt)
        if frameTimes.count > 60 { frameTimes.removeFirst() }
        guard SDLGameScreen.logsFrameRate else { return }
        FrameProfiler.recordFrame(delta: dt)
        frameLogTimer += dt
        guard frameLogTimer >= 1 else { return }
        let window = frameLogTimer
        frameLogTimer = 0
        let line = "[frames] \(averageFPS) fps · \(FrameProfiler.drain(window: window))"
            + " · chunks \(session.world.chunks.count) · fizzlers \(session.fizzlers.fizzlers.count)"
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

    // MARK: - Screens

    private func openInventory(_ request: GameSession.ScreenRequest, app: SDLApp) {
        let screen: SDLInventoryScreen
        switch request {
        case .crafting(let gridSize):
            screen = SDLInventoryScreen(inventory: session.inventory, gridSize: gridSize,
                                        creative: session.mode == .creative, chest: nil)
        case .chest(let chest):
            screen = SDLInventoryScreen(inventory: session.inventory, gridSize: 2,
                                        creative: session.mode == .creative, chest: chest)
        }
        inventory = screen
        input.releaseHeld()
        releasePointer(app)
        session.leftPlay()
    }

    private func closeInventory(_ app: SDLApp) {
        inventory?.returnHeldItems()
        inventory = nil
        session.closedScreen()
        capturePointer(app)
    }

    private func openPause(_ app: SDLApp) {
        session.save()
        let screen = SDLPauseScreen()
        if session.lastSaveFailure != nil { screen.warning = GameSession.saveFailureMessage }
        screen.onResume = { [weak self] in self?.closePause(app) }
        screen.onMainMenu = { [weak self] in self?.returnToMenu(app) }
        screen.onQuit = { [weak self] in
            guard let self else { return }
            if self.session.save(waitingForCompletion: true) { app.quit() } else { self.pause?.warning = GameSession.saveFailureMessage }
        }
        pause = screen
        input.releaseHeld()
        releasePointer(app)
        session.leftPlay()
    }

    private func closePause(_ app: SDLApp) {
        pause = nil
        capturePointer(app)
    }

    private func returnToMenu(_ app: SDLApp) {
        guard session.save(waitingForCompletion: true) else {
            pause?.warning = GameSession.saveFailureMessage
            return
        }
        app.setScreen(SDLMenuScreen(app: app))
    }

    func leave(app: SDLApp) {
        inventory?.returnHeldItems()
        session.save(waitingForCompletion: true)
        session.shutdown()
        streamer.shutdown()
        session.world.releaseEntities()
        app.setPointerCaptured(false)
        app.setWindowTitle("Blockhaven")
    }
}
#endif
