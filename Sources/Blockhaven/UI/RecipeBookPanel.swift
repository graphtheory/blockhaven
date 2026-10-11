#if canImport(AppKit)
import AppKit

/// The recipe book: every recipe in the game, on shelves, drawn beside the
/// crafting screen.
///
/// The hint strip this sits next to answers "what can I make right now",
/// which is the wrong question when you are eight and want to know whether
/// a bed is a thing you can make at all. So this lists *everything*,
/// craftable or not, with the pattern drawn out as a little grid — the
/// recipe is the information, and hiding the ones you can't afford yet
/// hides exactly the ones worth going and mining for.
///
/// It is a plain object rather than an `NSView` on purpose. Row geometry,
/// hit-testing and the shelf order are then all reachable without a window,
/// which is what lets `BLOCKHAVEN_CHECK_BOOK` assert that every recipe is
/// listed once and that clicking row *n* fills row *n*'s recipe.
final class RecipeBookPanel {
    /// A line in the book: a shelf heading, or a recipe by its index in
    /// `RecipeBook.all`.
    enum Entry: Equatable {
        case header(Recipe.Group)
        case recipe(Int)
    }

    private(set) var entries: [Entry] = []
    /// One frame per entry, in view coordinates, already scrolled. Rows
    /// scrolled out of the viewport still have frames — `hitEntry` is what
    /// knows they are not clickable.
    private(set) var rowFrames: [CGRect] = []

    var isOpen = false
    private(set) var rect: CGRect = .zero
    private(set) var scroller = PanelScroller()

    var viewport: CGRect { scroller.viewport }
    var scrollOffset: CGFloat { scroller.offset }

    private let headerHeight: CGFloat = 26
    /// Two lines tall: what the recipe makes, and what it is made of. The
    /// second line is the whole reason this panel exists — a row that
    /// draws its ingredients as four 14-pixel squares is a row nobody can
    /// read, and reading it is the question being asked of the book.
    private let rowHeight: CGFloat = 58
    private let preferredWidth: CGFloat = 396
    private let minimumWidth: CGFloat = 330
    private let titleBand: CGFloat = 44

    /// How far one arrow-key press moves the list.
    var scrollStep: CGFloat { rowHeight }

    init() {
        for shelf in RecipeBook.shelves {
            entries.append(.header(shelf.group))
            entries.append(contentsOf: shelf.entries.map { Entry.recipe($0) })
        }
    }

    // MARK: - Layout

    /// Seats the book beside the crafting panel — right for preference,
    /// left if the window is lopsided, and centred over everything when
    /// neither side has room. The last case is the small-window one: a book
    /// covering the inventory is still readable, and a book clipped off the
    /// screen edge is not.
    ///
    /// `blockedLeft` is the creative palette having got there first. The
    /// left fallback then isn't free, and the book would be drawn straight
    /// through it.
    func layout(in bounds: CGRect, beside panelRect: CGRect, gap: CGFloat, blockedLeft: Bool = false) {
        guard isOpen else {
            rect = .zero
            scroller.viewport = .zero
            rowFrames = []
            return
        }

        let panelHeight = min(bounds.height - 48, 640)
        let width: CGFloat
        let originX: CGFloat
        let roomRight = bounds.maxX - (panelRect.maxX + gap)
        let roomLeft = blockedLeft ? 0 : panelRect.minX - gap - bounds.minX
        if roomRight >= minimumWidth {
            width = min(preferredWidth, roomRight)
            originX = panelRect.maxX + gap
        } else if roomLeft >= minimumWidth {
            width = min(preferredWidth, roomLeft)
            originX = panelRect.minX - gap - width
        } else {
            width = min(preferredWidth, max(minimumWidth, bounds.width - 2 * gap))
            originX = bounds.midX - width / 2
        }

        rect = CGRect(
            x: originX, y: bounds.midY - panelHeight / 2, width: width, height: panelHeight
        )
        scroller.viewport = CGRect(
            x: rect.minX + 1, y: rect.minY + 10,
            width: rect.width - 2, height: rect.height - 10 - titleBand
        )
        scroller.contentHeight = entries.reduce(0) { $0 + height(of: $1) }
        layoutRows()
    }

    private func height(of entry: Entry) -> CGFloat {
        switch entry {
        case .header: return headerHeight
        case .recipe: return rowHeight
        }
    }

    private func layoutRows() {
        rowFrames.removeAll(keepingCapacity: true)
        var top = viewport.maxY + scroller.offset
        for entry in entries {
            let entryHeight = height(of: entry)
            top -= entryHeight
            rowFrames.append(CGRect(
                x: viewport.minX, y: top, width: viewport.width, height: entryHeight
            ))
        }
    }

