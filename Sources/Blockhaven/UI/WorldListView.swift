#if canImport(AppKit)
import AppKit

/// The list of every saved world, reached from the start menu when there is
/// more than one to choose between.
///
/// One row per world: what it's called, which rules it runs under, and when
/// it was last played. Click a row or walk the list with the arrow keys and
/// press Return. Esc goes back.
///
/// There is deliberately no way to delete a world from here. A row that can
/// destroy an afternoon's building is not something to put a mis-click
/// away from a row that opens it, and the player this is built for is
/// seven. Worlds go away by someone deleting a file in Finder, on purpose,
/// or they don't go away.
final class WorldListView: NSView {
    /// Called with the world the player picked.
    var onPick: ((WorldCatalog.Entry) -> Void)?
    /// Called when the player backs out to the cards.
    var onBack: (() -> Void)?

    private let worlds: [WorldCatalog.Entry]
    private var selected = 0
    /// Index of the first row drawn, so a long list can be walked past the
    /// bottom of the window.
    private var scroll = 0
    private var trackingArea: NSTrackingArea?

    init(frame frameRect: NSRect, worlds: [WorldCatalog.Entry]) {
        self.worlds = worlds
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        clampScroll()
        needsDisplay = true
    }

    /// Forces the highlight, so the snapshot harness can capture a selected
    /// row — the same reason `StartMenuView.previewHover` exists.
    func previewSelection(_ index: Int) {
        guard worlds.indices.contains(index) else { return }
        selected = index
        clampScroll()
        needsDisplay = true
    }

    // MARK: - Layout

    private let rowHeight: CGFloat = 76
    private let rowGap: CGFloat = 10
    private let maxListWidth: CGFloat = 660

    private var listWidth: CGFloat {
        min(maxListWidth, bounds.width - 96)
    }

    /// How many rows fit between the heading and the footer.
    private var visibleRows: Int {
        let available = bounds.height - 210
        return max(1, Int(available / (rowHeight + rowGap)))
    }

    private var listTop: CGFloat {
        let shown = min(visibleRows, worlds.count)
        let total = CGFloat(shown) * rowHeight + CGFloat(max(0, shown - 1)) * rowGap
        return (bounds.midY + total / 2 - 16).rounded()
    }

    private func rowFrame(_ index: Int) -> CGRect {
        let offset = CGFloat(index - scroll)
        return CGRect(
            x: ((bounds.width - listWidth) / 2).rounded(),
            y: listTop - (offset + 1) * rowHeight - offset * rowGap,
            width: listWidth,
            height: rowHeight
        )
    }

    private var visibleRange: Range<Int> {
        let end = min(worlds.count, scroll + visibleRows)
        return scroll..<max(scroll, end)
    }

    private func clampScroll() {
        let window = visibleRows
        if selected < scroll { scroll = selected }
        if selected >= scroll + window { scroll = selected - window + 1 }
        scroll = max(0, min(scroll, max(0, worlds.count - window)))
    }

    private func rowIndex(at point: NSPoint) -> Int? {
        visibleRange.first { rowFrame($0).contains(point) }
    }

    /// The way back, as a button rather than only as a line of text
    /// naming a key. Bottom-left, where the start menu keeps its own
    /// pills, so the corner means the same thing on both screens.
    private var backFrame: CGRect {
        let font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        let width = (backLabel.size(withAttributes: [.font: font]).width + 32).rounded()
        return CGRect(x: 24, y: 20, width: width, height: 34)
    }

    private var backLabel: String { L10n.t("Back  ·  Esc", "Tillbaka  ·  Esc") }
    private var backHovered = false

    private func drawBack(_ context: CGContext) {
        let frame = backFrame
        context.setFillColor((backHovered
            ? NSColor(calibratedWhite: 0.22, alpha: 1)
            : NSColor(calibratedWhite: 0.12, alpha: 1)).cgColor)
        let path = CGPath(roundedRect: frame, cornerWidth: 10, cornerHeight: 10, transform: nil)
        context.addPath(path)
        context.fillPath()
        context.setStrokeColor(NSColor(calibratedWhite: backHovered ? 0.60 : 0.28, alpha: 1).cgColor)
        context.setLineWidth(1)
        context.addPath(path)
        context.strokePath()
        drawText(backLabel,
                 at: NSPoint(x: frame.midX, y: frame.midY - 6),
                 font: .systemFont(ofSize: 12.5, weight: .medium),
                 color: NSColor(calibratedWhite: backHovered ? 0.92 : 0.62, alpha: 1), centred: true)
    }

