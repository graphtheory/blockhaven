#if canImport(AppKit)
import AppKit

/// The inventory / crafting screen. Opens over the world with the cursor
/// handed back; clicking picks a stack up onto the cursor, clicking again
/// puts it down, right-click splits or places one. A crafting grid sits at
/// the top — 2×2 from the inventory key, 3×3 when opened at a crafting
/// table — or, when the screen was opened by right-clicking a chest, the
/// chest's twenty-seven slots instead.
///
/// Three panels can sit beside it: the recipe book (every recipe there is),
/// the creative palette (every item there is, in unlimited supply), and the
/// "you can make" strip. They compete for the same two margins, and
/// `layoutSlots` is where that competition is settled.
///
/// This is a real `NSView`, so it handles its own mouse events rather than
/// having them forwarded from the game view.
final class InventoryView: NSView {
    /// Every clickable slot, tagged by what it addresses.
    private typealias SlotKind = InventoryInteraction.SlotKind

    private struct Slot {
        let kind: SlotKind
        var frame: CGRect
    }

    /// The rules every click follows — shared with the SDL front end.
    private let model: InventoryInteraction
    private var inventory: Inventory { model.inventory }
    private var craftingGrid: CraftingGrid {
        get { model.craftingGrid }
        set { model.craftingGrid = newValue }
    }
    private var chest: Chest? { model.chest }
    private var heldStack: ItemStack? {
        get { model.heldStack }
        set { model.heldStack = newValue }
    }
    private var cursorPoint: CGPoint = .zero

    private var slots: [Slot] = []
    private let slotSize: CGFloat = 44
    private let slotGap: CGFloat = 4
    /// Computed, not stored at init, so it resolves in whatever language
    /// the game speaks at draw time.
    private var title: String {
        if chest != nil { return L10n.t("Chest", "Kista") }
        return craftingGrid.size >= 3
            ? L10n.t("Crafting Table", "Arbetsbänk")
            : L10n.t("Inventory", "Förråd")
    }

    /// Every recipe in the game, opened with the Book button or R. Kept
    /// out of `slots` because it is not a slot: it has its own hit-testing,
    /// its own scrolling, and clicking it moves items around rather than
    /// picking one up.
    private let book = RecipeBookPanel()
    private var bookButtonRect: CGRect = .zero
    private var paletteButtonRect: CGRect = .zero
    /// Every item in the game, in creative worlds only. Nil elsewhere, and
    /// that nil is what keeps survival honest: the palette *is* the
    /// unlimited supply, so a survival screen simply has not got one.
    private let palette: CreativePalettePanel?
    /// Runs only while a refused row is shaking — the inventory screen has
    /// no animation loop of its own, and one that ticked all the time to
    /// serve a third of a second of feedback would be worse than this.
    private var flashTimer: Timer?

