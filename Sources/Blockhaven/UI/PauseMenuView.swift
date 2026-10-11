#if canImport(AppKit)
import AppKit

/// The pause screen, shown over a frozen world when `Esc` is pressed in
/// play. Resume, the one setting that ruins the game when it's wrong, and
/// a way out.
///
/// Drawn with Core Graphics like `StartMenuView` rather than with AppKit
/// controls, so it matches the rest of the game's panels. It owns no
/// navigation — the controller that presented it acts on the callbacks.
final class PauseMenuView: NSView {
    /// Called when the player wants back into the world.
    var onResume: (() -> Void)?
    /// Called when the player wants this world saved and put away, and the
    /// start menu back.
    var onMainMenu: (() -> Void)?
    /// Called when the player wants out of the game entirely.
    var onQuit: (() -> Void)?
    /// Called to swap between fullscreen and a window. The window is the
    /// delegate's to own, so this screen only asks.
    var onToggleWindow: (() -> Void)?

    /// What the window row should say it will do — whether the game is
    /// covering the screen right now. The controller sets it when the
    /// screen goes up and after every toggle.
    var isFullscreen = true {
        didSet {
            guard isFullscreen != oldValue else { return }
            needsDisplay = true
        }
    }

    /// Something the footer's promise isn't true of — set when a save
    /// didn't reach the disk. It replaces the footer rather than joining
    /// it: "your world is saved either way out" is exactly the sentence
    /// being contradicted.
    var warning: String? {
        didSet {
            guard warning != oldValue else { return }
            needsDisplay = true
        }
    }

    private enum Row: Int, CaseIterable {
        case resume, sensitivity, window, mainMenu, quit
    }

    /// The sensitivity settles on one of three steps here. The stored
    /// setting is a continuous 0.4...2.0 multiplier; these are the values
    /// worth offering without a slider. Both names ride along and the row
    /// picks one as it draws, so a language flip shows on the next draw.
    private static let sensitivitySteps: [(name: String, swedish: String, value: CGFloat)] = [
        ("Low", "Låg", 0.6), ("Normal", "Normal", 1.0), ("High", "Hög", 1.5),
    ]

    private var hoveredRow: Row?
    private var trackingArea: NSTrackingArea?

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    // MARK: - Layout

    private let panelWidth: CGFloat = 340
    private let rowHeight: CGFloat = 46
    private let rowGap: CGFloat = 12

    /// The panel is sized to its rows plus a header, and centred — there's
    /// nothing else on screen competing for the middle.
    private var panelRect: CGRect {
        let rows = CGFloat(Row.allCases.count)
        let height = rows * rowHeight + (rows - 1) * rowGap + 120
        return CGRect(
            x: ((bounds.width - panelWidth) / 2).rounded(),
            y: ((bounds.height - height) / 2).rounded(),
            width: panelWidth,
            height: height
        )
    }

    private func rowFrame(_ row: Row) -> CGRect {
        let panel = panelRect
        let index = CGFloat(row.rawValue)
        return CGRect(
            x: panel.minX + 24,
            y: panel.maxY - 84 - (index + 1) * rowHeight - index * rowGap,
            width: panel.width - 48,
            height: rowHeight
        )
    }

    private func row(at point: CGPoint) -> Row? {
        Row.allCases.first { rowFrame($0).contains(point) }
    }

    // MARK: - Sensitivity

    /// The step nearest the stored setting, so a hand-edited value still
    /// shows something honest instead of snapping the display to "Normal".
    private var sensitivityIndex: Int {
        let current = GameSettings.mouseSensitivity
        var best = 0
        for (index, step) in PauseMenuView.sensitivitySteps.enumerated()
        where abs(step.value - current) < abs(PauseMenuView.sensitivitySteps[best].value - current) {
            best = index
        }
        return best
    }

