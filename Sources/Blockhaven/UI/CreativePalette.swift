#if canImport(AppKit)
import AppKit


/// The creative palette, drawn beside the inventory screen: every item in
/// the game, on shelves, in unlimited supply.
///
/// A plain object rather than an `NSView`, for the same reason
/// `RecipeBookPanel` is one — cell geometry and hit-testing are then
/// reachable without a window, which is what lets `BLOCKHAVEN_CHECK_CREATIVE`
/// assert that every item is listed once and that clicking cell *n* hands
/// over item *n*.
final class CreativePalettePanel {
    /// Open by default, unlike the book: in creative this panel *is* where
    /// blocks come from, so a screen that opened without it would be a
    /// screen with no blocks on it.
    var isOpen = true
    private(set) var rect: CGRect = .zero
    private(set) var scroller = PanelScroller()

    /// One frame per item, in view coordinates, already scrolled. Cells
    /// scrolled out of the viewport still have frames — `hitItem` is what
    /// knows they are not clickable.
    private(set) var cellFrames: [CGRect] = []
    /// The items, in cell order.
    private(set) var items: [ItemType] = CreativeCatalogue.allItems
    private var headerFrames: [(title: String, frame: CGRect)] = []

    private let cellSize: CGFloat = 40
    private let cellGap: CGFloat = 4
    private let headerHeight: CGFloat = 24
    /// Title and one line of instruction.
    private let titleBand: CGFloat = 46
    /// The strip along the bottom the bin stands in. Below the list rather
    /// than up in the title band, where in a narrow window the screen's
    /// own Blocks button is drawn over the top of it.
    private let binBand: CGFloat = 34

    /// Where a stack goes to be thrown away. Creative is the only mode
    /// that has one: it is the only mode where an unwanted stack costs
    /// nothing to lose, and — now that the palette hands out sixty-odd
    /// items on request — the only one where a bag fills with things
    /// nobody chose.
    private(set) var binRect: CGRect = .zero
    let preferredWidth: CGFloat = 248
    /// Four columns and the scrollbar. Narrower than this and a cell is
    /// smaller than the icon it holds.
    let minimumWidth: CGFloat = 208

    var scrollStep: CGFloat { cellSize + cellGap }

    // MARK: - Layout

    /// Seats the palette beside the crafting panel: left for preference —
    /// the recipe book wants the right and the two must not fight over it
    /// — then right, then nowhere. Nowhere is a window too narrow to hold
    /// both panels, where a palette clipped off the edge would be worse
    /// than the hint the screen prints instead.
    func layout(in bounds: CGRect, beside panelRect: CGRect, gap: CGFloat, preferRight: Bool = false) {
        guard isOpen else {
            clearLayout()
            return
        }
        let roomLeft = panelRect.minX - gap - bounds.minX
        let roomRight = bounds.maxX - (panelRect.maxX + gap)
        let sides = preferRight
            ? [(roomRight, true), (roomLeft, false)]
            : [(roomLeft, false), (roomRight, true)]

        // Neither margin has room: the palette goes *over* the inventory
        // rather than not existing. A book you cannot open is an
        // inconvenience; a creative screen with no blocks on it is not a
        // creative screen, so this one takes the middle of the window
        // instead of standing down.
        let seat = sides.first { $0.0 >= minimumWidth }
        let width = seat.map { min(preferredWidth, $0.0) }
            ?? min(preferredWidth, max(minimumWidth, bounds.width - 2 * gap))
        let originX: CGFloat
        if let seat {
            originX = seat.1 ? panelRect.maxX + gap : panelRect.minX - gap - width
        } else {
            originX = bounds.midX - width / 2
        }
        let height = min(bounds.height - 48, 640)
        rect = CGRect(x: originX, y: bounds.midY - height / 2, width: width, height: height)
        scroller.viewport = CGRect(
            x: rect.minX + 1, y: rect.minY + binBand,
            width: rect.width - 2, height: rect.height - binBand - titleBand
        )
        binRect = CGRect(x: rect.maxX - 12 - 30, y: rect.minY + 5, width: 30, height: 26)
        layoutCells()
    }

    private func clearLayout() {
        rect = .zero
        scroller.viewport = .zero
        binRect = .zero
        cellFrames = []
        headerFrames = []
    }

    /// True when the palette is sitting on top of the inventory rather
    /// than beside it — the small-window case, and the one where it and
    /// the recipe book cannot both be up.
    func overlaps(_ other: CGRect) -> Bool {
        rect.width > 0 && rect.intersects(other)
    }

