import Foundation

/// A column-major 4x4 float matrix — what OpenGL wants and what the `simd`
/// module would provide on the Mac, written out because Windows has no
/// `simd` module.
struct Matrix4 {
    var columns: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)

    init(_ c0: SIMD4<Float>, _ c1: SIMD4<Float>, _ c2: SIMD4<Float>, _ c3: SIMD4<Float>) {
        columns = (c0, c1, c2, c3)
    }

    static let identity = Matrix4(
        SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, 0, 0, 1)
    )

    static func * (a: Matrix4, b: Matrix4) -> Matrix4 {
        Matrix4(a * b.columns.0, a * b.columns.1, a * b.columns.2, a * b.columns.3)
    }

    static func * (m: Matrix4, v: SIMD4<Float>) -> SIMD4<Float> {
        m.columns.0 * v.x + m.columns.1 * v.y + m.columns.2 * v.z + m.columns.3 * v.w
    }

    static func translation(_ t: SIMD3<Float>) -> Matrix4 {
        Matrix4(SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(t.x, t.y, t.z, 1))
    }

    static func scale(_ s: SIMD3<Float>) -> Matrix4 {
        Matrix4(SIMD4(s.x, 0, 0, 0), SIMD4(0, s.y, 0, 0), SIMD4(0, 0, s.z, 0), SIMD4(0, 0, 0, 1))
    }

    /// Right-handed rotation about +X, the same sense as `simd_quatf`.
    static func rotationX(_ angle: Float) -> Matrix4 {
        let c = cos(angle), s = sin(angle)
        return Matrix4(SIMD4(1, 0, 0, 0), SIMD4(0, c, s, 0), SIMD4(0, -s, c, 0), SIMD4(0, 0, 0, 1))
    }

    static func rotationY(_ angle: Float) -> Matrix4 {
        let c = cos(angle), s = sin(angle)
        return Matrix4(SIMD4(c, 0, -s, 0), SIMD4(0, 1, 0, 0), SIMD4(s, 0, c, 0), SIMD4(0, 0, 0, 1))
    }

    static func rotationZ(_ angle: Float) -> Matrix4 {
        let c = cos(angle), s = sin(angle)
        return Matrix4(SIMD4(c, s, 0, 0), SIMD4(-s, c, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, 0, 0, 1))
    }

    /// OpenGL's clip space: depth -1…1, looking down -Z.
    static func perspective(fovYRadians: Float, aspect: Float, near: Float, far: Float) -> Matrix4 {
        let f = 1 / tan(fovYRadians / 2)
        return Matrix4(
            SIMD4(f / aspect, 0, 0, 0),
            SIMD4(0, f, 0, 0),
            SIMD4(0, 0, (far + near) / (near - far), -1),
            SIMD4(0, 0, 2 * far * near / (near - far), 0)
        )
    }

    /// Pixel coordinates with the origin top-left, for the 2D overlay.
    static func orthographic(width: Float, height: Float) -> Matrix4 {
        Matrix4(
            SIMD4(2 / width, 0, 0, 0),
            SIMD4(0, -2 / height, 0, 0),
            SIMD4(0, 0, -1, 0),
            SIMD4(-1, 1, 0, 1)
        )
    }
}

extension CameraState {
    /// World to camera, built from the same rig `FirstPersonCamera` hangs on
    /// RealityKit entities: yaw (plus a half turn, so -Z looks along the
    /// yaw), then pitch, then the bob and shake offset and the roll. This
    /// is that chain inverted.
    var viewMatrix: Matrix4 {
        let eye = SIMD3<Float>(Float(eyePosition.x), Float(eyePosition.y), Float(eyePosition.z))
        return Matrix4.rotationZ(-roll)
            * Matrix4.translation(SIMD3(-offset.x, -offset.y, 0))
            * Matrix4.rotationX(-Float(pitch))
            * Matrix4.rotationY(-Float(yaw) - .pi)
            * Matrix4.translation(-eye)
    }
}
