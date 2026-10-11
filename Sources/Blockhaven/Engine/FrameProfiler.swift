import Foundation

/// Where the frame went.
///
/// The display this game is played on runs at 100 Hz and RealityKit waits
/// for it, so the frame rate sits at the cap whether a frame took 2 ms or
/// 9 ms of CPU: *fps cannot show headroom here, and a mean fps cannot show
/// a hitch at all* — one 30 ms stall inside sixty 10 ms frames moves the
/// average by three. So the frame log reports two things fps hides:
///
///   * `worst`, the longest single frame in the reporting window, which is
///     what a stutter actually is; and
///   * per-phase totals in **milliseconds spent per second of wall clock**,
///     which is the honest way to say "streaming costs 4 % of the machine"
///     regardless of what the vsync does.
///
/// Everything here is inert unless `BLOCKHAVEN_FRAME_LOG=1`, and even then
/// it is two `CFAbsoluteTimeGetCurrent` calls and an add per phase.
enum FrameProfiler {
    /// The phases worth naming. Ordered as they run in `tick`.
    enum Phase: Int, CaseIterable {
        /// The whole streaming step, which the next three are inside of.
        case stream
        /// Copying a chunk's neighbourhood out of the world, before the
        /// geometry for it is handed to the mesh queue.
        case gather
        /// Building geometry on the frame — only urgent player edits do
        /// this now; streaming chunks build on a background queue and
        /// never appear here.
        case mesh
        /// Turning finished geometry into `MeshResource`s and entities.
        case upload
        case mobs, sky, hud

        var label: String {
            switch self {
            case .stream: return "stream"
            case .gather: return "gather"
            case .mesh: return "mesh"
            case .upload: return "upload"
            case .mobs: return "mobs"
            case .sky: return "sky"
            case .hud: return "hud"
            }
        }
    }

    static let isEnabled = ProcessInfo.processInfo.environment["BLOCKHAVEN_FRAME_LOG"] == "1"

    private static var totals = [Double](repeating: 0, count: Phase.allCases.count)
    private static var worstFrame: Double = 0

    /// Times `body` into `phase`. Nested phases double-count deliberately:
    /// `mesh` is the part of `stream` that builds geometry, and reading it
    /// as a share of `stream` is the point.
    @inline(__always)
    static func measure<T>(_ phase: Phase, _ body: () -> T) -> T {
        guard isEnabled else { return body() }
        let started = monotonicSeconds()
        defer { totals[phase.rawValue] += monotonicSeconds() - started }
        return body()
    }

    /// Adds an already-measured span — for work whose timing is taken
    /// somewhere the closure form doesn't reach.
    @inline(__always)
    static func add(_ phase: Phase, seconds: Double) {
        guard isEnabled else { return }
        totals[phase.rawValue] += seconds
    }

    static func recordFrame(delta: Double) {
        guard isEnabled else { return }
        worstFrame = max(worstFrame, delta)
    }

    /// The phase breakdown for the window just ended, as ms per second of
    /// wall clock, and the worst frame in it. Resets the window.
    static func drain(window: Double) -> String {
        guard isEnabled, window > 0 else { return "" }
        var text = String(format: "worst %.1f ms", worstFrame * 1000)
        for phase in Phase.allCases where totals[phase.rawValue] > 0 {
            text += String(format: " · %@ %.1f", phase.label, totals[phase.rawValue] * 1000 / window)
        }
        text += " ms/s"
        totals = [Double](repeating: 0, count: Phase.allCases.count)
        worstFrame = 0
        return text
    }
}
