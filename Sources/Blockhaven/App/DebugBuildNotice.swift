import Foundation

/// The one performance cliff in this project that looks like a bug.
///
/// `swift run` builds `-Onone`, and an unoptimised build of this game is
/// not "a bit slower" — measured on the demo world at the display's own
/// 3440x1440, it is **3–27 fps against a pinned 100**, with the worst
/// frame at 425 ms where release sees 17 ms. Meshing alone spends 878 ms
/// of every wall-clock second. The world is octaves of noise and small
/// vector maths, and every bit of it stays a real function call until the
/// optimiser gets at it.
///
/// That cliff is invisible from the terminal: the build succeeds, the
/// window opens, the world is correct, and the only symptom is that the
/// game feels broken. So a debug build says so, in the two places someone
/// is actually looking — the terminal it was launched from, and the title
/// bar of the window it opened.
///
/// `make run-debug` sets `BLOCKHAVEN_DEBUG_PLAY=1` to say "yes, I meant
/// this, I have a breakpoint to hit", which drops the banner but keeps the
/// title-bar tag: an optimised frame inlines the line you wanted to stop
/// on, so playing slowly on purpose is a real thing to want.
enum DebugBuildNotice {

    /// True when this binary was built without the optimiser.
    static var isUnoptimised: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    /// Acknowledged by `make run-debug`, which means it on purpose.
    private static var isAcknowledged: Bool {
        ProcessInfo.processInfo.environment["BLOCKHAVEN_DEBUG_PLAY"] == "1"
    }

    /// What to append to the window title, or nil in a release build. The
    /// title bar is the one part of a slow run that stays on screen for as
    /// long as the confusion lasts.
    static var titleSuffix: String? {
        guard isUnoptimised else { return nil }
        return L10n.t(" — DEBUG BUILD (slow)", " — FELSÖKNINGSBYGGE (långsamt)")
    }

    /// Prints the banner, if one is warranted. Harness output is pinned to
    /// English elsewhere and this is developer output either way, so it is
    /// not localized.
    static func warnIfNeeded() {
        guard isUnoptimised, !isAcknowledged else { return }
        StandardError.write(Data("""

            ┌──────────────────────────────────────────────────────────────┐
            │  This is an UNOPTIMISED DEBUG BUILD. Expect single-digit     │
            │  fps — that is the build, not your machine and not the       │
            │  render distance.                                            │
            │                                                              │
            │      make play    play the current world, optimised          │
            │      make demo    open the demo world, optimised             │
            │                                                              │
            │  (`swift run` builds -Onone. Use `make run-debug` if you     │
            │   actually want a slow build under the debugger.)            │
            └──────────────────────────────────────────────────────────────┘


            """.utf8))
    }
}
