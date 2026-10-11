#if canImport(CSDL3)
import Foundation
import CSDL3

/// The start menu, the naming panel for a new world, and the list of
/// every saved world — `StartMenuView`, `NewWorldNameView` and
/// `WorldListView` on the Mac, as one screen with three faces.
final class SDLMenuScreen: SDLScreen {
    private enum Face {
        case cards
        case naming(GameMode)
        case worlds(scroll: Int)
    }

    private var face = Face.cards
    private var pointer = SDLPointer()
    private var worlds: [WorldCatalog.Entry]
    private var typed = ""
    private var caretClock: Double = 0
    private var notice: String?
    /// Keys pressed this frame, for the faces that answer the keyboard.
    private var keys: [SDL_Scancode] = []
    private var clock: Double = 0

    init(app: SDLApp) {
        worlds = WorldCatalog.entries()
        app.setPointerCaptured(false)
        app.setWindowTitle("Blockhaven")
    }

    func handle(_ event: SDL_Event, app: SDLApp) {
        pointer.handle(event)
        switch eventType(event) {
        case SDL_EVENT_KEY_DOWN:
            keys.append(event.key.scancode)
        case SDL_EVENT_TEXT_INPUT:
            guard case .naming = face, let raw = event.text.text else { return }
            for character in String(cString: raw) where typed.count < WorldCatalog.maximumNameLength {
                typed.append(character)
            }
        default:
            break
        }
    }

    func frame(dt: Double, app: SDLApp) {
        clock += dt
        caretClock += dt
        defer {
            pointer.endFrame()
            keys.removeAll()
        }
        drawBackdrop(app)
        switch face {
        case .cards: cards(app)
        case .naming(let mode): naming(mode, app: app)
        case .worlds(let scroll): worldList(scroll: scroll, app: app)
        }
    }

    func leave(app: SDLApp) {
        SDL_StopTextInput(app.window)
    }

    // MARK: - Backdrop

    /// A field of the game's own blocks behind the menu, scrolling slowly —
    /// grass, dirt and stone in rows, darkened so the text stands off it.
    private func drawBackdrop(_ app: SDLApp) {
        let ui = app.ui
        let tile: Float = 64
        let tiles: [AtlasTile] = [.grassTop, .grassTop, .dirt, .stone, .stone, .cobblestone, .stone, .coalOre, .stone, .ironOre]
        let drift = Float(clock * 6).truncatingRemainder(dividingBy: tile)
        var row = 0
        var y: Float = -tile + drift
        while y < ui.height {
            var x: Float = 0
            var column = 0
            while x < ui.width {
                let pick = tiles[min(tiles.count - 1, max(0, row % tiles.count))]
                let variant = (column * 7 + row * 3) % 5 == 0 && pick == .stone ? AtlasTile.gravel : pick
                let r = app.assets.tileRect(variant)
                ui.image(app.assets.atlasFlat, x: x, y: y, width: tile, height: tile,
                         u0: r.u0, v0: r.v0, u1: r.u1, v1: r.v1)
                x += tile
                column += 1
            }
            y += tile
            row += 1
        }
        ui.rect(x: 0, y: 0, width: ui.width, height: ui.height, color: .init(0, 0, 0, 0.55))
    }

    // MARK: - Cards

    private enum Card {
        case resume(WorldCatalog.Entry)
        case newWorld(GameMode)
        case demo
    }