    private var columns: Int {
        max(1, Int((scroller.viewport.width - 20) / (cellSize + cellGap)))
    }

    private func layoutCells() {
        cellFrames.removeAll(keepingCapacity: true)
        headerFrames.removeAll(keepingCapacity: true)
        let columns = self.columns
        var top = scroller.viewport.maxY + scroller.offset
        let left = scroller.viewport.minX + 10

        for shelf in CreativeCatalogue.shelves {
            headerFrames.append((
                shelf.shelf.title,
                CGRect(x: left, y: top - headerHeight, width: scroller.viewport.width - 20, height: headerHeight)
            ))
            top -= headerHeight
            for (index, _) in shelf.items.enumerated() {
                let row = index / columns, column = index % columns
                cellFrames.append(CGRect(
                    x: left + CGFloat(column) * (cellSize + cellGap),
                    y: top - CGFloat(row + 1) * cellSize - CGFloat(row) * cellGap,
                    width: cellSize, height: cellSize
                ))
            }
            let rows = (shelf.items.count + columns - 1) / columns
            top -= CGFloat(rows) * (cellSize + cellGap) + 6
        }
        scroller.contentHeight = scroller.viewport.maxY + scroller.offset - top
    }

    /// The cell frames are baked with the scroll offset in them, so every
    /// scroll is a re-layout.
    private func reflow() {
        layoutCells()
    }

    func scroll(by delta: CGFloat) {
        scroller.scroll(by: delta)
        reflow()
    }

    func setScroll(_ value: CGFloat) {
        scroller.set(value)
        reflow()
    }

    func handleKey(_ keyCode: UInt16) -> Bool {
        guard PanelScroller.keyScroll(keyCode, in: &scroller) else { return false }
        reflow()
        return true
    }

    func beginScrollDrag(at point: CGPoint) -> Bool {
        guard scroller.beginDrag(at: point) else { return false }
        reflow()
        return true
    }

    func continueScrollDrag(to point: CGPoint) {
        guard scroller.isDragging else { return }
        scroller.drag(to: point)
        reflow()
    }

    func endScrollDrag() { scroller.endDrag() }
    var isScrollDragging: Bool { scroller.isDragging }

    var scrollLimit: CGFloat { scroller.maximum }
    var scrollOffset: CGFloat { scroller.offset }

    // MARK: - Hit testing

    /// The item under a point, or nil — including nil for a cell that has
    /// scrolled out from under the viewport's clip, which is drawn nowhere
    /// and so must not be clickable either.
    func index(at point: CGPoint) -> Int? {
        guard rect.width > 0, scroller.viewport.contains(point) else { return nil }
        guard !scroller.trackRect.contains(point) else { return nil }
        return cellFrames.firstIndex { $0.contains(point) }
    }

    func item(at point: CGPoint) -> ItemType? {
        index(at: point).map { items[$0] }
    }

    /// Whether a point is anywhere on the panel — the click-swallowing
    /// test, which is not the same as being on a cell.
    func contains(_ point: CGPoint) -> Bool {
        rect.width > 0 && rect.contains(point)
    }

    /// The middle of a cell, or nil when that middle is not inside the
    /// viewport — the same rule `RecipeBookPanel.center(ofEntry:)` keeps,
    /// and for the same reason: a point nothing can click is not an answer.
    func center(ofItem index: Int) -> CGPoint? {
        guard cellFrames.indices.contains(index) else { return nil }
        let centre = CGPoint(x: cellFrames[index].midX, y: cellFrames[index].midY)
        return scroller.viewport.contains(centre) ? centre : nil
    }

    // MARK: - Drawing

