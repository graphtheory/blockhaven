#if canImport(AppKit)
import AppKit

/// The in-play overlay: crosshair, hotbar, hearts, hunger, air bubbles, the
/// held-item name flash, and the F3 debug readout.
///
/// Drawn with Core Graphics into a transparent `NSView` layered over the
/// RealityKit view. RealityKit has no overlay-scene equivalent to
/// SceneKit's, and a plain view is the simplest thing that composites
/// correctly and hit-tests predictably.
final class HUDView: NSView {
    typealias State = HUDState

    private var state = State()

    /// Cached so the hint doesn't hit UserDefaults every frame — read again
    /// each draw only until it flips true (InventoryView sets it on first
    /// open), then never again.
    private var craftingHintDismissed = GameSettings.craftingHintShown

    private let slotSize: CGFloat = 44
    private let slotGap: CGFloat = 4
    private let bottomMargin: CGFloat = 22

    override var isFlipped: Bool { false }
    /// Input belongs to the game view underneath; this is pure decoration.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isOpaque: Bool { false }

    func update(_ newState: State) {
        state = newState
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setShouldAntialias(true)

        if state.isSubmerged {
            context.setFillColor(NSColor(calibratedRed: 0.10, green: 0.28, blue: 0.62, alpha: 0.32).cgColor)
            context.fill(bounds)
        }
        if state.isInLava {
            context.setFillColor(NSColor(calibratedRed: 0.85, green: 0.25, blue: 0.05, alpha: 0.40).cgColor)
            context.fill(bounds)
        }
        if state.showDamageFlash {
            context.setFillColor(NSColor(calibratedRed: 0.75, green: 0.05, blue: 0.05, alpha: 0.30).cgColor)
            context.fill(bounds)
        }

        drawCrosshair(context)
        let hotbarRect = drawHotbar(context)
        if state.showSurvivalBars { drawStatusBars(context, above: hotbarRect) }
        drawItemName(context, above: hotbarRect)
        drawToast(context, above: hotbarRect)
        drawCraftingHint(context, above: hotbarRect)
        drawCompassDial(context)
        drawDebug(context)

        if state.fadeToBlack > 0 {
            context.setFillColor(
                NSColor(calibratedWhite: 0, alpha: min(1, state.fadeToBlack)).cgColor
            )
            context.fill(bounds)
        }
    }

    // MARK: - Pieces

