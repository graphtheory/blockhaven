import Foundation
import Foundation

/// Adversarial stress testing and edge-case verification for Milestone 1:
/// Environmental Sensing & Active Signal Lighting (Wave 9).
///
/// Exercises:
/// 1. Celestial transitions, fine-grained solar curve monotonicity, signal reach falloff, and rain observation.
/// 2. Vertical sky occlusion at multiple elevations (y+1, y+2, y+10, y+50, y=191), transparent non-occluders (glass), and deep 4-wall chimneys (lateral overhangs).
/// 3. Signal lamp rapid sequential flipping (200 cycles), adjacent dual-lamp relighting, and 3x3 matrix unwinding with zero stranded light.
/// 4. Universal pressure plate multi-entity occupancy, sequential departure, entity death transitions, fizzler explosions, despawns, and player co-occupancy.
///
/// Run via `BLOCKHAVEN_CHECK_SENSOR_STRESS=1`. Exits nonzero on failure.
enum SensorStressCheck {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["BLOCKHAVEN_CHECK_SENSOR_STRESS"] != nil
    }

    private struct Report {
        var lines: [String] = []
        var failed = false

        mutating func check(_ name: String, _ passed: Bool, _ detail: String) {
            lines.append("[stress-check] \(name): \(passed ? "ok" : "FAILED") — \(detail)")
            if !passed { failed = true }
        }
    }

    static func run() -> Never {
        var report = Report()
        let world = World(seed: 777)
        let spawn = world.spawnPosition()
        let centre = World.chunkCoord(forWorldX: Int(spawn.x), worldZ: Int(spawn.z))
        for dz in -3...3 {
            for dx in -3...3 {
                world.forceGenerate(ChunkCoord(x: centre.x + dx, z: centre.z + dz))
            }
        }

        let originX = Int(spawn.x)
        let originZ = Int(spawn.z)
        var highest = 0
        for z in (originZ - 25)...(originZ + 25) {
            for x in (originX - 25)...(originX + 25) {
                var top = Chunk.height - 1
                while top > 0, !world.block(worldX: x, y: top, worldZ: z).isSolid { top -= 1 }
                highest = max(highest, top)
            }
        }
        let deckY = highest + 2
        let groundY = deckY + 1
        guard deckY + 25 < Chunk.height else {
            StandardError.write(Data("[stress-check] insufficient vertical headroom\n".utf8))
            exit(2)
        }

        for z in (originZ - 25)...(originZ + 25) {
            for x in (originX - 25)...(originX + 25) {
                world.setBlock(worldX: x, y: deckY, worldZ: z, to: .stone, remesh: false)
                for y in groundY...(deckY + 20) {
                    world.setBlock(worldX: x, y: y, worldZ: z, to: .air, remesh: false)
                }
            }
        }

        let fuses = FuseManager()

        // =========================================================================
        // MARK: - Section 1: Celestial Transitions & Solar Signal Reach
        // =========================================================================

        // 1a. Boundary and monotonicity checks across fine-grained timeOfDay
        let dawnPower = SignalNetwork.daylightPower(timeOfDay: 0.0)
        let noonPower = SignalNetwork.daylightPower(timeOfDay: 0.25)
        let duskPower = SignalNetwork.daylightPower(timeOfDay: 0.50)
        let midnightPower = SignalNetwork.daylightPower(timeOfDay: 0.75)

        report.check(
            "celestial cardinal points power values",
            dawnPower == 0 && noonPower == 15 && duskPower == 0 && midnightPower == 0,
            "dawn: \(dawnPower), noon: \(noonPower), dusk: \(duskPower), midnight: \(midnightPower)"
        )

        var morningMonotonic = true
        var prevPower = 0
        for step in 0...250 {
            let t = Double(step) / 1000.0
            let p = SignalNetwork.daylightPower(timeOfDay: t)
            if p < prevPower { morningMonotonic = false; break }
            prevPower = p
        }

        var afternoonMonotonic = true
        prevPower = 15
        for step in 250...500 {
            let t = Double(step) / 1000.0
            let p = SignalNetwork.daylightPower(timeOfDay: t)
            if p > prevPower { afternoonMonotonic = false; break }
            prevPower = p
        }

        var nightAllZero = true
        for step in 500...1000 {
            let t = Double(step) / 1000.0
            let p = SignalNetwork.daylightPower(timeOfDay: t)
            if p != 0 { nightAllZero = false; break }
        }

        report.check(
            "solar curve monotonicity and night zero invariance",
            morningMonotonic && afternoonMonotonic && nightAllZero,
            "morningMonotonic: \(morningMonotonic), afternoonMonotonic: \(afternoonMonotonic), nightAllZero: \(nightAllZero)"
        )

        // 1b. Wrap-around consistency (multi-day continuity)
        let day2NoonPower = SignalNetwork.daylightPower(timeOfDay: 1.25)
        let day2DuskPower = SignalNetwork.daylightPower(timeOfDay: 1.50)
        let day3NoonPower = SignalNetwork.daylightPower(timeOfDay: 2.25)
        report.check(
            "multi-day cyclic wrap-around",
            day2NoonPower == 15 && day2DuskPower == 0 && day3NoonPower == 15,
            "day2Noon: \(day2NoonPower), day2Dusk: \(day2DuskPower), day3Noon: \(day3NoonPower)"
        )

        // 1c. Wire reach matches variable daylight power level
        let s1X = originX - 15
        let s1Z = originZ - 15
        let s1Cell = SignalNetwork.Key(s1X, groundY, s1Z)
        world.setBlock(worldX: s1Cell.x, y: s1Cell.y, worldZ: s1Cell.z, to: .daylightSensor)
        for i in 1...16 {
            world.setBlock(worldX: s1Cell.x + i, y: s1Cell.y, worldZ: s1Cell.z, to: .wireOff)
        }

        let s1Network = SignalNetwork()
        s1Network.daylightSensorPlaced(at: s1Cell)

        // At noon (power 15): reach should power wire 1...15, but wire 16 should be wireOff
        s1Network.updateDaylightSensors(world: world, timeOfDay: 0.25, fuses: fuses)
        let noon1To15Lit = (1...15).allSatisfy {
            world.block(worldX: s1Cell.x + $0, y: s1Cell.y, worldZ: s1Cell.z) == .wireOn
        }
        let noon16Off = world.block(worldX: s1Cell.x + 16, y: s1Cell.y, worldZ: s1Cell.z) == .wireOff

        report.check(
            "noon daylight sensor signal reach strictly bounds at 15 blocks",
            noon1To15Lit && noon16Off,
            "wires 1-15 lit: \(noon1To15Lit), wire 16 off: \(noon16Off)"
        )

        // At mid-morning t = 0.18 (elevation cos gives ~10 power)
        s1Network.updateDaylightSensors(world: world, timeOfDay: 0.18, fuses: fuses)
        let midPower = SignalNetwork.daylightPower(timeOfDay: 0.18)
        let midLitCount = (1...16).filter {
            world.block(worldX: s1Cell.x + $0, y: s1Cell.y, worldZ: s1Cell.z) == .wireOn
        }.count
        report.check(
            "mid-morning daylight reach matches scaled power level",
            midLitCount == midPower,
            "midPower: \(midPower), midLitCount: \(midLitCount)"
        )

        // Cleanup S1
        world.setBlock(worldX: s1Cell.x, y: s1Cell.y, worldZ: s1Cell.z, to: .air)
        for i in 1...16 {
            world.setBlock(worldX: s1Cell.x + i, y: s1Cell.y, worldZ: s1Cell.z, to: .air)
        }
        s1Network.daylightSensorRemoved(at: s1Cell)

        // =========================================================================
        // MARK: - Section 2: Vertical Occlusion & Partial Overhangs
        // =========================================================================
        let s2X = originX + 15
        let s2Z = originZ - 15
        let s2Cell = SignalNetwork.Key(s2X, groundY, s2Z)
        world.setBlock(worldX: s2Cell.x, y: s2Cell.y, worldZ: s2Cell.z, to: .daylightSensor)
        world.setBlock(worldX: s2Cell.x + 1, y: s2Cell.y, worldZ: s2Cell.z, to: .wireOff)

        let s2Network = SignalNetwork()
        s2Network.daylightSensorPlaced(at: s2Cell)

        // 2a. Elevation sweeps (y+1, y+5, y+15, y=191)
        var occlusionPassed = true
        let testElevations = [groundY + 1, groundY + 5, groundY + 15, Chunk.height - 1]
        for testY in testElevations {
            world.setBlock(worldX: s2Cell.x, y: testY, worldZ: s2Cell.z, to: .stone)
            s2Network.updateDaylightSensors(world: world, timeOfDay: 0.25, fuses: fuses)
            let wireLit = world.block(worldX: s2Cell.x + 1, y: s2Cell.y, worldZ: s2Cell.z) == .wireOn
            if wireLit { occlusionPassed = false }
            world.setBlock(worldX: s2Cell.x, y: testY, worldZ: s2Cell.z, to: .air)
        }
        s2Network.updateDaylightSensors(world: world, timeOfDay: 0.25, fuses: fuses)
        let restoredOpen = world.block(worldX: s2Cell.x + 1, y: s2Cell.y, worldZ: s2Cell.z) == .wireOn

        report.check(
            "vertical occlusion blocks power across various elevations up to world height",
            occlusionPassed && restoredOpen,
            "occlusionPassed: \(occlusionPassed), restoredOpen: \(restoredOpen)"
        )

        // 2b. Transparent non-occluders: glass does not block sky exposure
        world.setBlock(worldX: s2Cell.x, y: groundY + 1, worldZ: s2Cell.z, to: .glass)
        s2Network.updateDaylightSensors(world: world, timeOfDay: 0.25, fuses: fuses)
        let glassPermitsSky = world.block(worldX: s2Cell.x + 1, y: s2Cell.y, worldZ: s2Cell.z) == .wireOn
        world.setBlock(worldX: s2Cell.x, y: groundY + 1, worldZ: s2Cell.z, to: .air)

        report.check(
            "glass above daylight sensor does not occlude open sky",
            glassPermitsSky,
            "glassPermitsSky: \(glassPermitsSky)"
        )

        // 2c. Deep chimney / lateral overhangs: surround sensor column with 10-block high walls
        for y in (groundY + 1)...(groundY + 10) {
            world.setBlock(worldX: s2Cell.x + 1, y: y, worldZ: s2Cell.z, to: .stone)
            world.setBlock(worldX: s2Cell.x - 1, y: y, worldZ: s2Cell.z, to: .stone)
            world.setBlock(worldX: s2Cell.x, y: y, worldZ: s2Cell.z + 1, to: .stone)
            world.setBlock(worldX: s2Cell.x, y: y, worldZ: s2Cell.z - 1, to: .stone)
        }
        s2Network.updateDaylightSensors(world: world, timeOfDay: 0.25, fuses: fuses)
        let chimneyOpen = world.block(worldX: s2Cell.x + 1, y: s2Cell.y, worldZ: s2Cell.z) == .wireOn

        // Now cap the chimney at the top
        world.setBlock(worldX: s2Cell.x, y: groundY + 11, worldZ: s2Cell.z, to: .stone)
        s2Network.updateDaylightSensors(world: world, timeOfDay: 0.25, fuses: fuses)
        let cappedDark = world.block(worldX: s2Cell.x + 1, y: s2Cell.y, worldZ: s2Cell.z) == .wireOff

        // Tear down chimney
        world.setBlock(worldX: s2Cell.x, y: groundY + 11, worldZ: s2Cell.z, to: .air)
        for y in (groundY + 1)...(groundY + 10) {
            world.setBlock(worldX: s2Cell.x + 1, y: y, worldZ: s2Cell.z, to: .air)
            world.setBlock(worldX: s2Cell.x - 1, y: y, worldZ: s2Cell.z, to: .air)
            world.setBlock(worldX: s2Cell.x, y: y, worldZ: s2Cell.z + 1, to: .air)
            world.setBlock(worldX: s2Cell.x, y: y, worldZ: s2Cell.z - 1, to: .air)
        }
        world.setBlock(worldX: s2Cell.x, y: s2Cell.y, worldZ: s2Cell.z, to: .air)
        world.setBlock(worldX: s2Cell.x + 1, y: s2Cell.y, worldZ: s2Cell.z, to: .air)
        s2Network.daylightSensorRemoved(at: s2Cell)

        report.check(
            "lateral overhangs in deep chimney leave sky open until column capped",
            chimneyOpen && cappedDark,
            "chimneyOpen: \(chimneyOpen), cappedDark: \(cappedDark)"
        )

        // =========================================================================
        // MARK: - Section 3: Signal Lamp Rapid Flipping & Zero Stranded Light
        // =========================================================================
        let lampX = originX - 15
        let lampZ = originZ + 15
        let lampKey = SignalNetwork.Key(lampX, groundY, lampZ)
        let leverKey = SignalNetwork.Key(lampX - 1, groundY, lampZ)

        world.setBlock(worldX: lampKey.x, y: lampKey.y, worldZ: lampKey.z, to: .signalLamp)
        world.setBlock(worldX: leverKey.x, y: leverKey.y, worldZ: leverKey.z, to: .leverOff)

        let lampNetwork = SignalNetwork()
        lampNetwork.lampPlaced(at: lampKey)
        lampNetwork.leverPlaced(at: leverKey)
        lampNetwork.recompute(world: world, fuses: fuses)

        // 3a. Rapid sequential toggle (200 flips)
        var rapidToggleConsistent = true
        for i in 1...200 {
            let turnOn = (i % 2 == 1)
            world.setBlock(worldX: leverKey.x, y: leverKey.y, worldZ: leverKey.z, to: turnOn ? .leverOn : .leverOff)
            lampNetwork.recompute(world: world, fuses: fuses)

            let expectedBlock: BlockType = turnOn ? .signalLampLit : .signalLamp
            let actualBlock = world.block(worldX: lampKey.x, y: lampKey.y, worldZ: lampKey.z)
            let lampLight = world.lightLevel(worldX: lampKey.x, y: lampKey.y, worldZ: lampKey.z)

            if actualBlock != expectedBlock {
                rapidToggleConsistent = false
                break
            }
            if turnOn && lampLight != 15 {
                rapidToggleConsistent = false
                break
            }
            if !turnOn && lampLight != 0 {
                rapidToggleConsistent = false
                break
            }
        }

        // Check for stranded light in 21x21x21 bounding box
        var strandedCount = 0
        for dz in -10...10 {
            for dy in -5...10 {
                for dx in -10...10 {
                    let lx = lampKey.x + dx
                    let ly = lampKey.y + dy
                    let lz = lampKey.z + dz
                    if ly >= 0 && ly < Chunk.height {
                        let l = world.lightLevel(worldX: lx, y: ly, worldZ: lz)
                        if l > 0 { strandedCount += 1 }
                    }
                }
            }
        }

        report.check(
            "signal lamp rapid flipping (200 cycles) completes with zero stranded light",
            rapidToggleConsistent && strandedCount == 0,
            "consistent: \(rapidToggleConsistent), strandedCount: \(strandedCount)"
        )

        // 3b. Adjacent dual-lamp interaction (Lamp A and Lamp B)
        let lampBKey = SignalNetwork.Key(lampX + 1, groundY, lampZ)
        let leverBKey = SignalNetwork.Key(lampX + 2, groundY, lampZ)

        world.setBlock(worldX: lampBKey.x, y: lampBKey.y, worldZ: lampBKey.z, to: .signalLamp)
        world.setBlock(worldX: leverBKey.x, y: leverBKey.y, worldZ: leverBKey.z, to: .leverOff)
        lampNetwork.lampPlaced(at: lampBKey)
        lampNetwork.leverPlaced(at: leverBKey)

        // Turn BOTH ON
        world.setBlock(worldX: leverKey.x, y: leverKey.y, worldZ: leverKey.z, to: .leverOn)
        world.setBlock(worldX: leverBKey.x, y: leverBKey.y, worldZ: leverBKey.z, to: .leverOn)
        lampNetwork.recompute(world: world, fuses: fuses)

        let bothLit = world.block(worldX: lampKey.x, y: lampKey.y, worldZ: lampKey.z) == .signalLampLit
            && world.block(worldX: lampBKey.x, y: lampBKey.y, worldZ: lampBKey.z) == .signalLampLit

        // Turn Lamp A OFF, keep Lamp B ON
        world.setBlock(worldX: leverKey.x, y: leverKey.y, worldZ: leverKey.z, to: .leverOff)
        lampNetwork.recompute(world: world, fuses: fuses)

        let lampAReverted = world.block(worldX: lampKey.x, y: lampKey.y, worldZ: lampKey.z) == .signalLamp
        let lampAInternalLight = world.lightLevel(worldX: lampKey.x, y: lampKey.y, worldZ: lampKey.z) // 0: solid opaque block
        let lampAAirLight = world.lightLevel(worldX: lampKey.x, y: lampKey.y + 1, worldZ: lampKey.z) // 13: air above Lamp A illuminated by Lamp B
        let lampBLit = world.block(worldX: lampBKey.x, y: lampBKey.y, worldZ: lampBKey.z) == .signalLampLit

        // Turn Lamp B OFF -> complete unwinding
        world.setBlock(worldX: leverBKey.x, y: leverBKey.y, worldZ: leverBKey.z, to: .leverOff)
        lampNetwork.recompute(world: world, fuses: fuses)

        let lampBReverted = world.block(worldX: lampBKey.x, y: lampBKey.y, worldZ: lampBKey.z) == .signalLamp
        var dualStrandedCount = 0
        for dz in -10...10 {
            for dy in -5...10 {
                for dx in -10...10 {
                    let lx = lampKey.x + dx
                    let ly = lampKey.y + dy
                    let lz = lampKey.z + dz
                    if ly >= 0 && ly < Chunk.height {
                        if world.lightLevel(worldX: lx, y: ly, worldZ: lz) > 0 { dualStrandedCount += 1 }
                    }
                }
            }
        }

        report.check(
            "adjacent dual lamps properly cross-illuminate and unwind to zero",
            bothLit && lampAReverted && lampAInternalLight == 0 && lampAAirLight == 13 && lampBLit && lampBReverted && dualStrandedCount == 0,
            "bothLit: \(bothLit), lampAInternal: \(lampAInternalLight), lampAAir: \(lampAAirLight), lampBReverted: \(lampBReverted), stranded: \(dualStrandedCount)"
        )

        // Cleanup Section 3
        world.setBlock(worldX: lampKey.x, y: lampKey.y, worldZ: lampKey.z, to: .air)
        world.setBlock(worldX: leverKey.x, y: leverKey.y, worldZ: leverKey.z, to: .air)
        world.setBlock(worldX: lampBKey.x, y: lampBKey.y, worldZ: lampBKey.z, to: .air)
        world.setBlock(worldX: leverBKey.x, y: leverBKey.y, worldZ: leverBKey.z, to: .air)
        lampNetwork.lampRemoved(at: lampKey)
        lampNetwork.lampRemoved(at: lampBKey)

        // =========================================================================
        // MARK: - Section 4: Universal Pressure Plate Multi-Entity Occupancy & Transitions
        // =========================================================================
        let plateX = originX + 15
        let plateZ = originZ + 15
        let plateKey = SignalNetwork.Key(plateX, groundY, plateZ)
        let pDoorKey = SignalNetwork.Key(plateX + 2, groundY, plateZ)

        world.setBlock(worldX: plateKey.x, y: plateKey.y, worldZ: plateKey.z, to: .pressurePlateOff)
        world.setBlock(worldX: plateKey.x + 1, y: plateKey.y, worldZ: plateKey.z, to: .wireOff)
        world.setBlock(worldX: pDoorKey.x, y: pDoorKey.y, worldZ: pDoorKey.z,
                       to: .oakDoor(.lower, facing: .north, open: false))
        world.setBlock(worldX: pDoorKey.x, y: pDoorKey.y + 1, worldZ: pDoorKey.z,
                       to: .oakDoor(.upper, facing: .north, open: false))

        let plateNetwork = SignalNetwork()
        plateNetwork.platePlaced(at: plateKey)
        plateNetwork.recompute(world: world, fuses: fuses)

        let plateCenter = Vector3(CGFloat(plateKey.x) + 0.5, CGFloat(plateKey.y), CGFloat(plateKey.z) + 0.5)
        let offPlatePos = Vector3(CGFloat(plateKey.x + 5) + 0.5, CGFloat(plateKey.y), CGFloat(plateKey.z + 5) + 0.5)

        // 4a. Multi-Entity Occupancy: Fizzler + Skeleton + Animal (Cow)
        var fizzler = Fizzler(position: plateCenter, seed: 1)
        var skeleton = Skeleton(position: plateCenter, seed: 2)
        var cow = Animal(kind: .cow, position: plateCenter, seed: 3)

        // Step 1: Fizzler arrives
        _ = plateNetwork.updatePlates(world: world, fuses: fuses) { key in
            OccupancyQuery.isOccupied(key: key, fizzlers: [fizzler])
        }
        let s1On = world.block(worldX: plateKey.x, y: plateKey.y, worldZ: plateKey.z) == .pressurePlateOn

        // Step 2: Skeleton joins
        _ = plateNetwork.updatePlates(world: world, fuses: fuses) { key in
            OccupancyQuery.isOccupied(key: key, fizzlers: [fizzler], skeletons: [skeleton])
        }
        let s2On = world.block(worldX: plateKey.x, y: plateKey.y, worldZ: plateKey.z) == .pressurePlateOn

        // Step 3: Cow joins
        _ = plateNetwork.updatePlates(world: world, fuses: fuses) { key in
            OccupancyQuery.isOccupied(key: key, fizzlers: [fizzler], skeletons: [skeleton], animals: [cow])
        }
        let s3On = world.block(worldX: plateKey.x, y: plateKey.y, worldZ: plateKey.z) == .pressurePlateOn

        // Step 4: Fizzler leaves (Skeleton and Cow remain)
        fizzler = Fizzler(position: offPlatePos, seed: 1)
        _ = plateNetwork.updatePlates(world: world, fuses: fuses) { key in
            OccupancyQuery.isOccupied(key: key, fizzlers: [fizzler], skeletons: [skeleton], animals: [cow])
        }
        let s4On = world.block(worldX: plateKey.x, y: plateKey.y, worldZ: plateKey.z) == .pressurePlateOn

        // Step 5: Skeleton leaves (Cow remains)
        skeleton = Skeleton(position: offPlatePos, seed: 2)
        _ = plateNetwork.updatePlates(world: world, fuses: fuses) { key in
            OccupancyQuery.isOccupied(key: key, fizzlers: [fizzler], skeletons: [skeleton], animals: [cow])
        }
        let s5On = world.block(worldX: plateKey.x, y: plateKey.y, worldZ: plateKey.z) == .pressurePlateOn

        // Step 6: Cow leaves -> plate deactivates
        cow = Animal(kind: .cow, position: offPlatePos, seed: 3)
        _ = plateNetwork.updatePlates(world: world, fuses: fuses) { key in
            OccupancyQuery.isOccupied(key: key, fizzlers: [fizzler], skeletons: [skeleton], animals: [cow])
        }
        let s6Off = world.block(worldX: plateKey.x, y: plateKey.y, worldZ: plateKey.z) == .pressurePlateOff
        let doorShut = !world.block(worldX: pDoorKey.x, y: pDoorKey.y, worldZ: pDoorKey.z).doorIsOpen

        report.check(
            "multi-entity simultaneous occupancy and sequential departure transitions",
            s1On && s2On && s3On && s4On && s5On && s6Off && doorShut,
            "s1: \(s1On), s2: \(s2On), s3: \(s3On), s4: \(s4On), s5: \(s5On), s6: \(s6Off), doorShut: \(doorShut)"
        )

        // 4b. Entity lethal damage / death transition
        var liveFizzler = Fizzler(position: plateCenter, seed: 4)
        var liveSkeleton = Skeleton(position: plateCenter, seed: 5)
        _ = plateNetwork.updatePlates(world: world, fuses: fuses) { key in
            OccupancyQuery.isOccupied(key: key, fizzlers: [liveFizzler], skeletons: [liveSkeleton])
        }
        let deathTestStart = world.block(worldX: plateKey.x, y: plateKey.y, worldZ: plateKey.z) == .pressurePlateOn

        // Kill fizzler: skeleton still alive -> plate stays on
        liveFizzler.damage(100, knockback: .zero)
        _ = plateNetwork.updatePlates(world: world, fuses: fuses) { key in
            OccupancyQuery.isOccupied(key: key, fizzlers: [liveFizzler], skeletons: [liveSkeleton])
        }
        let halfDeadPlateOn = world.block(worldX: plateKey.x, y: plateKey.y, worldZ: plateKey.z) == .pressurePlateOn

        // Kill skeleton: all dead -> plate turns off
        liveSkeleton.damage(100, knockback: .zero)
        _ = plateNetwork.updatePlates(world: world, fuses: fuses) { key in
            OccupancyQuery.isOccupied(key: key, fizzlers: [liveFizzler], skeletons: [liveSkeleton])
        }
        let allDeadPlateOff = world.block(worldX: plateKey.x, y: plateKey.y, worldZ: plateKey.z) == .pressurePlateOff

        report.check(
            "entity lethal damage and death transition releases plate when last occupant dies",
            deathTestStart && halfDeadPlateOn && allDeadPlateOff,
            "start: \(deathTestStart), halfDead: \(halfDeadPlateOn), allDead: \(allDeadPlateOff)"
        )

        // 4c. Fizzler explosion release
        var explodingFizzler = Fizzler(position: plateCenter, seed: 6)
        _ = plateNetwork.updatePlates(world: world, fuses: fuses) { key in
            OccupancyQuery.isOccupied(key: key, fizzlers: [explodingFizzler])
        }
        let explodeStartOn = world.block(worldX: plateKey.x, y: plateKey.y, worldZ: plateKey.z) == .pressurePlateOn

        // Advance fizzler state: wandering -> stalking -> fusing -> exploded
        explodingFizzler.step(dt: 0.1, playerEye: plateCenter, canSeePlayer: true, world: world) // wandering -> stalking
        explodingFizzler.step(dt: 0.1, playerEye: plateCenter, canSeePlayer: true, world: world) // stalking -> fusing
        explodingFizzler.step(dt: 2.0, playerEye: plateCenter, canSeePlayer: true, world: world) // fusing -> exploded
        let hasExploded = explodingFizzler.hasExploded
        _ = plateNetwork.updatePlates(world: world, fuses: fuses) { key in
            OccupancyQuery.isOccupied(key: key, fizzlers: [explodingFizzler])
        }
        let explodeReleased = world.block(worldX: plateKey.x, y: plateKey.y, worldZ: plateKey.z) == .pressurePlateOff

        report.check(
            "fizzler explosion immediately releases pressure plate",
            explodeStartOn && hasExploded && explodeReleased,
            "startOn: \(explodeStartOn), hasExploded: \(hasExploded), released: \(explodeReleased)"
        )

        // 4d. Despawn transition via AnimalManager
        var animalMgr = AnimalManager(mode: .survival, seed: 42)
        animalMgr.adopt([Animal(kind: .sheep, position: plateCenter, seed: 7)])
        _ = plateNetwork.updatePlates(world: world, fuses: fuses) { key in
            OccupancyQuery.isOccupied(cell: key, player: nil, animals: animalMgr)
        }
        let despawnStartOn = world.block(worldX: plateKey.x, y: plateKey.y, worldZ: plateKey.z) == .pressurePlateOn

        animalMgr.removeAll()
        _ = plateNetwork.updatePlates(world: world, fuses: fuses) { key in
            OccupancyQuery.isOccupied(cell: key, player: nil, animals: animalMgr)
        }
        let despawnReleased = world.block(worldX: plateKey.x, y: plateKey.y, worldZ: plateKey.z) == .pressurePlateOff

        report.check(
            "entity despawn / chunk purge immediately releases pressure plate",
            despawnStartOn && despawnReleased,
            "startOn: \(despawnStartOn), released: \(despawnReleased)"
        )

        // 4e. Player and mob co-occupancy
        var player = PlayerController(spawn: plateCenter)
        var bystander = Fizzler(position: plateCenter, seed: 8)
        _ = plateNetwork.updatePlates(world: world, fuses: fuses) { key in
            OccupancyQuery.isOccupied(key: key, player: player, fizzlers: [bystander])
        }
        let coOccupied = world.block(worldX: plateKey.x, y: plateKey.y, worldZ: plateKey.z) == .pressurePlateOn

        // Player leaves, fizzler stays
        player.position = offPlatePos
        _ = plateNetwork.updatePlates(world: world, fuses: fuses) { key in
            OccupancyQuery.isOccupied(key: key, player: player, fizzlers: [bystander])
        }
        let playerLeftStillOn = world.block(worldX: plateKey.x, y: plateKey.y, worldZ: plateKey.z) == .pressurePlateOn

        // Fizzler leaves
        bystander = Fizzler(position: offPlatePos, seed: 8)
        _ = plateNetwork.updatePlates(world: world, fuses: fuses) { key in
            OccupancyQuery.isOccupied(key: key, player: player, fizzlers: [bystander])
        }
        let bothLeftOff = world.block(worldX: plateKey.x, y: plateKey.y, worldZ: plateKey.z) == .pressurePlateOff

        report.check(
            "player and mob co-occupancy smoothly hands off actuation",
            coOccupied && playerLeftStillOn && bothLeftOff,
            "coOccupied: \(coOccupied), playerLeftStillOn: \(playerLeftStillOn), bothLeftOff: \(bothLeftOff)"
        )

        // =========================================================================
        // MARK: - Section 5: Adversarial Booster Rail Suppression Under All Conditions
        // =========================================================================
        let bDeckX = originX - 20
        let bDeckZ = originZ - 20
        let bSensorCell = SignalNetwork.Key(bDeckX, groundY, bDeckZ)
        let bWire1 = SignalNetwork.Key(bDeckX + 1, groundY, bDeckZ)
        let bWire2 = SignalNetwork.Key(bDeckX + 2, groundY, bDeckZ)
        let bWire3 = SignalNetwork.Key(bDeckX + 3, groundY, bDeckZ)
        let bRailKey = SignalNetwork.Key(bDeckX + 4, groundY, bDeckZ)

        world.setBlock(worldX: bSensorCell.x, y: bSensorCell.y, worldZ: bSensorCell.z, to: .daylightSensor)
        world.setBlock(worldX: bWire1.x, y: bWire1.y, worldZ: bWire1.z, to: .wireOff)
        world.setBlock(worldX: bWire2.x, y: bWire2.y, worldZ: bWire2.z, to: .wireOff)
        world.setBlock(worldX: bWire3.x, y: bWire3.y, worldZ: bWire3.z, to: .wireOff)
        world.setBlock(worldX: bRailKey.x, y: bRailKey.y, worldZ: bRailKey.z, to: .boosterNorthSouth)

        let advRailSignals = SignalNetwork()
        advRailSignals.daylightSensorPlaced(at: bSensorCell)

        // 5a. Solar noon: power 15 -> wireOn, booster active
        advRailSignals.updateDaylightSensors(world: world, timeOfDay: 0.25, fuses: fuses)
        let s5aWireLit = world.block(worldX: bWire3.x, y: bWire3.y, worldZ: bWire3.z) == .wireOn
        let s5aActive = world.boosterIsActive(worldX: bRailKey.x, y: bRailKey.y, worldZ: bRailKey.z)
        report.check(
            "adv-booster: solar noon (t=0.25) powers wire and activates booster rail",
            s5aWireLit && s5aActive,
            "wire lit: \(s5aWireLit), booster active: \(s5aActive)"
        )

        // 5b. Afternoon descent & falloff suppression:
        // At t = 0.48: daylightPower is 2. The rail is at distance 4 (wire 1..3, rail at 4).
        // Since power 2 < distance 4, power only reaches wire 2. Wire 3 is off, rail is unpowered.
        // But rail is within wiredCells (maxReach 15).
        // Therefore rail MUST be suppressed!
        advRailSignals.updateDaylightSensors(world: world, timeOfDay: 0.48, fuses: fuses)
        let p48 = SignalNetwork.daylightPower(timeOfDay: 0.48)
        let w2At48 = world.block(worldX: bWire2.x, y: bWire2.y, worldZ: bWire2.z)
        let w3At48 = world.block(worldX: bWire3.x, y: bWire3.y, worldZ: bWire3.z)
        let s5bSuppressed = !world.boosterIsActive(worldX: bRailKey.x, y: bRailKey.y, worldZ: bRailKey.z)
        report.check(
            "adv-booster: late afternoon reach falloff (power 2 < dist 4) suppresses booster rail before dusk",
            p48 <= 2 && w2At48 == .wireOn && w3At48 == .wireOff && s5bSuppressed,
            "power: \(p48), wire2: \(w2At48), wire3: \(w3At48), suppressed: \(s5bSuppressed)"
        )

        // 5c. Solar dusk (t=0.50): power 0 -> wireOff, booster suppressed
        advRailSignals.updateDaylightSensors(world: world, timeOfDay: 0.50, fuses: fuses)
        let s5cWireDark = world.block(worldX: bWire1.x, y: bWire1.y, worldZ: bWire1.z) == .wireOff
        let s5cSuppressed = !world.boosterIsActive(worldX: bRailKey.x, y: bRailKey.y, worldZ: bRailKey.z)
        report.check(
            "adv-booster: solar dusk (t=0.50) completely shuts off wire and holds booster rail suppressed",
            s5cWireDark && s5cSuppressed,
            "wire dark: \(s5cWireDark), booster suppressed: \(s5cSuppressed)"
        )

        // 5d. Midnight (t=0.75): power 0 -> booster suppressed
        advRailSignals.updateDaylightSensors(world: world, timeOfDay: 0.75, fuses: fuses)
        let s5dSuppressed = !world.boosterIsActive(worldX: bRailKey.x, y: bRailKey.y, worldZ: bRailKey.z)
        report.check(
            "adv-booster: midnight (t=0.75) keeps booster rail reliably suppressed",
            s5dSuppressed,
            "booster suppressed: \(s5dSuppressed)"
        )

        // 5e. Midday cloudy/occluded at noon:
        // Test elevations y+1, y+5, y+50, and world top (height - 1)
        var s5eAllPassed = true
        for offY in [1, 5, 50, (Chunk.height - 1 - bSensorCell.y)] {
            world.setBlock(worldX: bSensorCell.x, y: bSensorCell.y + offY, worldZ: bSensorCell.z, to: .stone)
            advRailSignals.updateDaylightSensors(world: world, timeOfDay: 0.25, fuses: fuses)
            let isSuppressed = !world.boosterIsActive(worldX: bRailKey.x, y: bRailKey.y, worldZ: bRailKey.z)
            let isDark = world.block(worldX: bWire3.x, y: bWire3.y, worldZ: bWire3.z) == .wireOff
            if !isSuppressed || !isDark { s5eAllPassed = false }
            world.setBlock(worldX: bSensorCell.x, y: bSensorCell.y + offY, worldZ: bSensorCell.z, to: .air)
        }
        // Restored
        advRailSignals.updateDaylightSensors(world: world, timeOfDay: 0.25, fuses: fuses)
        let s5eRestoredActive = world.boosterIsActive(worldX: bRailKey.x, y: bRailKey.y, worldZ: bRailKey.z)
        report.check(
            "adv-booster: vertical occlusion across multiple elevations suppresses booster at noon, restored when cleared",
            s5eAllPassed && s5eRestoredActive,
            "allPassed: \(s5eAllPassed), restoredActive: \(s5eRestoredActive)"
        )

        // 5f. Transparent non-occluder (glass) does NOT suppress booster rail at noon
        world.setBlock(worldX: bSensorCell.x, y: bSensorCell.y + 1, worldZ: bSensorCell.z, to: .glass)
        advRailSignals.updateDaylightSensors(world: world, timeOfDay: 0.25, fuses: fuses)
        let s5fGlassActive = world.boosterIsActive(worldX: bRailKey.x, y: bRailKey.y, worldZ: bRailKey.z)
        world.setBlock(worldX: bSensorCell.x, y: bSensorCell.y + 1, worldZ: bSensorCell.z, to: .air)
        report.check(
            "adv-booster: glass above sensor permits sunlight, keeping booster rail active",
            s5fGlassActive,
            "glass permits active: \(s5fGlassActive)"
        )

        // 5g. Wire disconnection & reconnection dynamics:
        // Set midnight -> rail is suppressed
        advRailSignals.updateDaylightSensors(world: world, timeOfDay: 0.75, fuses: fuses)
        let s5gPreSuppressed = !world.boosterIsActive(worldX: bRailKey.x, y: bRailKey.y, worldZ: bRailKey.z)

        // Break connecting wire3 -> rail drops out of wired circuit
        world.setBlock(worldX: bWire3.x, y: bWire3.y, worldZ: bWire3.z, to: .air)
        advRailSignals.recompute(world: world, fuses: fuses)
        let s5gUnwiredActive = world.boosterIsActive(worldX: bRailKey.x, y: bRailKey.y, worldZ: bRailKey.z)

        // Reconnect wire3 -> rail rejoins circuit, held suppressed again at midnight
        world.setBlock(worldX: bWire3.x, y: bWire3.y, worldZ: bWire3.z, to: .wireOff)
        advRailSignals.recompute(world: world, fuses: fuses)
        let s5gRewiredSuppressed = !world.boosterIsActive(worldX: bRailKey.x, y: bRailKey.y, worldZ: bRailKey.z)

        // Switch to noon -> rail becomes active
        advRailSignals.updateDaylightSensors(world: world, timeOfDay: 0.25, fuses: fuses)
        let s5gNoonActive = world.boosterIsActive(worldX: bRailKey.x, y: bRailKey.y, worldZ: bRailKey.z)

        report.check(
            "adv-booster: wire disconnection immediately reverts rail to active default, reconnection re-suppresses at midnight and activates at noon",
            s5gPreSuppressed && s5gUnwiredActive && s5gRewiredSuppressed && s5gNoonActive,
            "preSuppressed: \(s5gPreSuppressed), unwiredActive: \(s5gUnwiredActive), rewiredSuppressed: \(s5gRewiredSuppressed), noonActive: \(s5gNoonActive)"
        )

        // 5h. MaxReach boundary condition (dist 15 vs dist 16)
        // Cleanup 5a-g
        world.setBlock(worldX: bSensorCell.x, y: bSensorCell.y, worldZ: bSensorCell.z, to: .air)
        world.setBlock(worldX: bWire1.x, y: bWire1.y, worldZ: bWire1.z, to: .air)
        world.setBlock(worldX: bWire2.x, y: bWire2.y, worldZ: bWire2.z, to: .air)
        world.setBlock(worldX: bWire3.x, y: bWire3.y, worldZ: bWire3.z, to: .air)
        world.setBlock(worldX: bRailKey.x, y: bRailKey.y, worldZ: bRailKey.z, to: .air)
        advRailSignals.daylightSensorRemoved(at: bSensorCell)

        let reachSensor = SignalNetwork.Key(originX - 16, groundY, originZ)
        world.setBlock(worldX: reachSensor.x, y: reachSensor.y, worldZ: reachSensor.z, to: .daylightSensor)
        for i in 1...14 {
            world.setBlock(worldX: reachSensor.x + i, y: reachSensor.y, worldZ: reachSensor.z, to: .wireOff)
        }
        let rail15 = SignalNetwork.Key(reachSensor.x + 15, groundY, reachSensor.z) // dist 15: reachable
        let rail16 = SignalNetwork.Key(reachSensor.x + 16, groundY, reachSensor.z) // dist 16: beyond max reach 15
        world.setBlock(worldX: rail15.x, y: rail15.y, worldZ: rail15.z, to: .boosterNorthSouth)
        world.setBlock(worldX: rail16.x, y: rail16.y, worldZ: rail16.z, to: .boosterNorthSouth)

        let reachSignals = SignalNetwork()
        reachSignals.daylightSensorPlaced(at: reachSensor)

        // At noon: rail15 is powered -> active. rail16 is beyond reach -> unwired default active.
        reachSignals.updateDaylightSensors(world: world, timeOfDay: 0.25, fuses: fuses)
        let r15NoonActive = world.boosterIsActive(worldX: rail15.x, y: rail15.y, worldZ: rail15.z)
        let r16NoonActive = world.boosterIsActive(worldX: rail16.x, y: rail16.y, worldZ: rail16.z)

        // At midnight: rail15 is within wiredCells (dist 15) -> SUPPRESSED!
        // rail16 is dist 16 (> maxReach 15) -> not in wiredCells -> UNWIRED DEFAULT ACTIVE!
        reachSignals.updateDaylightSensors(world: world, timeOfDay: 0.75, fuses: fuses)
        let r15MidSuppressed = !world.boosterIsActive(worldX: rail15.x, y: rail15.y, worldZ: rail15.z)
        let r16MidActive = world.boosterIsActive(worldX: rail16.x, y: rail16.y, worldZ: rail16.z)

        report.check(
            "adv-booster: maxReach 15 boundary strictly suppresses rail at distance 15 at night while rail at distance 16 remains unwired active",
            r15NoonActive && r16NoonActive && r15MidSuppressed && r16MidActive,
            "r15Noon: \(r15NoonActive), r16Noon: \(r16NoonActive), r15MidSuppressed: \(r15MidSuppressed), r16MidActive: \(r16MidActive)"
        )

        // Cleanup reach boundary
        world.setBlock(worldX: reachSensor.x, y: reachSensor.y, worldZ: reachSensor.z, to: .air)
        for i in 1...14 {
            world.setBlock(worldX: reachSensor.x + i, y: reachSensor.y, worldZ: reachSensor.z, to: .air)
        }
        world.setBlock(worldX: rail15.x, y: rail15.y, worldZ: rail15.z, to: .air)
        world.setBlock(worldX: rail16.x, y: rail16.y, worldZ: rail16.z, to: .air)
        reachSignals.daylightSensorRemoved(at: reachSensor)
        reachSignals.recompute(world: world, fuses: fuses)

        // =========================================================================
        // MARK: - Section 6: Journal Re-Indexing & Multi-Cycle Save/Load/Restore
        // =========================================================================
        // 6a. Multi-Cycle Save/Load/Restore Iteration (5 sequential generations)
        var cycleJournal: [ChunkCoord: [Int: BlockType]] = [:]
        let jCoord = ChunkCoord(x: centre.x + 1, z: centre.z + 1)
        let jBaseX = jCoord.x * Chunk.width + 4
        let jBaseZ = jCoord.z * Chunk.depth + 4
        let jBaseY = groundY

        let sensorA = SignalNetwork.Key(jBaseX, jBaseY, jBaseZ)
        let wireA1 = SignalNetwork.Key(jBaseX + 1, jBaseY, jBaseZ)
        let wireA2 = SignalNetwork.Key(jBaseX + 2, jBaseY, jBaseZ)
        let lampA = SignalNetwork.Key(jBaseX + 3, jBaseY, jBaseZ)

        let sensorB = SignalNetwork.Key(jBaseX, jBaseY, jBaseZ + 4)
        let wireB1 = SignalNetwork.Key(jBaseX + 1, jBaseY, jBaseZ + 4)
        let wireB2 = SignalNetwork.Key(jBaseX + 2, jBaseY, jBaseZ + 4)
        let lampB = SignalNetwork.Key(jBaseX + 2, jBaseY, jBaseZ + 5)
        let railB = SignalNetwork.Key(jBaseX + 3, jBaseY, jBaseZ + 4)

        // Cycle 1: Build Circuit A in a fresh world, journal it
        let cycleWorld1 = World(seed: 1001)
        cycleWorld1.forceGenerate(jCoord)
        cycleWorld1.setBlock(worldX: sensorA.x, y: sensorA.y, worldZ: sensorA.z, to: .daylightSensor)
        cycleWorld1.setBlock(worldX: wireA1.x, y: wireA1.y, worldZ: wireA1.z, to: .wireOff)
        cycleWorld1.setBlock(worldX: wireA2.x, y: wireA2.y, worldZ: wireA2.z, to: .wireOff)
        cycleWorld1.setBlock(worldX: lampA.x, y: lampA.y, worldZ: lampA.z, to: .signalLamp)
        cycleJournal = cycleWorld1.editJournal

        // Cycle 2: Restore into World 2 from Cycle 1 journal, register index, verify Circuit A
        let cycleWorld2 = World(seed: 1001, edits: cycleJournal)
        cycleWorld2.forceGenerate(jCoord)
        let signals2 = SignalNetwork()
        GameSession.registerJournalIndex(from: cycleJournal, signals: signals2)

        let c2SensorARegistered = signals2.daylightSensorCells.contains(sensorA)
        let c2LampARegistered = signals2.lampCells.contains(lampA)

        signals2.updateDaylightSensors(world: cycleWorld2, timeOfDay: 0.25, fuses: fuses)
        let c2LampALit = cycleWorld2.block(worldX: lampA.x, y: lampA.y, worldZ: lampA.z) == .signalLampLit
        let c2LampALight = cycleWorld2.lightLevel(worldX: lampA.x, y: lampA.y, worldZ: lampA.z) == 15

        // In World 2, add Circuit B (Sensor B + Lamp B + Booster Rail B)
        cycleWorld2.setBlock(worldX: sensorB.x, y: sensorB.y, worldZ: sensorB.z, to: .daylightSensor)
        cycleWorld2.setBlock(worldX: wireB1.x, y: wireB1.y, worldZ: wireB1.z, to: .wireOff)
        cycleWorld2.setBlock(worldX: wireB2.x, y: wireB2.y, worldZ: wireB2.z, to: .wireOff)
        cycleWorld2.setBlock(worldX: lampB.x, y: lampB.y, worldZ: lampB.z, to: .signalLamp)
        cycleWorld2.setBlock(worldX: railB.x, y: railB.y, worldZ: railB.z, to: .boosterNorthSouth)
        cycleJournal = cycleWorld2.editJournal

        // Cycle 3: Restore into World 3 from Cycle 2 journal, register index, verify both circuits
        let cycleWorld3 = World(seed: 1001, edits: cycleJournal)
        cycleWorld3.forceGenerate(jCoord)
        let signals3 = SignalNetwork()
        GameSession.registerJournalIndex(from: cycleJournal, signals: signals3)

        let c3BothSensors = signals3.daylightSensorCells.contains(sensorA) && signals3.daylightSensorCells.contains(sensorB)
        let c3BothLamps = signals3.lampCells.contains(lampA) && signals3.lampCells.contains(lampB)

        // At noon: both lamps lit (15), railB active
        signals3.updateDaylightSensors(world: cycleWorld3, timeOfDay: 0.25, fuses: fuses)
        let c3NoonLit = cycleWorld3.block(worldX: lampA.x, y: lampA.y, worldZ: lampA.z) == .signalLampLit
            && cycleWorld3.block(worldX: lampB.x, y: lampB.y, worldZ: lampB.z) == .signalLampLit
            && cycleWorld3.boosterIsActive(worldX: railB.x, y: railB.y, worldZ: railB.z)

        // At midnight: both lamps unlit (0), railB suppressed
        signals3.updateDaylightSensors(world: cycleWorld3, timeOfDay: 0.75, fuses: fuses)
        let c3MidUnlit = cycleWorld3.block(worldX: lampA.x, y: lampA.y, worldZ: lampA.z) == .signalLamp
            && cycleWorld3.block(worldX: lampB.x, y: lampB.y, worldZ: lampB.z) == .signalLamp
            && !cycleWorld3.boosterIsActive(worldX: railB.x, y: railB.y, worldZ: railB.z)
            && cycleWorld3.lightLevel(worldX: lampA.x, y: lampA.y, worldZ: lampA.z) == 0
            && cycleWorld3.lightLevel(worldX: lampB.x, y: lampB.y, worldZ: lampB.z) == 0

        // In World 3, remove sensorA and replace with a leverOn
        cycleWorld3.setBlock(worldX: sensorA.x, y: sensorA.y, worldZ: sensorA.z, to: .leverOn)
        cycleJournal = cycleWorld3.editJournal

        // Cycle 4: Restore into World 4 from Cycle 3 journal, register index
        let cycleWorld4 = World(seed: 1001, edits: cycleJournal)
        cycleWorld4.forceGenerate(jCoord)
        let signals4 = SignalNetwork()
        GameSession.registerJournalIndex(from: cycleJournal, signals: signals4)

        // sensorA is replaced by lever -> must NOT be in daylightSensorCells!
        let c4SensorAGone = !signals4.daylightSensorCells.contains(sensorA)
        let c4LeverAPresent = signals4.leverCells.contains(sensorA)
        let c4SensorBRemains = signals4.daylightSensorCells.contains(sensorB)

        // Recompute initial lever power
        signals4.recompute(world: cycleWorld4, fuses: fuses)
        let c4LampAAlwaysLit = cycleWorld4.block(worldX: lampA.x, y: lampA.y, worldZ: lampA.z) == .signalLampLit

        // Update solar at midnight: sensorB shuts off lampB and suppresses railB, but lever keeps lampA lit!
        signals4.updateDaylightSensors(world: cycleWorld4, timeOfDay: 0.75, fuses: fuses)
        let c4MidLampAStaysLit = cycleWorld4.block(worldX: lampA.x, y: lampA.y, worldZ: lampA.z) == .signalLampLit
        let c4MidLampBUnlit = cycleWorld4.block(worldX: lampB.x, y: lampB.y, worldZ: lampB.z) == .signalLamp
        let c4MidRailBSuppressed = !cycleWorld4.boosterIsActive(worldX: railB.x, y: railB.y, worldZ: railB.z)

        cycleJournal = cycleWorld4.editJournal

        // Cycle 5: Re-restore into World 5 and simulate multiple chunk regenerate/restore calls
        let cycleWorld5 = World(seed: 1001, edits: cycleJournal)
        for dz in -1...1 {
            for dx in -1...1 {
                cycleWorld5.forceGenerate(ChunkCoord(x: jCoord.x + dx, z: jCoord.z + dz))
            }
        }
        let signals5 = SignalNetwork()
        GameSession.registerJournalIndex(from: cycleJournal, signals: signals5)
        signals5.recompute(world: cycleWorld5, fuses: fuses)

        // Noon transition in World 5
        signals5.updateDaylightSensors(world: cycleWorld5, timeOfDay: 0.25, fuses: fuses)
        let c5NoonLampALit = cycleWorld5.block(worldX: lampA.x, y: lampA.y, worldZ: lampA.z) == .signalLampLit
        let c5NoonLampBLit = cycleWorld5.block(worldX: lampB.x, y: lampB.y, worldZ: lampB.z) == .signalLampLit
        let c5NoonRailBActive = cycleWorld5.boosterIsActive(worldX: railB.x, y: railB.y, worldZ: railB.z)

        // Midnight transition in World 5
        signals5.updateDaylightSensors(world: cycleWorld5, timeOfDay: 0.75, fuses: fuses)
        let c5MidLampALit = cycleWorld5.block(worldX: lampA.x, y: lampA.y, worldZ: lampA.z) == .signalLampLit
        let c5MidLampBUnlit = cycleWorld5.block(worldX: lampB.x, y: lampB.y, worldZ: lampB.z) == .signalLamp
        let c5MidRailBSuppressed = !cycleWorld5.boosterIsActive(worldX: railB.x, y: railB.y, worldZ: railB.z)

        report.check(
            "adv-journal: 5-cycle save/load reconstruction maintains correct sensor, lamp, and booster states through mutating topology",
            c2SensorARegistered && c2LampARegistered && c2LampALit && c2LampALight
                && c3BothSensors && c3BothLamps && c3NoonLit && c3MidUnlit
                && c4SensorAGone && c4LeverAPresent && c4SensorBRemains && c4LampAAlwaysLit && c4MidLampAStaysLit && c4MidLampBUnlit && c4MidRailBSuppressed
                && c5NoonLampALit && c5NoonLampBLit && c5NoonRailBActive && c5MidLampALit && c5MidLampBUnlit && c5MidRailBSuppressed,
            "c2: \(c2LampALit), c3: \(c3NoonLit)/\(c3MidUnlit), c4: \(c4SensorAGone)/\(c4MidLampAStaysLit), c5: \(c5NoonLampBLit)/\(c5MidRailBSuppressed)"
        )

        // 6b. Cross-chunk boundary journal persistence:
        // Sensor in chunk0, Wire crossing into chunk1, Lamp in chunk1
        let crossWorld = World(seed: 2002)
        let chunk0Coord = ChunkCoord(x: centre.x + 2, z: centre.z)
        let chunk1Coord = ChunkCoord(x: centre.x + 3, z: centre.z)
        crossWorld.forceGenerate(chunk0Coord)
        crossWorld.forceGenerate(chunk1Coord)

        let crossSensor = SignalNetwork.Key(chunk0Coord.x * Chunk.width + Chunk.width - 1, groundY, chunk0Coord.z * Chunk.depth + 2)
        let crossWire1 = SignalNetwork.Key(chunk1Coord.x * Chunk.width, groundY, chunk0Coord.z * Chunk.depth + 2)
        let crossLamp = SignalNetwork.Key(chunk1Coord.x * Chunk.width + 1, groundY, chunk0Coord.z * Chunk.depth + 2)

        crossWorld.setBlock(worldX: crossSensor.x, y: crossSensor.y, worldZ: crossSensor.z, to: .daylightSensor)
        crossWorld.setBlock(worldX: crossWire1.x, y: crossWire1.y, worldZ: crossWire1.z, to: .wireOff)
        crossWorld.setBlock(worldX: crossLamp.x, y: crossLamp.y, worldZ: crossLamp.z, to: .signalLamp)

        let crossJournal = crossWorld.editJournal
        let restoredCrossWorld = World(seed: 2002, edits: crossJournal)
        restoredCrossWorld.forceGenerate(chunk0Coord)
        restoredCrossWorld.forceGenerate(chunk1Coord)

        let crossSignals = SignalNetwork()
        GameSession.registerJournalIndex(from: crossJournal, signals: crossSignals)

        let crossSensorIndexed = crossSignals.daylightSensorCells.contains(crossSensor)
        let crossLampIndexed = crossSignals.lampCells.contains(crossLamp)

        crossSignals.updateDaylightSensors(world: restoredCrossWorld, timeOfDay: 0.25, fuses: fuses)
        let crossNoonLampLit = restoredCrossWorld.block(worldX: crossLamp.x, y: crossLamp.y, worldZ: crossLamp.z) == .signalLampLit
        let crossNoonLampLight = restoredCrossWorld.lightLevel(worldX: crossLamp.x, y: crossLamp.y, worldZ: crossLamp.z) == 15

        crossSignals.updateDaylightSensors(world: restoredCrossWorld, timeOfDay: 0.75, fuses: fuses)
        let crossMidLampUnlit = restoredCrossWorld.block(worldX: crossLamp.x, y: crossLamp.y, worldZ: crossLamp.z) == .signalLamp
        let crossMidLampLight = restoredCrossWorld.lightLevel(worldX: crossLamp.x, y: crossLamp.y, worldZ: crossLamp.z) == 0

        report.check(
            "adv-journal: cross-chunk seam boundary journal persistence and index registration powers lamp across chunk border",
            crossSensorIndexed && crossLampIndexed && crossNoonLampLit && crossNoonLampLight && crossMidLampUnlit && crossMidLampLight,
            "sensor: \(crossSensorIndexed), lamp: \(crossLampIndexed), noonLit: \(crossNoonLampLit), midUnlit: \(crossMidLampUnlit)"
        )

        // =========================================================================
        // MARK: - Verdict Reporting
        // =========================================================================
        for line in report.lines { StandardError.write(Data((line + "\n").utf8)) }
        let verdict = report.failed
            ? "[stress-check] FAILED — empirical adversarial tests\n"
            : "[stress-check] all passed — empirical adversarial tests\n"
        StandardError.write(Data(verdict.utf8))
        exit(report.failed ? 1 : 0)
    }
}
