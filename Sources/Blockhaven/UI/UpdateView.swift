#if canImport(AppKit)
import AppKit

/// The Mac's version of `SDLUpdateScreen`: what a launch shows while the
/// updater checks for, downloads and installs a newer version. Calls
/// `onFinished` when there is nothing to do; quits the app once the new
/// one has been started.
final class UpdateView: NSView {
    var onFinished: (() -> Void)?
    private let updater = Updater()
    private var timer: Timer?
    private var started = Date()
    private var line = ""
    private var fraction: Double?

    func begin() {
        updater.start()
        started = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    private func poll() {
        switch updater.state {
        case .done:
            timer?.invalidate()
            onFinished?()
            return
        case .installing(let version):
            line = L10n.t("Installing \(version)…", "Installerar \(version)…")
            fraction = 1
            timer?.invalidate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
        case .downloading(let version):
            line = L10n.t("Updating to \(version)…", "Uppdaterar till \(version)…")
            fraction = updater.progress()
        case .checking:
            line = Date().timeIntervalSince(started) > 0.5
                ? L10n.t("Checking for updates…", "Letar efter uppdateringar…") : ""
            fraction = nil
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedRed: 0.08, green: 0.09, blue: 0.11, alpha: 1).setFill()
        bounds.fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 18, weight: .medium),
            .foregroundColor: NSColor(calibratedWhite: 0.9, alpha: 1),
        ]
        let size = line.size(withAttributes: attributes)
        line.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY + 10), withAttributes: attributes)
        guard let fraction else { return }
        let bar = NSRect(x: bounds.midX - 210, y: bounds.midY - 24, width: 420, height: 12)
        NSColor(calibratedWhite: 0.6, alpha: 1).setStroke()
        NSBezierPath(roundedRect: bar, xRadius: 6, yRadius: 6).stroke()
        NSColor(calibratedRed: 0.45, green: 0.78, blue: 0.32, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: bar.minX, y: bar.minY, width: bar.width * fraction, height: bar.height),
                     xRadius: 6, yRadius: 6).fill()
    }
}
#endif
