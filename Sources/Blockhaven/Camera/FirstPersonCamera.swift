#if canImport(AppKit)
import RealityKit
import simd
import CoreGraphics

/// A yaw entity carrying a pitch entity carrying the camera, posed from a
/// `CameraState` each frame.
@MainActor
final class FirstPersonCamera {
    let rig = Entity()
    private let pitchEntity = Entity()
    let cameraEntity = PerspectiveCamera()

    init() {
        cameraEntity.camera.fieldOfViewInDegrees = CameraState.fieldOfViewDegrees
        cameraEntity.camera.near = CameraState.near
        cameraEntity.camera.far = CameraState.far

        rig.addChild(pitchEntity)
        pitchEntity.addChild(cameraEntity)
        apply(CameraState())
    }

    func attach(to parent: Entity) {
        parent.addChild(rig)
    }

    func apply(_ state: CameraState) {
        rig.position = SIMD3<Float>(state.eyePosition)
        // The camera looks down its local -Z; the yaw+pi flip aims that
        // -Z along (sin yaw, cos yaw).
        rig.orientation = simd_quatf(angle: Float(state.yaw + .pi), axis: SIMD3<Float>(0, 1, 0))
        pitchEntity.orientation = simd_quatf(angle: Float(state.pitch), axis: SIMD3<Float>(1, 0, 0))
        cameraEntity.position = SIMD3<Float>(state.offset.x, state.offset.y, 0)
        cameraEntity.orientation = simd_quatf(angle: state.roll, axis: SIMD3<Float>(0, 0, 1))
    }
}
#endif
