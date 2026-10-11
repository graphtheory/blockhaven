#if canImport(AppKit)
import AppKit

/// The launch screen: continue the saved world or start a new one, then
/// the world is built.
///
/// Drawn with Core Graphics like the rest of the UI rather than with
/// AppKit controls, so it matches the in-game panels instead of looking
/// like a system dialog.
final class StartMenuView: NSView {
    enum Choice: Equatable {
        case resume
        /// A new world, already named — the naming panel below runs before
        /// this is ever emitted, so nothing downstream has to deal with a
        /// world that doesn't know what it's called.
        case newWorld(GameMode, String)
        /// Open the list of every saved world.
        case loadOther
        /// The demo world. No naming panel and no mode question: it is one
        /// fixed world, and asking two questions about a thing you are
        /// meant to be able to open and look at would defeat it.
        case demo
        /// Leave the game. A menu without this is a menu you cannot get
        /// out of: the game runs fullscreen with the Mac's menu bar
        /// hidden, so ⌘Q was the only way out and nothing on screen said
        /// so.
        case quit
        /// Fullscreen, or a window with a title bar on it. The other half
        /// of the same problem — and the half that hands the menu bar,
        /// the Dock and the red close button back.
        case toggleWindow
    }

    /// Called with what the player picked. The delegate swaps this view out.
    var onChoice: ((Choice) -> Void)?

    /// The world Continue would open — the most recently played one. Setting
    /// it adds the Continue card, so the menu has to be told before it's
    /// shown.
    var continueWorld: WorldCatalog.Entry? {
        didSet { needsDisplay = true }
    }

    /// How many worlds are saved in total. Two or more puts the "load
    /// another world" line under the cards; with one there is nothing else
    /// to load and the line would be a dead end.
    var worldCount = 0 {
        didSet { needsDisplay = true }
    }

    /// What the window button should say it will do. Set by the delegate,
    /// which owns the window.
    var isFullscreen = true {
        didSet { needsDisplay = true }
    }

    private var showsLoadOther: Bool { worldCount >= 2 }

    /// Continue comes first: it's what someone coming back almost always
    /// wants, and the one card whose neighbour being clicked by mistake
    /// costs them their afternoon.
    ///
    /// The name here is a placeholder — the real one is typed into the
    /// panel the card opens — so it never reaches a caller.
    private var choices: [Choice] {
        var list: [Choice] = []
        if continueWorld != nil { list.append(.resume) }
        list.append(contentsOf: GameMode.allCases.map { .newWorld($0, "") })
        list.append(.demo)
        return list
    }

    /// The naming panel, while a New World card is being answered.
    private var namePanel: NewWorldNameView?

    private var hoveredIndex: Int?
    private var trackingArea: NSTrackingArea?

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    // MARK: - Layout

    private let maxCardWidth: CGFloat = 352
    private let cardGap: CGFloat = 32

    /// Tall enough for the wordiest card's list of details, rather than a
    /// number that happened to fit the lists as they stood. A fifth line
    /// added to creative's blurb ran off the bottom of every card on the
    /// row, which is the sort of thing a constant is for and a constant
    /// cannot notice. The 196 is where the first detail line starts
    /// (`frame.maxY - 208`) plus the margin under the last one.
    private var cardHeight: CGFloat {
        196 + 26 * CGFloat(choices.map { details(for: $0).count }.max() ?? 4)
    }

    /// Cards give up width rather than running off the edge — three of them
    /// don't fit a small window at full size.
    private var cardWidth: CGFloat {
        let count = CGFloat(choices.count)
        let available = bounds.width - 64 - (count - 1) * cardGap
        return min(maxCardWidth, max(200, available / count))
    }

    /// Frame of the card for `index`, laid out as a centred row sitting
    /// just below the middle, leaving the title room to breathe above.
    private func cardFrame(_ index: Int) -> NSRect {
        let count = choices.count
        let width = cardWidth
        let total = CGFloat(count) * width + CGFloat(count - 1) * cardGap
        let left = (bounds.width - total) / 2 + CGFloat(index) * (width + cardGap)
        return NSRect(
            x: left.rounded(),
            y: (bounds.midY - cardHeight / 2 + 6).rounded(),
            width: width,
            height: cardHeight
        )
    }

