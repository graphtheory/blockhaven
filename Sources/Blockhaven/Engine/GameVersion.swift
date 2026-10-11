import Foundation

/// Which build this is, so whoever is playing can say what they have and
/// tell it apart from what the website offers.
///
/// The number is `VERSION` (bumped by hand when it means something) and
/// the count of commits on main, so the Mac and Windows builds of one
/// commit carry the same number and every later commit a bigger one. The
/// packaging scripts write it in: the Mac app's Info.plist, and
/// `version.txt` beside the Windows exe. A build run from the source tree
/// has neither and says so.
enum GameVersion {
    /// "1.1.232", or nil for a build run straight from the source tree.
    static let number: String? = {
        if Bundle.main.bundleURL.pathExtension == "app",
           let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            return short
        }
        let file = executableURL().deletingLastPathComponent().appendingPathComponent("version.txt")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }()

    /// What the start menu shows in its corner.
    static var label: String {
        if let number { return L10n.t("Version \(number)", "Version \(number)") }
        return L10n.t("Development build", "Utvecklingsbygge")
    }

    /// The first line of a run's output, so a log a player sends names
    /// the build that wrote it.
    static func announce() {
        StandardError.write(Data("[version] \(number ?? "development build")\n".utf8))
    }
}
