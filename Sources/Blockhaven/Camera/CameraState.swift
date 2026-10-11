import Foundation

/// Where the player is looking, and the small flourishes riding on top of
/// it — a walking bob and explosion shake. Forward is
/// (sin yaw, 0, cos yaw), matching `PlayerController.moveDirection`, so
/// WASD and the crosshair always agree about where "ahead" is.
///
/// Pure numbers: `FirstPersonCamera` hangs them on RealityKit entities on
/// the Mac, the SDL renderer builds a view matrix from them everywhere else.
struct CameraState {
    static let sensitivity: CGFloat = 0.0031
    /// Just under 90° so looking straight up never flips the yaw basis.
    static let maxPitch: CGFloat = 1.5533
    static let fieldOfViewDegrees: Float = 70
    static let near: Float = 0.08
    static let far: Float = 400

    private(set) var yaw: CGFloat = 0
    private(set) var pitch: CGFloat = 0
    private var bobPhase: CGFloat = 0
    private var bobAmount: CGFloat = 0
    /// Remaining trauma from an explosion, decaying to zero.
    private var shake: CGFloat = 0
    private var shakePhase: CGFloat = 0

    /// The eye the bob and shake hang off, in world space.
    private(set) var eyePosition = Vector3.zero
    /// The bob and shake, in the camera's own frame: x right, y up.
    private(set) var offset = SIMD2<Float>(0, 0)
    /// Roll into the step, radians about the view axis.
    private(set) var roll: Float = 0

    var lookDirection: Vector3 {
        Vector3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch))
    }

    /// Mouse-look: screen-right drags turn right, screen-down looks down.
    mutating func applyLook(dx: CGFloat, dy: CGFloat, sensitivity: CGFloat) {
        let scale = CameraState.sensitivity * sensitivity
        yaw -= dx * scale
        pitch = max(-CameraState.maxPitch, min(CameraState.maxPitch, pitch - dy * scale))
    }

    mutating func reset(yaw newYaw: CGFloat, pitch newPitch: CGFloat) {
        yaw = newYaw
        pitch = max(-CameraState.maxPitch, min(CameraState.maxPitch, newPitch))
    }

    mutating func update(dt: Double, eyePosition: Vector3, horizontalSpeed: CGFloat, isGrounded: Bool) {
        self.eyePosition = eyePosition

        // Bob eases in and out rather than snapping, so stopping doesn't
        // leave the eye jammed at the top of the arc.
        let target: CGFloat = isGrounded ? min(1, horizontalSpeed / 5.0) : 0
        bobAmount += (target - bobAmount) * min(1, CGFloat(dt) * 8)
        bobPhase += CGFloat(dt) * (2.2 + horizontalSpeed * 1.5)

        // Shake decays fast and rides on top of the bob. Two different
        // frequencies per axis keep it from reading as a clean oscillation.
        shake = max(0, shake - CGFloat(dt) * 1.9)
        shakePhase += CGFloat(dt) * 46
        let jolt = shake * shake
        let shakeX = sin(shakePhase) * 0.13 * jolt
        let shakeY = sin(shakePhase * 1.7 + 1.1) * 0.13 * jolt

        offset = SIMD2<Float>(
            Float(sin(bobPhase) * 0.035 * bobAmount + shakeX),
            Float(-abs(cos(bobPhase)) * 0.045 * bobAmount + shakeY)
        )
        // A touch of roll into the step makes the walk read as weight.
        roll = Float(sin(bobPhase) * 0.012 * bobAmount + sin(shakePhase * 1.3) * 0.06 * jolt)
    }

    /// Kicks the camera — used when something explodes nearby. `amount` is
    /// roughly seconds of shake; it stacks rather than replacing, so two
    /// blasts at once hit harder.
    mutating func addShake(_ amount: CGFloat) {
        shake = min(1.4, shake + amount)
    }
}