    func scroll(by delta: CGFloat) {
        guard isOpen else { return }
        scroller.scroll(by: delta)
        layoutRows()
    }

    func setScroll(_ value: CGFloat) {
        scroller.set(value)
        layoutRows()
    }

    /// Arrows, Page keys and Home/End, shared with the creative palette so
    /// the two lists cannot answer to different keys.
    func handleKey(_ keyCode: UInt16) -> Bool {
        guard isOpen, PanelScroller.keyScroll(keyCode, in: &scroller) else { return false }
        layoutRows()
        return true
    }

    /// The scrollbar as a control: the knob can be dragged and the track
    /// pages. Returns whether the click was the scrollbar's.
    func beginScrollDrag(at point: CGPoint) -> Bool {
        guard isOpen, scroller.beginDrag(at: point) else { return false }
        layoutRows()
        return true
    }

    func continueScrollDrag(to point: CGPoint) {
        guard scroller.isDragging else { return }
        scroller.drag(to: point)
        layoutRows()
    }

    func endScrollDrag() { scroller.endDrag() }
    var isScrollDragging: Bool { scroller.isDragging }

    /// The entry under a point, or nil — including nil for a row that has
    /// scrolled out from under the viewport's clip, which is drawn nowhere
    /// and so must not be clickable either.
    func hitEntry(at point: CGPoint) -> Int? {
        guard isOpen, viewport.contains(point) else { return nil }
        guard !scroller.trackRect.contains(point) else { return nil }
        return rowFrames.firstIndex { $0.contains(point) }
    }

    /// The middle of an entry's row — how the snapshot harness points the
    /// cursor at a row without a mouse, and how the check aims a click.
    ///
    /// Nil unless that middle is inside the viewport, which is stricter
    /// than the row merely overlapping it: a row scrolled half under the
    /// edge has a centre nothing can click, and handing that point back
    /// would be handing back a click that misses.
    func center(ofEntry index: Int) -> CGPoint? {
        guard rowFrames.indices.contains(index) else { return nil }
        let centre = CGPoint(x: rowFrames[index].midX, y: rowFrames[index].midY)
        return viewport.contains(centre) ? centre : nil
    }

    /// How far the list can be scrolled before it runs out of recipes.
    var scrollLimit: CGFloat { scroller.maximum }

    // MARK: - The refusal shake

    private static let flashDuration: CFTimeInterval = 0.32
    private var flashEntry: Int?
    private var flashStarted: CFAbsoluteTime = 0

    /// Marks a row as refused. Clicking a recipe you can't make should feel
    /// like the row said no, not like the click missed.
    func flash(entry: Int) {
        flashEntry = entry
        flashStarted = CFAbsoluteTimeGetCurrent()
    }

    /// 0…1 through the refusal animation, or nil when nothing is shaking.
    var flashPhase: CGFloat? {
        guard flashEntry != nil else { return nil }
        let elapsed = CFAbsoluteTimeGetCurrent() - flashStarted
        guard elapsed < RecipeBookPanel.flashDuration else { return nil }
        return CGFloat(max(0, elapsed / RecipeBookPanel.flashDuration))
    }

    var isFlashing: Bool { flashPhase != nil }

    // MARK: - Drawing

