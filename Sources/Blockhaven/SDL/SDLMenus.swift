#if canImport(CSDL3)
import Foundation
import CSDL3

/// The pointer as the menus see it: where it is, and what was clicked this
/// frame. Fed from SDL events, read and cleared by `frame`.
struct SDLPointer {
    var x: Float = -1
    var y: Float = -1
    var clicked = false
    var rightClicked = false
    var wheel: Float = 0

    mutating func handle(_ event: SDL_Event) {
        switch eventType(event) {
        case SDL_EVENT_MOUSE_MOTION:
            x = event.motion.x
            y = event.motion.y
        case SDL_EVENT_MOUSE_BUTTON_DOWN:
            x = event.button.x
            y = event.button.y
            if Int32(event.button.button) == SDL_BUTTON_LEFT { clicked = true }
            if Int32(event.button.button) == SDL_BUTTON_RIGHT { rightClicked = true }
        case SDL_EVENT_MOUSE_WHEEL:
            wheel += event.wheel.y
        default:
            break
        }
    }

    mutating func endFrame() {
        clicked = false
        rightClicked = false
        wheel = 0
    }

    func inside(_ x: Float, _ y: Float, _ w: Float, _ h: Float) -> Bool {
        self.x >= x && self.x < x + w && self.y >= y && self.y < y + h
    }
}

/// The look every menu row shares: a dark panel that lights up under the
/// pointer, in the same greys and greens as the Mac's menus.
enum SDLWidgets {
    static let rowHeight: Float = 44
    static let accent = UIRenderer.Color(0.44, 0.76, 0.32)

    /// A full-width clickable row. Returns true on the frame it is clicked.
    @discardableResult
    static func button(_ app: SDLApp, _ pointer: SDLPointer, _ label: String,
                       x: Float, y: Float, width: Float, height: Float = rowHeight,
                       value: String? = nil, enabled: Bool = true, selected: Bool = false) -> Bool {
        let hovered = enabled && pointer.inside(x, y, width, height)
        let fill: UIRenderer.Color = hovered || selected
            ? .init(0.30, 0.30, 0.32, 0.92) : .init(0.13, 0.13, 0.14, 0.88)
        app.ui.rect(x: x, y: y, width: width, height: height, color: fill)
        app.ui.frame(x: x, y: y, width: width, height: height,
                     color: hovered || selected ? .init(0.9, 0.9, 0.9, 0.9) : .init(0.45, 0.45, 0.45, 0.8), thickness: 1.5)
        let size: Float = 12
        let textY = (y + (height - size) / 2).rounded()
        let colour: UIRenderer.Color = enabled ? .white : .init(0.55, 0.55, 0.55)
        if let value {
            app.text.draw(app.ui, label, x: x + 16, y: textY, size: size, color: colour)
            let w = app.text.width(value, size: size)
            app.text.draw(app.ui, value, x: x + width - 16 - w, y: textY, size: size, color: accent)
        } else {
            app.text.drawCentered(app.ui, label, centreX: x + width / 2, y: textY, size: size, color: colour)
        }
        return hovered && pointer.clicked
    }

    /// The whole window dimmed, so a menu reads over a live world.
    static func dim(_ app: SDLApp, alpha: Float = 0.55) {
        app.ui.rect(x: 0, y: 0, width: app.ui.width, height: app.ui.height, color: .init(0, 0, 0, alpha))
    }
}

/// Esc in play: resume, sensitivity, window, save and leave, quit — the
/// rows `PauseMenuView` offers on the Mac.
final class SDLPauseScreen {
    var warning: String?
    /// The storyline's journal, drawn down the left side.
    var journal: [String] = []
    var onResume: (() -> Void)?
    var onMainMenu: (() -> Void)?
    var onQuit: (() -> Void)?
    private var pointer = SDLPointer()

    private static let sensitivitySteps: [(name: String, swedish: String, value: CGFloat)] = [
        ("Low", "Låg", 0.6), ("Normal", "Normal", 1.0), ("High", "Hög", 1.5),
    ]

    private var sensitivityIndex: Int {
        let current = GameSettings.mouseSensitivity
        var best = 0
        for (index, step) in SDLPauseScreen.sensitivitySteps.enumerated()
        where abs(step.value - current) < abs(SDLPauseScreen.sensitivitySteps[best].value - current) {
            best = index
        }
        return best
    }

    func handle(_ event: SDL_Event, app: SDLApp) {
        pointer.handle(event)
        if eventType(event) == SDL_EVENT_KEY_DOWN, !event.key.repeat,
           event.key.scancode == SDL_SCANCODE_ESCAPE {
            onResume?()
        }
    }

    func draw(app: SDLApp) {
        defer { pointer.endFrame() }
        SDLWidgets.dim(app)
        for (index, line) in journal.enumerated() {
            let colour: UIRenderer.Color = line.hasPrefix("[x]") ? .init(0.62, 0.86, 0.56) : .white
            app.text.draw(app.ui, line, x: 24, y: 40 + Float(index) * 20, size: index == 0 ? 14 : 10, color: colour)
        }
        let width: Float = 360
        let x = ((app.ui.width - width) / 2).rounded()
        let gap: Float = 10
        let total = 5 * SDLWidgets.rowHeight + 4 * gap
        var y = ((app.ui.height - total) / 2).rounded()
        app.text.drawCentered(app.ui, L10n.t("Paused", "Paus"), centreX: app.ui.width / 2, y: y - 50, size: 22)

        if SDLWidgets.button(app, pointer, L10n.t("Resume", "Fortsätt"), x: x, y: y, width: width) {
            onResume?()
            return
        }
        y += SDLWidgets.rowHeight + gap
        let step = SDLPauseScreen.sensitivitySteps[sensitivityIndex]
        if SDLWidgets.button(app, pointer, L10n.t("Mouse Sensitivity", "Muskänslighet"), x: x, y: y, width: width,
                             value: L10n.t(step.name, step.swedish)) {
            let next = (sensitivityIndex + 1) % SDLPauseScreen.sensitivitySteps.count
            GameSettings.mouseSensitivity = SDLPauseScreen.sensitivitySteps[next].value
        }
        y += SDLWidgets.rowHeight + gap
        if SDLWidgets.button(app, pointer, L10n.t("Screen", "Skärm"), x: x, y: y, width: width,
                             value: app.isFullscreen ? L10n.t("Fullscreen", "Helskärm") : L10n.t("Windowed", "Fönster")) {
            app.toggleFullscreen()
        }
        y += SDLWidgets.rowHeight + gap
        if SDLWidgets.button(app, pointer, L10n.t("Save & Main Menu", "Spara & huvudmeny"), x: x, y: y, width: width) {
            onMainMenu?()
            return
        }
        y += SDLWidgets.rowHeight + gap
        if SDLWidgets.button(app, pointer, L10n.t("Quit", "Avsluta"), x: x, y: y, width: width) {
            onQuit?()
            return
        }
        y += SDLWidgets.rowHeight + 24
        app.text.drawCentered(app.ui, L10n.t("Esc resumes  ·  your world is saved either way out",
                                             "Esc fortsätter  ·  din värld sparas oavsett hur du avslutar"),
                              centreX: app.ui.width / 2, y: y, size: 9, color: .init(0.8, 0.8, 0.8))
        if let warning {
            for (index, line) in app.text.wrap(warning, size: 10, maxWidth: 520).enumerated() {
                app.text.drawCentered(app.ui, line, centreX: app.ui.width / 2, y: y + 24 + Float(index) * 16,
                                      size: 10, color: .init(1, 0.55, 0.45))
            }
        }
    }
}
#endif