    private func cards(_ app: SDLApp) {
        let ui = app.ui
        var list: [Card] = []
        if let first = worlds.first { list.append(.resume(first)) }
        list += [.newWorld(.survival), .newWorld(.creative), .demo]

        app.text.drawCentered(ui, "BLOCKHAVEN", centreX: ui.width / 2, y: 70, size: 34,
                              color: .init(0.95, 0.95, 0.9))
        app.text.drawCentered(ui, worlds.isEmpty
                              ? L10n.t("Choose how you want to play", "Välj hur du vill spela")
                              : L10n.t("Continue your world, or start a new one", "Fortsätt din värld eller börja en ny"),
                              centreX: ui.width / 2, y: 124, size: 12, color: .init(0.85, 0.85, 0.85))

        let cardWidth: Float = 230, cardHeight: Float = 250, gap: Float = 18
        let total = Float(list.count) * cardWidth + Float(list.count - 1) * gap
        let scale = min(1, (ui.width - 40) / total)
        let w = cardWidth * scale, h = cardHeight * scale, g = gap * scale
        var x = ((ui.width - (Float(list.count) * w + Float(list.count - 1) * g)) / 2).rounded()
        let y = max(160, ((ui.height - h) / 2).rounded())
        for (index, card) in list.enumerated() {
            let hovered = pointer.inside(x, y, w, h)
            let pressedKey = keys.contains(SDL_Scancode(rawValue: SDL_SCANCODE_1.rawValue + .init(index)))
            drawCard(card, x: x, y: y, width: w, height: h, hovered: hovered, number: index + 1, app: app)
            if (hovered && pointer.clicked) || pressedKey {
                take(card, app: app)
                return
            }
            x += w + g
        }

        // The row under the cards: the world list, the window, quit.
        let rowY = y + h + 30
        let rowWidth: Float = 240
        var buttons: [(String, () -> Void)] = []
        if worlds.count > 1 {
            buttons.append((L10n.t("Your Worlds", "Dina världar") + "  ·  L", { [weak self] in self?.face = .worlds(scroll: 0) }))
        }
        buttons.append(((app.isFullscreen ? L10n.t("Windowed  ·  W", "Fönsterläge  ·  W") : L10n.t("Fullscreen  ·  W", "Helskärm  ·  W")),
                        { app.toggleFullscreen() }))
        // Names the language it switches to, in that language — the line
        // is for whoever cannot read the rest of the screen.
        buttons.append((GameSettings.language == .english ? "Byt till svenska  ·  S" : "Switch to English  ·  S",
                        { GameSettings.language = GameSettings.language.toggled }))
        buttons.append((L10n.t("Quit  ·  Q", "Avsluta  ·  Q"), { app.quit() }))
        let rowTotal = Float(buttons.count) * rowWidth + Float(buttons.count - 1) * 12
        var bx = ((ui.width - rowTotal) / 2).rounded()
        for (label, action) in buttons {
            if SDLWidgets.button(app, pointer, label, x: bx, y: rowY, width: rowWidth, height: 38) {
                action()
                return
            }
            bx += rowWidth + 12
        }
        if keys.contains(SDL_SCANCODE_L), worlds.count > 1 { face = .worlds(scroll: 0) }
        if keys.contains(SDL_SCANCODE_W) { app.toggleFullscreen() }
        if keys.contains(SDL_SCANCODE_Q) { app.quit() }
        if keys.contains(SDL_SCANCODE_S) { GameSettings.language = GameSettings.language.toggled }

        worldsFolderRow(app, y: rowY + 54)
        app.text.draw(ui, GameVersion.label + (Updater.notice.map { "  ·  " + $0 } ?? ""), x: 14, y: ui.height - 22, size: 9, color: .init(0.5, 0.5, 0.5))

        if let notice {
            app.text.drawCentered(ui, notice, centreX: ui.width / 2, y: rowY + 118, size: 10, color: .init(1, 0.85, 0.5))
        }
    }

