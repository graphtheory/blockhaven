#if canImport(CSDL3)
import Foundation

/// The boxes every mob, cart and lit stick of TNT is drawn with this frame.
///
/// Shapes and skins are the Mac's (`FizzlerEntity`, `SkeletonEntity`,
/// `AnimalEntity`): the same proportions, the same faces, and the same walk
/// gait. Wings flapping and tails wagging are still Mac-only.
final class SDLMobModels {
    private let assets: SDLAssets

    init(assets: SDLAssets) {
        self.assets = assets
    }

    /// One mob's stride: where it stood last frame, and how far through the
    /// walk cycle its legs are.
    private struct Gait {
        var last: Vector3
        var phase: Double = 0
        var speed: Float = 0
    }
    private enum MobKey: Hashable { case fizzler(Int), skeleton(Int), animal(Int) }
    private var gaits: [MobKey: Gait] = [:]
    private var seen: Set<MobKey> = []

    /// Advances one mob's gait the way `AnimalEntity.apply` does: the phase
    /// moves with the ground covered rather than the clock, so the legs keep
    /// time with the walk and a mob standing still settles straight. Returns
    /// the phase and how hard the legs swing, 0 to 1.
    private func stride(_ key: MobKey, at position: Vector3, dt: Double, reference: Float) -> (phase: Float, swing: Float) {
        seen.insert(key)
        var gait = gaits[key] ?? Gait(last: position)
        let dx = position.x - gait.last.x, dz = position.z - gait.last.z
        let moved = Float((dx * dx + dz * dz).squareRoot())
        // A teleport or a respawn is not a stride.
        let speed = dt > 0 && moved < 2 ? moved / Float(dt) : 0
        // Eased, so one frame that happened to move a mob twice as far
        // as the next does not make its legs stutter.
        gait.speed += (speed - gait.speed) * Float(min(1, dt * 12))
        gait.phase += Double(gait.speed) * dt * 7
        gait.last = position
        gaits[key] = gait
        return (Float(gait.phase), min(1, gait.speed / max(0.05, reference)))
    }

    struct Placed {
        var box: SDLEntityRenderer.Box
        var flash: Float
    }

    func boxes(for session: GameSession, dt: Double) -> [Placed] {
        var out: [Placed] = []
        seen.removeAll(keepingCapacity: true)
        for (id, fizzler) in session.fizzlers.fizzlers {
            let swell = Float(fizzler.swell)
            // The fuse blink shows its cracks blazing; the hurt flash whitens.
            let burning = swell > 0 && sin(swell * swell * 46) > 0
            let scale = 1 + 0.1 * swell
            let gait = stride(.fizzler(id), at: fizzler.position, dt: dt, reference: 1.2)
            fizzlerBoxes(at: fizzler.position, facing: Float(fizzler.facing), scale: scale,
                         hurt: fizzler.isHurt, burning: burning, gait: gait, into: &out)
        }
        for (id, skeleton) in session.skeletons.skeletons {
            let gait = stride(.skeleton(id), at: skeleton.position, dt: dt, reference: 1.2)
            skeletonBoxes(at: skeleton.position, facing: Float(skeleton.facing), hurt: skeleton.isHurt,
                          gait: gait, skin: session.world.isLunar ? "sentry" : "skeleton", into: &out)
        }
        for (id, animal) in session.animals.animals {
            let kind = animal.kind
            let reference = Float(kind.isAquatic ? kind.walkSpeed : kind.walkSpeed * 0.6)
            animalBoxes(animal, gait: stride(.animal(id), at: animal.position, dt: dt, reference: reference), into: &out)
        }
        gaits = gaits.filter { seen.contains($0.key) }
        for cart in session.minecarts.carts.values {
            cartBoxes(cart, into: &out)
        }
        for fuse in session.drawnFuses(budget: 96) {
            let fraction = fuse.remaining / fuse.total
            let lit = sin(Double(fuse.remaining) * 18) > 0 && fraction < 0.98
            let c = fuse.centre
            let base = SIMD3<Float>(Float(c.x) - 0.5, Float(c.y) - 0.5, Float(c.z) - 0.5)
            let tnt = assets.tileRect(.tntSide)
            let top = assets.tileRect(.tntTop)
            out.append(Placed(
                box: .init(
                    transform: Matrix4.translation(base),
                    texture: assets.atlas,
                    faces: [rect(tnt), rect(tnt), rect(top), rect(top), rect(tnt), rect(tnt)],
                    tint: lit ? SIMD4(1.6, 1.6, 1.6, 1) : SIMD4(1, 1, 1, 1)
                ),
                flash: lit ? 0.35 : 0
            ))
        }
        return out
    }

