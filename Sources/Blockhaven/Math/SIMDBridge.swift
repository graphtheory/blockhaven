import Foundation

/// The only conversion point between the simulation's `Vector3` (double
/// precision, engine-neutral) and RealityKit's single-precision SIMD
/// vectors. Renderer files opt into it explicitly.
extension SIMD3 where Scalar == Float {
    init(_ vector: Vector3) {
        self.init(Float(vector.x), Float(vector.y), Float(vector.z))
    }
}

extension Vector3 {
    init(_ vector: SIMD3<Float>) {
        self.init(CGFloat(vector.x), CGFloat(vector.y), CGFloat(vector.z))
    }
}
