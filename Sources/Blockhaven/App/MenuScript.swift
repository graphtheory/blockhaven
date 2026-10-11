#if canImport(AppKit)
import AppKit

/// Drives the menus from an environment variable, so the flows between them
/// can be tested without a person at the keyboard.
///
/// `BLOCKHAVEN_SCRIPT="new:survival:Test House;edit;mainmenu;continue;check;quit"`
/// runs those steps a second apart, each through the *same* callbacks a
/// click goes through — `StartMenuView.onChoice`, the pause screen's Save &
/// Main Menu, `AppDelegate.returnToMenu`. Nothing here reimplements a menu;
/// if a step works and the button doesn't, the wiring between them is the
/// bug, and that is the point.
///
/// This exists because the alternative is worse. The game has no scripting
/// surface, synthesising key events into another process needs accessibility
/// permission, and a backgrounded window is throttled to a couple of frames
/// a second — so "menu to world to menu twice, nothing crashes, the old
/// world is released" is otherwise a claim nobody can check. Every step
/// writes a line to stderr, and that transcript is the evidence.
///
/// Steps:
///   `new:<mode>:<name>`  take a New World card and name it
///   `continue`           take the Continue card
///   `list`               open the world list and describe it
///   `pick:<n>`           open the nth world in the list, 1-based
///   `key:<name>`         press a key: `up`, `down`, `left`, `right`,
///                        `return`, `esc`, `tab`, or any single character
///   `edit`               place a marker block in the world in play
///   `check`              report the marker, and the world it's in
///   `mainmenu`           the pause screen's Save & Main Menu
///   `menu`               describe the start menu as it stands
///   `worlds`             describe the catalogue on disk
///   `window`             report whether the game is fullscreen or in a
///                        window — the state `key:w` on the start menu and
///                        the pause screen's Screen row both change
///   `wait`               do nothing for one step
///   `quit`               terminate, which saves like any other exit
enum MenuScript {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["BLOCKHAVEN_SCRIPT"] != nil
    }

    /// Seconds between steps. A world needs a moment to prime its spawn
    /// chunks and the window a moment to come up; `BLOCKHAVEN_SCRIPT_STEP`
    /// stretches that on a slow machine.
    private static var stepInterval: TimeInterval {
        Double(ProcessInfo.processInfo.environment["BLOCKHAVEN_SCRIPT_STEP"] ?? "") ?? 1.0
    }

    private static var steps: [String] = []
    private static var index = 0
    private static weak var delegate: AppDelegate?
    /// The list the last `list` step drew, so `pick` has something to pick
    /// from.
    private static var listed: [WorldCatalog.Entry] = []

    static func start(_ appDelegate: AppDelegate) {
        guard let raw = ProcessInfo.processInfo.environment["BLOCKHAVEN_SCRIPT"] else { return }
        delegate = appDelegate
        steps = raw.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        log("script: \(steps.count) steps, \(stepInterval)s apart")
        schedule()
    }

    private static func schedule() {
        Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: false) { _ in
            MainActor.assumeIsolated {
                runNext()
            }
        }
    }

    @MainActor
    private static func runNext() {
        guard index < steps.count else {
            log("script finished")
            return
        }
        let step = steps[index]
        index += 1
        run(step)
        schedule()
    }

    @MainActor
    private static func run(_ step: String) {
        guard let delegate else { return }
        let parts = step.split(separator: ":", maxSplits: 2).map(String.init)
        let verb = parts.first ?? ""
        log("→ \(step)")

        switch verb {
        case "new":
            guard parts.count >= 2, let mode = GameMode(rawValue: parts[1]) else {
                log("  ! not a mode: \(step)")
                return
            }
            let name = parts.count > 2 ? parts[2] : ""
            guard let menu = delegate.startMenu else {
                log("  ! no start menu on screen")
                return
            }
            // Through the panel, not around it: this is the naming step a
            // player sees, including the trim and the fallback.
            menu.presentNamePanel(for: mode)
            menu.scriptTypeName(name)
            menu.scriptConfirmName()

        case "continue":
            guard let menu = delegate.startMenu else {
                log("  ! no start menu on screen")
                return
            }
            menu.scriptTakeContinue()

        case "list":
            guard let menu = delegate.startMenu else {
                log("  ! no start menu on screen")
                return
            }
            listed = WorldCatalog.entries()
            for (position, world) in listed.enumerated() {
                log("  \(position + 1). \(world.name) · \(world.mode.rawValue)"
                    + " · \(WorldCatalog.relativeTime(since: world.lastPlayed))"
                    + " · \(world.url.lastPathComponent)")
            }
            menu.scriptTakeLoadOther()

        case "pick":
            guard let position = Int(parts.count > 1 ? parts[1] : ""),
                  listed.indices.contains(position - 1) else {
                log("  ! no world \(parts.count > 1 ? parts[1] : "?") in the list")
                return
            }
            let entry = listed[position - 1]
            log("  opening \(entry.name) (\(entry.url.lastPathComponent))")
            delegate.scriptOpen(entry)

        case "key":
            // Straight at whatever has focus, as a real key press would
            // arrive. This is the only way to test the keyboard paths
            // themselves — every other step here calls the callback a click
            // would reach, which proves nothing about whether a key can get
            // there.
            let name = parts.count > 1 ? parts[1] : ""
            guard let event = keyEvent(named: name, in: delegate.window) else {
                log("  ! no key called \"\(name)\"")
                return
            }
            guard let responder = delegate.window.firstResponder else {
                log("  ! nothing has focus")
                return
            }
            responder.keyDown(with: event)

        case "window":
            log("  screen: \(delegate.isFullscreen ? "fullscreen" : "windowed")"
                + ", style \(delegate.window.styleMask.rawValue)"
                + ", frame \(Int(delegate.window.frame.width))x\(Int(delegate.window.frame.height))"
                + ", focus \(delegate.window.firstResponder.map { "\(type(of: $0))" } ?? "none")")

        case "edit":
            guard let game = delegate.game else {
                log("  ! no world in play")
                return
            }
            log("  \(game.scriptPlaceMarker())")

        case "check":
            guard let game = delegate.game else {
                log("  ! no world in play")
                return
            }
            log("  \(game.scriptSummary())")
            log("  \(game.scriptMarkerReport())")

        case "mainmenu":
            guard let game = delegate.game else {
                log("  ! no world in play")
                return
            }
            game.scriptPauseAndReturnToMenu()

        case "menu":
            guard let menu = delegate.startMenu else {
                log("  ! no start menu on screen")
                return
            }
            log("  \(menu.scriptDescription())")

        case "worlds":
            let worlds = WorldCatalog.entries()
            log("  \(worlds.count) world(s) in \(WorldCatalog.directoryURL.path)")
            for world in worlds {
                log("  · \(world.name) [\(world.mode.rawValue)] "
                    + "\(WorldCatalog.relativeTime(since: world.lastPlayed)) "
                    + "→ \(world.url.lastPathComponent)")
            }

        case "wait":
            break

        case "quit":
            NSApp.terminate(nil)

        default:
            log("  ! unknown step")
        }
    }

    /// A key press as AppKit delivers one. The named keys carry the key
    /// code the views switch on; anything else is taken as the character
    /// itself, which is what the menus read for `1`, `2`, `3` and `L`.
    private static func keyEvent(named name: String, in window: NSWindow) -> NSEvent? {
        let special: [String: (code: UInt16, characters: String)] = [
            "up": (126, "\u{F700}"),
            "down": (125, "\u{F701}"),
            "left": (123, "\u{F702}"),
            "right": (124, "\u{F703}"),
            "return": (36, "\r"),
            "esc": (53, "\u{1B}"),
            "tab": (48, "\t"),
        ]
        let key = special[name.lowercased()] ?? (code: 0, characters: name)
        guard key.characters.count == 1 else { return nil }
        return NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: key.characters,
            charactersIgnoringModifiers: key.characters,
            isARepeat: false,
            keyCode: key.code
        )
    }

    static func log(_ message: String) {
        StandardError.write(Data("[script] \(message)\n".utf8))
    }
}
#endif
