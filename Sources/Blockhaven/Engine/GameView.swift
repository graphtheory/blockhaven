#if canImport(AppKit)
import RealityKit
import AppKit
import QuartzCore

/// The RealityKit view, subclassed to capture all input. In play mode the
/// pointer is captured and the mouse aims; when a UI screen is up the
/// cursor is handed back and clicks route to the UI instead.
///
/// `ARView` is RealityKit's `NSView` on macOS — despite the name it has no
/// dependency on ARKit here, and it is what lets the game own raw key and
/// mouse events rather than going through SwiftUI.
final class GameView: ARView {
    let input = InputState()

    /// True while an inventory/crafting screen owns the pointer.
    var uiMode = false {
        didSet {
            guard uiMode != oldValue else { return }
            if uiMode {
                releasePointer()
                input.releaseMovement()
            }
        }
    }

    private var releaseObservers: [NSObjectProtocol] = []
    private var lastJumpPressTime: TimeInterval = 0

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Losing the app or the key window must always hand the cursor
        // back — a hidden, detached pointer over someone else's window is
        // the worst bug a game can ship.
        if releaseObservers.isEmpty {
            let center = NotificationCenter.default
            for name in [NSApplication.didResignActiveNotification, NSWindow.didResignKeyNotification] {
                releaseObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.releasePointer()
                        self?.input.releaseMovement()
                    }
                })
            }
        }
        // Tracking area so the UI cursor position updates without a button
        // held down.
        let tracking = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(tracking)
    }

    deinit {
        releaseObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: - Pointer capture

    func capturePointer() {
        guard !uiMode, !input.read({ $0.pointerCaptured }) else { return }
        input.mutate { $0.pointerCaptured = true }
        CGAssociateMouseAndMouseCursorPosition(0)
        NSCursor.hide()
        window?.acceptsMouseMovedEvents = true
    }

    func releasePointer() {
        guard input.read({ $0.pointerCaptured }) else { return }
        input.mutate {
            $0.pointerCaptured = false
            $0.attackDown = false
        }
        CGAssociateMouseAndMouseCursorPosition(1)
        NSCursor.unhide()
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        guard !event.isARepeat else { return }
        handleKey(event.keyCode, isDown: true)
    }

    override func keyUp(with event: NSEvent) {
        handleKey(event.keyCode, isDown: false)
    }

    override func flagsChanged(with event: NSEvent) {
        let shift = event.modifierFlags.contains(.shift)
        let control = event.modifierFlags.contains(.control)
        input.mutate {
            $0.sneakDown = shift
            $0.uiShiftHeld = shift
            $0.sprintDown = control
        }
    }

    private func handleKey(_ keyCode: UInt16, isDown: Bool) {
        // Double-tap space toggles creative flight, as in the original. The
        // timing check lives outside the lock so it stays a plain
        // main-thread read.
        var toggleFly = false
        if keyCode == 49, isDown {
            let now = CACurrentMediaTime()
            if now - lastJumpPressTime < 0.32 {
                toggleFly = true
                lastJumpPressTime = 0
            } else {
                lastJumpPressTime = now
            }
        }

        input.mutate { state in
            switch keyCode {
            case 126, 13: state.forwardDown = isDown // Up Arrow, W
            case 125, 1: state.backDown = isDown // Down Arrow, S
            case 123, 0: state.leftDown = isDown // Left Arrow, A
            case 124, 2: state.rightDown = isDown // Right Arrow, D

            case 49: // Space
                state.jumpDown = isDown
                if isDown {
                    state.jumpRequested = true
                    if toggleFly { state.toggleFlyRequested = true }
                }

            case 12: state.flyUpDown = isDown // Q

            case 14: // E
                // E does two jobs, and which one it does is decided by the
                // view controller, which is the only side that knows
                // whether the player is flying: on foot it opens the
                // inventory, in the air it drops. Tab opens the inventory
                // either way, so nothing is unreachable mid-flight.
                state.flyDownDown = isDown
                if isDown { state.toggleInventoryRequested = true }

            case 48: if isDown { state.toggleInventoryRequested = true } // Tab
            // F, and the middle mouse button below it: put the block you
            // are looking at into your hand. the original binds this to the
            // wheel click alone, which on a trackpad is a button that does
            // not exist — so the key is the one that has to work.
            case 3: if isDown { state.pickBlockRequested = true } // F
            case 99: if isDown { state.toggleDebugRequested = true } // F3
            case 53: if isDown { state.escapeRequested = true } // Esc

            case 18, 19, 20, 21, 23, 22, 26, 28, 25: // 1...9
                if isDown {
                    let digits: [UInt16: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9]
                    state.hotbarSelection = digits[keyCode]
                }

            default:
                break
            }
        }
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        if uiMode {
            let point = convert(event.locationInWindow, from: nil)
            input.mutate {
                $0.uiCursor = point
                $0.uiPrimaryClick = true
            }
            return
        }
        if input.read({ $0.pointerCaptured }) {
            input.mutate { $0.attackDown = true }
        } else {
            capturePointer()
        }
    }

    override func mouseUp(with event: NSEvent) {
        input.mutate { $0.attackDown = false }
    }

    /// The middle button, for players who have one.
    override func otherMouseDown(with event: NSEvent) {
        guard !uiMode, event.buttonNumber == 2 else { return }
        guard input.read({ $0.pointerCaptured }) else { return }
        input.mutate { $0.pickBlockRequested = true }
    }

    override func rightMouseDown(with event: NSEvent) {
        if uiMode {
            let point = convert(event.locationInWindow, from: nil)
            input.mutate {
                $0.uiCursor = point
                $0.uiSecondaryClick = true
            }
            return
        }
        if input.read({ $0.pointerCaptured }) {
            input.mutate { $0.useRequested = true }
        }
    }

    // With the cursor detached, motion arrives as deltas on
    // mouseMoved/mouseDragged while the pointer itself stays put.
    override func mouseMoved(with event: NSEvent) {
        if uiMode {
            let point = convert(event.locationInWindow, from: nil)
            input.mutate { $0.uiCursor = point }
            return
        }
        accumulateLook(event)
    }

    override func mouseDragged(with event: NSEvent) {
        if uiMode {
            let point = convert(event.locationInWindow, from: nil)
            input.mutate { $0.uiCursor = point }
            return
        }
        accumulateLook(event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        guard !uiMode else { return }
        accumulateLook(event)
    }

    override func scrollWheel(with event: NSEvent) {
        guard !uiMode else { return }
        // One hotbar step per notch; trackpads deliver many small deltas,
        // so anything under a threshold is ignored.
        if event.scrollingDeltaY > 0.5 {
            input.mutate { $0.hotbarScroll -= 1 }
        } else if event.scrollingDeltaY < -0.5 {
            input.mutate { $0.hotbarScroll += 1 }
        }
    }

    private func accumulateLook(_ event: NSEvent) {
        let dx = event.deltaX, dy = event.deltaY
        input.mutate {
            guard $0.pointerCaptured else { return }
            $0.mouseLookDX += dx
            $0.mouseLookDY += dy
        }
    }
}
#endif