    private func rect(_ r: (u0: Float, v0: Float, u1: Float, v1: Float)) -> SIMD4<Float> {
        SIMD4(r.u0, r.v0, r.u1, r.v1)
    }

    /// A box `size` big, its centre at `centre` in the mob's own frame, with
    /// the mob placed at `origin` and turned by `facing` about Y.
    /// `swing` turns it about x from the middle of its top face — a leg
    /// from its hip, an arm from its shoulder.
    private func box(origin: Vector3, facing: Float, scale: Float = 1, centre: SIMD3<Float>, size: SIMD3<Float>,
                     swing: Float = 0, faces: [SIMD4<Float>], flash: Bool) -> Placed {
        let o = SIMD3<Float>(Float(origin.x), Float(origin.y), Float(origin.z))
        let hip = centre + SIMD3(0, size.y / 2, 0)
        let transform = Matrix4.translation(o)
            * Matrix4.rotationY(facing)
            * Matrix4.scale(SIMD3(repeating: scale))
            * Matrix4.translation(hip)
            * Matrix4.rotationX(swing)
            * Matrix4.translation(SIMD3(-size.x / 2, -size.y, -size.z / 2))
            * Matrix4.scale(size)
        return Placed(box: .init(transform: transform, texture: assets.skins, faces: faces), flash: flash ? 0.55 : 0)
    }

    /// Six faces of one skin, or a different one on the front (+Z).
    private func skinned(_ all: String, front: String? = nil) -> [SIMD4<Float>] {
        var faces = Array(repeating: assets.skin(all), count: 6)
        if let front { faces[4] = assets.skin(front) }
        return faces
    }

    /// `FizzlerEntity`'s stone golem: wide body, two thick legs, arms
    /// that swing against them, a small head sunk into the shoulders.
    private func fizzlerBoxes(at p: Vector3, facing: Float, scale: Float, hurt: Bool, burning: Bool,
                              gait: (phase: Float, swing: Float), into out: inout [Placed]) {
        let leg = SIMD3<Float>(0.26, 0.5, 0.3), legX: Float = 0.18
        let torso = SIMD3<Float>(0.76, 0.68, 0.46)
        let arm = SIMD3<Float>(0.2, 0.56, 0.24)
        let head = SIMD3<Float>(0.46, 0.42, 0.42)
        let body = skinned(burning ? "fizzler.flash" : "fizzler.body")
        out.append(box(origin: p, facing: facing, scale: scale, centre: SIMD3(0, leg.y + torso.y / 2, 0),
                       size: torso, faces: body, flash: hurt))
        out.append(box(origin: p, facing: facing, scale: scale,
                       centre: SIMD3(0, leg.y + torso.y + head.y / 2 - 0.04, 0.03),
                       size: head, faces: burning ? body : skinned("fizzler.body", front: "fizzler.face"), flash: hurt))
        for side: Float in [-1, 1] {
            let step = sin(gait.phase + (side < 0 ? 0 : .pi))
            out.append(box(origin: p, facing: facing, scale: scale, centre: SIMD3(side * legX, leg.y / 2, 0),
                           size: leg, swing: step * 0.45 * gait.swing, faces: body, flash: hurt))
            out.append(box(origin: p, facing: facing, scale: scale,
                           centre: SIMD3(side * (torso.x + arm.x) / 2, leg.y + torso.y - 0.02 - arm.y / 2, 0),
                           size: arm, swing: -step * 0.35 * gait.swing, faces: body, flash: hurt))
        }
    }

    private func skeletonBoxes(at p: Vector3, facing: Float, hurt: Bool,
                               gait: (phase: Float, swing: Float), skin: String, into out: inout [Placed]) {
        let bone = skinned("\(skin).body")
        let legH: Float = 0.75, bodyH: Float = 0.7, head: Float = 0.45
        out.append(box(origin: p, facing: facing, centre: SIMD3(0, legH + bodyH / 2, 0),
                       size: SIMD3(0.45, bodyH, 0.22), faces: bone, flash: hurt))
        out.append(box(origin: p, facing: facing, centre: SIMD3(0, legH + bodyH + head / 2, 0),
                       size: SIMD3(repeating: head), faces: skinned("\(skin).body", front: "\(skin).face"), flash: hurt))
        // Each arm swings against the leg on its own side.
        for dx in [Float(-0.12), 0.12] {
            let swing = sin(gait.phase + (dx < 0 ? 0 : .pi)) * 0.5 * gait.swing
            out.append(box(origin: p, facing: facing, centre: SIMD3(dx, legH / 2, 0),
                           size: SIMD3(0.12, legH, 0.12), swing: swing, faces: bone, flash: hurt))
        }
        for dx in [Float(-0.29), 0.29] {
            let swing = -sin(gait.phase + (dx < 0 ? 0 : .pi)) * 0.35 * gait.swing
            out.append(box(origin: p, facing: facing, centre: SIMD3(dx, legH + bodyH - 0.3, 0.1),
                           size: SIMD3(0.11, 0.6, 0.11), swing: swing, faces: bone, flash: hurt))
        }
    }

