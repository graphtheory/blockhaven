import Foundation

/// Engine-neutral three-dimensional coordinates used by world, physics, and
/// renderer code alike. `CGFloat` keeps arithmetic in one scalar domain
/// while removing the SceneKit dependency from everything but the bridge.
struct Vector3: Equatable, Sendable {
    var x: CGFloat
    var y: CGFloat
    var z: CGFloat

    init(_ x: CGFloat, _ y: CGFloat, _ z: CGFloat) {
        self.x = x
        self.y = y
        self.z = z
    }

    static let zero = Vector3(0, 0, 0)
}

func + (l: Vector3, r: Vector3) -> Vector3 { Vector3(l.x + r.x, l.y + r.y, l.z + r.z) }
func - (l: Vector3, r: Vector3) -> Vector3 { Vector3(l.x - r.x, l.y - r.y, l.z - r.z) }
func * (l: Vector3, r: CGFloat) -> Vector3 { Vector3(l.x * r, l.y * r, l.z * r) }

extension Vector3 {
    func length() -> CGFloat {
        sqrt(x * x + y * y + z * z)
    }

    func normalized() -> Vector3 {
        let len = length()
        guard len > 0.0001 else { return Vector3(0, 0, 1) }
        return Vector3(x / len, y / len, z / len)
    }
}