    /// Called when the screen wants to close itself (Esc or E).
    var onClose: (() -> Void)?

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    init(frame: NSRect, inventory: Inventory, gridSize: Int, creative: Bool = false, chest: Chest? = nil) {
        self.model = InventoryInteraction(inventory: inventory, gridSize: gridSize, chest: chest)
        self.palette = creative ? CreativePalettePanel() : nil
        super.init(frame: frame)
        layoutSlots()
        // Having found the inventory at all is the discoverability bar —
        // dismisses the HUD's one-time crafting hint for good. Skipped
        // under the snapshot harness, which builds this screen without a
        // player ever having opened it and would otherwise burn the hint
        // in the real, disk-backed defaults domain.
        if !OffscreenSnapshot.isRequested {
            GameSettings.craftingHintShown = true
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutSlots()
        needsDisplay = true
    }

    // MARK: - Layout

    private var panelRect: CGRect = .zero

    private func layoutSlots() {
        slots.removeAll()
        let gridSize = craftingGrid.size
        let step = slotSize + slotGap
        let rowWidth = CGFloat(Inventory.hotbarSize) * step - slotGap

        // Panel is sized to the widest row (the 9-wide inventory) with the
        // crafting area — or the chest's three rows — stacked above it.
        let topRows = chest != nil ? 3 : gridSize
        let topHeight = CGFloat(topRows) * step
        // Room for the caption that tells the two halves of a chest screen
        // apart. Twenty-seven slots over twenty-seven identical slots is a
        // picture with no up or down in it.
        let bagGap: CGFloat = chest != nil ? 32 : 16
        let inventoryHeight = 4 * step + 10 // 3 main rows + a gap + hotbar
        let panelWidth = rowWidth + 40
        let panelHeight = topHeight + inventoryHeight + 54 + bagGap
        panelRect = CGRect(
            x: (bounds.width - panelWidth) / 2,
            y: (bounds.height - panelHeight) / 2,
            width: panelWidth, height: panelHeight
        )

        // The side panels, in the order they get to choose. The palette
        // takes the left because the book has always taken the right, and
        // in creative both are open at once — a palette that moved to
        // whichever side was free would move under the player's hand every
        // time they pressed R.
        let gap: CGFloat = 16
        // Inset by the same gap the panels keep from the main one, so a
        // book seated on the right stops short of the window edge rather
        // than sitting flush against it.
        let margins = bounds.insetBy(dx: gap, dy: 0)
        palette?.layout(in: margins, beside: panelRect, gap: gap)
        let paletteRect = palette?.rect ?? .zero
        let paletteOnLeft = paletteRect.width > 0 && paletteRect.maxX <= panelRect.minX
        let paletteOnRight = paletteRect.width > 0 && !paletteOnLeft
        // The book takes the right when it is open, and the hint strip
        // stands down: the book already highlights everything the strip
        // would have listed, and two panels saying the same thing beside
        // each other is how a screen stops being readable.
        book.layout(in: margins, beside: panelRect, gap: gap, blockedLeft: paletteOnLeft)
        // Both panels want the middle of a window too narrow for either
        // margin, and two of them there is one of them unreadable. The
        // book gives way: it is a thing you consult, and the palette is
        // the thing you build out of.
        if book.isOpen, palette?.overlaps(panelRect) == true {
            palette?.isOpen = false
            palette?.layout(in: margins, beside: panelRect, gap: gap)
        }
        bookButtonRect = chest == nil
            ? CGRect(x: panelRect.maxX - 20 - 88, y: panelRect.maxY - 38, width: 88, height: 24)
            : .zero
        paletteButtonRect = palette == nil
            ? .zero
            : CGRect(
                x: (chest == nil ? bookButtonRect.minX - 8 : panelRect.maxX - 20) - 104,
                y: panelRect.maxY - 38, width: 104, height: 24
            )

        let bookOnRight = book.isOpen && book.rect.minX >= panelRect.maxX
        let bookOnLeft = book.isOpen && !bookOnRight && book.rect.maxX <= panelRect.minX
        let roomRight = (bookOnRight || paletteOnRight)
            ? 0 : margins.maxX - (panelRect.maxX + gap)
        let roomLeft = (bookOnLeft || paletteOnLeft) ? 0 : panelRect.minX - gap - margins.minX
        // "What can I make" panel, beside the main one rather than inside
        // it — panelRect is sized exactly for the grid + inventory rows
        // with no spare room. Prefers the right, falls back to the left,
        // and drops out entirely when neither margin is free: a panel
        // clipped off the edge, or drawn over the palette, reads worse
        // than no panel.
        if chest != nil || (book.isOpen && !bookOnRight && !bookOnLeft) {
            craftableRect = .zero
        } else if roomRight >= craftableMinWidth {
            craftableRect = CGRect(
                x: panelRect.maxX + gap, y: panelRect.minY,
                width: min(craftableWidth, roomRight), height: panelRect.height
            )
        } else if roomLeft >= craftableMinWidth {
            let width = min(craftableWidth, roomLeft)
            craftableRect = CGRect(
                x: panelRect.minX - gap - width, y: panelRect.minY,
                width: width, height: panelRect.height
            )
        } else {
            craftableRect = .zero
        }

        let contentLeft = panelRect.minX + 20
        var cursorY = panelRect.maxY - 50 - slotSize

        if chest != nil {
            // The chest's own three rows of nine, laid out exactly like the
            // main inventory below them — which is the point: the two
            // halves of this screen are the same shape, and moving a stack
            // between them is the same gesture either way.
            for index in 0..<Chest.size {
                let row = index / 9, column = index % 9
                slots.append(Slot(kind: .chest(index), frame: CGRect(
                    x: contentLeft + CGFloat(column) * step,
                    y: cursorY - CGFloat(row) * step,
                    width: slotSize, height: slotSize
                )))
            }
            outputFrame = .zero
            craftGridRight = 0
        } else {
            // Crafting grid, top-left of the panel.
            for index in 0..<(gridSize * gridSize) {
                let row = index / gridSize, column = index % gridSize
                slots.append(Slot(kind: .craft(index), frame: CGRect(
                    x: contentLeft + CGFloat(column) * step,
                    y: cursorY - CGFloat(row) * step,
                    width: slotSize, height: slotSize
                )))
            }
            // Output slot to the right of the grid, vertically centred.
            outputFrame = CGRect(
                x: contentLeft + CGFloat(gridSize) * step + 44,
                y: cursorY - CGFloat(gridSize - 1) * step / 2,
                width: slotSize, height: slotSize
            )
            slots.append(Slot(kind: .craftOutput, frame: outputFrame))
            craftGridRight = contentLeft + CGFloat(gridSize - 1) * step + slotSize
        }

        cursorY -= CGFloat(topRows) * step + bagGap
        bagCaptionOrigin = CGPoint(x: contentLeft, y: cursorY + slotSize + 6)

        // Three rows of main inventory.
        for index in Inventory.hotbarSize..<Inventory.totalSize {
            let offset = index - Inventory.hotbarSize
            let row = offset / 9, column = offset % 9
            slots.append(Slot(kind: .inventory(index), frame: CGRect(
                x: contentLeft + CGFloat(column) * step,
                y: cursorY - CGFloat(row) * step,
                width: slotSize, height: slotSize
            )))
        }

        // Hotbar row, separated by a visible gap so it reads as the row
        // that's actually in hand.
        let hotbarY = cursorY - 3 * step - 10
        for index in 0..<Inventory.hotbarSize {
            slots.append(Slot(kind: .inventory(index), frame: CGRect(
                x: contentLeft + CGFloat(index) * step,
                y: hotbarY, width: slotSize, height: slotSize
            )))
        }
    }

    private var bagCaptionOrigin: CGPoint = .zero
    private var outputFrame: CGRect = .zero
    private var craftGridRight: CGFloat = 0
    private var craftableRect: CGRect = .zero
    private let craftableWidth: CGFloat = 220
    /// Narrower than this and the longest line the panel draws — the empty
    /// state, wider than any icon-plus-item-name row — runs off its edge.
    private let craftableMinWidth: CGFloat = 180

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // Dim the world so the screen reads as paused.
        context.setFillColor(NSColor(calibratedWhite: 0, alpha: 0.6).cgColor)
        context.fill(bounds)

        context.setFillColor(NSColor(calibratedWhite: 0.13, alpha: 1).cgColor)
        context.fill(panelRect)
        context.setStrokeColor(NSColor(calibratedWhite: 0.42, alpha: 1).cgColor)
        context.setLineWidth(2)
        context.stroke(panelRect.insetBy(dx: 1, dy: 1))

        (title as NSString).draw(
            at: CGPoint(x: panelRect.minX + 20, y: panelRect.maxY - 30),
            withAttributes: [
                .font: NSFont.boldSystemFont(ofSize: 15),
                .foregroundColor: NSColor.white,
            ]
        )

        if chest == nil {
            drawCraftArrow(context)
        } else {
            (L10n.t("Your things", "Dina saker") as NSString).draw(
                at: bagCaptionOrigin,
                withAttributes: [
                    .font: NSFont.boldSystemFont(ofSize: 10),
                    .foregroundColor: NSColor(calibratedWhite: 0.62, alpha: 1),
                    .kern: 1.2,
                ]
            )
        }

        let craftedOutput = chest == nil ? RecipeBook.match(craftingGrid) : nil
        for slot in slots {
            let stack: ItemStack?
            switch slot.kind {
            case .inventory(let index): stack = inventory[index]
            case .craft(let index): stack = craftingGrid[index]
            case .craftOutput: stack = craftedOutput
            case .chest(let index): stack = chest?[index]
            }

            // The output slot is tinted so it reads as a result, not an
            // ordinary slot you can drop things into.
            let fill: NSColor
            if slot.kind == .craftOutput {
                fill = craftedOutput == nil
                    ? NSColor(calibratedWhite: 0.20, alpha: 1)
                    : NSColor(calibratedRed: 0.24, green: 0.34, blue: 0.22, alpha: 1)
            } else {
                fill = NSColor(calibratedWhite: 0.28, alpha: 1)
            }
            context.setFillColor(fill.cgColor)
            context.fill(slot.frame)
            context.setStrokeColor(NSColor(calibratedWhite: 0.50, alpha: 1).cgColor)
            context.setLineWidth(1.5)
            context.stroke(slot.frame.insetBy(dx: 0.75, dy: 0.75))

            if let stack {
                HUDView.drawItem(stack, in: slot.frame, context: context)
            }
        }

        book.draw(context, inventory: inventory, gridSize: craftingGrid.size, cursor: cursorPoint)
        palette?.draw(context, cursor: cursorPoint, holding: heldStack != nil)
        // The two switches go on last, over whichever panel is covering
        // the title bar in a window too narrow to seat it elsewhere. A
        // panel that hides its own way out is a panel a child is stuck
        // inside — and `handleClick` asks them first for the same reason.
        if palette != nil { drawPaletteButton(context) }
        if chest == nil { drawBookButton(context) }
        drawTooltip(context)
        drawCraftablePanel(context)

        // The carried stack rides the cursor, drawn last so it's on top.
        if let held = heldStack {
            let rect = CGRect(
                x: cursorPoint.x - slotSize / 2,
                y: cursorPoint.y - slotSize / 2,
                width: slotSize, height: slotSize
            )
            HUDView.drawItem(held, in: rect, context: context)
        }
    }