    private func cycleSensitivity() {
        let next = (sensitivityIndex + 1) % PauseMenuView.sensitivitySteps.count
        GameSettings.mouseSensitivity = PauseMenuView.sensitivitySteps[next].value
        needsDisplay = true
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // Dim the world so the screen reads as paused, matching the
        // inventory screen's wash.
        context.setFillColor(NSColor(calibratedWhite: 0, alpha: 0.6).cgColor)
        context.fill(bounds)

        let panel = panelRect
        context.setFillColor(NSColor(calibratedWhite: 0.13, alpha: 1).cgColor)
        context.fill(panel)
        context.setStrokeColor(NSColor(calibratedWhite: 0.42, alpha: 1).cgColor)
        context.setLineWidth(2)
        context.stroke(panel.insetBy(dx: 1, dy: 1))

        drawText(L10n.t("Paused", "Paus"),
                 at: NSPoint(x: panel.midX, y: panel.maxY - 52),
                 font: .systemFont(ofSize: 28, weight: .bold),
                 color: NSColor(calibratedWhite: 0.97, alpha: 1), centred: true)

        for row in Row.allCases {
            drawRow(context, row: row, hovered: hoveredRow == row)
        }

        // Inside the panel, in the space under the rows: these keys are
        // about the rows, where the line below the panel is about leaving.
        drawText(L10n.t("↑ ↓ choose  ·  Return takes the row",
                        "↑ ↓ flyttar  ·  Retur väljer raden"),
                 at: NSPoint(x: panel.midX, y: panel.minY + 14),
                 font: .systemFont(ofSize: 11.5, weight: .regular),
                 color: NSColor(calibratedWhite: 0.48, alpha: 1), centred: true)

        // Opening this screen writes the world to disk, and being sure of
        // that is most of the reason to leave from here rather than just
        // closing the window. Both ways out save; the footer says so once
        // rather than repeating it on each row — unless a save has just
        // failed, in which case it says that instead, in a colour that
        // isn't the rest of the panel.
        let footer = warning ?? (WorldSave.isEnabled
            ? L10n.t("Esc resumes  ·  your world is saved either way out",
                     "Esc fortsätter  ·  din värld sparas oavsett hur du avslutar")
            : L10n.t("Esc resumes  ·  ⌘Q quits",
                     "Esc fortsätter  ·  ⌘Q avslutar"))
        drawText(footer,
                 at: NSPoint(x: panel.midX, y: panel.minY - 30),
                 font: .systemFont(ofSize: 12.5, weight: warning == nil ? .regular : .medium),
                 color: warning == nil
                    ? NSColor(calibratedWhite: 0.55, alpha: 1)
                    : NSColor(calibratedRed: 0.95, green: 0.62, blue: 0.28, alpha: 1),
                 centred: true)
    }