    private func accent(for mode: GameMode) -> NSColor {
        switch mode {
        case .survival: return NSColor(calibratedRed: 0.44, green: 0.76, blue: 0.32, alpha: 1)
        case .creative: return NSColor(calibratedRed: 0.36, green: 0.66, blue: 0.98, alpha: 1)
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // The same dusk wash as the start menu, so backing out of here
        // doesn't feel like changing rooms.
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

        let top = listTop
        drawText(L10n.t("Your Worlds", "Dina världar"),
                 at: NSPoint(x: bounds.midX, y: top + 76),
                 font: .systemFont(ofSize: 40, weight: .bold),
                 color: NSColor(calibratedWhite: 0.97, alpha: 1), centred: true)
        drawText(worlds.count == 1
                     ? L10n.t("1 world saved", "1 värld sparad")
                     : L10n.t("\(worlds.count) worlds saved", "\(worlds.count) världar sparade"),
                 at: NSPoint(x: bounds.midX, y: top + 46),
                 font: .systemFont(ofSize: 14, weight: .regular),
                 color: NSColor(calibratedWhite: 0.62, alpha: 1), centred: true)

        for index in visibleRange {
            drawRow(context, index: index)
        }

        // An empty list is not a state the menu can reach — the load line
        // only appears at two worlds — but the harness can shoot this
        // screen against an empty directory, and a footer positioned off
        // the last row would index one that isn't there.
        let lastRow = min(worlds.count, scroll + visibleRows) - 1
        let bottom = lastRow >= 0 ? rowFrame(lastRow).minY : bounds.midY
        var footer = L10n.t("Click a world, or use ↑ ↓ and Return  ·  Esc goes back",
                            "Klicka på en värld, eller använd ↑ ↓ och Retur  ·  Esc går tillbaka")
        // Counted from where the list actually is, not from the top: a
        // footer still promising seven more below while you are looking at
        // the last two is worse than no footer at all.
        let above = scroll
        let below = max(0, worlds.count - (scroll + visibleRows))
        if above > 0 { footer = "\(footer)  ·  \(L10n.t("\(above) more above", "\(above) till ovanför"))" }
        if below > 0 { footer = "\(footer)  ·  \(L10n.t("\(below) more below", "\(below) till nedanför"))" }
        drawText(footer,
                 at: NSPoint(x: bounds.midX, y: bottom - 44),
                 font: .systemFont(ofSize: 12.5, weight: .regular),
                 color: NSColor(calibratedWhite: 0.46, alpha: 1), centred: true)

        drawBack(context)
    }

    private func drawRow(_ context: CGContext, index: Int) {
        let world = worlds[index]
        let frame = rowFrame(index)
        let isSelected = index == selected
        let colour = accent(for: world.mode)

        context.setFillColor((isSelected
            ? NSColor(calibratedWhite: 0.24, alpha: 1)
            : NSColor(calibratedWhite: 0.155, alpha: 1)).cgColor)
        let path = CGPath(roundedRect: frame, cornerWidth: 10, cornerHeight: 10, transform: nil)
        context.addPath(path)
        context.fillPath()
        context.setStrokeColor((isSelected ? colour : NSColor(calibratedWhite: 0.30, alpha: 1)).cgColor)
        context.setLineWidth(isSelected ? 2 : 1)
        context.addPath(path)
        context.strokePath()

        // A block from the world's mode as the row's icon — the same
        // vocabulary the cards use, so survival and creative are told apart
        // by shape and colour before anyone reads a word. Grass and diamond
        // rather than the cards' full sets: both have to read at 42 points
        // against a dark row, which glass, the creative card's first block,
        // does not — it is a wireframe outline and all but vanishes.
        let icon: ItemType = world.mode == .survival ? .grass : .diamond
        NSGraphicsContext.current?.imageInterpolation = .none
        ItemIcons.icon(for: icon)
            .draw(in: NSRect(x: frame.minX + 18, y: frame.midY - 21, width: 42, height: 42))

        drawText(world.name,
                 at: NSPoint(x: frame.minX + 76, y: frame.midY + 4),
                 font: .systemFont(ofSize: 19, weight: .semibold),
                 color: NSColor(calibratedWhite: 0.98, alpha: 1), centred: false)

        drawText("\(world.mode.displayName)  ·  \(WorldCatalog.relativeTime(since: world.lastPlayed))",
                 at: NSPoint(x: frame.minX + 76, y: frame.midY - 20),
                 font: .systemFont(ofSize: 13, weight: .regular),
                 color: colour.withAlphaComponent(isSelected ? 1 : 0.75), centred: false)

        if isSelected {
            drawText(L10n.t("Return to play", "Retur för att spela"),
                     at: NSPoint(x: frame.maxX - 74, y: frame.midY - 7),
                     font: .systemFont(ofSize: 12.5, weight: .medium),
                     color: NSColor(calibratedWhite: 0.72, alpha: 1), centred: true)
        }
    }

    private func drawText(
        _ string: String,
        at point: NSPoint,
        font: NSFont,
        color: NSColor,
        centred: Bool
    ) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
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

    /// Hovering moves the selection rather than lighting a second row, so
    /// the mouse and the arrow keys can never disagree about what Return
    /// would open.
    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let overBack = backFrame.contains(point)
        if overBack != backHovered {
            backHovered = overBack
            needsDisplay = true
        }
        guard let index = rowIndex(at: point), index != selected else { return }
        selected = index
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if backFrame.contains(point) {
            onBack?()
            return
        }
        guard let index = rowIndex(at: point) else { return }
        onPick?(worlds[index])
    }

    override func scrollWheel(with event: NSEvent) {
        guard worlds.count > visibleRows else { return }
        if event.scrollingDeltaY > 0.5 {
            scroll = max(0, scroll - 1)
        } else if event.scrollingDeltaY < -0.5 {
            scroll = min(max(0, worlds.count - visibleRows), scroll + 1)
        } else {
            return
        }
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // Esc
            onBack?()
        case 126: // Up
            move(-1)
        case 125: // Down
            move(1)
        case 36, 76: // Return, Enter
            guard worlds.indices.contains(selected) else { return }
            onPick?(worlds[selected])
        default:
            super.keyDown(with: event)
        }
    }

    private func move(_ delta: Int) {
        guard !worlds.isEmpty else { return }
        selected = max(0, min(worlds.count - 1, selected + delta))
        clampScroll()
        needsDisplay = true
    }
}
#endif