    /// Where worlds are kept, and a way to move them — to a OneDrive or
    /// Dropbox folder, so the same worlds are there on every computer.
    private func worldsFolderRow(_ app: SDLApp, y: Float) {
        let ui = app.ui
        if let answer = SDLFolderPicker.take(), case .chosen(let folder) = answer {
            let copied = WorldCatalog.choose(folder: folder)
            worlds = WorldCatalog.entries()
            notice = copied > 0
                ? L10n.t("Worlds folder changed — copied \(copied) world(s) there",
                         "Mappen för världar ändrad — kopierade \(copied) värld(ar) dit")
                : L10n.t("Worlds folder changed", "Mappen för världar ändrad")
        }
        guard WorldSave.isEnabled, ProcessInfo.processInfo.environment["BLOCKHAVEN_SAVE_DIR"] == nil else { return }

        let folder = WorldCatalog.directoryURL
        // The last two parts of the path are the ones that say where it is
        // ("OneDrive / the original"); the rest is the same on every computer.
        let parts = folder.pathComponents.filter { $0 != "/" && $0 != "\\" }
        let shown = (parts.count > 2 ? "… / " : "") + parts.suffix(2).joined(separator: " / ")
        let label = L10n.t("Worlds are saved in: ", "Världar sparas i: ") + shown
        app.text.drawCentered(ui, label, centreX: ui.width / 2, y: y, size: 9, color: .init(0.82, 0.82, 0.82))

        let buttonWidth: Float = 200, gap: Float = 12
        let chosen = WorldCatalog.chosenFolder != nil
        let count: Float = chosen ? 2 : 1
        var x = ((ui.width - (count * buttonWidth + (count - 1) * gap)) / 2).rounded()
        if SDLWidgets.button(app, pointer, L10n.t("Change folder…", "Byt mapp…"), x: x, y: y + 20, width: buttonWidth, height: 32,
                             enabled: !SDLFolderPicker.isOpen) {
            SDLFolderPicker.open(window: app.window, startingAt: folder)
        }
        x += buttonWidth + gap
        if chosen, SDLWidgets.button(app, pointer, L10n.t("Use the default", "Använd standard"), x: x, y: y + 20, width: buttonWidth, height: 32) {
            let copied = WorldCatalog.choose(folder: nil)
            worlds = WorldCatalog.entries()
            notice = copied > 0
                ? L10n.t("Back to the default folder — copied \(copied) world(s) there",
                         "Tillbaka till standardmappen — kopierade \(copied) värld(ar) dit")
                : L10n.t("Back to the default folder", "Tillbaka till standardmappen")
        }
    }

    private func drawCard(_ card: Card, x: Float, y: Float, width: Float, height: Float, hovered: Bool, number: Int, app: SDLApp) {
        let ui = app.ui
        ui.rect(x: x, y: y, width: width, height: height, color: hovered ? .init(0.22, 0.22, 0.24, 0.96) : .init(0.12, 0.12, 0.13, 0.94))
        ui.frame(x: x, y: y, width: width, height: height,
                 color: hovered ? SDLWidgets.accent : .init(0.4, 0.4, 0.4, 0.9), thickness: hovered ? 3 : 1.5)

        let kicker: String, title: String, line: String, icon: ItemType
        switch card {
        case .resume(let entry):
            kicker = L10n.t("CONTINUE", "FORTSÄTT")
            title = entry.name
            line = WorldCatalog.relativeTime(since: entry.lastPlayed)
            icon = entry.mode == .creative ? .diamondPickaxe : .grass
        case .newWorld(let mode):
            kicker = L10n.t("NEW WORLD", "NY VÄRLD")
            title = mode.displayName
            line = mode.tagline
            icon = mode == .creative ? .diamondPickaxe : .woodenPickaxe
        case .demo:
            kicker = L10n.t("HAVE A LOOK", "TITTA RUNT")
            title = L10n.t("Demo World", "Demovärld")
            line = L10n.t("Landmarks, a railway and a roller coaster", "Byggnader, en järnväg och en berg-och-dalbana")
            icon = .minecart
        }
        let iconSize = width * 0.38
        if let r = app.assets.iconRect(icon) {
            ui.image(app.assets.items, x: x + (width - iconSize) / 2, y: y + 22, width: iconSize, height: iconSize,
                     u0: r.u0, v0: r.v0, u1: r.u1, v1: r.v1)
        }
        var ty = y + 34 + iconSize
        app.text.drawCentered(ui, kicker, centreX: x + width / 2, y: ty, size: 9, color: SDLWidgets.accent)
        ty += 20
        app.text.drawCentered(ui, title, centreX: x + width / 2, y: ty, size: 14)
        ty += 26
        for wrapped in app.text.wrap(line, size: 9, maxWidth: width - 24) {
            app.text.drawCentered(ui, wrapped, centreX: x + width / 2, y: ty, size: 9, color: .init(0.78, 0.78, 0.78))
            ty += 15
        }
        app.text.drawCentered(ui, "\(number)", centreX: x + width / 2, y: y + height - 22, size: 9, color: .init(0.55, 0.55, 0.55))
    }

