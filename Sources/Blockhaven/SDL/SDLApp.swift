#if canImport(CSDL3)
import Foundation
import CSDL3

/// One full-window state of the SDL front end — the start menu, the world
/// list, a world in play. `SDLApp` hands each one the events and the
/// frames, and swaps them when one asks to.
protocol SDLScreen: AnyObject {
    /// One SDL event, before the frame that will see its effect.
    func handle(_ event: SDL_Event, app: SDLApp)
    /// Steps and draws one frame. `dt` is the real time since the last one.
    func frame(dt: Double, app: SDLApp)
    /// The screen is being replaced or the app is quitting; save and let go.
    func leave(app: SDLApp)
}

/// An event's type as the enum it is. C enums import as `UInt32` on the
/// Mac and as `Int32` on Windows, where MSVC makes every enum an `int`, so
/// the raw value is converted rather than passed straight through.
@inline(__always)
func eventType(_ event: SDL_Event) -> SDL_EventType {
    SDL_EventType(rawValue: .init(truncatingIfNeeded: event.type))
}

// SDL's window flags are 64-bit `#define`s, which Swift does not import.
private let SDL_WINDOW_FULLSCREEN_FLAG: UInt64 = 0x0000_0000_0000_0001
private let SDL_WINDOW_OPENGL_FLAG: UInt64 = 0x0000_0000_0000_0002
private let SDL_WINDOW_RESIZABLE_FLAG: UInt64 = 0x0000_0000_0000_0020
private let SDL_WINDOW_HIGH_PIXEL_DENSITY_FLAG: UInt64 = 0x0000_0000_0000_2000
private let SDL_WINDOW_HIDDEN_FLAG: UInt64 = 0x0000_0000_0000_0008

/// The SDL and OpenGL front end: the window, the frame loop, and the screen
/// in it. Windows runs nothing else; the Mac runs it on request.
final class SDLApp {
    let window: OpaquePointer
    private let context: SDL_GLContext
    let assets: SDLAssets
    let ui: UIRenderer
    let text: TextRenderer
    private(set) var screen: SDLScreen?
    private var nextScreen: SDLScreen?
    private var running = true

    /// The drawable, in pixels, and the window, in points.
    private(set) var pixelWidth = 1280
    private(set) var pixelHeight = 800
    private(set) var pointWidth: Float = 1280
    private(set) var pointHeight: Float = 800
    var pixelsPerPoint: Float { Float(pixelWidth) / max(1, pointWidth) }

    static func run() -> Never {
        let app = SDLApp()
        app.loop()
        exit(0)
    }

