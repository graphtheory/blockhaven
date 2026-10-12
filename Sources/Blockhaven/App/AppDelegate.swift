#if canImport(AppKit)
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!

    /// `BLOCKHAVEN_WINDOW_SIZE=WxH`, if it parses and is at least 640x400.
    private static var requestedWindowSize: NSSize? {
        guard let raw = ProcessInfo.processInfo.environment["BLOCKHAVEN_WINDOW_SIZE"] else {
            return nil
        }
        let parts = raw.lowercased().split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2, parts[0] >= 640, parts[1] >= 400 else { return nil }
        return NSSize(width: parts[0], height: parts[1])
    }

    /// The window's title, with the debug-build tag if there is one. Every
    /// title assignment goes through here so a slow build cannot announce
    /// itself on three of the four windows and stay quiet on the fourth.
    static func windowTitle(_ worldName: String? = nil) -> String {
        let base = worldName.map { "Blockhaven — \($0)" } ?? "Blockhaven"
        return base + (DebugBuildNotice.titleSuffix ?? "")
    }

    /// The world in play, if any. Nil while the start menu is up, which is
    /// what keeps the menu from ever writing a save.
    private(set) var game: GameViewController?

    /// The start menu while it is on screen, so a scripted run can reach
    /// the cards without synthesising mouse events.
    private(set) weak var startMenu: StartMenuView?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()

        // Where saves go, decided and checked before anything can write.
        WorldSave.checkSaveLocation()

        // Before anything else can touch the save directory. A world older
        // than the catalogue has to be copied into `saves/` before the first
        // thing that *writes* there gets its hands on it — which, on the
        // `BLOCKHAVEN_MODE` path below, is a world that never shows a menu at
        // all. Doing it here means every launch of the game migrates, and
        // exactly one of them ever has anything to do.
        WorldCatalog.migrateIfNeeded()

        // Games belong fullscreen, and fullscreen here means a borderless
        // window covering the screen rather than `toggleFullScreen`: native
        // fullscreen only auto-hides the menu bar and reveals it whenever
        // the cursor touches the top edge, which a captured cursor does
        // constantly. `BLOCKHAVEN_WINDOWED=1` opts out into an ordinary
        // titled window, which is what the smoke tests use.
        //
        // Which it is is a stored setting now rather than a fact of the
        // launch, and both menus can change it. Fullscreen hides the menu
        // bar, so a player who wants out has to be given a door: the start
        // menu's Quit button, the pause screen's, and this, which puts the
        // Mac's own back on screen.
        let windowed = !GameSettings.fullscreen
        let screenFrame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        // `BLOCKHAVEN_WINDOW_SIZE=WxH` sizes that window. It exists for
        // measurement: the post-process pass is priced per pixel, and the
        // only other way to time it at the real display's 3440x1440 is a
        // borderless fullscreen run, which is not something to leave lying
        // around in a script. macOS still constrains the frame to the
        // screen, so what was actually rendered is whatever the
        // `[postfx]` line reports, not what was asked for here.
        let windowSize = AppDelegate.requestedWindowSize ?? NSSize(width: 1280, height: 800)
        let contentRect = windowed ? NSRect(origin: .zero, size: windowSize) : screenFrame

        window = GameWindow(
            contentRect: contentRect,
            styleMask: windowed ? [.titled, .closable, .miniaturizable, .resizable] : [.borderless],
            backing: .buffered,
            defer: false
        )
        window.title = AppDelegate.windowTitle()
        if windowed {
            window.center()
            window.minSize = NSSize(width: 640, height: 400)
            window.collectionBehavior = [.fullScreenPrimary]
        }

        // `BLOCKHAVEN_MODE=creative` (or `survival`) skips the picker into a
        // fresh world, which is how the smoke tests get into one without a
        // mouse. It never continues a save; it still writes one — to its own
        // file, under a name that says where it came from, so a run of the
        // harness can never land on top of a world someone is playing.
        //
        // `BLOCKHAVEN_DEMO=1` goes straight into the demo world, which is
        // the one world the harness can enter without risking anything:
        // it has no save file to land on top of by construction.
        if ProcessInfo.processInfo.environment["BLOCKHAVEN_DEMO"] != nil {
            startGame(GameViewController(demoWorld: ()))
        } else if let named = ProcessInfo.processInfo.environment["BLOCKHAVEN_MODE"],
                  let mode = GameMode(rawValue: named) {
            startGame(GameViewController(newWorld: mode, name: "\(mode.rawValue.capitalized) Test World"))
        } else if Updater.isEligible {
            // An installed build checks for a newer version first.
            let update = UpdateView(frame: self.contentRect())
            update.autoresizingMask = [.width, .height]
            update.onFinished = { [weak self] in self?.showStartMenu() }
            show(update)
            update.begin()
        } else {
            showStartMenu()
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if !windowed {
            NSApp.presentationOptions = [.hideMenuBar, .hideDock]
        }

        // `BLOCKHAVEN_SCRIPT=...` walks the menus on a timer. See `MenuScript`.
        if MenuScript.isRequested { MenuScript.start(self) }
    }

    /// Fullscreen, or a window with a title bar and a close button.
    ///
    /// Restyling the window in place rather than building a new one: the
    /// content view is a live RealityKit scene with a world in it, and
    /// handing that to a second window would tear down and rebuild every
    /// chunk on screen for the sake of a border.
    func setFullscreen(_ on: Bool) {
        // A run pinned to a window by `BLOCKHAVEN_WINDOWED=1` stays in one:
        // it is what keeps a smoke test off the whole display.
        guard ProcessInfo.processInfo.environment["BLOCKHAVEN_WINDOWED"] != "1" else { return }
        // Asked for what it already is.
        guard isFullscreen != on else { return }
        GameSettings.fullscreen = on

        let responder = window.firstResponder
        if on {
            let screenFrame = NSScreen.main?.frame ?? window.frame
            window.styleMask = [.borderless]
            window.setFrame(screenFrame, display: true)
            NSApp.presentationOptions = [.hideMenuBar, .hideDock]
        } else {
            NSApp.presentationOptions = []
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.minSize = NSSize(width: 640, height: 400)
            window.collectionBehavior = [.fullScreenPrimary]
            let size = AppDelegate.requestedWindowSize ?? NSSize(width: 1280, height: 800)
            window.setContentSize(size)
            window.center()
        }
        window.title = AppDelegate.windowTitle()
        window.makeKeyAndOrderFront(nil)
        // Changing the style mask drops the first responder, and the view
        // that loses it is the one reading the keyboard — a menu that
        // stopped answering its own keys after a click on Windowed would
        // be a worse trap than the one this button exists to open.
        if let responder = responder as? NSView, responder.window === window {
            window.makeFirstResponder(responder)
        } else {
            window.makeFirstResponder(window.contentViewController?.view ?? window.contentView)
        }
    }

    /// Read off the window rather than off the setting: the setting is
    /// what the *next* launch will do, and these two can disagree for a
    /// whole run — `BLOCKHAVEN_WINDOWED=1` pins a window whatever is
    /// stored, and a `-blockhaven.fullscreen` on the command line shadows
    /// what a toggle writes. What the menus report has to be what is on
    /// the screen.
    ///
    /// `.titled` rather than `.borderless`, which is the empty option set
    /// and so is "contained" in every style mask there is.
    var isFullscreen: Bool { !(window?.styleMask.contains(.titled) ?? false) }

    /// The seed a world started from the menu gets.
    ///
    /// `World`'s own default is a fixed constant, which was the right answer
    /// while there was one save slot and every measurement in the repo was
    /// taken against that one landscape. It is the wrong answer the moment
    /// there is a list of worlds: two of them generating the same terrain
    /// makes the second one pointless. So the menu — and only the menu —
    /// supplies a real seed. `BLOCKHAVEN_MODE`, the snapshot harness and the
    /// streaming benchmark all still get the constant, so nothing that
    /// compares one run against another has moved.
    ///
    /// `BLOCKHAVEN_SEED=<n>` pins it, for reproducing a world someone
    /// describes.
    static func freshSeed() -> UInt64 { GameSession.freshSeed() }

    func scriptOpen(_ entry: WorldCatalog.Entry) {
        open(entry)
    }

    /// The app has no menu bar on screen in fullscreen, but it still needs
    /// a main menu: ⌘Q is a menu key equivalent, and without one there is
    /// no way to quit at all.
    private func buildMainMenu() {
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: L10n.t("Quit Blockhaven", "Avsluta Blockhaven"),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appItem.submenu = appMenu

        let mainMenu = NSMenu()
        mainMenu.addItem(appItem)
        NSApp.mainMenu = mainMenu
    }

    /// The menu comes first; the world isn't built until it's answered,
    /// since generation depends on nothing the menu changes but the rules
    /// do. The catalogue is read here rather than when Continue is clicked,
    /// because the menu can't draw itself without knowing which world it is
    /// offering to continue.
    ///
    /// Also the way *back*: the pause screen's Save & Main Menu lands here,
    /// so the list is re-read every time and the world just left is at the
    /// top of it.
    func showStartMenu() {
        let worlds = WorldCatalog.entries()
        let menu = StartMenuView(frame: contentRect())
        menu.continueWorld = worlds.first
        menu.worldCount = worlds.count
        menu.autoresizingMask = [.width, .height]
        menu.onChoice = { [weak self] choice in
            guard let self else { return }
            switch choice {
            case .resume:
                guard let entry = worlds.first else { return }
                open(entry)
            case .newWorld(let mode, let name):
                startGame(GameViewController(newWorld: mode, name: name, seed: AppDelegate.freshSeed()))
            case .demo:
                startGame(GameViewController(demoWorld: ()))
            case .loadOther:
                showWorldList(worlds)
            case .quit:
                NSApp.terminate(nil)
            case .toggleWindow:
                setFullscreen(!isFullscreen)
                menu.isFullscreen = isFullscreen
                // The restyle dropped the first responder; the menu on
                // screen is the thing that should have it.
                window.makeFirstResponder(menu)
            }
        }
        menu.isFullscreen = isFullscreen
        show(menu)
        startMenu = menu
    }

    /// The list of every saved world, one step in from the cards.
    private func showWorldList(_ worlds: [WorldCatalog.Entry]) {
        let list = WorldListView(frame: contentRect(), worlds: worlds)
        list.autoresizingMask = [.width, .height]
        list.onBack = { [weak self] in self?.showStartMenu() }
        list.onPick = { [weak self] entry in self?.open(entry) }
        show(list)
    }

    /// Opens a world from the catalogue, or falls back to the menu if its
    /// file has become unreadable since the list was drawn — a world that
    /// won't load is a reason to show the others, not to start a blank one
    /// over the top of it.
    private func open(_ entry: WorldCatalog.Entry) {
        guard let save = WorldSave.load(from: entry.url) else {
            StandardError.write(
                Data("[worlds] could not open \(entry.url.lastPathComponent)\n".utf8)
            )
            showStartMenu()
            return
        }
        startGame(GameViewController(entry: entry, save: save))
    }

    /// Swaps a menu screen in. `contentViewController` is cleared first:
    /// setting `contentView` out from under a controller leaves the window
    /// holding it, which would keep the world that was just torn down alive
    /// behind the menu.
    private func show(_ view: NSView) {
        window.contentViewController = nil
        window.contentView = view
        window.title = AppDelegate.windowTitle()
        window.makeFirstResponder(view)
    }

    private func contentRect() -> NSRect {
        NSRect(origin: .zero, size: window.contentLayoutRect.size)
    }

    private func startGame(_ controller: GameViewController) {
        game = controller
        startMenu = nil
        window.title = AppDelegate.windowTitle(controller.worldName)
        controller.onReturnToMenu = { [weak self] in self?.returnToMenu() }
        controller.onTravel = { [weak self] next in self?.travel(to: next) }
        controller.onToggleWindowMode = { [weak self] in
            guard let self else { return }
            setFullscreen(!isFullscreen)
        }
        controller.onWindowModeQuery = { [weak self] in self?.isFullscreen ?? true }
        // Assigning `contentViewController` resizes the window to the
        // controller's freshly-loaded 1280×800 view, which shrank the
        // fullscreen borderless window to a corner of the screen. Restore
        // the frame the window (and the menu before it) actually had.
        let frame = window.frame
        window.contentViewController = controller
        window.setFrame(frame, display: true)
        window.makeFirstResponder(controller.view)
    }

    /// A rocket landed: the place left behind is already folded into the
    /// new session's save, so it is taken apart without writing, and the
    /// other place is opened in its stead. Deferred a turn of the run loop
    /// so the old controller's frame finishes before it is torn down.
    func travel(to next: GameSession) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let controller = self.game else { return }
            controller.teardown()
            self.game = nil
            self.startGame(GameViewController(session: next))
        }
    }

    /// Saves the world, takes it apart, and puts the start menu back.
    ///
    /// The save waits for the disk. Everything after this point assumes the
    /// world's bytes are down — the menu is about to read the catalogue and
    /// offer this very world as Continue, and it has to find the state the
    /// player just left, not the state of the last autosave.
    ///
    /// So a save that didn't land cancels the whole thing. The live world is
    /// the only copy of the session at that point; tearing it down would
    /// throw an afternoon away and put a stale version of it on the Continue
    /// card as if nothing had happened. Staying put, with the pause screen
    /// saying why, is the only honest answer.
    func returnToMenu() {
        guard let controller = game else { return }
        guard controller.save(waitingForCompletion: true) else {
            controller.showSaveFailure()
            return
        }
        controller.teardown()
        // Cleared before the menu is built, so a terminate arriving in
        // between doesn't find a controller that has already let go of its
        // world and try to save it a second time.
        game = nil
        showStartMenu()
    }

    /// Every way out of the game arrives here — ⌘Q, closing the window, and
    /// the pause screen's Quit, which all terminate the app — so the last
    /// save is written in exactly one place, and waits for the disk before
    /// the process goes away.
    ///
    /// Quitting from the start menu finds `game` nil and writes nothing,
    /// which is the point: the world that was open was already saved on the
    /// way out of it, and there is nothing live to save.
    func applicationWillTerminate(_ notification: Notification) {
        game?.save(waitingForCompletion: true)
        game?.teardown()
        game = nil
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

/// A borderless `NSWindow` refuses key and main status by default, which
/// would leave the fullscreen game with no keyboard at all.
final class GameWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
#endif