    private func take(_ card: Card, app: SDLApp) {
        switch card {
        case .resume(let entry): open(entry, app: app)
        case .newWorld(let mode):
            typed = SDLMenuScreen.defaultName(for: mode)
            face = .naming(mode)
            SDL_StartTextInput(app.window)
        case .demo:
            app.setScreen(SDLGameScreen(session: GameSession(demoWorld: ()), app: app))
        }
    }

    private func open(_ entry: WorldCatalog.Entry, app: SDLApp) {
        guard let save = WorldSave.load(from: entry.url) else {
            notice = L10n.t("That world could not be opened", "Den världen gick inte att öppna")
            face = .cards
            return
        }
        app.setScreen(SDLGameScreen(session: GameSession(entry: entry, save: save), app: app))
    }

    // MARK: - Naming a new world

    private static func defaultName(for mode: GameMode) -> String {
        switch mode {
        case .survival: return L10n.t("Survival World", "Överlevnadsvärld")
        case .creative: return L10n.t("Creative World", "Kreativ värld")
        }
    }

    private func naming(_ mode: GameMode, app: SDLApp) {
        let ui = app.ui
        ui.rect(x: 0, y: 0, width: ui.width, height: ui.height, color: .init(0, 0, 0, 0.45))
        let width: Float = 520, height: Float = 230
        let x = ((ui.width - width) / 2).rounded(), y = ((ui.height - height) / 2).rounded()
        ui.rect(x: x, y: y, width: width, height: height, color: .init(0.155, 0.155, 0.155, 1))
        ui.frame(x: x, y: y, width: width, height: height, color: SDLWidgets.accent.withAlpha(0.85), thickness: 2)
        app.text.drawCentered(ui, L10n.t("NEW \(mode.displayName.uppercased()) WORLD",
                                         "NY \(mode.displayName.uppercased()) VÄRLD"),
                              centreX: ui.width / 2, y: y + 26, size: 10, color: SDLWidgets.accent)
        app.text.drawCentered(ui, L10n.t("What should this world be called?", "Vad ska den här världen heta?"),
                              centreX: ui.width / 2, y: y + 52, size: 13)

        let field = (x: x + 30, y: y + 90, w: width - 60, h: Float(44))
        ui.rect(x: field.x, y: field.y, width: field.w, height: field.h, color: .init(0.06, 0.06, 0.06, 1))
        ui.frame(x: field.x, y: field.y, width: field.w, height: field.h, color: .init(0.6, 0.6, 0.6, 1), thickness: 1.5)
        let shown = typed.isEmpty ? SDLMenuScreen.defaultName(for: mode) : typed
        app.text.draw(ui, shown, x: field.x + 12, y: field.y + 15, size: 14,
                      color: typed.isEmpty ? .init(0.5, 0.5, 0.5) : .white)
        if Int(caretClock * 2) % 2 == 0 {
            let caretX = field.x + 12 + (typed.isEmpty ? 0 : app.text.width(typed, size: 14) + 3)
            ui.rect(x: caretX, y: field.y + 11, width: 2, height: 22, color: .white)
        }
        let remaining = WorldCatalog.maximumNameLength - typed.count
        if remaining <= 8 {
            app.text.draw(ui, L10n.t("\(remaining) left", "\(remaining) kvar"),
                          x: field.x + field.w - 60, y: field.y + field.h + 8, size: 9, color: .init(0.7, 0.7, 0.7))
        }
        app.text.drawCentered(ui, L10n.t("Return starts the world  ·  Esc goes back to the cards",
                                         "Retur startar världen  ·  Esc går tillbaka till korten"),
                              centreX: ui.width / 2, y: y + height - 34, size: 9, color: .init(0.75, 0.75, 0.75))

        let start = SDLWidgets.button(app, pointer, L10n.t("Start", "Starta"), x: x + width - 150, y: y + height + 14, width: 120, height: 36)
        let back = SDLWidgets.button(app, pointer, L10n.t("Back", "Tillbaka"), x: x + 30, y: y + height + 14, width: 120, height: 36)

        for key in keys {
            switch key {
            case SDL_SCANCODE_BACKSPACE: if !typed.isEmpty { typed.removeLast() }
            case SDL_SCANCODE_ESCAPE:
                SDL_StopTextInput(app.window)
                face = .cards
                return
            case SDL_SCANCODE_RETURN, SDL_SCANCODE_KP_ENTER:
                begin(mode, app: app)
                return
            default: break
            }
        }
        if back {
            SDL_StopTextInput(app.window)
            face = .cards
        } else if start {
            begin(mode, app: app)
        }
    }