    /// Accent colour and the blocks shown on each card — the quickest way
    /// to tell them apart at a glance. Continue gets a colour neither mode
    /// uses, so it never reads as a third way to start over.
    private func decoration(for choice: Choice) -> (accent: NSColor, blocks: [ItemType]) {
        switch choice {
        case .resume:
            return (NSColor(calibratedRed: 0.95, green: 0.72, blue: 0.30, alpha: 1),
                    [.planks, .craftingTable, .glass, .diamondSword])
        case .newWorld(.survival, _):
            return (NSColor(calibratedRed: 0.44, green: 0.76, blue: 0.32, alpha: 1),
                    [.grass, .log, .cobblestone, .woodenPickaxe])
        case .newWorld(.creative, _):
            return (NSColor(calibratedRed: 0.36, green: 0.66, blue: 0.98, alpha: 1),
                    [.glass, .obsidian, .brick, .diamond])
        case .demo:
            // Purple: the one card that is neither continuing nor starting
            // over, and it should not be mistaken for either.
            return (NSColor(calibratedRed: 0.72, green: 0.48, blue: 0.94, alpha: 1),
                    [.rail, .minecart, .torch, .tnt])
        case .loadOther, .quit, .toggleWindow:
            return (NSColor(calibratedWhite: 0.7, alpha: 1), [])
        }
    }

    /// The small label above the title, which is what separates continuing
    /// a survival world from starting one.
    private func eyebrow(for choice: Choice) -> String {
        switch choice {
        case .resume: return L10n.t("CONTINUE", "FORTSÄTT")
        case .newWorld: return L10n.t("NEW WORLD", "NY VÄRLD")
        case .demo: return L10n.t("HAVE A LOOK", "TITTA RUNT")
        case .loadOther, .quit, .toggleWindow: return L10n.t("LOAD", "LADDA")
        }
    }

    /// Continue is titled with the world's own name, not its mode. Once
    /// there is more than one world, "Survival" is no longer an answer to
    /// "which one is this?" — and the name is the thing the player chose.
    private func title(for choice: Choice) -> String {
        switch choice {
        case .resume: return continueWorld?.name ?? WorldSave.legacyName
        case .newWorld(let mode, _): return mode.displayName
        case .demo: return L10n.t("Demo World", "Demovärld")
        case .loadOther, .quit, .toggleWindow: return L10n.t("Your Worlds", "Dina världar")
        }
    }

    private func tagline(for choice: Choice) -> String {
        switch choice {
        case .resume:
            guard let world = continueWorld else {
                return L10n.t("Pick up where you left off", "Fortsätt där du slutade")
            }
            return "\(world.mode.displayName)  ·  \(WorldCatalog.relativeTime(since: world.lastPlayed))"
        case .newWorld(let mode, _): return mode.tagline
        case .demo:
            return L10n.t("Landmarks, a railway and a roller coaster",
                          "Byggnader, en järnväg och en berg-och-dalbana")
        case .loadOther, .quit, .toggleWindow:
            return L10n.t("Every world you've saved", "Alla världar du har sparat")
        }
    }

    private func details(for choice: Choice) -> [String] {
        switch choice {
        case .resume:
            return [
                L10n.t("Everything you built is still there",
                       "Allt du har byggt finns kvar"),
                L10n.t("Your inventory, health and the time of day",
                       "Ditt förråd, din hälsa och tiden på dygnet"),
                L10n.t("The same world, from the same seed",
                       "Samma värld, från samma frö"),
                L10n.t("Saved as you play, and when you leave",
                       "Sparas medan du spelar, och när du slutar"),
            ]
        case .newWorld(let mode, _):
            return mode.details
        case .demo:
            return [
                L10n.t("Neuschwanstein, the Hagia Sophia, the Eiffel Tower",
                       "Neuschwanstein, Hagia Sofia, Eiffeltornet"),
                L10n.t("A railway right round the site, with a hill to ride",
                       "En järnväg runt hela området, med en backe att åka"),
                L10n.t("Everything unlocked, and nothing to lose",
                       "Allt upplåst, och inget att förlora"),
                L10n.t("Starts fresh every time — it is never saved",
                       "Börjar om varje gång — den sparas aldrig"),
            ]
        case .loadOther, .quit, .toggleWindow:
            return []
        }
    }

