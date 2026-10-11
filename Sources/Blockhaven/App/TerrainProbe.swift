import Foundation

/// Prints a grid of the generator's surface heights and exits.
///
/// Siting a landmark starts with a question the app never otherwise
/// answers aloud: how high is the ground over there? The pyramid's desert
/// and Atlantis's sea were both chosen by probes that were written, run
/// and deleted — this is that probe kept, so the next siting starts with
/// an answer instead of an archaeology of comments claiming one.
///
/// `BLOCKHAVEN_PROBE="x0,z0,x1,z1[,step]"`, heights sampled on `step`
/// spacing (default 8) for whatever seed `BLOCKHAVEN_SEED` names, or the
/// demo seed when it names none — the demo site is what keeps needing
/// siting. Pure generator arithmetic: no window, no chunks, no saves.
enum TerrainProbe {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["BLOCKHAVEN_PROBE"] != nil
            || ProcessInfo.processInfo.environment["BLOCKHAVEN_PROBE_BLOCKS"] != nil
    }

    /// The second question a siting asks, once something looks wrong:
    /// what is actually standing in this box? `BLOCKHAVEN_PROBE_BLOCKS=
    /// "x0,y0,z0,x1,y1,z1"` prints a census of every non-air block in
    /// the volume — of the *demo* world when `BLOCKHAVEN_DEMO` is set,
    /// of the bare seed otherwise — with the extremes each type reaches,
    /// which is usually enough to name a mystery seen in a snapshot.
    static func runBlocks() -> Never {
        let spec = ProcessInfo.processInfo.environment["BLOCKHAVEN_PROBE_BLOCKS"] ?? ""
        let parts = spec.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 6 else {
            print("[probe] BLOCKHAVEN_PROBE_BLOCKS wants \"x0,y0,z0,x1,y1,z1\", got \"\(spec)\"")
            exit(1)
        }
        let x = min(parts[0], parts[3])...max(parts[0], parts[3])
        let y = min(parts[1], parts[4])...max(parts[1], parts[4])
        let z = min(parts[2], parts[5])...max(parts[2], parts[5])

        let seed = ProcessInfo.processInfo.environment["BLOCKHAVEN_SEED"]
            .flatMap { UInt64($0) } ?? DemoWorld.seed
        let world = World(seed: seed)
        if ProcessInfo.processInfo.environment["BLOCKHAVEN_DEMO"] != nil {
            DemoWorld.build(in: world)
        }
        var generated: Set<ChunkCoord> = []
        var census: [BlockType: (count: Int, minY: Int, maxY: Int, sample: (Int, Int, Int))] = [:]
        for zz in z {
            for xx in x {
                let coord = World.chunkCoord(forWorldX: xx, worldZ: zz)
                if generated.insert(coord).inserted { world.forceGenerate(coord) }
                for yy in y {
                    let block = world.block(worldX: xx, y: yy, worldZ: zz)
                    guard block != .air else { continue }
                    var entry = census[block] ?? (0, yy, yy, (xx, yy, zz))
                    entry.count += 1
                    entry.minY = min(entry.minY, yy)
                    entry.maxY = max(entry.maxY, yy)
                    census[block] = entry
                }
            }
        }
        print("[probe] blocks in x \(x), y \(y), z \(z):")
        for (block, entry) in census.sorted(by: { $0.value.count > $1.value.count }) {
            print("[probe]   \(block) ×\(entry.count), y \(entry.minY)...\(entry.maxY), e.g. \(entry.sample)")
        }
        if census.isEmpty { print("[probe]   nothing but air") }
        exit(0)
    }

    static func run() -> Never {
        if ProcessInfo.processInfo.environment["BLOCKHAVEN_PROBE_BLOCKS"] != nil {
            runBlocks()
        }
        let spec = ProcessInfo.processInfo.environment["BLOCKHAVEN_PROBE"] ?? ""
        let parts = spec.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count >= 4 else {
            print("[probe] BLOCKHAVEN_PROBE wants \"x0,z0,x1,z1[,step]\", got \"\(spec)\"")
            exit(1)
        }
        let x0 = min(parts[0], parts[2]), x1 = max(parts[0], parts[2])
        let z0 = min(parts[1], parts[3]), z1 = max(parts[1], parts[3])
        let step = max(1, parts.count > 4 ? parts[4] : 8)

        let seed = ProcessInfo.processInfo.environment["BLOCKHAVEN_SEED"]
            .flatMap { UInt64($0) } ?? DemoWorld.seed
        let world = World(seed: seed)

        print("[probe] seed \(seed), x \(x0)...\(x1), z \(z0)...\(z1), step \(step)")
        var header = "[probe]      "
        for x in stride(from: x0, through: x1, by: step) {
            header += String(format: "%5d", x)
        }
        print(header)
        for z in stride(from: z0, through: z1, by: step) {
            var row = String(format: "[probe] z%4d", z)
            for x in stride(from: x0, through: x1, by: step) {
                row += String(format: "%5d", world.generator.surfaceHeight(x: x, z: z))
            }
            print(row)
        }
        exit(0)
    }
}
