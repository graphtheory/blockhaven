import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if os(Windows)
import WinSDK
#endif

/// Keeps an installed game up to date by itself.
///
/// At launch, before the start menu, the game reads a small manifest from
/// the website. If it names a newer version, the game downloads that
/// version's installer (Windows) or disk image (Mac), installs it, and
/// starts again as the new version — nobody has to visit the website or
/// click anything. Offline, slow or broken, it gives up within seconds and
/// the menu opens as usual.
///
/// `BLOCKHAVEN_UPDATE_MANIFEST=<url>` reads another manifest (the CI test
/// serves one from localhost); `BLOCKHAVEN_NO_UPDATE=1` skips the check.
final class Updater: @unchecked Sendable {
    static let defaultManifest = "https://www.john-z.com/games/blockhaven/version.json"
    static let checkTimeout: TimeInterval = 4

    struct Manifest: Decodable {
        struct Download: Decodable {
            let url: String
            let size: Int
        }
        let version: String
        let windows: Download?
        let mac: Download?

        var download: Download? {
            #if os(Windows)
            windows
            #else
            mac
            #endif
        }
    }

    enum State: Equatable {
        case checking
        case downloading(version: String)
        case installing(version: String)
        /// Nothing to do — up to date, offline, or not an installed build.
        case done
    }

    /// One line the start menu shows when an update could not be applied.
    nonisolated(unsafe) static var notice: String?

    /// Only an installed build updates: a build from the source tree has no
    /// version, and a harness run must never go off and install something.
    static var isEligible: Bool {
        guard GameVersion.number != nil else { return false }
        let environment = ProcessInfo.processInfo.environment
        if environment["BLOCKHAVEN_NO_UPDATE"] != nil { return false }
        // Asking for a particular manifest is a deliberate test of this very
        // path, which may run against scratch saves.
        if environment["BLOCKHAVEN_UPDATE_MANIFEST"] != nil { return true }
        let harness = ["BLOCKHAVEN_DEMO", "BLOCKHAVEN_MODE", "BLOCKHAVEN_SNAPSHOT", "BLOCKHAVEN_SDL_SCREENSHOT",
                       "BLOCKHAVEN_SCRIPT", "BLOCKHAVEN_SAVE_DIR", "BLOCKHAVEN_NO_SAVE"]
        if harness.contains(where: { environment[$0] != nil }) { return false }
        return !environment.keys.contains { $0.hasPrefix("BLOCKHAVEN_CHECK_") || $0.hasPrefix("BLOCKHAVEN_BENCH") }
    }

    /// Whether `candidate` is a later version than `current`, comparing
    /// "1.1.240"-style numbers part by part.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0, y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }

    private let lock = NSLock()
    private var _state: State = .checking
    var state: State {
        lock.lock(); defer { lock.unlock() }
        return _state
    }
    private func set(_ state: State) {
        lock.lock(); _state = state; lock.unlock()
    }
    private var task: URLSessionDownloadTask?
    private var expectedSize = 0

    /// Starts the check in the background; poll `state` and `progress()`.
    /// On `.installing` the install has been handed off and the game should
    /// quit; on `.done` it should carry on to the menu.
    func start() {
        guard let current = GameVersion.number else { set(.done); return }
        let environment = ProcessInfo.processInfo.environment
        guard let manifestURL = URL(string: environment["BLOCKHAVEN_UPDATE_MANIFEST"] ?? Self.defaultManifest) else {
            set(.done); return
        }
        var request = URLRequest(url: manifestURL, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: Self.checkTimeout)
        request.setValue("Blockhaven/\(current)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { [self] data, _, error in
            guard let data, error == nil, let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else {
                log("no manifest (\(error.map { "\($0)" } ?? "unreadable")) — carrying on")
                set(.done); return
            }
            guard Self.isNewer(manifest.version, than: current), let download = manifest.download,
                  let url = URL(string: download.url) else {
                log("up to date: \(current), latest \(manifest.version)")
                set(.done); return
            }
            // Tried this version already and are still older: the install
            // did not take. Don't loop; say so in the menu instead.
            if GameSettings.lastUpdateAttempt == manifest.version {
                log("an earlier attempt to install \(manifest.version) did not take")
                Self.notice = L10n.t("Couldn't update to \(manifest.version) — get it at john-z.com/games",
                                     "Kunde inte uppdatera till \(manifest.version) — hämta den på john-z.com/games")
                set(.done); return
            }
            GameSettings.lastUpdateAttempt = manifest.version
            // The game quits moments from now; the guard has to be on disk.
            UserDefaults.standard.synchronize()
            log("updating \(current) → \(manifest.version)")
            fetch(url, size: download.size, version: manifest.version)
        }.resume()
    }