    private func choiceIndex(at point: NSPoint) -> Int? {
        choices.indices.first { cardFrame($0).contains(point) }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        drawBackdrop(context)
        drawHorizonBand(context)

        let list = choices
        let cardTop = cardFrame(0).maxY
        drawText("Blockhaven",
                 at: NSPoint(x: bounds.midX, y: cardTop + 108),
                 font: .systemFont(ofSize: 52, weight: .bold),
                 color: NSColor(calibratedWhite: 0.97, alpha: 1), centred: true)
        drawText(continueWorld == nil
                    ? L10n.t("Choose how you want to play", "Välj hur du vill spela")
                    : L10n.t("Continue your world, or start a new one", "Fortsätt din värld eller börja en ny"),
                 at: NSPoint(x: bounds.midX, y: cardTop + 70),
                 font: .systemFont(ofSize: 16, weight: .regular),
                 color: NSColor(calibratedWhite: 0.68, alpha: 1), centred: true)

        for (index, choice) in list.enumerated() {
            drawCard(context, choice: choice, in: cardFrame(index), hovered: hoveredIndex == index)
        }

        if showsLoadOther { drawLoadOther(context) }
        drawLanguagePill(context)
        drawPill(context, label: quitLabel, in: quitFrame,
                 hovered: hoveredIndex == StartMenuView.quitHoverIndex,
                 accent: NSColor(calibratedRed: 0.92, green: 0.46, blue: 0.40, alpha: 1))
        drawPill(context, label: windowLabel, in: windowFrame,
                 hovered: hoveredIndex == StartMenuView.windowHoverIndex, accent: nil)
        drawText(GameVersion.label + (Updater.notice.map { "  ·  " + $0 } ?? ""),
                 at: NSPoint(x: bounds.midX, y: 29),
                 font: .systemFont(ofSize: 11, weight: .regular),
                 color: NSColor(calibratedWhite: 0.86, alpha: 0.9), centred: true)

        // Built from the count rather than picked from two spellings: the
        // row is three cards or four depending on whether there is a world
        // to continue, and a hint that names a key which isn't there is
        // worse than no hint.
        let numbers = (1...max(2, list.count)).map(String.init)
        let keys = numbers.dropLast().joined(separator: ", ")
            + L10n.t(" or ", " eller ") + (numbers.last ?? "2")
        drawText(L10n.t("Click a card, or press \(keys)  ·  a new world's mode is fixed for good",
                        "Klicka på ett kort eller tryck \(keys)  ·  en ny världs spelläge går inte att ändra"),
                 at: NSPoint(x: bounds.midX, y: footerBaseline),
                 font: .systemFont(ofSize: 12.5, weight: .regular),
                 color: NSColor(calibratedWhite: 0.46, alpha: 1), centred: true)

        // The L shortcut was live but nowhere on screen, which made the
        // whole menu keyboard-workable only for someone who guessed that
        // the 1/2/3 pattern carried on into a letter. Its own line, under
        // the numbers, because it is a key for the line above the footer
        // rather than for the cards.
        if showsLoadOther {
            drawText(L10n.t("Press L for the list of every world",
                            "Tryck L för listan över alla världar"),
                     at: NSPoint(x: bounds.midX, y: footerBaseline - 21),
                     font: .systemFont(ofSize: 12.5, weight: .regular),
                     color: NSColor(calibratedWhite: 0.40, alpha: 1), centred: true)
        }
    }

    // MARK: - Language

    /// The language toggle, tucked into the bottom-right corner where it
    /// can be found when wanted and ignored the rest of the time — it is a
    /// setting, not a fourth way to start playing.
    ///
    /// The label names the language it switches TO, written in that
    /// language: the whole line is aimed at the reader who can't read the
    /// rest of the screen, so no word of it may need translating.
    private var languageLabel: String {
        GameSettings.language == .english ? "Byt till svenska  ·  S" : "Switch to English  ·  S"
    }

    private var languageFrame: CGRect {
        let font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        let width = languageLabel.size(withAttributes: [.font: font]).width + 32
        return CGRect(
            x: (bounds.maxX - width - 24).rounded(),
            y: 20,
            width: width.rounded(),
            height: 34
        )
    }

