#if canImport(AppKit)
import AppKit

/// The scrolling half of a panel that lists more than it can show.
///
/// Pulled out of the recipe book so the creative palette could have the
/// same one, and because scrolling turned out to be the part of those
/// panels that was actually broken. Three things were wrong and all three
/// live here now:
///
/// * A wheel notch is one or two *lines*, not one or two points. Passing
///   `scrollingDeltaY` straight through moved a 58-point row by two
///   points, which reads as a list that has decided not to move. A
///   trackpad sends precise deltas already in points and must not be
///   scaled — so the two are told apart rather than averaged.
/// * The scrollbar was a picture of the scroll position. Now it is the
///   control: the knob can be grabbed and dragged, which is how anyone
///   who has used any other list expects to cross fifty recipes.
/// * Page and Home/End had nowhere to go.
struct PanelScroller {
    /// The clipped region the rows are drawn into.
    var viewport: CGRect = .zero
    /// How tall the whole list is, scrolled or not.
    var contentHeight: CGFloat = 0
    private(set) var offset: CGFloat = 0

    /// How far a wheel *line* moves the list. A shade under the tallest
    /// row either panel draws, so one notch always leaves something from
    /// the last screenful in view to read against.
    static let lineHeight: CGFloat = 42

    var maximum: CGFloat { max(0, contentHeight - viewport.height) }
    var canScroll: Bool { maximum > 0 }

    mutating func set(_ value: CGFloat) {
        offset = min(max(0, value), maximum)
    }

    mutating func scroll(by delta: CGFloat) {
        set(offset + delta)
    }

    /// A whole screenful less one row's worth of overlap, so paging keeps
    /// a line of context rather than teleporting.
    mutating func page(_ direction: CGFloat) {
        scroll(by: direction * max(PanelScroller.lineHeight, viewport.height - PanelScroller.lineHeight))
    }

    /// Points to scroll for one wheel or trackpad event.
    ///
    /// Positive `scrollingDeltaY` is a finger moving up the page, which
    /// should bring earlier rows back — so the caller's list offset goes
    /// the other way, and this returns the value already negated.
    static func delta(for event: NSEvent) -> CGFloat {
        event.hasPreciseScrollingDeltas
            ? -event.scrollingDeltaY
            : -event.scrollingDeltaY * lineHeight
    }

    // MARK: - The scrollbar, as a control

    /// Wide enough to grab. The four-point sliver this replaces was a
    /// readout; nobody could hit it on purpose.
    private static let barWidth: CGFloat = 11

    var trackRect: CGRect {
        guard canScroll else { return .zero }
        return CGRect(
            x: viewport.maxX - PanelScroller.barWidth - 2, y: viewport.minY + 4,
            width: PanelScroller.barWidth, height: viewport.height - 8
        )
    }

    var knobRect: CGRect {
        let track = trackRect
        guard track.height > 0, contentHeight > 0 else { return .zero }
        let visible = min(1, viewport.height / contentHeight)
        let knobHeight = max(30, track.height * visible)
        let travel = track.height - knobHeight
        let progress = maximum > 0 ? offset / maximum : 0
        return CGRect(
            x: track.minX, y: track.maxY - knobHeight - travel * progress,
            width: track.width, height: knobHeight
        )
    }

    /// Where in the knob the drag was started, so the knob doesn't jump
    /// its own centre to the pointer on the first pixel of movement.
    private(set) var dragGrab: CGFloat?

    /// Takes a click on the scrollbar. A click on the knob starts a drag;
    /// a click on the track above or below it pages that way; a click
    /// anywhere else is not ours and is refused, so it can go on to be a
    /// click on a row.
    mutating func beginDrag(at point: CGPoint) -> Bool {
        guard canScroll, trackRect.contains(point) else { return false }
        let knob = knobRect
        if knob.contains(point) {
            dragGrab = point.y - knob.midY
        } else {
            page(point.y > knob.maxY ? -1 : 1)
            dragGrab = nil
        }
        return true
    }

    mutating func drag(to point: CGPoint) {
        guard let grab = dragGrab else { return }
        let track = trackRect
        let knobHeight = knobRect.height
        let travel = track.height - knobHeight
        guard travel > 0 else { return }
        // Where the knob's centre wants to be, expressed as how far down
        // its travel that is, inverted because the list runs downward and
        // the view is not flipped.
        let centre = point.y - grab
        let top = track.maxY - knobHeight / 2
        set((top - centre) / travel * maximum)
    }

    mutating func endDrag() {
        dragGrab = nil
    }

    var isDragging: Bool { dragGrab != nil }

    func draw(_ context: CGContext, hovered: Bool) {
        guard canScroll else { return }
        let track = trackRect
        context.setFillColor(NSColor(calibratedWhite: 0.20, alpha: 1).cgColor)
        context.addPath(CGPath(
            roundedRect: track, cornerWidth: track.width / 2, cornerHeight: track.width / 2,
            transform: nil
        ))
        context.fillPath()
        let knob = knobRect.insetBy(dx: 1.5, dy: 0)
        context.setFillColor(NSColor(
            calibratedWhite: hovered || isDragging ? 0.78 : 0.58, alpha: 1
        ).cgColor)
        context.addPath(CGPath(
            roundedRect: knob, cornerWidth: knob.width / 2, cornerHeight: knob.width / 2,
            transform: nil
        ))
        context.fillPath()
    }

    /// The arrows, Page keys and Home/End a list should answer to,
    /// resolved from a key code. Nil for anything else.
    ///
    /// Shared so the two panels cannot drift apart on which keys work,
    /// which is exactly how the book ended up answering to two of them.
    static func keyScroll(_ keyCode: UInt16, in scroller: inout PanelScroller) -> Bool {
        switch keyCode {
        case 126: scroller.scroll(by: -lineHeight)          // up
        case 125: scroller.scroll(by: lineHeight)           // down
        case 116: scroller.page(-1)                         // page up
        case 121: scroller.page(1)                          // page down
        case 115: scroller.set(0)                           // home
        case 119: scroller.set(scroller.maximum)            // end
        default: return false
        }
        return true
    }
}
#endif
