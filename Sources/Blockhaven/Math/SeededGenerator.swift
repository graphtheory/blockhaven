import Foundation

/// A small deterministic RNG (SplitMix64) so world generation is
/// reproducible across runs for a given seed.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

/// Deterministic hash of an integer lattice point → [0, 1). Stateless (no
/// sequential RNG state to thread through), so any chunk can sample any
/// lattice point in any order and still agree with its neighbors.
func latticeHash(_ x: Int, _ y: Int, seed: UInt64) -> Double {
    var z = UInt64(bitPattern: Int64(x)) &* 0x9E3779B97F4A7C15
    z ^= UInt64(bitPattern: Int64(y)) &* 0xBF58476D1CE4E5B9
    z ^= seed &* 0x94D049BB133111EB
    z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
    z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
    z = z ^ (z >> 31)
    return Double(z >> 11) * (1.0 / Double(1 << 53))
}

/// Bilinear-interpolated value noise summed over a few octaves — cheap,
/// dependency-free terrain shaping with no periodic tiling artifacts at the
/// scale a single world uses.
struct ValueNoise {
    let seed: UInt64

    func sample(_ x: Double, _ z: Double) -> Double {
        var amplitude = 1.0
        var frequency = 1.0
        var total = 0.0
        var maxAmplitude = 0.0
        for octave in 0..<4 {
            total += octave2D(x * frequency, z * frequency, octaveSeed: seed &+ UInt64(octave)) * amplitude
            maxAmplitude += amplitude
            amplitude *= 0.5
            frequency *= 2.0
        }
        return total / maxAmplitude
    }

    private func octave2D(_ x: Double, _ z: Double, octaveSeed: UInt64) -> Double {
        let x0 = Int(x.rounded(.down)), z0 = Int(z.rounded(.down))
        let tx = x - Double(x0), tz = z - Double(z0)
        let v00 = latticeHash(x0, z0, seed: octaveSeed)
        let v10 = latticeHash(x0 + 1, z0, seed: octaveSeed)
        let v01 = latticeHash(x0, z0 + 1, seed: octaveSeed)
        let v11 = latticeHash(x0 + 1, z0 + 1, seed: octaveSeed)
        let sx = tx * tx * (3 - 2 * tx)
        let sz = tz * tz * (3 - 2 * tz)
        let top = v00 + (v10 - v00) * sx
        let bottom = v01 + (v11 - v01) * sx
        return (top + (bottom - top) * sz) * 2 - 1
    }
}