    /// Bytes so far over bytes expected, for the progress bar.
    func progress() -> Double {
        guard let task, expectedSize > 0 else { return 0 }
        return min(1, Double(task.countOfBytesReceived) / Double(expectedSize))
    }

    private func fetch(_ url: URL, size: Int, version: String) {
        expectedSize = size
        set(.downloading(version: version))
        let download = URLSession.shared.downloadTask(with: url) { [self] location, _, error in
            guard let location, error == nil else {
                log("download failed: \(error.map { "\($0)" } ?? "no file")")
                set(.done); return
            }
            let name = url.lastPathComponent.isEmpty ? "Blockhaven-update" : url.lastPathComponent
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("blockhaven-update-\(version)")
            let file = folder.appendingPathComponent(name)
            do {
                try? FileManager.default.removeItem(at: folder)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: location, to: file)
            } catch {
                log("could not keep the download: \(error)")
                set(.done); return
            }
            let got = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? -1
            guard got == size else {
                log("download is \(got) bytes, expected \(size) — not installing it")
                set(.done); return
            }
            if Self.launchInstall(file, folder: folder) {
                log("installing \(version)")
                set(.installing(version: version))
            } else {
                set(.done)
            }
        }
        task = download
        download.resume()
    }

    /// Hands the downloaded file to the platform's installer. True when the
    /// game should now quit and let it run.
    private static func launchInstall(_ file: URL, folder: URL) -> Bool {
        #if os(Windows)
        // A per-user install: no administrator prompt. The installer closes
        // nothing of ours (we quit right after this) and restarts the game
        // when it is done — see the `skipifnotsilent` entry in the .iss.
        let path = file.path.replacingOccurrences(of: "/", with: "\\")
        let launched = path.withCString(encodedAs: UTF16.self) { exe in
            "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART".withCString(encodedAs: UTF16.self) { arguments in
                "open".withCString(encodedAs: UTF16.self) { verb in
                    Int(bitPattern: ShellExecuteW(nil, verb, exe, arguments, nil, Int32(SW_SHOWNORMAL)))
                }
            }
        }
        if launched <= 32 {
            StandardError.write(Data("[update] the installer would not start (\(launched))\n".utf8))
            return false
        }
        return true
        #elseif canImport(AppKit)
        return MacAppReplacement.replace(with: file, scratch: folder)
        #else
        return false
        #endif
    }

    private func log(_ message: String) {
        StandardError.write(Data("[update] \(message)\n".utf8))
    }
}

#if canImport(AppKit)
/// Swaps the running app for the one in a downloaded disk image, then
/// starts the new one. The app is replaced through a temporary copy beside
/// it, so a failure halfway leaves the old app where it was.
enum MacAppReplacement {
    static func replace(with image: URL, scratch: URL) -> Bool {
        let target = Bundle.main.bundleURL
        guard target.pathExtension == "app" else { return false }
        let mount = scratch.appendingPathComponent("mount")
        guard run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-mountpoint", mount.path, image.path]) else {
            return false
        }
        defer { _ = run("/usr/bin/hdiutil", ["detach", "-force", mount.path]) }
        let manager = FileManager.default
        guard let app = (try? manager.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil))?
            .first(where: { $0.pathExtension == "app" }) else { return false }
        let staged = target.deletingLastPathComponent().appendingPathComponent(".\(target.lastPathComponent).new")
        let retired = target.deletingLastPathComponent().appendingPathComponent(".\(target.lastPathComponent).old")
        try? manager.removeItem(at: staged)
        try? manager.removeItem(at: retired)
        guard run("/usr/bin/ditto", [app.path, staged.path]) else {
            StandardError.write(Data("[update] could not write next to \(target.path)\n".utf8))
            return false
        }
        do {
            try manager.moveItem(at: target, to: retired)
            try manager.moveItem(at: staged, to: target)
        } catch {
            if !manager.fileExists(atPath: target.path) { try? manager.moveItem(at: retired, to: target) }
            try? manager.removeItem(at: staged)
            return false
        }
        try? manager.removeItem(at: retired)
        // A fresh instance of the new app; this one quits once the caller
        // sees `.installing`.
        // Harness settings go along, so a test's relaunch stays on its
        // scratch saves; a player's launch has none.
        let forwarded = ProcessInfo.processInfo.environment
            .filter { $0.key.hasPrefix("BLOCKHAVEN_") }
            .flatMap { ["--env", "\($0.key)=\($0.value)"] }
        return run("/usr/bin/open", ["-n"] + forwarded + [target.path])
    }

    @discardableResult
    private static func run(_ tool: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
#endif