    func draw(_ context: CGContext, cursor: CGPoint, holding: Bool) {
        guard rect.width > 0 else { return }

        context.setFillColor(NSColor(calibratedWhite: 0.13, alpha: 1).cgColor)
        context.fill(rect)
        context.setStrokeColor(NSColor(calibratedWhite: 0.42, alpha: 1).cgColor)
        context.setLineWidth(2)
        context.stroke(rect.insetBy(dx: 1, dy: 1))

        (L10n.t("Blocks", "Block") as NSString).draw(
            at: CGPoint(x: rect.minX + 12, y: rect.maxY - 28),
            withAttributes: [
                .font: NSFont.boldSystemFont(ofSize: 15),
                .foregroundColor: NSColor.white,
            ]
        )
        (L10n.t(
            "Click to take \u{2014} it never runs out",
            "Klicka för att ta \u{2014} det tar aldrig slut"
        ) as NSString).draw(
            at: CGPoint(x: rect.minX + 12, y: rect.maxY - 43),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 10),
                .foregroundColor: NSColor(calibratedWhite: 0.58, alpha: 1),
            ]
        )

        let hovered = index(at: cursor)
        context.saveGState()
        context.clip(to: scroller.viewport)
        for header in headerFrames where header.frame.intersects(scroller.viewport) {
            (header.title.uppercased() as NSString).draw(
                at: CGPoint(x: header.frame.minX + 2, y: header.frame.minY + 7),
                withAttributes: [
                    .font: NSFont.boldSystemFont(ofSize: 10),
                    .foregroundColor: NSColor(calibratedRed: 0.62, green: 0.76, blue: 0.55, alpha: 1),
                    .kern: 1.2,
                ]
            )
            context.setFillColor(NSColor(calibratedWhite: 0.3, alpha: 1).cgColor)
            context.fill(CGRect(
                x: header.frame.minX + 2, y: header.frame.minY + 4,
                width: header.frame.width - 4, height: 1
            ))
        }
        for (index, frame) in cellFrames.enumerated() where frame.intersects(scroller.viewport) {
            context.setFillColor(NSColor(
                calibratedWhite: index == hovered ? 0.40 : 0.28, alpha: 1
            ).cgColor)
            context.fill(frame)
            context.setStrokeColor(NSColor(
                calibratedWhite: index == hovered ? 0.85 : 0.50, alpha: 1
            ).cgColor)
            context.setLineWidth(1.5)
            context.stroke(frame.insetBy(dx: 0.75, dy: 0.75))
            // No count drawn: the supply is unlimited, and a "64" on every
            // cell is sixty-odd numbers that all say the same nothing.
            HUDView.drawItem(ItemStack(items[index]), in: frame, context: context)
        }
        context.restoreGState()

        drawBin(context, cursor: cursor, holding: holding)
        scroller.draw(context, hovered: scroller.trackRect.contains(cursor))
    }

    /// The bin: a lid, a body and two ribs. Lit up when the player is
    /// carrying something, because that is the only moment it does
    /// anything, and a button that looks live when it is not is a button
    /// that gets clicked for nothing.
    private func drawBin(_ context: CGContext, cursor: CGPoint, holding: Bool) {
        let hovered = binRect.contains(cursor)
        (L10n.t("Drop here to throw away", "Släng något här") as NSString).draw(
            at: CGPoint(x: rect.minX + 12, y: binRect.midY - 6),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 10),
                .foregroundColor: NSColor(calibratedWhite: holding ? 0.72 : 0.45, alpha: 1),
            ]
        )
        let path = CGPath(roundedRect: binRect, cornerWidth: 4, cornerHeight: 4, transform: nil)
        context.addPath(path)
        context.setFillColor((holding && hovered
            ? NSColor(calibratedRed: 0.52, green: 0.22, blue: 0.20, alpha: 1)
            : NSColor(calibratedWhite: hovered ? 0.30 : 0.20, alpha: 1)).cgColor)
        context.fillPath()
        context.addPath(path)
        context.setStrokeColor(NSColor(calibratedWhite: holding ? 0.70 : 0.42, alpha: 1).cgColor)
        context.setLineWidth(1.5)
        context.strokePath()

        let shade: CGFloat = holding ? 0.90 : 0.55
        context.setFillColor(NSColor(calibratedWhite: shade, alpha: 1).cgColor)
        let body = CGRect(x: binRect.midX - 5, y: binRect.midY - 7, width: 10, height: 11)
        context.fill(body)
        context.fill(CGRect(x: binRect.midX - 7, y: body.maxY, width: 14, height: 2))
        context.fill(CGRect(x: binRect.midX - 2, y: body.maxY + 2, width: 4, height: 2))
        context.setFillColor(NSColor(calibratedWhite: 0.15, alpha: 1).cgColor)
        context.fill(CGRect(x: body.minX + 3, y: body.minY + 2, width: 1, height: 7))
        context.fill(CGRect(x: body.maxX - 4, y: body.minY + 2, width: 1, height: 7))
    }

    /// The name of whatever the cursor is over, for the screen's tooltip.
    func tooltip(at point: CGPoint) -> String? {
        if binRect.contains(point) {
            return L10n.t("Throw away", "Släng")
        }
        return item(at: point)?.displayName
    }
}
#endif
