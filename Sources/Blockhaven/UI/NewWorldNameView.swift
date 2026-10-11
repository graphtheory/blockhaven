#if canImport(AppKit)
import AppKit

/// The step between picking New World and the world existing: what to call
/// it.
///
/// A panel over the start menu rather than a screen of its own, because
/// naming is a detour off a card that is still sitting there behind it —
/// and because Esc has to land you back on the cards, not somewhere new.
///
/// The field is drawn and edited here rather than being an `NSTextField`.
/// That keeps it looking like the rest of the game's panels, and it means
/// the snapshot harness can shoot it: an AppKit control is a subview, and
/// the harness renders these views by calling `draw` directly, which
/// subviews never see. What is given up is what a name for a block-game
/// world never needs — an input method, a selection, a context menu.
final class NewWorldNameView: NSView {
    /// Called with the finished name, already trimmed and capped.
    var onConfirm: ((String) -> Void)?
    /// Called when the player backs out to the cards.
    var onCancel: (() -> Void)?

    let mode: GameMode

    /// What the field starts with, and what an empty name falls back to.
    /// Resolved on use rather than stored, so the placeholder follows a
    /// language flip — and switched on the mode, because Swedish compounds
    /// "survival world" into one word where English keeps them apart.
    var defaultName: String { Self.defaultName(for: mode) }

    private static func defaultName(for mode: GameMode) -> String {
        switch mode {
        case .survival: return L10n.t("Survival World", "Överlevnadsvärld")
        case .creative: return L10n.t("Creative World", "Kreativ värld")
        }
    }

    private var typed: String