    /// The way into the recipe book, drawn as an actual button in the
    /// panel's title bar. R opens it too, and the button says so — a key
    /// with nothing on screen pointing at it is a key nobody finds.
    private func drawBookButton(_ context: CGContext) {
        let path = CGPath(
            roundedRect: bookButtonRect, cornerWidth: 4, cornerHeight: 4, transform: nil
        )
        let hovered = bookButtonRect.contains(cursorPoint)
        context.addPath(path)
        context.setFillColor((book.isOpen
            ? NSColor(calibratedRed: 0.28, green: 0.40, blue: 0.26, alpha: 1)
            : NSColor(calibratedWhite: hovered ? 0.32 : 0.24, alpha: 1)).cgColor)
        context.fillPath()
        context.addPath(path)
        context.setStrokeColor(NSColor(calibratedWhite: 0.55, alpha: 1).cgColor)
        context.setLineWidth(1.5)
        context.strokePath()

        // A little brown book: spine, then two pale pages.
        let glyph = CGRect(x: bookButtonRect.minX + 8, y: bookButtonRect.midY - 6, width: 13, height: 12)
        context.setFillColor(NSColor(calibratedRed: 0.55, green: 0.22, blue: 0.18, alpha: 1).cgColor)
        context.fill(glyph)
        context.setFillColor(NSColor(calibratedWhite: 0.86, alpha: 1).cgColor)
        context.fill(CGRect(x: glyph.minX + 2, y: glyph.minY + 2, width: 4, height: 8))
        context.fill(CGRect(x: glyph.midX + 1, y: glyph.minY + 2, width: 4, height: 8))

        (L10n.t("Book (R)", "Bok (R)") as NSString).draw(
            at: CGPoint(x: glyph.maxX + 5, y: bookButtonRect.midY - 7),
            withAttributes: [
                .font: NSFont.boldSystemFont(ofSize: 11),
                .foregroundColor: NSColor.white,
            ]
        )
    }

