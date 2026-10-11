#if canImport(CSDL3)
import Foundation
import CSDL3

/// What a launch shows while `Updater` checks for a newer version, and
/// while it downloads one: a line of text and a progress bar. Hands over
/// to the start menu when there is nothing to do, and quits the game when
/// the installer has taken over (it starts the new version itself).
final class SDLUpdateScreen: SDLScreen {
    private let updater = Updater()
    private var clock: Double = 0

    init() {
        updater.start()
    }

    func handle(_ event: SDL_Event, app: SDLApp) {}

    func frame(dt: Double, app: SDLApp) {
        clock += dt
        glClearColor(0.08, 0.09, 0.11, 1)
        glClear(GL_COLOR_BUFFER_BIT)
        let ui = app.ui
        let centreX = ui.width / 2, y = ui.height / 2 - 30

        switch updater.state {
        case .done:
            WorldCatalog.migrateIfNeeded()
            app.setScreen(SDLMenuScreen(app: app))
            return
        case .installing(let version):
            app.text.drawCentered(ui, L10n.t("Installing \(version)…", "Installerar \(version)…"),
                                  centreX: centreX, y: y, size: 14)
            // Give the frame a moment on screen, then get out of the
            // installer's way.
            if clock > 0.3 { app.quit() }
        case .downloading(let version):
            app.text.drawCentered(ui, L10n.t("Updating to \(version)…", "Uppdaterar till \(version)…"),
                                  centreX: centreX, y: y, size: 14)
            let width: Float = min(420, ui.width - 80), height: Float = 14
            let x = (centreX - width / 2).rounded()
            ui.frame(x: x, y: y + 40, width: width, height: height, color: .init(0.6, 0.6, 0.6))
            ui.rect(x: x + 2, y: y + 42, width: (width - 4) * Float(updater.progress()), height: height - 4,
                    color: .init(0.45, 0.78, 0.32))
        case .checking:
            // Only after a beat, so a fast check never flashes text.
            if clock > 0.5 {
                app.text.drawCentered(ui, L10n.t("Checking for updates…", "Letar efter uppdateringar…"),
                                      centreX: centreX, y: y, size: 12, color: .init(0.7, 0.7, 0.7))
            }
        }
    }

    func leave(app: SDLApp) {}
}
#endif