    private func drawCrosshair(_ context: CGContext) {
        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        let arm: CGFloat = 8, thickness: CGFloat = 2
        // Difference blending keeps the crosshair visible against both a
        // bright sky and a dark cave wall.
        context.saveGState()
        context.setBlendMode(.difference)
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: centre.x - arm, y: centre.y - thickness / 2, width: arm * 2, height: thickness))
        context.fill(CGRect(x: centre.x - thickness / 2, y: centre.y - arm, width: thickness, height: arm * 2))
        context.restoreGState()
    }

    /// Draws the nine slots and returns the bar's overall frame.
    @discardableResult
    private func drawHotbar(_ context: CGContext) -> CGRect {
        let count = Inventory.hotbarSize
        let totalWidth = CGFloat(count) * slotSize + CGFloat(count - 1) * slotGap
        let originX = (bounds.width - totalWidth) / 2
        let originY = bottomMargin
        let barRect = CGRect(x: originX, y: originY, width: totalWidth, height: slotSize)

        for index in 0..<count {
            let rect = CGRect(
                x: originX + CGFloat(index) * (slotSize + slotGap),
                y: originY,
                width: slotSize, height: slotSize
            )
            context.setFillColor(NSColor(calibratedWhite: 0.10, alpha: 0.62).cgColor)
            context.fill(rect)
            context.setStrokeColor(NSColor(calibratedWhite: 0.45, alpha: 0.85).cgColor)
            context.setLineWidth(1.5)
            context.stroke(rect.insetBy(dx: 0.75, dy: 0.75))

            if let stack = state.hotbar[index] {
                drawItem(stack, in: rect, context: context)
            }
        }

        // Selection frame, drawn last so it sits over its neighbours.
        let selected = max(0, min(count - 1, state.selectedSlot))
        let selectedRect = CGRect(
            x: originX + CGFloat(selected) * (slotSize + slotGap),
            y: originY, width: slotSize, height: slotSize
        ).insetBy(dx: -2.5, dy: -2.5)
        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(2.5)
        context.stroke(selectedRect)

        return barRect
    }

    /// Item icon plus its stack count. Shared by the hotbar and the
    /// inventory screen.
    static func drawItem(_ stack: ItemStack, in rect: CGRect, context: CGContext) {
        let icon = ItemIcons.icon(for: stack.type)
        let inset = rect.insetBy(dx: 5, dy: 5)
        if let cgIcon = icon.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            context.saveGState()
            context.interpolationQuality = .none
            context.draw(cgIcon, in: inset)
            context.restoreGState()
        }
        // A worn tool carries its life under it: green while there is
        // plenty, red when there is not. Drawn only once a tool has been
        // used, so a full bar never appears — a gauge on every slot
        // reporting that nothing has happened is a gauge nobody reads.
        if let fraction = stack.wearFraction {
            let bar = CGRect(
                x: rect.minX + 5, y: rect.minY + 4, width: rect.width - 10, height: 3
            )
            context.setFillColor(NSColor(calibratedWhite: 0.05, alpha: 0.85).cgColor)
            context.fill(bar.insetBy(dx: -1, dy: -1))
            // Hue runs green (0.33) to red (0) with the life left, which is
            // the same scale a health bar uses anywhere else.
            context.setFillColor(NSColor(
                calibratedHue: 0.33 * fraction, saturation: 0.85, brightness: 0.9, alpha: 1
            ).cgColor)
            context.fill(CGRect(
                x: bar.minX, y: bar.minY, width: max(1, bar.width * fraction), height: bar.height
            ))
        }

        guard stack.count > 1 else { return }
        let text = "\(stack.count)" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 12),
            .foregroundColor: NSColor.white,
            // A dark stroke keeps the count legible over a pale icon.
            .strokeColor: NSColor.black,
            .strokeWidth: -3.5,
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(
            at: CGPoint(x: rect.maxX - size.width - 3, y: rect.minY + 2),
            withAttributes: attributes
        )
    }

    private func drawItem(_ stack: ItemStack, in rect: CGRect, context: CGContext) {
        HUDView.drawItem(stack, in: rect, context: context)
    }

    private func drawStatusBars(_ context: CGContext, above hotbar: CGRect) {
        let iconSize: CGFloat = 13
        let spacing: CGFloat = 18
        let y = hotbar.maxY + 12

        for index in 0..<10 {
            // Each icon covers two points of the stat, so a half-full icon
            // is a genuine half heart.
            let filled = state.health - index * 2
            let colour: NSColor = filled >= 2
                ? NSColor(calibratedRed: 0.86, green: 0.15, blue: 0.15, alpha: 1)
                : (filled == 1 ? NSColor(calibratedRed: 0.58, green: 0.10, blue: 0.10, alpha: 1)
                               : NSColor(calibratedWhite: 0.12, alpha: 0.62))
            drawHeart(
                context,
                at: CGPoint(x: hotbar.minX + 8 + CGFloat(index) * spacing, y: y + iconSize / 2),
                size: iconSize, colour: colour
            )
        }

        for index in 0..<10 {
            let filled = state.hunger - index * 2
            let colour: NSColor = filled >= 2
                ? NSColor(calibratedRed: 0.72, green: 0.48, blue: 0.20, alpha: 1)
                : (filled == 1 ? NSColor(calibratedRed: 0.48, green: 0.32, blue: 0.13, alpha: 1)
                               : NSColor(calibratedWhite: 0.12, alpha: 0.62))
            drawDrumstick(
                context,
                at: CGPoint(x: hotbar.maxX - 8 - CGFloat(9 - index) * spacing, y: y + iconSize / 2),
                size: iconSize, colour: colour
            )
        }

        // Worn armor, drawn as a small icon above the hearts — the one
        // reminder of what's soaking the next hit, since it never sits in
        // a hotbar slot to be seen there.
        if let chestplate = state.equippedChestplate {
            // Big enough to read the silhouette the same size the hotbar
            // draws it at — a hunger-bubble-sized box lost the neck notch
            // that is the whole reason it doesn't read as a stray pixel.
            let rect = CGRect(x: hotbar.minX + 4, y: y + iconSize + 6, width: 32, height: 32)
            HUDView.drawItem(ItemStack(chestplate), in: rect, context: context)
        }

        // Bubbles only appear while air is actually being spent.
        guard state.air < PlayerStats.maxAir else { return }
        for index in 0..<10 where state.air > index * 2 {
            let centre = CGPoint(
                x: hotbar.maxX - 8 - CGFloat(9 - index) * spacing,
                y: y + iconSize / 2 + 20
            )
            context.setFillColor(NSColor(calibratedRed: 0.55, green: 0.85, blue: 1.0, alpha: 1).cgColor)
            context.fillEllipse(in: CGRect(x: centre.x - 5, y: centre.y - 5, width: 10, height: 10))
            context.setStrokeColor(NSColor(calibratedWhite: 0.06, alpha: 0.9).cgColor)
            context.setLineWidth(1)
            context.strokeEllipse(in: CGRect(x: centre.x - 5, y: centre.y - 5, width: 10, height: 10))
        }
    }

    private func drawHeart(_ context: CGContext, at centre: CGPoint, size: CGFloat, colour: NSColor) {
        let scale = size / 14
        let path = CGMutablePath()
        // Two lobes over a point.
        path.move(to: CGPoint(x: centre.x, y: centre.y - 6 * scale))
        path.addCurve(
            to: CGPoint(x: centre.x - 7 * scale, y: centre.y + 2 * scale),
            control1: CGPoint(x: centre.x - 3 * scale, y: centre.y - 3 * scale),
            control2: CGPoint(x: centre.x - 7 * scale, y: centre.y - 1 * scale)
        )
        path.addArc(
            center: CGPoint(x: centre.x - 3.5 * scale, y: centre.y + 3.5 * scale),
            radius: 3.6 * scale, startAngle: .pi, endAngle: 0, clockwise: false
        )
        path.addArc(
            center: CGPoint(x: centre.x + 3.5 * scale, y: centre.y + 3.5 * scale),
            radius: 3.6 * scale, startAngle: .pi, endAngle: 0, clockwise: false
        )
        path.addCurve(
            to: CGPoint(x: centre.x, y: centre.y - 6 * scale),
            control1: CGPoint(x: centre.x + 7 * scale, y: centre.y - 1 * scale),
            control2: CGPoint(x: centre.x + 3 * scale, y: centre.y - 3 * scale)
        )
        path.closeSubpath()
        context.addPath(path)
        context.setFillColor(colour.cgColor)
        context.fillPath()
        context.addPath(path)
        context.setStrokeColor(NSColor(calibratedWhite: 0.04, alpha: 0.85).cgColor)
        context.setLineWidth(1)
        context.strokePath()
    }

    private func drawDrumstick(_ context: CGContext, at centre: CGPoint, size: CGFloat, colour: NSColor) {
        let scale = size / 13
        let path = CGMutablePath()
        // A meaty end with a bone sticking out to the lower left.
        path.addEllipse(in: CGRect(
            x: centre.x - 2 * scale, y: centre.y - 2 * scale,
            width: 9 * scale, height: 9 * scale
        ))
        path.move(to: CGPoint(x: centre.x - 1 * scale, y: centre.y))
        path.addLine(to: CGPoint(x: centre.x - 6 * scale, y: centre.y - 5 * scale))
        path.addLine(to: CGPoint(x: centre.x - 4 * scale, y: centre.y - 7 * scale))
        path.addLine(to: CGPoint(x: centre.x + 1 * scale, y: centre.y - 2 * scale))
        path.closeSubpath()
        context.addPath(path)
        context.setFillColor(colour.cgColor)
        context.fillPath()
        context.addPath(path)
        context.setStrokeColor(NSColor(calibratedWhite: 0.04, alpha: 0.85).cgColor)
        context.setLineWidth(1)
        context.strokePath()
    }

    private func drawItemName(_ context: CGContext, above hotbar: CGRect) {
        guard let name = state.itemName else { return }
        let text = name as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 15),
            .foregroundColor: NSColor.white,
            .strokeColor: NSColor.black,
            .strokeWidth: -3.0,
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(
            at: CGPoint(x: bounds.midX - size.width / 2, y: hotbar.maxY + 48),
            withAttributes: attributes
        )
    }

    /// A one-time nudge toward crafting, gone for good once the player has
    /// opened the inventory (InventoryView flips the settings flag on init).
    private func drawCraftingHint(_ context: CGContext, above hotbar: CGRect) {
        if !craftingHintDismissed {
            craftingHintDismissed = GameSettings.craftingHintShown
        }
        guard !craftingHintDismissed else { return }

        let text = (state.isCreative
            ? L10n.t(
                "Press E for every block — F picks up the one you're looking at",
                "Tryck E för alla block — F plockar upp det du tittar på"
            )
            : L10n.t(
                "Press E to craft — place the Crafting Table for more recipes",
                "Tryck E för att tillverka — placera arbetsbänken för fler recept"
            )) as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.white,
        ]
        let size = text.size(withAttributes: attributes)
        let origin = CGPoint(x: bounds.midX - size.width / 2, y: hotbar.maxY + 78)
        context.setFillColor(NSColor(calibratedWhite: 0.04, alpha: 0.58).cgColor)
        context.fill(CGRect(
            x: origin.x - 8, y: origin.y - 5,
            width: size.width + 16, height: size.height + 10
        ))
        text.draw(at: origin, withAttributes: attributes)
    }

    private func drawToast(_ context: CGContext, above hotbar: CGRect) {
        guard let toast = state.toast else { return }
        let text = toast as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = text.size(withAttributes: attributes)
        let origin = CGPoint(
            x: (bounds.width - size.width) / 2,
            y: hotbar.maxY + 62
        )
        context.setFillColor(NSColor(calibratedWhite: 0.04, alpha: 0.58).cgColor)
        context.fill(CGRect(
            x: origin.x - 10, y: origin.y - 5,
            width: size.width + 20, height: size.height + 10
        ))
        text.draw(at: origin, withAttributes: attributes)
    }

    /// A small dial top-center, only while a compass is the held item: a
    /// fixed "ahead" tick and a needle at `compassBearing`, so the needle
    /// swings toward the tick exactly when home is dead ahead — the whole
    /// point of drawing it screen-relative rather than as a map.
    private func drawCompassDial(_ context: CGContext) {
        guard let bearing = state.compassBearing else { return }
        let centre = CGPoint(x: bounds.midX, y: bounds.height - 54)
        let radius: CGFloat = 16

        context.setFillColor(NSColor(calibratedWhite: 0.04, alpha: 0.5).cgColor)
        context.fillEllipse(in: CGRect(
            x: centre.x - radius - 4, y: centre.y - radius - 4,
            width: (radius + 4) * 2, height: (radius + 4) * 2
        ))

        context.setStrokeColor(NSColor(calibratedWhite: 0.9, alpha: 0.8).cgColor)
        context.setLineWidth(1.5)
        context.strokeEllipse(in: CGRect(
            x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2
        ))

        // The fixed "ahead" tick, straight up: what the needle points at
        // when home is exactly where the player is facing.
        context.setFillColor(NSColor(calibratedWhite: 0.9, alpha: 0.7).cgColor)
        context.fill(CGRect(x: centre.x - 1, y: centre.y + radius - 3, width: 2, height: 6))

        context.saveGState()
        context.translateBy(x: centre.x, y: centre.y)
        context.rotate(by: -bearing)
        // Violet rather than the usual red while an unclaimed grave is the
        // target: the needle changing color is the only thing that tells a
        // player it swapped off home without a word of text.
        let needleColor = state.compassTargetsGrave
            ? NSColor(calibratedRed: 0.55, green: 0.25, blue: 0.8, alpha: 1)
            : NSColor(calibratedRed: 0.85, green: 0.2, blue: 0.2, alpha: 1)
        context.setFillColor(needleColor.cgColor)
        context.move(to: CGPoint(x: 0, y: radius - 2))
        context.addLine(to: CGPoint(x: 3, y: 0))
        context.addLine(to: CGPoint(x: -3, y: 0))
        context.closePath()
        context.fillPath()
        context.restoreGState()

        if let distance = state.compassDistance {
            let text = "\(Int(distance))m" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.white,
            ]
            let size = text.size(withAttributes: attributes)
            text.draw(
                at: CGPoint(x: centre.x - size.width / 2, y: centre.y - radius - size.height - 5),
                withAttributes: attributes
            )
        }
    }

    private func drawDebug(_ context: CGContext) {
        guard let debugText = state.debugText else { return }
        let text = debugText as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.white,
        ]
        let size = text.size(withAttributes: attributes)
        let origin = CGPoint(x: 10, y: bounds.height - size.height - 10)
        // A panel behind the text: white-on-sky is unreadable, and the
        // readout is exactly what you reach for when something looks wrong.
        context.setFillColor(NSColor(calibratedWhite: 0.04, alpha: 0.58).cgColor)
        context.fill(CGRect(
            x: origin.x - 7, y: origin.y - 5,
            width: size.width + 14, height: size.height + 10
        ))
        text.draw(at: origin, withAttributes: attributes)
    }
}
#endif