    /// The palette's own switch, beside the book's. It exists for the
    /// window too narrow to seat the palette beside the inventory, where
    /// the panel covers the slots and has to be got out of the way — but
    /// it is drawn always, because a panel that can be closed and has no
    /// visible way back is worse than one that cannot be closed at all.
    private func drawPaletteButton(_ context: CGContext) {
        let open = palette?.isOpen == true
        let path = CGPath(
            roundedRect: paletteButtonRect, cornerWidth: 4, cornerHeight: 4, transform: nil
        )
        let hovered = paletteButtonRect.contains(cursorPoint)
        context.addPath(path)
        context.setFillColor((open
            ? NSColor(calibratedRed: 0.28, green: 0.40, blue: 0.26, alpha: 1)
            : NSColor(calibratedWhite: hovered ? 0.32 : 0.24, alpha: 1)).cgColor)
        context.fillPath()
        context.addPath(path)
        context.setStrokeColor(NSColor(calibratedWhite: 0.55, alpha: 1).cgColor)
        context.setLineWidth(1.5)
        context.strokePath()

        // Three little cubes, which is what the panel is full of.
        let glyph = CGRect(x: paletteButtonRect.minX + 8, y: paletteButtonRect.midY - 6, width: 13, height: 12)
        context.setFillColor(NSColor(calibratedRed: 0.45, green: 0.66, blue: 0.36, alpha: 1).cgColor)
        context.fill(CGRect(x: glyph.minX, y: glyph.minY + 6, width: 6, height: 6))
        context.setFillColor(NSColor(calibratedRed: 0.62, green: 0.48, blue: 0.30, alpha: 1).cgColor)
        context.fill(CGRect(x: glyph.minX + 7, y: glyph.minY + 6, width: 6, height: 6))
        context.setFillColor(NSColor(calibratedWhite: 0.62, alpha: 1).cgColor)
        context.fill(CGRect(x: glyph.minX + 3, y: glyph.minY, width: 6, height: 6))

        (L10n.t("Blocks (B)", "Block (B)") as NSString).draw(
            at: CGPoint(x: glyph.maxX + 5, y: paletteButtonRect.midY - 7),
            withAttributes: [
                .font: NSFont.boldSystemFont(ofSize: 11),
                .foregroundColor: NSColor.white,
            ]
        )
    }