    private init() {
        SDL_SetHint(SDL_HINT_APP_NAME, "Blockhaven")
        guard SDL_Init(SDL_INIT_VIDEO) else {
            SDLApp.fail("SDL could not start: \(String(cString: SDL_GetError()))")
        }
        SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 3)
        SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 3)
        SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, Int32(SDL_GL_CONTEXT_PROFILE_CORE))
        SDL_GL_SetAttribute(SDL_GL_CONTEXT_FLAGS, Int32(SDL_GL_CONTEXT_FORWARD_COMPATIBLE_FLAG))
        SDL_GL_SetAttribute(SDL_GL_DOUBLEBUFFER, 1)
        SDL_GL_SetAttribute(SDL_GL_DEPTH_SIZE, 24)
        // No sRGB or multisampling asked of the window: the 3D passes draw
        // into a `SceneTarget` that does both, the same on every driver.

        var flags = SDL_WINDOW_OPENGL_FLAG | SDL_WINDOW_RESIZABLE_FLAG | SDL_WINDOW_HIGH_PIXEL_DENSITY_FLAG
        if GameSettings.fullscreen { flags |= SDL_WINDOW_FULLSCREEN_FLAG }
        // A harness run that should not put a window on anyone's screen;
        // the screenshot still reads the frame back.
        if ProcessInfo.processInfo.environment["BLOCKHAVEN_SDL_HIDDEN"] != nil {
            flags = (flags | SDL_WINDOW_HIDDEN_FLAG) & ~SDL_WINDOW_FULLSCREEN_FLAG
        }
        guard let made = SDL_CreateWindow("Blockhaven", 1280, 800, flags) else {
            SDLApp.fail("The game window could not open: \(String(cString: SDL_GetError()))")
        }
        window = made
        guard let context = SDL_GL_CreateContext(window) else {
            SDLApp.fail("""
                This computer's graphics driver does not offer OpenGL 3.3, which the game needs.
                Updating the graphics driver usually fixes this.

                (\(String(cString: SDL_GetError())))
                """)
        }
        self.context = context
        SDL_GL_MakeCurrent(window, context)
        SDL_GL_SetSwapInterval(1)
        loadOpenGL()
        if let renderer = glGetString(GL_RENDERER), let version = glGetString(GL_VERSION) {
            StandardError.write(Data(
                "[sdl] OpenGL \(String(cString: version)) on \(String(cString: renderer))\n".utf8
            ))
        }

        assets = SDLAssets()
        ui = UIRenderer()
        text = TextRenderer()
        updateSize()
        setWindowIcon(assets.windowIcon)
        setScreen(SDLApp.firstScreen(app: self))
    }

    /// Where a launch lands. The harness switches go straight into a world,
    /// exactly as they do on the Mac; anything else gets the start menu.
    private static func firstScreen(app: SDLApp) -> SDLScreen {
        let environment = ProcessInfo.processInfo.environment
        if environment["BLOCKHAVEN_DEMO"] != nil {
            return SDLGameScreen(session: GameSession(demoWorld: ()), app: app)
        }
        if let named = environment["BLOCKHAVEN_MODE"], let mode = GameMode(rawValue: named) {
            return SDLGameScreen(
                session: GameSession(newWorld: mode, name: "\(mode.rawValue.capitalized) Test World"),
                app: app
            )
        }
        // An installed build checks for a newer version first; see Updater.
        if Updater.isEligible { return SDLUpdateScreen() }
        WorldCatalog.migrateIfNeeded()
        return SDLMenuScreen(app: app)
    }

    /// Replaces the current screen at the end of this frame.
    func setScreen(_ screen: SDLScreen) {
        if self.screen == nil {
            self.screen = screen
        } else {
            nextScreen = screen
        }
    }

    func quit() { running = false }

    var isFullscreen: Bool {
        (SDL_GetWindowFlags(window) & SDL_WINDOW_FULLSCREEN_FLAG) != 0
    }

    func toggleFullscreen() {
        let goFullscreen = !isFullscreen
        SDL_SetWindowFullscreen(window, goFullscreen)
        GameSettings.fullscreen = goFullscreen
    }

    func setPointerCaptured(_ captured: Bool) {
        SDL_SetWindowRelativeMouseMode(window, captured)
    }

    func setWindowTitle(_ title: String) {
        SDL_SetWindowTitle(window, title)
    }

    /// The taskbar and the window's corner show this rather than SDL's own.
    private func setWindowIcon(_ image: RGBAImage) {
        var pixels = image.pixels
        pixels.withUnsafeMutableBytes { bytes in
            // Bytes in R, G, B, A order are ABGR8888 to SDL on a
            // little-endian machine, which every Mac and PC this runs on is.
            guard let surface = SDL_CreateSurfaceFrom(
                Int32(image.width), Int32(image.height), SDL_PIXELFORMAT_ABGR8888,
                bytes.baseAddress, Int32(image.width * 4)
            ) else { return }
            SDL_SetWindowIcon(window, surface)
            SDL_DestroySurface(surface)
        }
    }

    private func updateSize() {
        var w: Int32 = 0, h: Int32 = 0
        SDL_GetWindowSizeInPixels(window, &w, &h)
        pixelWidth = Int(max(1, w))
        pixelHeight = Int(max(1, h))
        SDL_GetWindowSize(window, &w, &h)
        pointWidth = Float(max(1, w))
        pointHeight = Float(max(1, h))
    }

    private func loop() {
        var last = SDL_GetTicksNS()
        var event = SDL_Event()
        while running {
            while SDL_PollEvent(&event) {
                switch eventType(event) {
                case SDL_EVENT_QUIT:
                    running = false
                case SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED, SDL_EVENT_WINDOW_RESIZED:
                    updateSize()
                default:
                    break
                }
                screen?.handle(event, app: self)
            }
            guard running else { break }

            let now = SDL_GetTicksNS()
            let dt = Double(now - last) / 1_000_000_000
            last = now

            glViewport(0, 0, GLsizei(pixelWidth), GLsizei(pixelHeight))
            ui.begin(width: pointWidth, height: pointHeight, scale: pixelsPerPoint)
            screen?.frame(dt: dt, app: self)
            ui.flush(pixelWidth: pixelWidth, pixelHeight: pixelHeight)
            SDLScreenshot.captureIfDue(app: self, dt: dt)
            SDL_GL_SwapWindow(window)

            if let next = nextScreen {
                nextScreen = nil
                screen?.leave(app: self)
                screen = next
            }
        }
        screen?.leave(app: self)
        screen = nil
        SDL_GL_DestroyContext(context)
        SDL_DestroyWindow(window)
        SDL_Quit()
    }

    /// Tells the player, in a real dialog box, and stops. A game that dies
    /// on a child's computer without a word is the worst way it can fail.
    static func fail(_ message: String) -> Never {
        StandardError.write(Data("[sdl] \(message)\n".utf8))
        SDL_ShowSimpleMessageBox(SDL_MESSAGEBOX_ERROR, "Blockhaven", message, nil)
        exit(1)
    }
}
#endif
