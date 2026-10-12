#if canImport(AppKit)
import RealityKit
import AppKit

/// Day/night cycle. Because block shading is baked into the texture atlas
/// and drawn unlit, the time of day is expressed by grading three things
/// together: the two ends of the sky gradient, and a tint multiplied over
/// every block material. That re-grades the whole world in one assignment
/// instead of relighting geometry.
///
/// The sky itself is drawn by `SkyEntities` — a gradient dome, the sun, the
/// moon and a cloud layer — which this hands the graded colours to every
/// frame.
@MainActor
final class SkyController {
    /// The clock itself — time of day, weather, and the colours they grade
    /// to. Shared with the simulation, which only ever reads it.
    let clock: SkyClock

    /// The sun, moon and cloud layer. Unlit and positioned off the camera
    /// each frame, so they sit outside the block daylight grade entirely.
    private let celestial = SkyEntities()
    private var attachedScene: Scene?
    /// Which slice of the day the block materials are graded for, or -1
    /// when they have not been graded yet.
    private var gradedSlice = -1
    /// The clock's jump count as of the last grade — see `SkyClock.jumps`.
    private var seenJumps = 0

    init(clock: SkyClock = SkyClock()) {
        self.clock = clock
    }

    /// The one place components become an `NSColor`, so the space they are
    /// declared in is the space they are handed over in.
    private static func nsColor(_ rgb: SIMD3<Float>) -> NSColor {
        NSColor(
            srgbRed: CGFloat(rgb.x), green: CGFloat(rgb.y), blue: CGFloat(rgb.z), alpha: 1
        )
    }

    var timeOfDay: Double { clock.timeOfDay }
    var weatherDayIndex: Int { clock.weatherDayIndex }
    var isNight: Bool { clock.isNight }
    var isRaining: Bool { clock.isRaining }
    var clockText: String { clock.clockText }

    /// Advances the clock and applies the resulting grade.
    func update(dt: Double, view: ARView?, eye: SIMD3<Float>) {
        clock.advance(dt: dt)
        apply(view: view, eye: eye, dt: dt)
    }

    /// Re-grades after something else moved the clock — the simulation
    /// advancing it, or a jump.
    func follow(view: ARView?, eye: SIMD3<Float>, dt: Double) {
        apply(view: view, eye: eye, dt: dt)
    }

    func setTimeOfDay(_ value: Double) {
        clock.setTimeOfDay(value)
        forgetGrade()
    }

    /// A jump can land inside the slice the world is already graded for
    /// — loading a save, or nudging the debug clock — and the next `apply`
    /// would then skip the re-grade entirely. Forget the slice so it can't.
    /// `SkyEntities` keeps its *own* slice, on its own offset phase, so
    /// forgetting only this one re-graded the terrain and left the sky
    /// above it at the time that was jumped away from.
    func forgetGrade() {
        gradedSlice = -1
        celestial.forgetGrade()
    }

    func setWeatherDayIndex(_ value: Int) {
        clock.setWeatherDayIndex(value)
    }

    /// `dt` only drives cloud drift; callers that just re-grade after a
    /// time jump (load, the debug HUD, the snapshot harness) pass none and
    /// still get the sun/moon/clouds placed correctly for the new time.
    ///
    /// `eye` is where the sky is centred. It is passed in rather than read
    /// back out of `view.cameraTransform`, which is a scene query, and the
    /// caller already knows the answer to it — the player's eye is what set
    /// the camera rig's position in the first place.
    func apply(view: ARView?, eye: SIMD3<Float>, dt: Double = 0) {
        if clock.jumps != seenJumps {
            seenJumps = clock.jumps
            forgetGrade()
        }
        let graded = clock.grade()

        // Re-grading every block is the expensive half of the cycle: it
        // walks every chunk entity on screen. It runs on a slice of the day
        // — a few times a second — which is far finer than any of these
        // colours can visibly move and keeps the churn off the frame
        // budget. The sky's own repaint runs at the same rate but half a
        // slice out of phase (`SkyEntities.skyGradeSlice`), so the two
        // bursts never land on one frame.
        //
        // The background assignment lives inside the same gate. It is a
        // backstop only — the gradient dome covers every direction the
        // camera can look, and this is what would show if the dome's
        // texture ever failed to build — so restating it on every one of a
        // hundred frames a second bought nothing.
        let slice = SkyEntities.gradeSlice(of: clock.timeOfDay)
        if slice != gradedSlice {
            gradedSlice = slice
            view?.environment.background = .color(SkyController.nsColor(graded.zenith))
            // Distant blocks fade into the bottom of the sky gradient, so
            // the render edge disappears into the horizon rather than
            // crossing it; the sun direction lets the shader warm that haze
            // on the sun's side and hang glints off the water.
            MaterialLibrary.applyDaylight(
                tint: SkyController.nsColor(graded.daylight),
                fog: SkyController.nsColor(graded.horizon),
                zenith: graded.zenith,
                sunDirection: SkyEntities.sunDirection(angle: SkyEntities.sunAngle(at: clock.timeOfDay))
            )
        }

        guard let view else { return }
        if attachedScene !== view.scene {
            view.scene.addAnchor(celestial.anchor)
            attachedScene = view.scene
        }
        celestial.update(
            timeOfDay: clock.timeOfDay,
            zenith: graded.zenith,
            horizon: graded.horizon,
            cameraPosition: eye,
            dt: dt,
            beacon: clock.beacon,
            lunar: clock.isLunar
        )
    }

    /// The current colour overhead, used as the background backstop behind
    /// the gradient dome.
    var skyColor: NSColor { SkyController.nsColor(clock.grade().zenith) }

    /// The current colour at the skyline — the sky gradient's bottom end,
    /// and the colour distant terrain fogs into.
    var horizonColor: NSColor { SkyController.nsColor(clock.grade().horizon) }
}
#endif