    /// The arrow between grid and output is what makes the top half read
    /// as "these become that" rather than as more storage.
    private func drawCraftArrow(_ context: CGContext) {
        let midY = outputFrame.midY
        let tailX = craftGridRight + 10
        let headX = outputFrame.minX - 10
        guard headX > tailX + 12 else { return }
        context.setFillColor(NSColor(calibratedWhite: 0.62, alpha: 1).cgColor)
        context.fill(CGRect(x: tailX, y: midY - 3, width: headX - tailX - 9, height: 6))
        context.move(to: CGPoint(x: headX, y: midY))
        context.addLine(to: CGPoint(x: headX - 11, y: midY + 8))
        context.addLine(to: CGPoint(x: headX - 11, y: midY - 8))
        context.closePath()
        context.fillPath()
    }

    private func drawTooltip(_ context: CGContext) {
        // No tooltip while carrying something — the cursor stack already
        // shows what's in hand — and none for a slot a panel is covering,
        // which happens in a window too narrow to seat one alongside.
        guard heldStack == nil else { return }
        guard !(book.isOpen && book.rect.contains(cursorPoint)) else { return }

        let text: String
        if let name = palette?.tooltip(at: cursorPoint) {
            text = name
        } else if palette?.contains(cursorPoint) == true {
            return
        } else if let slot = slot(at: cursorPoint) {
            let stack: ItemStack?
            switch slot.kind {
            case .inventory(let index): stack = inventory[index]
            case .craft(let index): stack = craftingGrid[index]
            case .craftOutput: stack = RecipeBook.match(craftingGrid)
            case .chest(let index): stack = chest?[index]
            }
            guard let stack else { return }
            text = stack.type.displayName
        } else {
            return
        }

        let string = text as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.white,
        ]
        let size = string.size(withAttributes: attributes)
        let rect = CGRect(
            x: cursorPoint.x + 14, y: cursorPoint.y + 10,
            width: size.width + 14, height: size.height + 8
        )
        context.setFillColor(NSColor(calibratedWhite: 0.05, alpha: 0.94).cgColor)
        context.fill(rect)
        context.setStrokeColor(NSColor(calibratedWhite: 0.5, alpha: 1).cgColor)
        context.setLineWidth(1)
        context.stroke(rect)
        string.draw(at: CGPoint(x: rect.minX + 7, y: rect.minY + 4), withAttributes: attributes)
    }

    /// "What can I make right now" — the discoverability panel. Recomputed
    /// every draw, matching the cost of the RecipeBook.match call already
    /// made above for the live crafting-grid output.
    private func drawCraftablePanel(_ context: CGContext) {
        // Empty when the window is too narrow to seat it beside the main panel.
        guard craftableRect.width > 0 else { return }

        context.setFillColor(NSColor(calibratedWhite: 0.13, alpha: 1).cgColor)
        context.fill(craftableRect)
        context.setStrokeColor(NSColor(calibratedWhite: 0.42, alpha: 1).cgColor)
        context.setLineWidth(2)
        context.stroke(craftableRect.insetBy(dx: 1, dy: 1))

        (L10n.t("You can make:", "Du kan tillverka:") as NSString).draw(
            at: CGPoint(x: craftableRect.minX + 12, y: craftableRect.maxY - 24),
            withAttributes: [
                .font: NSFont.boldSystemFont(ofSize: 13),
                .foregroundColor: NSColor.white,
            ]
        )

        let recipes = RecipeBook.craftable(from: inventory, gridSize: craftingGrid.size)
        let listTop = craftableRect.maxY - 42
        let listBottom = craftableRect.minY + 12
        let rowHeight: CGFloat = 34
        let iconSize: CGFloat = 28
        let smallAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor(calibratedWhite: 0.7, alpha: 1),
        ]

        guard !recipes.isEmpty else {
            (L10n.t(
                "Nothing yet \u{2014} gather materials!",
                "Inget än \u{2014} samla material!"
            ) as NSString).draw(
                at: CGPoint(x: craftableRect.minX + 12, y: listTop - 4),
                withAttributes: smallAttributes
            )
            return
        }

        let maxRows = max(0, Int((listTop - listBottom) / rowHeight))
        let shown = recipes.count > maxRows ? Array(recipes.prefix(max(0, maxRows - 1))) : recipes
        let nameAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.white,
        ]

        for (index, recipe) in shown.enumerated() {
            let rowY = listTop - CGFloat(index + 1) * rowHeight
            let iconRect = CGRect(
                x: craftableRect.minX + 12, y: rowY + (rowHeight - iconSize) / 2,
                width: iconSize, height: iconSize
            )
            HUDView.drawItem(recipe.output, in: iconRect, context: context)
            (recipe.output.type.displayName as NSString).draw(
                at: CGPoint(x: iconRect.maxX + 8, y: rowY + rowHeight / 2 - 7),
                withAttributes: nameAttributes
            )
        }

        let remaining = recipes.count - shown.count
        if remaining > 0 {
            let rowY = listTop - CGFloat(shown.count + 1) * rowHeight
            (L10n.t("+\(remaining) more", "+\(remaining) till") as NSString).draw(
                at: CGPoint(x: craftableRect.minX + 12, y: rowY + rowHeight / 2 - 6),
                withAttributes: smallAttributes
            )
        }
    }

    // MARK: - Interaction

    private func slot(at point: CGPoint) -> Slot? {
        slots.first { $0.frame.contains(point) }
    }

    override func mouseMoved(with event: NSEvent) {
        cursorPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        cursorPoint = convert(event.locationInWindow, from: nil)
        // A scrollbar being dragged keeps the pointer even when it wanders
        // off the bar, which is what "drag" means everywhere else.
        if book.isScrollDragging { book.continueScrollDrag(to: cursorPoint) }
        if palette?.isScrollDragging == true { palette?.continueScrollDrag(to: cursorPoint) }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        book.endScrollDrag()
        palette?.endScrollDrag()
    }

    override func mouseDown(with event: NSEvent) {
        cursorPoint = convert(event.locationInWindow, from: nil)
        handleClick(secondary: false, shiftHeld: event.modifierFlags.contains(.shift))
    }

    override func rightMouseDown(with event: NSEvent) {
        cursorPoint = convert(event.locationInWindow, from: nil)
        handleClick(secondary: true, shiftHeld: event.modifierFlags.contains(.shift))
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        // E and Esc both close, matching the keys that opened it.
        case 14, 53:
            onClose?()
        case 15: // R
            toggleBook()
        case 11: // B
            togglePalette()
        // Arrows, Page and Home/End go to the list under the pointer, and
        // to whichever list is open when the pointer is elsewhere. Two
        // scrolling panels can be on screen at once in creative, so "the
        // list" has to be answered rather than assumed. Swallowed either
        // way: an arrow key with no list to move is a key this screen has
        // no other use for, and passing it on only rings the bell.
        case 126, 125, 116, 121, 115, 119:
            _ = scrollPanelUnderCursor(event.keyCode)
            needsDisplay = true
        default:
            super.keyDown(with: event)
        }
    }

    private func scrollPanelUnderCursor(_ keyCode: UInt16) -> Bool {
        if book.isOpen, book.rect.contains(cursorPoint) { return book.handleKey(keyCode) }
        if palette?.contains(cursorPoint) == true { return palette?.handleKey(keyCode) ?? false }
        if book.isOpen { return book.handleKey(keyCode) }
        return palette?.handleKey(keyCode) ?? false
    }

    override func scrollWheel(with event: NSEvent) {
        cursorPoint = convert(event.locationInWindow, from: nil)
        let delta = PanelScroller.delta(for: event)
        if book.isOpen, book.rect.contains(cursorPoint) {
            book.scroll(by: delta)
        } else if palette?.contains(cursorPoint) == true {
            palette?.scroll(by: delta)
        } else if book.isOpen {
            book.scroll(by: delta)
        } else {
            palette?.scroll(by: delta)
        }
        needsDisplay = true
    }

    func toggleBook() {
        guard chest == nil else { return }
        book.isOpen.toggle()
        layoutSlots()
        needsDisplay = true
    }

    func togglePalette() {
        guard let palette else { return }
        palette.isOpen.toggle()
        // Opening the palette in a window that can only hold one of them
        // closes the book, which is the same trade `layoutSlots` makes in
        // the other direction.
        if palette.isOpen, book.isOpen {
            layoutSlots()
            if !palette.isOpen || palette.overlaps(panelRect) {
                book.isOpen = false
                palette.isOpen = true
            }
        }
        layoutSlots()
        needsDisplay = true
    }

    /// Opens the book with a row under the cursor, for the snapshot
    /// harness — which has every part of this screen except a mouse.
    func previewBook(hover: Int?, scroll: CGFloat) {
        book.isOpen = true
        layoutSlots()
        book.setScroll(scroll)
        if let hover, let point = book.center(ofEntry: hover) { cursorPoint = point }
        needsDisplay = true
    }

    /// The same trick for the creative palette: scroll it, and put the
    /// cursor on a cell so the capture shows a hover and its tooltip.
    func previewPalette(hover: Int?, scroll: CGFloat) {
        palette?.setScroll(scroll)
        if let hover, let point = palette?.center(ofItem: hover) { cursorPoint = point }
        needsDisplay = true
    }

    /// Clicking a row in the book. A row you could make lays itself out on
    /// the grid; one you could not shakes and stays where it is.
    private func handleBookClick(entry index: Int) {
        guard case .recipe(let recipeIndex) = book.entries[index] else { return }
        let recipe = RecipeBook.all[recipeIndex]
        // The cursor goes in with it. Putting down what the player is
        // holding is part of the move — it may be an ingredient — and so is
        // handing it back untouched when the row refuses. Both are
        // arithmetic on an inventory, so both live where that arithmetic is
        // checked rather than out here in a view.
        guard model.fill(with: recipe) else {
            return startFlash(entry: index)
        }
    }

    private func startFlash(entry index: Int) {
        book.flash(entry: index)
        flashTimer?.invalidate()
        flashTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) {
            [weak self] timer in
            guard let self else { return timer.invalidate() }
            needsDisplay = true
            if !book.isFlashing { timer.invalidate(); flashTimer = nil }
        }
    }

    private func handleClick(secondary: Bool, shiftHeld: Bool) {
        defer { needsDisplay = true }
        // The switches are drawn over everything, so they are asked before
        // everything — including before the scrollbars, which in an
        // overlaying panel can cross the title bar they sit in.
        if paletteButtonRect.contains(cursorPoint) {
            togglePalette()
            return
        }
        if bookButtonRect.contains(cursorPoint) {
            toggleBook()
            return
        }
        // A scrollbar gets the click before the list it scrolls does — the
        // left button only, since dragging with the right one is not a
        // gesture anything else here answers to.
        if !secondary {
            if book.beginScrollDrag(at: cursorPoint) { return }
            if palette?.beginScrollDrag(at: cursorPoint) == true { return }
        }
        // The book swallows every click that lands on it, not just the ones
        // that land on a row. In a window too narrow to seat it beside the
        // panel it is drawn *over* the inventory, so it is asked before the
        // slots underneath it, in the order things are drawn: a click goes
        // to whatever the player can actually see.
        if book.isOpen, book.rect.contains(cursorPoint) {
            if let entry = book.hitEntry(at: cursorPoint), !secondary {
                handleBookClick(entry: entry)
            }
            return
        }
        if let palette, palette.contains(cursorPoint) {
            if palette.binRect.contains(cursorPoint) {
                // The bin. Creative is the only mode with one, because it
                // is the only mode where throwing a stack away costs
                // nothing — and the only mode that hands out so much that
                // a way to say no to some of it is needed.
                model.discardHeld()
            } else if let item = palette.item(at: cursorPoint) {
                model.takeFromPalette(item, secondary: secondary, shiftHeld: shiftHeld)
            }
            return
        }
        guard let slot = slot(at: cursorPoint) else { return }

        model.click(slot.kind, secondary: secondary, shiftHeld: shiftHeld)
    }

    deinit {
        flashTimer?.invalidate()
    }

    /// Everything the player left on the crafting grid or the cursor goes
    /// back to the inventory when the screen closes — never silently lost.
    /// The chest keeps its own slots, which is the point of a chest.
    func returnHeldItems() {
        flashTimer?.invalidate()
        flashTimer = nil
        model.returnHeldItems()
    }

}
#endif