    func draw(_ context: CGContext, inventory: Inventory, gridSize: Int, cursor: CGPoint) {
        guard isOpen, rect.width > 0 else { return }
        if flashPhase == nil { flashEntry = nil }

        context.setFillColor(NSColor(calibratedWhite: 0.13, alpha: 1).cgColor)
        context.fill(rect)
        context.setStrokeColor(NSColor(calibratedWhite: 0.42, alpha: 1).cgColor)
        context.setLineWidth(2)
        context.stroke(rect.insetBy(dx: 1, dy: 1))

        (L10n.t("Recipe Book", "Receptbok") as NSString).draw(
            at: CGPoint(x: rect.minX + 12, y: rect.maxY - 28),
            withAttributes: [
                .font: NSFont.boldSystemFont(ofSize: 15),
                .foregroundColor: NSColor.white,
            ]
        )
        // Said in words rather than with a glyph legend. The badge on a row
        // says *which* recipes; what a reader needs from up here is what
        // the fading means, and "faded" is the word for what they can see.
        let subtitle = gridSize >= 3
            ? L10n.t(
                "Click a lit-up recipe to lay it out",
                "Klicka på ett recept som lyser så läggs det ut"
            )
            : L10n.t(
                "Click a lit-up one \u{2014} faded needs a crafting table",
                "Klicka på ett som lyser \u{2014} de bleka behöver en arbetsbänk"
            )
        (subtitle as NSString).draw(
            at: CGPoint(x: rect.minX + 12, y: rect.maxY - 43),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 10),
                .foregroundColor: NSColor(calibratedWhite: 0.58, alpha: 1),
            ]
        )

        let hovered = hitEntry(at: cursor)
        context.saveGState()
        context.clip(to: viewport)
        for (index, entry) in entries.enumerated() {
            let frame = rowFrames[index]
            guard frame.intersects(viewport) else { continue }
            switch entry {
            case .header(let group):
                drawHeader(group, in: frame, context: context)
            case .recipe(let recipeIndex):
                drawRecipeRow(
                    RecipeBook.all[recipeIndex], entry: index, in: frame, context: context,
                    inventory: inventory, gridSize: gridSize, hovered: hovered == index
                )
            }
        }
        context.restoreGState()

        scroller.draw(context, hovered: scroller.trackRect.contains(cursor))
    }

    private func drawHeader(_ group: Recipe.Group, in frame: CGRect, context: CGContext) {
        (group.title.uppercased() as NSString).draw(
            at: CGPoint(x: frame.minX + 12, y: frame.minY + 7),
            withAttributes: [
                .font: NSFont.boldSystemFont(ofSize: 10),
                .foregroundColor: NSColor(calibratedRed: 0.62, green: 0.76, blue: 0.55, alpha: 1),
                .kern: 1.2,
            ]
        )
        context.setFillColor(NSColor(calibratedWhite: 0.3, alpha: 1).cgColor)
        context.fill(CGRect(x: frame.minX + 12, y: frame.minY + 4, width: frame.width - 24, height: 1))
    }

    private func drawRecipeRow(
        _ recipe: Recipe, entry: Int, in frame: CGRect, context: CGContext,
        inventory: Inventory, gridSize: Int, hovered: Bool
    ) {
        let fitsHere = recipe.fits(gridSize: gridSize)
        let craftableNow = RecipeBook.canCraft(recipe, from: inventory, gridSize: gridSize)

        // A row being shaken slides sideways and stays put in the list, so
        // the refusal reads as "not that one" rather than as a redraw.
        var row = frame.insetBy(dx: 8, dy: 3)
        if entry == flashEntry, let phase = flashPhase {
            row.origin.x += sin(phase * .pi * 6) * 6 * (1 - phase)
        }

        if craftableNow {
            context.setFillColor(NSColor(calibratedRed: 0.24, green: 0.34, blue: 0.22, alpha: 1).cgColor)
            context.fill(row)
            context.setStrokeColor(NSColor(calibratedRed: 0.52, green: 0.72, blue: 0.44, alpha: 1).cgColor)
            context.setLineWidth(1.5)
            context.stroke(row.insetBy(dx: 0.75, dy: 0.75))
        } else if hovered && fitsHere {
            context.setFillColor(NSColor(calibratedWhite: 0.20, alpha: 1).cgColor)
            context.fill(row)
        }
        if entry == flashEntry, let phase = flashPhase {
            context.setFillColor(NSColor(
                calibratedRed: 0.7, green: 0.28, blue: 0.24, alpha: (1 - phase) * 0.3
            ).cgColor)
            context.fill(row)
        }

        // Everything a 2×2 grid can't reach is drawn faint — but only faint
        // enough to read. Showing those rows at all is the whole point:
        // they are the reason to go and put down a crafting table, and a
        // pattern too washed out to study is no reason to do anything.
        // Measured against a capture at 0.34, which was not readable.
        let alpha: CGFloat = fitsHere ? 1 : 0.52
        let nameColor = fitsHere
            ? NSColor.white
            : NSColor(calibratedWhite: 0.58, alpha: 1)

        // The top line is what this makes; the line under it is what it
        // costs. Both are pinned to the top of the row rather than to its
        // middle, so the cost line lands in the same place on every row
        // and the eye can run straight down it.
        let titleY = row.maxY - 20
        let patternRect = CGRect(x: row.minX + 6, y: row.minY + 3, width: 48, height: row.height - 6)
        drawPattern(recipe, in: patternRect, context: context, alpha: alpha)

        let arrowX = patternRect.maxX + 6
        drawArrow(context, from: arrowX, to: arrowX + 15, midY: titleY + 6, alpha: alpha)

        let outputRect = CGRect(x: arrowX + 21, y: titleY - 6, width: 26, height: 26)
        drawIcon(recipe.output.type, in: outputRect, context: context, alpha: alpha)

        // The count rides in the name — "Oak Stairs ×4" — rather than as a
        // corner badge. It is the number a child is actually reading.
        var name = recipe.output.type.displayName
        if recipe.output.count > 1 { name += " \u{00D7}\(recipe.output.count)" }
        let textX = outputRect.maxX + 8
        (name as NSString).draw(
            at: CGPoint(x: textX, y: titleY),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: nameColor,
            ]
        )

        drawIngredients(
            recipe, at: CGPoint(x: patternRect.maxX + 8, y: titleY - 18),
            maxX: row.maxX - 8, context: context, inventory: inventory, alpha: alpha
        )

        var note: String?
        if !fitsHere {
            note = hovered
                ? L10n.t("needs a crafting table", "behöver en arbetsbänk")
                : L10n.t("crafting table", "arbetsbänk")
        } else if case .shapeless = recipe.pattern {
            note = L10n.t("any shape", "valfri form")
        }
        if let note {
            (note as NSString).draw(
                at: CGPoint(x: patternRect.maxX + 8, y: row.minY + 2),
                withAttributes: [
                    .font: NSFont.systemFont(ofSize: 9),
                    .foregroundColor: NSColor(calibratedWhite: fitsHere ? 0.62 : 0.56, alpha: 1),
                ]
            )
        }

        if recipe.requiresTable {
            drawTableBadge(
                context,
                in: CGRect(x: row.maxX - 20, y: titleY - 1, width: 14, height: 14),
                alpha: fitsHere ? 0.85 : 0.5
            )
        }
    }

    /// What the recipe costs, in words: "Planks 2/6 · Stick 1/1".
    ///
    /// The pattern beside it already says this in pictures, and pictures
    /// are what a 14-pixel cell can hold — which is to say not the name of
    /// the thing, and not how many of it you have. Both numbers are drawn
    /// because the pair is the actual question: what it costs, and how far
    /// off you are. Green when you have enough of that one, so a row that
    /// is almost affordable shows you exactly which ingredient to go and
    /// find.
    private func drawIngredients(
        _ recipe: Recipe, at origin: CGPoint, maxX: CGFloat,
        context: CGContext, inventory: Inventory, alpha: CGFloat
    ) {
        // Sorted by name so a given recipe always reads the same way —
        // `ingredientCounts` is a dictionary and would otherwise reshuffle
        // its line between two draws of the same row.
        let needed = recipe.ingredientCounts
            .map { (item: $0.key, need: $0.value, have: inventory.count(of: $0.key)) }
            .sorted { $0.item.displayName < $1.item.displayName }

        let font = NSFont.systemFont(ofSize: 11)
        let separator = " \u{00B7} " as NSString
        let separatorAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(calibratedWhite: 0.45, alpha: alpha),
        ]
        let ellipsis = "\u{2026}" as NSString

        var x = origin.x
        for (index, ingredient) in needed.enumerated() {
            let enough = ingredient.have >= ingredient.need
            let text = "\(ingredient.item.displayName) \(min(ingredient.have, 999))/\(ingredient.need)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: enough
                    ? NSColor(calibratedRed: 0.56, green: 0.82, blue: 0.46, alpha: alpha)
                    : NSColor(calibratedWhite: 0.72, alpha: alpha),
            ]
            let width = text.size(withAttributes: attributes).width
            // Out of room: say so with an ellipsis rather than running the
            // last name off the edge of the panel.
            guard x + width <= maxX else {
                ellipsis.draw(at: CGPoint(x: x, y: origin.y), withAttributes: separatorAttributes)
                return
            }
            text.draw(at: CGPoint(x: x, y: origin.y), withAttributes: attributes)
            x += width
            if index < needed.count - 1 {
                separator.draw(at: CGPoint(x: x, y: origin.y), withAttributes: separatorAttributes)
                x += separator.size(withAttributes: separatorAttributes).width
            }
        }
    }

    /// The pattern as a miniature of the crafting grid. Shaped recipes get
    /// their cells where they belong; shapeless ones get their ingredients
    /// in a row inside a dashed outline, because "these four, anywhere" is
    /// a different promise from "this shape".
    private func drawPattern(
        _ recipe: Recipe, in rect: CGRect, context: CGContext, alpha: CGFloat
    ) {
        switch recipe.pattern {
        case .shaped(let rows):
            let columns = rows.map(\.count).max() ?? 1
            let cell = min(14, min(rect.width / CGFloat(columns), rect.height / CGFloat(rows.count)) - 1)
            let blockWidth = cell * CGFloat(columns) + 2 * CGFloat(columns - 1)
            let blockHeight = cell * CGFloat(rows.count) + 2 * CGFloat(rows.count - 1)
            let originX = rect.midX - blockWidth / 2
            let topY = rect.midY + blockHeight / 2
            for (row, items) in rows.enumerated() {
                for (column, item) in items.enumerated() {
                    let cellRect = CGRect(
                        x: originX + CGFloat(column) * (cell + 2),
                        y: topY - CGFloat(row + 1) * cell - CGFloat(row) * 2,
                        width: cell, height: cell
                    )
                    drawCell(cellRect, item: item, context: context, alpha: alpha)
                }
            }
        case .shapeless(let items):
            let count = max(1, items.count)
            let cell = min(12, (rect.width - 4 - 2 * CGFloat(count - 1)) / CGFloat(count))
            let blockWidth = cell * CGFloat(count) + 2 * CGFloat(count - 1)
            let originX = rect.midX - blockWidth / 2
            let y = rect.midY - cell / 2 + 2
            for (index, item) in items.enumerated() {
                drawCell(
                    CGRect(x: originX + CGFloat(index) * (cell + 2), y: y, width: cell, height: cell),
                    item: item, context: context, alpha: alpha
                )
            }
            let outline = CGRect(
                x: originX - 3, y: y - 3, width: blockWidth + 6, height: cell + 6
            )
            context.saveGState()
            context.setAlpha(alpha)
            context.setStrokeColor(NSColor(calibratedWhite: 0.62, alpha: 1).cgColor)
            context.setLineWidth(1)
            context.setLineDash(phase: 0, lengths: [3, 2])
            context.addPath(CGPath(
                roundedRect: outline, cornerWidth: 3, cornerHeight: 3, transform: nil
            ))
            context.strokePath()
            context.restoreGState()
        }
    }

    private func drawCell(
        _ rect: CGRect, item: ItemType?, context: CGContext, alpha: CGFloat
    ) {
        context.saveGState()
        context.setAlpha(alpha)
        context.setFillColor(NSColor(calibratedWhite: item == nil ? 0.17 : 0.30, alpha: 1).cgColor)
        context.fill(rect)
        context.setStrokeColor(NSColor(calibratedWhite: 0.44, alpha: 1).cgColor)
        context.setLineWidth(0.75)
        context.stroke(rect.insetBy(dx: 0.375, dy: 0.375))
        context.restoreGState()
        guard let item else { return }
        drawIcon(item, in: rect.insetBy(dx: 1, dy: 1), context: context, alpha: alpha)
    }

    private func drawIcon(
        _ item: ItemType, in rect: CGRect, context: CGContext, alpha: CGFloat
    ) {
        let icon = ItemIcons.icon(for: item)
        guard let cgIcon = icon.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        context.saveGState()
        context.setAlpha(alpha)
        context.interpolationQuality = .none
        context.draw(cgIcon, in: rect)
        context.restoreGState()
    }

    private func drawArrow(
        _ context: CGContext, from tailX: CGFloat, to headX: CGFloat,
        midY: CGFloat, alpha: CGFloat
    ) {
        context.saveGState()
        context.setAlpha(alpha)
        context.setFillColor(NSColor(calibratedWhite: 0.62, alpha: 1).cgColor)
        context.fill(CGRect(x: tailX, y: midY - 1.5, width: headX - tailX - 5, height: 3))
        context.move(to: CGPoint(x: headX, y: midY))
        context.addLine(to: CGPoint(x: headX - 6, y: midY + 4.5))
        context.addLine(to: CGPoint(x: headX - 6, y: midY - 4.5))
        context.closePath()
        context.fillPath()
        context.restoreGState()
    }

    /// A tiny crafting table: a 2×2 of panes on a slab, which is what the
    /// table's own icon reads as at this size.
    private func drawTableBadge(_ context: CGContext, in rect: CGRect, alpha: CGFloat) {
        context.saveGState()
        context.setAlpha(alpha)
        context.setFillColor(NSColor(calibratedRed: 0.45, green: 0.31, blue: 0.17, alpha: 1).cgColor)
        context.fill(rect)
        context.setFillColor(NSColor(calibratedRed: 0.72, green: 0.55, blue: 0.33, alpha: 1).cgColor)
        let cell = (rect.width - 3) / 2
        for row in 0..<2 {
            for column in 0..<2 {
                context.fill(CGRect(
                    x: rect.minX + 1 + CGFloat(column) * (cell + 1),
                    y: rect.minY + 1 + CGFloat(row) * (cell + 1),
                    width: cell, height: cell
                ))
            }
        }
        context.restoreGState()
    }

}
#endif