    private func animalBoxes(_ animal: Animal, gait: (phase: Float, swing: Float), into out: inout [Placed]) {
        let tag = "\(animal.kind.rawValue).\(animal.morph == .rare ? "rare" : "common")"
        let p = animal.position, facing = Float(animal.facing), hurt = animal.isHurt
        let skin = skinned("\(tag).body")
        let headFaces = skinned("\(tag).body", front: "\(tag).head")
        // Body, head and legs in the Mac's proportions for each animal;
        // the swimmers and the chicken as their one main box and a head.
        let shape: (bw: Float, bh: Float, bl: Float, head: Float, lw: Float, lh: Float, rise: Float)
        switch animal.kind {
        case .pig: shape = (0.50, 0.50, 0.80, 0.42, 0.16, 0.35, 0)
        case .cow: shape = (0.62, 0.62, 1.00, 0.50, 0.20, 0.62, 0.08)
        case .sheep: shape = (0.55, 0.60, 0.85, 0.42, 0.17, 0.55, 0.04)
        case .wolf: shape = (0.36, 0.40, 0.72, 0.34, 0.13, 0.42, 0.10)
        case .chicken: shape = (0.28, 0.26, 0.36, 0.19, 0.055, 0.20, -0.04)
        case .axolotl: shape = (0.26, 0.16, 0.62, 0.24, 0.07, 0.06, -0.04)
        case .cod: shape = (0.14, 0.24, 0.50, 0.20, 0.0, 0.0, -0.06)
        case .squid: shape = (0.50, 0.62, 0.50, 0.0, 0.10, 0.40, 0)
        }
        let bodyY = shape.lh + shape.bh / 2
        out.append(box(origin: p, facing: facing, centre: SIMD3(0, bodyY, 0),
                       size: SIMD3(shape.bw, shape.bh, shape.bl), faces: skin, flash: hurt))
        if shape.head > 0 {
            let headY = shape.lh + shape.bh - shape.head / 2 + shape.rise
            let headZ = shape.bl / 2 + shape.head / 2 - 0.05
            out.append(box(origin: p, facing: facing, centre: SIMD3(0, headY, headZ),
                           size: SIMD3(repeating: shape.head), faces: headFaces, flash: hurt))
        }
        guard shape.lw > 0, shape.lh > 0 else { return }
        if animal.kind == .chicken {
            for dx in [Float(-0.06), 0.06] {
                let swing = sin(gait.phase + (dx < 0 ? 0 : .pi)) * 0.5 * gait.swing
                out.append(box(origin: p, facing: facing, centre: SIMD3(dx, shape.lh / 2, 0),
                               size: SIMD3(shape.lw, shape.lh, shape.lw), swing: swing,
                               faces: skinned("beak"), flash: hurt))
            }
            return
        }
        let legX = (shape.bw - shape.lw) / 2
        let legZ = shape.bl / 2 - shape.lw / 2 - 0.02
        for (dx, dz) in [(-legX, legZ), (legX, legZ), (-legX, -legZ), (legX, -legZ)] {
            let phase: Float = (dx < 0) == (dz < 0) ? 0 : .pi
            out.append(box(origin: p, facing: facing, centre: SIMD3(dx, shape.lh / 2, dz),
                           size: SIMD3(shape.lw, shape.lh, shape.lw), swing: sin(gait.phase + phase) * 0.5 * gait.swing,
                           faces: skin, flash: hurt))
        }
    }

    private func cartBoxes(_ cart: Minecart, into out: inout [Placed]) {
        let p = cart.position
        let iron = rect(assets.tileRect(.stone))
        let faces = Array(repeating: iron, count: 6)
        let o = SIMD3<Float>(Float(p.x), Float(p.y), Float(p.z))
        // Turned along the track, as `MinecartEntity` turns it.
        let yaw: Float
        switch cart.heading {
        case .north: yaw = .pi
        case .south: yaw = 0
        case .east: yaw = .pi / 2
        case .west: yaw = -.pi / 2
        }
        let transform = Matrix4.translation(o) * Matrix4.rotationY(yaw)
            * Matrix4.translation(SIMD3(-0.45, 0.1, -0.6)) * Matrix4.scale(SIMD3(0.9, 0.5, 1.2))
        out.append(Placed(box: .init(transform: transform, texture: assets.atlas, faces: faces), flash: 0))
    }
}
#endif