    private func drawRow(_ context: CGContext, row: Row, hovered: Bool) {
        let frame = rowFrame(row)
        context.setFillColor((hovered
            ? NSColor(calibratedWhite: 0.30, alpha: 1)
            : NSColor(calibratedWhite: 0.20, alpha: 1)).cgColor)
        context.fill(frame)
        context.setStrokeColor((hovered
            ? NSColor(calibratedWhite: 0.68, alpha: 1)
            : NSColor(calibratedWhite: 0.42, alpha: 1)).cgColor)
        context.setLineWidth(1.5)
        context.stroke(frame.insetBy(dx: 0.75, dy: 0.75))

        let label = NSFont.systemFont(ofSize: 15, weight: .medium)
        let baseline = frame.midY - 6
        switch row {
        case .resume:
            drawText(L10n.t("Resume", "Fortsätt"), at: NSPoint(x: frame.midX, y: baseline),
                     font: label, color: NSColor(calibratedWhite: 0.96, alpha: 1), centred: true)
        case .sensitivity:
            // Left label, right value: a setting row, not a button, even
            // though clicking anywhere on it cycles the value.
            drawText(L10n.t("Mouse Sensitivity", "Muskänslighet"), at: NSPoint(x: frame.minX + 16, y: baseline),
                     font: label, color: NSColor(calibratedWhite: 0.80, alpha: 1), centred: false)
            let step = PauseMenuView.sensitivitySteps[sensitivityIndex]
            let value = L10n.t(step.name, step.swedish)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: label,
                .foregroundColor: NSColor(calibratedRed: 0.44, green: 0.76, blue: 0.32, alpha: 1),
            ]
            let width = value.size(withAttributes: attributes).width
            value.draw(at: NSPoint(x: frame.maxX - 16 - width, y: baseline), withAttributes: attributes)
        case .window:
            // A setting row like the sensitivity above it: the name on the
            // left, what it is set to on the right. Fullscreen hides the
            // Mac's menu bar, so this is also the row that hands back the
            // Dock, the red close button and every other way out of a
            // program a person already knows.
            drawText(L10n.t("Screen", "Skärm"), at: NSPoint(x: frame.minX + 16, y: baseline),
                     font: label, color: NSColor(calibratedWhite: 0.80, alpha: 1), centred: false)
            let value = isFullscreen
                ? L10n.t("Fullscreen", "Helskärm")
                : L10n.t("Windowed", "Fönster")
            let attributes: [NSAttributedString.Key: Any] = [
                .font: label,
                .foregroundColor: NSColor(calibratedRed: 0.44, green: 0.76, blue: 0.32, alpha: 1),
            ]
            let width = value.size(withAttributes: attributes).width
            value.draw(at: NSPoint(x: frame.maxX - 16 - width, y: baseline), withAttributes: attributes)
        case .mainMenu:
            drawText(L10n.t("Save & Main Menu", "Spara & huvudmeny"), at: NSPoint(x: frame.midX, y: baseline),
                     font: label, color: NSColor(calibratedWhite: 0.96, alpha: 1), centred: true)
        case .quit:
            drawText(L10n.t("Quit", "Avsluta"), at: NSPoint(x: frame.midX, y: baseline),
                     font: label, color: NSColor(calibratedWhite: 0.96, alpha: 1), centred: true)
        }
    }

    /// `point` is the text's left edge, or its centre when `centred`.
    private func drawText(_ string: String, at point: NSPoint, font: NSFont, color: NSColor, centred: Bool) {
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

    override func mouseMoved(with event: NSEvent) {
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard row != hoveredRow else { return }
        hoveredRow = row
        keyboardDrove = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard let row = row(at: convert(event.locationInWindow, from: nil)) else { return }
        take(row)
    }

    /// Drops the highlight — used when the window moves under the cursor,
    /// which leaves a row lit that the pointer is no longer on.
    func clearHover() {
        hoveredRow = nil
        keyboardDrove = false
        needsDisplay = true
    }

    /// Whether the current highlight was put there by the arrow keys. Only
    /// then does Return act on it: a highlight the mouse drifted onto needs
    /// a click, so a pointer parked over Quit can't turn Return — which has
    /// always meant "resume" — into quitting.
    private var keyboardDrove = false

    /// Esc resumes, the arrows and Tab walk the rows, and Return takes the
    /// row the keyboard lit — or resumes when the keyboard lit nothing,
    /// which is what Return did before there was anything to walk.
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:  // Esc
            onResume?()
        case 125:  // Down
            moveSelection(by: 1)
        case 126:  // Up
            moveSelection(by: -1)
        case 48:  // Tab
            moveSelection(by: event.modifierFlags.contains(.shift) ? -1 : 1)
        default:
            if event.charactersIgnoringModifiers == "\r" {
                take(keyboardDrove ? (hoveredRow ?? .resume) : .resume)
            } else {
                super.keyDown(with: event)
            }
        }
    }

    /// Acts on a row. One place, so a key and a click can't drift apart.
    private func take(_ row: Row) {
        switch row {
        case .resume: onResume?()
        case .sensitivity: cycleSensitivity()
        case .window: onToggleWindow?()
        case .mainMenu: onMainMenu?()
        case .quit: onQuit?()
        }
    }

    /// Walks the highlight, which is the same highlight the mouse moves —
    /// there is one selection here, not a hovered row and a focused row
    /// disagreeing about what Return will do. The first press lights Resume
    /// rather than moving, so no single key ever lands next to Quit; after
    /// that it stops at the ends rather than wrapping, because Quit sitting
    /// one key past Resume is not a wrap anyone wants to discover by
    /// holding a key down.
    private func moveSelection(by delta: Int) {
        keyboardDrove = true
        guard let current = hoveredRow else {
            hoveredRow = .resume
            needsDisplay = true
            return
        }
        let rows = Row.allCases
        hoveredRow = rows[min(max(current.rawValue + delta, 0), rows.count - 1)]
        needsDisplay = true
    }

    /// Forces the highlight, so the snapshot harness can capture a lit row.
    func previewSelection(_ index: Int) {
        hoveredRow = Row(rawValue: index)
        needsDisplay = true
    }
}
#endif
