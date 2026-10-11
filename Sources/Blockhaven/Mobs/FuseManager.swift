import Foundation

/// Lit TNT, and the chain.
///
/// A block is one byte and cannot count, so a fuse cannot live in the world
/// array. Lighting a stick of TNT takes the block out and puts a *primed*
/// one here — which is exactly what the original does, and for the same
/// reason. It also gives the thing somewhere to flash from.
///
/// The chain is the whole point of the feature and it is one rule: a blast
/// does not destroy TNT it reaches, it lights it. `Blast.carve` reports
/// what it found and this decides what that means, which keeps the
/// recursion out of the Swift stack — a stack of forty TNT detonating each
/// other inline would go off as one frame and one stack overflow.
final class FuseManager {
    /// How long a fuse the player lights burns. the original's four seconds,
    /// which is long enough to run and short enough to be worth running.
    static let litFuse: Double = 4.0

    /// The fuse a blast lights. Short, and jittered, so a stack does not go
    /// off as one indistinguishable bang: the stagger is what makes a chain
    /// read as a chain rather than as a single larger explosion.
    static let chainFuse: ClosedRange<Double> = 0.10...0.55

    /// How far a stick of TNT throws. Bigger than a fizzler's 3.0 — TNT you
    /// placed on purpose should out-do a fizzler that wandered into you.
    static let blastRadius: CGFloat = 4.2

    /// The most this takes off the player at point-blank range, in
    /// half-hearts.
    static let maximumDamage = 13

    struct Primed {
        let id: Int
        /// The cell it was lit in. Kept as integers because that is where
        /// the crater is centred and where the entity stands.
        let x: Int
        let y: Int
        let z: Int
        var remaining: Double
        /// The fuse it started with, so the renderer can flash faster as it
        /// runs out without having to know which kind of fuse it was.
        let total: Double

        var centre: Vector3 {
            Vector3(CGFloat(x) + 0.5, CGFloat(y) + 0.5, CGFloat(z) + 0.5)
        }
    }

    private(set) var primed: [Int: Primed] = [:]
    private var nextID = 0
    private var random: SeededGenerator

    init(seed: UInt64 = 0x7A17_C0DE) {
        random = SeededGenerator(seed: seed)
    }

    /// Lights the TNT at a cell, taking the block out as it does.
    ///
    /// Returns false when there is no TNT there, which is what makes this
    /// safe to call from the chain: a cell can appear in two blasts in the
    /// same frame, and the second one finds air.
    @discardableResult
    func light(atX x: Int, y: Int, z: Int, in world: World, fuse: Double) -> Bool {
        guard world.block(worldX: x, y: y, worldZ: z) == .tnt else { return false }
        world.setBlock(worldX: x, y: y, worldZ: z, to: .air)
        let id = nextID
        nextID += 1
        primed[id] = Primed(id: id, x: x, y: y, z: z, remaining: fuse, total: fuse)
        return true
    }

    /// Lights everything a blast reached, on staggered short fuses.
    func lightChain(_ cells: [(x: Int, y: Int, z: Int)], in world: World) {
        for cell in cells {
            let span = FuseManager.chainFuse.upperBound - FuseManager.chainFuse.lowerBound
            let fuse = FuseManager.chainFuse.lowerBound + Double.random(in: 0...1, using: &random) * span
            light(atX: cell.x, y: cell.y, z: cell.z, in: world, fuse: fuse)
        }
    }

    /// Burns every fuse down and returns the blasts that went off this
    /// frame, chaining as it goes.
    ///
    /// The chain is applied here rather than left to the caller because a
    /// blast can light TNT whose own fuse is short enough to go off in the
    /// same frame at a low frame rate, and the loop below is the only place
    /// that can see that happen and still be correct.
    func update(dt: Double, world: World, playerEye: Vector3) -> [FizzlerManager.Explosion] {
        guard !primed.isEmpty else { return [] }
        var explosions: [FizzlerManager.Explosion] = []

        for id in primed.keys.sorted() {
            guard var fuse = primed[id] else { continue }
            fuse.remaining -= dt
            guard fuse.remaining <= 0 else {
                primed[id] = fuse
                continue
            }
            primed.removeValue(forKey: id)

            let centre = fuse.centre
            let result = Blast.carve(at: centre, radius: FuseManager.blastRadius, in: world)
            lightChain(result.ignited, in: world)
            explosions.append(FizzlerManager.Explosion(
                centre: centre,
                playerDamage: Blast.damage(
                    maximum: FuseManager.maximumDamage, at: playerEye,
                    from: centre, radius: FuseManager.blastRadius
                ),
                blocksDestroyed: result.destroyed,
                ignited: result.ignited
            ))
        }

        return explosions
    }

    /// Everything still ticking, for the renderer and for the checks.
    /// Sorted so a transcript is stable run to run.
    var live: [Primed] { primed.values.sorted { $0.id < $1.id } }

    /// Drops every fuse without detonating anything — leaving a world, or
    /// starting a fresh one, should not rain craters on the next.
    func clear() {
        primed.removeAll()
    }
}