    init(frame frameRect: NSRect, mode: GameMode) {
        self.mode = mode
        self.typed = Self.defaultName(for: mode)
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    /// The name as it would be used right now — what Return would commit.
    var resolvedName: String {
        WorldCatalog.sanitize(typed, fallback: defaultName)
    }

    /// Sets the field's contents, for the snapshot harness and for tests
    /// that shouldn't have to synthesise key events to type a name.
    func setTypedName(_ name: String) {
        typed = String(name.prefix(WorldCatalog.maximumNameLength))
        needsDisplay = true
    }

    private var accent: NSColor {
        switch mode {
        case .survival: return NSColor(calibratedRed: 0.44, green: 0.76, blue: 0.32, alpha: 1)
        case .creative: return NSColor(calibratedRed: 0.36, green: 0.66, blue: 0.98, alpha: 1)
        }
    }

    // MARK: - Layout

    private let panelWidth: CGFloat = 520
    private let panelHeight: CGFloat = 244

    private var panelRect: CGRect {
        CGRect(
            x: ((bounds.width - panelWidth) / 2).rounded(),
            y: ((bounds.height - panelHeight) / 2).rounded(),
            width: panelWidth,
            height: panelHeight
        )
    }

    private var fieldRect: CGRect {
        let panel = panelRect
        return CGRect(x: panel.minX + 32, y: panel.minY + 88, width: panel.width - 64, height: 52)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // Dim what's behind, so the cards read as still there but not the
        // thing being answered.
        context.setFillColor(NSColor(calibratedWhite: 0, alpha: 0.62).cgColor)
        context.fill(bounds)

        let panel = panelRect
        context.setFillColor(NSColor(calibratedWhite: 0.155, alpha: 1).cgColor)
        let path = CGPath(roundedRect: panel, cornerWidth: 14, cornerHeight: 14, transform: nil)
        context.addPath(path)
        context.fillPath()
        context.setStrokeColor(accent.withAlphaComponent(0.85).cgColor)
        context.setLineWidth(2)
        context.addPath(path)
        context.strokePath()

        // Swedish word order can't reuse the English template — the
        // survival eyebrow compounds into one word — so its half is
        // written out per mode.
        drawText(L10n.t("NEW \(mode.displayName.uppercased()) WORLD",
                        mode == .survival ? "NY ÖVERLEVNADSVÄRLD" : "NY KREATIV VÄRLD"),
                 at: NSPoint(x: panel.midX, y: panel.maxY - 40),
                 font: .systemFont(ofSize: 11, weight: .semibold),
                 color: accent.withAlphaComponent(0.9), centred: true, tracking: 1.6)

        drawText(L10n.t("What should this world be called?", "Vad ska den här världen heta?"),
                 at: NSPoint(x: panel.midX, y: panel.maxY - 86),
                 font: .systemFont(ofSize: 22, weight: .semibold),
                 color: NSColor(calibratedWhite: 0.98, alpha: 1), centred: true)

        drawField(context)

        drawText(L10n.t("Return starts the world  ·  Esc goes back to the cards",
                        "Retur startar världen  ·  Esc går tillbaka till korten"),
                 at: NSPoint(x: panel.midX, y: panel.minY + 42),
                 font: .systemFont(ofSize: 12.5, weight: .regular),
                 color: NSColor(calibratedWhite: 0.55, alpha: 1), centred: true)
    }

    private func drawField(_ context: CGContext) {
        let field = fieldRect
        context.setFillColor(NSColor(calibratedWhite: 0.09, alpha: 1).cgColor)
        context.fill(field)
        context.setStrokeColor(accent.cgColor)
        context.setLineWidth(1.5)
        context.stroke(field.insetBy(dx: 0.75, dy: 0.75))

        let font = NSFont.systemFont(ofSize: 20, weight: .medium)
        // An empty field shows the fallback greyed out, so it is always
        // clear what pressing Return would actually name the world.
        let showingPlaceholder = typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let text = showingPlaceholder ? defaultName : typed
        let color = showingPlaceholder
            ? NSColor(calibratedWhite: 0.45, alpha: 1)
            : NSColor(calibratedWhite: 0.97, alpha: 1)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let origin = NSPoint(x: field.minX + 14, y: field.midY - 10)
        text.draw(at: origin, withAttributes: attributes)

        // A block caret after the text — no blink, because a still panel
        // that is obviously waiting for typing beats an animation that is
        // half the time invisible in a screenshot.
        let width = showingPlaceholder ? 0 : text.size(withAttributes: attributes).width
        context.setFillColor(accent.cgColor)
        context.fill(CGRect(x: origin.x + width + 2, y: field.midY - 12, width: 2, height: 26))

        let remaining = WorldCatalog.maximumNameLength - typed.count
        if remaining <= 6 {
            drawText(L10n.t("\(remaining) left", "\(remaining) kvar"),
                     at: NSPoint(x: field.maxX - 6, y: field.minY - 20),
                     font: .systemFont(ofSize: 11, weight: .regular),
                     color: NSColor(calibratedWhite: 0.45, alpha: 1), centred: true)
        }
    }

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

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // Esc
            onCancel?()
            return
        case 36, 76: // Return, Enter
            onConfirm?(resolvedName)
            return
        case 51: // Delete
            if !typed.isEmpty { typed.removeLast() }
            needsDisplay = true
            return
        default:
            break
        }

        guard let characters = event.charactersIgnoringModifiers,
              !event.modifierFlags.contains(.command) else { return }
        for character in characters {
            // Anything that would make a name unreadable simply isn't
            // typed. Control characters and newlines are the obvious half;
            // the other half is AppKit's function keys, which arrive here
            // as ordinary characters in the private-use block — an arrow
            // key pressed in this field used to append a glyph nobody can
            // see or delete their way out of confidently.
            guard !character.isNewline, character.unicodeScalars.allSatisfy(isTypable) else { continue }
            guard typed.count < WorldCatalog.maximumNameLength else { break }
            typed.append(character)
        }
        needsDisplay = true
    }

    /// Everything AppKit reports as a keystroke that isn't a character a
    /// name can contain. `NSUpArrowFunctionKey` and its neighbours live at
    /// U+F700 and up, inside the Unicode private-use area.
    private func isTypable(_ scalar: Unicode.Scalar) -> Bool {
        !CharacterSet.controlCharacters.contains(scalar) && !(0xF700...0xF8FF).contains(scalar.value)
    }

    /// A click outside the panel backs out, the same as Esc — the panel is
    /// a detour, and tapping past it is how everyone tries to leave one.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard !panelRect.contains(point) else { return }
        onCancel?()
    }
}
#endif
