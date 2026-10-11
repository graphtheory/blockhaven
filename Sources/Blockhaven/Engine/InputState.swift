import Foundation
import Foundation

/// An immutable copy of the input for one frame. The game loop runs on
/// SceneKit's render queue while AppKit delivers events on the main
/// thread, so the loop takes one locked snapshot per frame rather than
/// reading the live fields and racing every event.
struct InputSnapshot {
    var forwardDown = false
    var backDown = false
    var leftDown = false
    var rightDown = false
    var jumpDown = false
    var sneakDown = false
    var sprintDown = false
    /// Q and E, which climb and drop while flying. Held rather than edges,
    /// like every other movement key.
    var flyUpDown = false
    var flyDownDown = false
    var pointerCaptured = false

    var lookDX: CGFloat = 0
    var lookDY: CGFloat = 0

    var attackDown = false
    var useRequested = false
    var jumpRequested = false

    var hotbarSelection: Int?
    var hotbarScroll = 0

    /// Middle-click, or F: put whatever the crosshair is on into the
    /// hand. An edge, like every other request here.
    var pickBlockRequested = false

    var toggleInventoryRequested = false
    var toggleDebugRequested = false
    var toggleFlyRequested = false
    var escapeRequested = false

    var uiCursor: CGPoint = .zero
    var uiPrimaryClick = false
    var uiSecondaryClick = false
    var uiShiftHeld = false
}

/// Shared keyboard/mouse state. Written from AppKit events on the main
/// thread, read once per frame from SceneKit's render queue — every access
/// goes through `lock`, since those are genuinely different threads.
final class InputState {
    private let lock = NSLock()

    // Held movement keys
    var forwardDown = false
    var backDown = false
    var leftDown = false
    var rightDown = false
    var jumpDown = false
    var sneakDown = false
    var sprintDown = false
    var flyUpDown = false
    var flyDownDown = false

    /// Jump edge — separate from `jumpDown` so a tap between frames still
    /// registers, and so the double-tap flight toggle can consume it.
    var jumpRequested = false

    /// True while the pointer is captured for mouse-look (cursor hidden
    /// and detached). Click captures; Esc releases.
    var pointerCaptured = false

    /// Mouse-look travel (points) accumulated while the pointer is
    /// captured. Drained into each frame's snapshot.
    var mouseLookDX: CGFloat = 0
    var mouseLookDY: CGFloat = 0

    /// Left mouse held: mine continuously. Right mouse edge: place/interact
    /// once per click, as the original does.
    var attackDown = false
    var useRequested = false

    /// Hotbar: absolute selection from a number key, and a relative nudge
    /// from the scroll wheel.
    var hotbarSelection: Int?
    var hotbarScroll = 0

    /// UI edges.
    var pickBlockRequested = false
    var toggleInventoryRequested = false
    var toggleDebugRequested = false
    var toggleFlyRequested = false
    var escapeRequested = false

    /// Cursor position in view coordinates while a UI screen owns the
    /// pointer, plus click edges routed to that UI.
    var uiCursor: CGPoint = .zero
    var uiPrimaryClick = false
    var uiSecondaryClick = false
    var uiShiftHeld = false

    /// Applies an event-handler mutation under the lock. AppKit code uses
    /// this instead of touching the fields directly.
    func mutate(_ body: (InputState) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        body(self)
    }

    /// Reads a value under the lock.
    func read<T>(_ body: (InputState) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(self)
    }

    /// Copies the current input for one frame and clears everything
    /// one-shot: edges, mouse travel, and the pending hotbar nudges. A
    /// single locked pass means an edge can never be seen twice or lost
    /// between the read and the clear.
    func consumeSnapshot() -> InputSnapshot {
        lock.lock()
        defer { lock.unlock() }

        var snapshot = InputSnapshot()
        snapshot.forwardDown = forwardDown
        snapshot.backDown = backDown
        snapshot.leftDown = leftDown
        snapshot.rightDown = rightDown
        snapshot.jumpDown = jumpDown
        snapshot.sneakDown = sneakDown
        snapshot.sprintDown = sprintDown
        snapshot.flyUpDown = flyUpDown
        snapshot.flyDownDown = flyDownDown
        snapshot.pointerCaptured = pointerCaptured

        snapshot.lookDX = mouseLookDX
        snapshot.lookDY = mouseLookDY

        snapshot.attackDown = attackDown
        snapshot.useRequested = useRequested
        snapshot.jumpRequested = jumpRequested

        snapshot.hotbarSelection = hotbarSelection
        snapshot.hotbarScroll = hotbarScroll

        snapshot.pickBlockRequested = pickBlockRequested
        snapshot.toggleInventoryRequested = toggleInventoryRequested
        snapshot.toggleDebugRequested = toggleDebugRequested
        snapshot.toggleFlyRequested = toggleFlyRequested
        snapshot.escapeRequested = escapeRequested

        snapshot.uiCursor = uiCursor
        snapshot.uiPrimaryClick = uiPrimaryClick
        snapshot.uiSecondaryClick = uiSecondaryClick
        snapshot.uiShiftHeld = uiShiftHeld

        mouseLookDX = 0
        mouseLookDY = 0
        useRequested = false
        jumpRequested = false
        hotbarSelection = nil
        hotbarScroll = 0
        pickBlockRequested = false
        toggleInventoryRequested = false
        toggleDebugRequested = false
        toggleFlyRequested = false
        escapeRequested = false
        uiPrimaryClick = false
        uiSecondaryClick = false

        return snapshot
    }

    /// Drops held movement state — used when a UI screen takes over, so
    /// the player doesn't keep walking while the inventory is open.
    func releaseMovement() {
        lock.lock()
        defer { lock.unlock() }
        forwardDown = false
        backDown = false
        leftDown = false
        rightDown = false
        jumpDown = false
        sneakDown = false
        sprintDown = false
        flyUpDown = false
        flyDownDown = false
        attackDown = false
    }
}