    private func begin(_ mode: GameMode, app: SDLApp) {
        SDL_StopTextInput(app.window)
        let name = WorldCatalog.sanitize(typed, fallback: SDLMenuScreen.defaultName(for: mode))
        app.setScreen(SDLGameScreen(
            session: GameSession(newWorld: mode, name: name, seed: GameSession.freshSeed()), app: app
        ))
    }

    // MARK: - Every saved world

    private func worldList(scroll: Int, app: SDLApp) {
        let ui = app.ui
        app.text.drawCentered(ui, L10n.t("Your Worlds", "Dina världar"), centreX: ui.width / 2, y: 50, size: 22)
        app.text.drawCentered(ui, worlds.count == 1
                              ? L10n.t("1 world saved", "1 värld sparad")
                              : L10n.t("\(worlds.count) worlds saved", "\(worlds.count) världar sparade"),
                              centreX: ui.width / 2, y: 86, size: 10, color: .init(0.8, 0.8, 0.8))
        let width: Float = 520, rowHeight: Float = 52, gap: Float = 8
        let x = ((ui.width - width) / 2).rounded()
        let top: Float = 120
        let visible = max(1, Int((ui.height - top - 100) / (rowHeight + gap)))
        var first = max(0, min(scroll, worlds.count - visible))
        if pointer.wheel < -0.5 { first = min(first + 1, max(0, worlds.count - visible)) }
        if pointer.wheel > 0.5 { first = max(0, first - 1) }
        if case .worlds(let current) = face, current != first { face = .worlds(scroll: first) }

        var y = top
        for entry in worlds.dropFirst(first).prefix(visible) {
            let label = entry.name
            let detail = "\(entry.mode.displayName)  ·  \(WorldCatalog.relativeTime(since: entry.lastPlayed))"
            if SDLWidgets.button(app, pointer, label, x: x, y: y, width: width, height: rowHeight, value: detail) {
                open(entry, app: app)
                return
            }
            y += rowHeight + gap
        }
        if SDLWidgets.button(app, pointer, L10n.t("Back  ·  Esc", "Tillbaka  ·  Esc"), x: x, y: ui.height - 70, width: width, height: 40)
            || keys.contains(SDL_SCANCODE_ESCAPE) {
            face = .cards
        }
    }
}
#endif