    private func drawLanguagePill(_ context: CGContext) {
        let frame = languageFrame
        let hovered = hoveredIndex == StartMenuView.languageHoverIndex

        context.setFillColor((hovered
            ? NSColor(calibratedWhite: 0.22, alpha: 1)
            : NSColor(calibratedWhite: 0.12, alpha: 1)).cgColor)
        let path = CGPath(roundedRect: frame, cornerWidth: 10, cornerHeight: 10, transform: nil)
        context.addPath(path)
        context.fillPath()
        context.setStrokeColor(NSColor(calibratedWhite: hovered ? 0.60 : 0.28, alpha: 1).cgColor)
        context.setLineWidth(1)
        context.addPath(path)
        context.strokePath()

        drawText(languageLabel,
                 at: NSPoint(x: frame.midX, y: frame.midY - 6),
                 font: .systemFont(ofSize: 12.5, weight: .medium),
                 color: NSColor(calibratedWhite: hovered ? 0.92 : 0.62, alpha: 1), centred: true)
    }

    private func toggleLanguage() {
        GameSettings.language = GameSettings.language.toggled
        // The label just changed, so the pill was remeasured — keep the
        // hover only while the cursor is inside the new frame, or the
        // pill stays lit with the mouse somewhere else entirely.
        if hoveredIndex == StartMenuView.languageHoverIndex,
           let window,
           !languageFrame.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) {
            hoveredIndex = nil
        }
        needsDisplay = true
    }

    /// Hover slot for the language pill, clear of the cards and the load
    /// line's slot alike.
    private static let languageHoverIndex = 98
    private static let quitHoverIndex = 97
    private static let windowHoverIndex = 96

    /// The two buttons in the bottom-left corner, mirroring the language
    /// pill on the right: the way out of the game, and the way out of
    /// fullscreen. They are plain and they are labelled, because the
    /// person who needs them is the person who has not found anything
    /// else.
    private var quitLabel: String { L10n.t("Quit  ·  Q", "Avsluta  ·  Q") }
    private var windowLabel: String {
        isFullscreen
            ? L10n.t("Windowed  ·  W", "Fönsterläge  ·  W")
            : L10n.t("Fullscreen  ·  W", "Helskärm  ·  W")
    }

    private func pillFrame(_ label: String, rightOf previous: CGRect?) -> CGRect {
        let font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        let width = (label.size(withAttributes: [.font: font]).width + 32).rounded()
        let x = previous.map { $0.maxX + 10 } ?? 24
        return CGRect(x: x, y: 20, width: width, height: 34)
    }

    private var quitFrame: CGRect { pillFrame(quitLabel, rightOf: nil) }
    private var windowFrame: CGRect { pillFrame(windowLabel, rightOf: quitFrame) }

    private func drawPill(
        _ context: CGContext, label: String, in frame: CGRect, hovered: Bool, accent: NSColor?
    ) {
        context.setFillColor((hovered
            ? NSColor(calibratedWhite: 0.22, alpha: 1)
            : NSColor(calibratedWhite: 0.12, alpha: 1)).cgColor)
        let path = CGPath(roundedRect: frame, cornerWidth: 10, cornerHeight: 10, transform: nil)
        context.addPath(path)
        context.fillPath()
        context.setStrokeColor((hovered
            ? (accent ?? NSColor(calibratedWhite: 0.60, alpha: 1))
            : NSColor(calibratedWhite: 0.28, alpha: 1)).cgColor)
        context.setLineWidth(1)
        context.addPath(path)
        context.strokePath()

        drawText(label,
                 at: NSPoint(x: frame.midX, y: frame.midY - 6),
                 font: .systemFont(ofSize: 12.5, weight: .medium),
                 color: hovered
                    ? (accent ?? NSColor(calibratedWhite: 0.92, alpha: 1))
                    : NSColor(calibratedWhite: 0.62, alpha: 1),
                 centred: true)
    }

    /// The line under the cards that opens the world list.
    ///
    /// A line rather than a fourth card on purpose: three cards are the
    /// choice, and this is a way to a longer list — giving it equal weight
    /// would put "open a menu" beside "start playing" as if they were the
    /// same kind of thing. It only appears at all once there is a second
    /// world to reach, so it is never a door onto a list of one.
    private var loadOtherFrame: CGRect {
        let width: CGFloat = 268
        return CGRect(
            x: (bounds.midX - width / 2).rounded(),
            y: (cardFrame(0).minY - 62).rounded(),
            width: width,
            height: 40
        )
    }

    private var footerBaseline: CGFloat {
        showsLoadOther ? loadOtherFrame.minY - 34 : cardFrame(0).minY - 48
    }

    private func drawLoadOther(_ context: CGContext) {
        let frame = loadOtherFrame
        let hovered = hoveredIndex == StartMenuView.loadOtherHoverIndex
        let accent = NSColor(calibratedRed: 0.95, green: 0.72, blue: 0.30, alpha: 1)

        context.setFillColor((hovered
            ? NSColor(calibratedWhite: 0.22, alpha: 1)
            : NSColor(calibratedWhite: 0.14, alpha: 1)).cgColor)
        let path = CGPath(roundedRect: frame, cornerWidth: 10, cornerHeight: 10, transform: nil)
        context.addPath(path)
        context.fillPath()
        context.setStrokeColor((hovered ? accent : NSColor(calibratedWhite: 0.30, alpha: 1)).cgColor)
        context.setLineWidth(hovered ? 1.8 : 1)
        context.addPath(path)
        context.strokePath()

        drawText(L10n.t("Load another world  ·  \(worldCount) saved",
                        "Ladda en annan värld  ·  \(worldCount) sparade"),
                 at: NSPoint(x: frame.midX, y: frame.midY - 7),
                 font: .systemFont(ofSize: 13.5, weight: .medium),
                 color: hovered ? accent : NSColor(calibratedWhite: 0.80, alpha: 1), centred: true)
    }

    /// Hover slot for the load line, kept clear of every card index.
    private static let loadOtherHoverIndex = 99

    /// A strip of blocks along the bottom edge, like standing on terrain —
    /// enough to say "this is a voxel game" before anything is loaded.
    private func drawHorizonBand(_ context: CGContext) {
        let tileSize: CGFloat = 30
        // Column depths repeat on a prime-ish cycle so the skyline looks
        // hand-dug rather than tiled. Kept shallow: this is a garnish along
        // the bottom edge, not the subject of the screen.
        let depths = [2, 3, 2, 2, 3, 2, 4, 2, 3, 2, 2, 3, 2, 4, 3]
        // Below the grass it's dirt for a couple of blocks, then stone —
        // the same stratigraphy the world generator uses.
        let subsurface: [AtlasTile] = [.dirt, .dirt, .stone, .stone, .cobblestone, .stone]

        context.saveGState()
        context.setAlpha(0.11)
        NSGraphicsContext.current?.imageInterpolation = .none
        var x: CGFloat = 0
        var column = 0
        while x < bounds.width {
            let depth = depths[column % depths.count]
            for row in 0..<depth {
                // Row 0 is the top of the column, so that's where the grass
                // fringe goes; everything under it is what it sits on.
                let tile = row == 0 ? AtlasTile.grassSide : subsurface[(row - 1) % subsurface.count]
                let y = CGFloat(depth - 1 - row) * tileSize
                TextureAtlas.tileImage(tile)
                    .draw(in: NSRect(x: x, y: y, width: tileSize, height: tileSize))
            }
            x += tileSize
            column += 1
        }
        context.restoreGState()
    }

    /// A dusk-coloured vertical wash, so the menu reads as part of the game
    /// rather than a blank sheet.
    private func drawBackdrop(_ context: CGContext) {
        let colors = [
            NSColor(calibratedRed: 0.10, green: 0.13, blue: 0.22, alpha: 1).cgColor,
            NSColor(calibratedRed: 0.05, green: 0.06, blue: 0.11, alpha: 1).cgColor,
        ]
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                     colors: colors as CFArray, locations: [0, 1]) {
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0, y: bounds.height),
                end: CGPoint(x: 0, y: 0),
                options: []
            )
        }
    }

    private func drawCard(_ context: CGContext, choice: Choice, in frame: NSRect, hovered: Bool) {
        let (accent, blocks) = decoration(for: choice)

        // Hovering lifts the card: lighter fill, accent border, soft glow.
        if hovered {
            context.saveGState()
            context.setShadow(offset: .zero, blur: 26, color: accent.withAlphaComponent(0.45).cgColor)
        }
        context.setFillColor((hovered
            ? NSColor(calibratedWhite: 0.24, alpha: 1)
            : NSColor(calibratedWhite: 0.165, alpha: 1)).cgColor)
        let path = CGPath(roundedRect: frame, cornerWidth: 14, cornerHeight: 14, transform: nil)
        context.addPath(path)
        context.fillPath()
        if hovered { context.restoreGState() }

        context.setStrokeColor((hovered ? accent : NSColor(calibratedWhite: 0.32, alpha: 1)).cgColor)
        context.setLineWidth(hovered ? 2 : 1)
        context.addPath(path)
        context.strokePath()

        // Accent rule under the header, tying the card to its colour.
        context.setFillColor(accent.withAlphaComponent(hovered ? 1 : 0.55).cgColor)
        context.fill(CGRect(x: frame.minX + 24, y: frame.maxY - 160, width: frame.width - 48, height: 2))

        drawBlockRow(blocks, in: frame)

        drawText(eyebrow(for: choice),
                 at: NSPoint(x: frame.midX, y: frame.maxY - 32),
                 font: .systemFont(ofSize: 11, weight: .semibold),
                 color: accent.withAlphaComponent(0.9), centred: true, tracking: 1.6)

        drawText(title(for: choice),
                 at: NSPoint(x: frame.midX, y: frame.maxY - 140),
                 font: .systemFont(ofSize: 27, weight: .semibold),
                 color: NSColor(calibratedWhite: 0.98, alpha: 1), centred: true)

        // The lines of prose are what a narrow card runs out of room for
        // first, so they take the squeeze rather than spilling past the
        // edge onto the backdrop.
        let scale = min(1, frame.width / maxCardWidth)
        var y = frame.maxY - 208
        drawText(tagline(for: choice),
                 at: NSPoint(x: frame.midX, y: y + 22),
                 font: .systemFont(ofSize: 13 * scale, weight: .medium),
                 color: accent, centred: true)

        for detail in details(for: choice) {
            // Accent square instead of a bullet character, so the list
            // lines up on a grid like everything else here.
            context.setFillColor(accent.withAlphaComponent(0.85).cgColor)
            context.fill(CGRect(x: frame.minX + 26 * scale, y: y + 4, width: 5, height: 5))
            drawText(detail,
                     at: NSPoint(x: frame.minX + 42 * scale, y: y),
                     font: .systemFont(ofSize: 12.5 * scale, weight: .regular),
                     color: NSColor(calibratedWhite: 0.80, alpha: 1), centred: false)
            y -= 26
        }
    }

    /// The isometric block icons across the top of a card, drawn with the
    /// same renderer the inventory uses.
    private func drawBlockRow(_ items: [ItemType], in frame: NSRect) {
        let size: CGFloat = 44
        let gap: CGFloat = 12
        let total = CGFloat(items.count) * size + CGFloat(items.count - 1) * gap
        var x = frame.midX - total / 2
        let y = frame.maxY - 104
        NSGraphicsContext.current?.imageInterpolation = .none
        for item in items {
            ItemIcons.icon(for: item).draw(in: NSRect(x: x, y: y, width: size, height: size))
            x += size + gap
        }
    }

    /// `point` is the text's left edge, or its centre when `centred`.
    private func drawText(
        _ string: String,
        at point: NSPoint,
        font: NSFont,
        color: NSColor,
        centred: Bool,
        tracking: CGFloat = 0
    ) {
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        if tracking != 0 { attributes[.kern] = tracking }
        let size = string.size(withAttributes: attributes)
        let origin = NSPoint(x: centred ? point.x - size.width / 2 : point.x, y: point.y)
        string.draw(at: origin, withAttributes: attributes)
    }

    // MARK: - Input

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    /// Forces the hover state, so the snapshot harness can capture how a
    /// highlighted card actually looks.
    func previewHover(_ index: Int?) {
        hoveredIndex = index
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        guard namePanel == nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        // The pill is tested before the cards, the same order mouseDown
        // uses and the order things are painted in — at the smallest
        // window the pill overlaps the rightmost card, and the hover has
        // to advertise what a click there would actually do.
        let index = (languageFrame.contains(point) ? StartMenuView.languageHoverIndex : nil)
            ?? (quitFrame.contains(point) ? StartMenuView.quitHoverIndex : nil)
            ?? (windowFrame.contains(point) ? StartMenuView.windowHoverIndex : nil)
            ?? (showsLoadOther && loadOtherFrame.contains(point) ? StartMenuView.loadOtherHoverIndex : nil)
            ?? choiceIndex(at: point)
        guard index != hoveredIndex else { return }
        hoveredIndex = index
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard namePanel == nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        if showsLoadOther, loadOtherFrame.contains(point) {
            onChoice?(.loadOther)
            return
        }
        if languageFrame.contains(point) {
            toggleLanguage()
            return
        }
        if quitFrame.contains(point) {
            onChoice?(.quit)
            return
        }
        if windowFrame.contains(point) {
            onChoice?(.toggleWindow)
            return
        }
        guard let index = choiceIndex(at: point) else { return }
        take(choices[index])
    }

    /// The number keys pick a card, Return takes the highlighted one, and L
    /// opens the world list — so the menu works without ever touching the
    /// mouse.
    override func keyDown(with event: NSEvent) {
        guard namePanel == nil else { return }
        let list = choices
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "1": take(list[0])
        case "2" where list.count > 1: take(list[1])
        case "3" where list.count > 2: take(list[2])
        case "4" where list.count > 3: take(list[3])
        case "l" where showsLoadOther: onChoice?(.loadOther)
        case "s": toggleLanguage()
        case "q": onChoice?(.quit)
        case "w": onChoice?(.toggleWindow)
        case "\r":
            // Return takes whatever the mouse is over, the load line
            // included — hovering it and pressing Return used to open the
            // last *card* instead, which with a Continue card present is
            // "start a brand new creative world".
            if hoveredIndex == StartMenuView.loadOtherHoverIndex {
                onChoice?(.loadOther)
            } else if hoveredIndex == StartMenuView.languageHoverIndex {
                toggleLanguage()
            } else if hoveredIndex == StartMenuView.quitHoverIndex {
                onChoice?(.quit)
            } else if hoveredIndex == StartMenuView.windowHoverIndex {
                onChoice?(.toggleWindow)
            } else {
                take(list[min(hoveredIndex ?? 0, list.count - 1)])
            }
        default: super.keyDown(with: event)
        }
    }

    /// Acts on a card. Continue and the demo go straight through; a new
    /// world stops here to be named first.
    private func take(_ choice: Choice) {
        switch choice {
        case .resume, .loadOther, .demo, .quit, .toggleWindow:
            onChoice?(choice)
        case .newWorld(let mode, _):
            presentNamePanel(for: mode)
        }
    }

    // MARK: - Naming a new world

    /// Puts the naming panel over the cards. It is a subview rather than a
    /// separate screen so the cards stay visible behind it — the panel is a
    /// question about the card that was just clicked, and Esc has to put
    /// you back on it.
    func presentNamePanel(for mode: GameMode) {
        guard namePanel == nil else { return }
        let panel = NewWorldNameView(frame: bounds, mode: mode)
        panel.autoresizingMask = [.width, .height]
        panel.onCancel = { [weak self] in self?.dismissNamePanel() }
        panel.onConfirm = { [weak self] name in
            guard let self else { return }
            dismissNamePanel()
            onChoice?(.newWorld(mode, name))
        }
        addSubview(panel)
        namePanel = panel
        window?.makeFirstResponder(panel)
        hoveredIndex = nil
        needsDisplay = true
    }

    private func dismissNamePanel() {
        namePanel?.removeFromSuperview()
        namePanel = nil
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    // MARK: - Scripted testing

    /// The handful of things `MenuScript` needs to work the cards. Each one
    /// goes through the same call a click makes, so a scripted run proves
    /// the wiring a player uses rather than a parallel copy of it.

    func scriptTypeName(_ name: String) {
        namePanel?.setTypedName(name)
    }

    func scriptConfirmName() {
        guard let panel = namePanel else { return }
        panel.onConfirm?(panel.resolvedName)
    }

    func scriptTakeContinue() {
        guard continueWorld != nil else { return }
        take(.resume)
    }

    func scriptTakeLoadOther() {
        guard showsLoadOther else { return }
        onChoice?(.loadOther)
    }

    /// What the menu is currently offering, in one line.
    func scriptDescription() -> String {
        let continueLine = continueWorld.map {
            "continue \"\($0.name)\" (\($0.mode.rawValue), \(WorldCatalog.relativeTime(since: $0.lastPlayed)))"
        } ?? "no continue card"
        return "\(continueLine) · \(worldCount) world(s) · load-another shown: \(showsLoadOther)"
    }
}
#endif
