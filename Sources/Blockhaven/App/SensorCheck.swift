import Foundation

/// Headless verification proof of Milestone 1: Environmental Sensing & Active Signal Lighting.
///
/// Validates:
/// 1. Daylight Sensor solar power emission at solar noon (powering wire, door, lamp).
/// 2. Daylight Sensor power drop to 0 at midnight (sky.isNight == true).
/// 3. Daylight Sensor vertical occlusion gating (0 power under opaque block at y+1 / y+2).
/// 4. Signal Lamp state transitions (unlit 0 -> lit 15 -> unlit 0) with BlockLight propagation and unwinding.
/// 5. Universal Pressure Plate activation and deactivation by Fizzler and Animal entities, and manager adoption.
/// 6. Booster Rail suppression (held inert / braking) when wired to a daylight sensor at night or when occluded.
/// 7. World edit journal reconstruction and restoration of daylight sensors and signal lamps into SignalNetwork.
///
/// Run via `BLOCKHAVEN_CHECK_SENSOR=1`. Exits nonzero on failure.
enum SensorCheck {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["BLOCKHAVEN_CHECK_SENSOR"] != nil
    }

    private struct Report {
        var lines: [String] = []
        var failed = false

        mutating func check(_ name: String, _ passed: Bool, _ detail: String) {
            lines.append("[check] \(name): \(passed ? "ok" : "FAILED") — \(detail)")
            if !passed { failed = true }
        }
    }

    static func run() -> Never {
        var report = Report()
        let world = World(seed: 42)
        let spawn = world.spawnPosition()
        let centre = World.chunkCoord(forWorldX: Int(spawn.x), worldZ: Int(spawn.z))
        for dz in -2...2 {
            for dx in -2...2 {
                world.forceGenerate(ChunkCoord(x: centre.x + dx, z: centre.z + dz))
            }
        }

        // Establish an elevated test platform clear of all terrain occluders
        let originX = Int(spawn.x)
        let originZ = Int(spawn.z)
        var highest = 0
        for z in (originZ - 18)...(originZ + 18) {
            for x in (originX - 18)...(originX + 18) {
                var top = Chunk.height - 1
                while top > 0, !world.block(worldX: x, y: top, worldZ: z).isSolid { top -= 1 }
                highest = max(highest, top)
            }
        }
        let deckY = highest + 2
        let groundY = deckY + 1
        guard deckY + 10 < Chunk.height else {
            StandardError.write(Data("[check] insufficient vertical headroom\n".utf8))
            exit(2)
        }

        for z in (originZ - 18)...(originZ + 18) {
            for x in (originX - 18)...(originX + 18) {
                world.setBlock(worldX: x, y: deckY, worldZ: z, to: .stone, remesh: false)
                for y in groundY...(deckY + 8) {
                    world.setBlock(worldX: x, y: y, worldZ: z, to: .air, remesh: false)
                }
            }
        }

        let fuses = FuseManager()

        // =========================================================================
        // MARK: - Test 1: Daylight Sensor Solar Noon Power Emission
        // =========================================================================
        let sensorX = originX
        let sensorZ = originZ
        let sensorCell = (x: sensorX, y: groundY, z: sensorZ)
        let sensorKey = SignalNetwork.Key(sensorCell.x, sensorCell.y, sensorCell.z)

        world.setBlock(worldX: sensorCell.x, y: sensorCell.y, worldZ: sensorCell.z, to: .daylightSensor)
        for step in 1...3 {
            world.setBlock(worldX: sensorCell.x + step, y: sensorCell.y, worldZ: sensorCell.z, to: .wireOff)
        }
        let doorCell = (x: sensorCell.x + 4, y: sensorCell.y, z: sensorCell.z)
        world.setBlock(worldX: doorCell.x, y: doorCell.y, worldZ: doorCell.z,
                       to: .oakDoor(.lower, facing: .north, open: false))
        world.setBlock(worldX: doorCell.x, y: doorCell.y + 1, worldZ: doorCell.z,
                       to: .oakDoor(.upper, facing: .north, open: false))

        let noonLampCell = (x: sensorCell.x + 3, y: sensorCell.y, z: sensorCell.z + 1)
        let noonLampKey = SignalNetwork.Key(noonLampCell.x, noonLampCell.y, noonLampCell.z)
        world.setBlock(worldX: noonLampCell.x, y: noonLampCell.y, worldZ: noonLampCell.z, to: .signalLamp)

        let sensorSignals = SignalNetwork()
        sensorSignals.daylightSensorPlaced(at: sensorKey)
        sensorSignals.lampPlaced(at: noonLampKey)

        var sky = Sky(timeOfDay: 0.25, isRaining: false) // solar noon
        sensorSignals.updateDaylightSensors(world: world, fuses: fuses, sky: sky)

        let wireLitAtNoon = (1...3).allSatisfy {
            world.block(worldX: sensorCell.x + $0, y: sensorCell.y, worldZ: sensorCell.z) == .wireOn
        }
        let doorOpenAtNoon = world.block(worldX: doorCell.x, y: doorCell.y, worldZ: doorCell.z).doorIsOpen
            && world.block(worldX: doorCell.x, y: doorCell.y + 1, worldZ: doorCell.z).doorIsOpen
        let lampLitAtNoon = world.block(worldX: noonLampCell.x, y: noonLampCell.y, worldZ: noonLampCell.z) == .signalLampLit

        report.check(
            "daylight sensor emits power at solar noon, powering wire, door and lamp",
            wireLitAtNoon && doorOpenAtNoon && lampLitAtNoon,
            "wire lit: \(wireLitAtNoon), door open: \(doorOpenAtNoon), lamp: \(world.block(worldX: noonLampCell.x, y: noonLampCell.y, worldZ: noonLampCell.z))"
        )

        // =========================================================================
        // MARK: - Test 2: Daylight Sensor Power Drops to 0 at Midnight
        // =========================================================================
        sky.dayFraction = 0.75 // midnight
        let isNightTime = sky.isNight
        sensorSignals.updateDaylightSensors(world: world, fuses: fuses, sky: sky)

        let wireDarkAtMidnight = (1...3).allSatisfy {
            world.block(worldX: sensorCell.x + $0, y: sensorCell.y, worldZ: sensorCell.z) == .wireOff
        }
        let doorShutAtMidnight = !world.block(worldX: doorCell.x, y: doorCell.y, worldZ: doorCell.z).doorIsOpen
            && !world.block(worldX: doorCell.x, y: doorCell.y + 1, worldZ: doorCell.z).doorIsOpen
        let lampUnlitAtMidnight = world.block(worldX: noonLampCell.x, y: noonLampCell.y, worldZ: noonLampCell.z) == .signalLamp

        report.check(
            "daylight sensor power drops to 0 at midnight",
            isNightTime && wireDarkAtMidnight && doorShutAtMidnight && lampUnlitAtMidnight,
            "isNight: \(isNightTime), wire dark: \(wireDarkAtMidnight), door shut: \(doorShutAtMidnight), lamp unlit: \(lampUnlitAtMidnight)"
        )

        // =========================================================================
        // MARK: - Test 3: Daylight Sensor Vertical Occlusion Gating
        // =========================================================================
        sky.dayFraction = 0.25 // reset to solar noon

        // Test occlusion at y + 1
        world.setBlock(worldX: sensorCell.x, y: sensorCell.y + 1, worldZ: sensorCell.z, to: .stone)
        sensorSignals.updateDaylightSensors(world: world, fuses: fuses, sky: sky)

        let skyBlockedY1 = !world.isSkyOpen(worldX: sensorCell.x, y: sensorCell.y, worldZ: sensorCell.z)
        let wireDarkY1 = (1...3).allSatisfy {
            world.block(worldX: sensorCell.x + $0, y: sensorCell.y, worldZ: sensorCell.z) == .wireOff
        }

        // Test occlusion at y + 2
        world.setBlock(worldX: sensorCell.x, y: sensorCell.y + 1, worldZ: sensorCell.z, to: .air)
        world.setBlock(worldX: sensorCell.x, y: sensorCell.y + 2, worldZ: sensorCell.z, to: .stone)
        sensorSignals.updateDaylightSensors(world: world, fuses: fuses, sky: sky)

        let skyBlockedY2 = !world.isSkyOpen(worldX: sensorCell.x, y: sensorCell.y, worldZ: sensorCell.z)
        let wireDarkY2 = (1...3).allSatisfy {
            world.block(worldX: sensorCell.x + $0, y: sensorCell.y, worldZ: sensorCell.z) == .wireOff
        }

        // Uncover and restore open sky
        world.setBlock(worldX: sensorCell.x, y: sensorCell.y + 2, worldZ: sensorCell.z, to: .air)
        sensorSignals.updateDaylightSensors(world: world, fuses: fuses, sky: sky)

        let skyOpenAgain = world.isSkyOpen(worldX: sensorCell.x, y: sensorCell.y, worldZ: sensorCell.z)
        let wireRestored = (1...3).allSatisfy {
            world.block(worldX: sensorCell.x + $0, y: sensorCell.y, worldZ: sensorCell.z) == .wireOn
        }

        report.check(
            "daylight sensor covered by opaque block at y+1 or y+2 outputs 0 power",
            skyBlockedY1 && wireDarkY1 && skyBlockedY2 && wireDarkY2 && skyOpenAgain && wireRestored,
            "y+1 dark: \(wireDarkY1), y+2 dark: \(wireDarkY2), restored: \(wireRestored)"
        )

        // Clean up Test 1-3 components so lit lamps do not shine into Test 4
        world.setBlock(worldX: sensorCell.x, y: sensorCell.y, worldZ: sensorCell.z, to: .air)
        for step in 1...3 {
            world.setBlock(worldX: sensorCell.x + step, y: sensorCell.y, worldZ: sensorCell.z, to: .air)
        }
        world.setBlock(worldX: doorCell.x, y: doorCell.y, worldZ: doorCell.z, to: .air)
        world.setBlock(worldX: doorCell.x, y: doorCell.y + 1, worldZ: doorCell.z, to: .air)
        world.setBlock(worldX: noonLampCell.x, y: noonLampCell.y, worldZ: noonLampCell.z, to: .air)
        sensorSignals.daylightSensorRemoved(at: sensorKey)
        sensorSignals.lampRemoved(at: noonLampKey)

        // =========================================================================
        // MARK: - Test 4: Signal Lamp Lifecycle & Light Propagation
        // =========================================================================
        let lampX = originX + 8
        let lampZ = originZ + 8
        let rLampCell = (x: lampX, y: groundY, z: lampZ)
        let rLampKey = SignalNetwork.Key(rLampCell.x, rLampCell.y, rLampCell.z)
        let rWireCell = (x: lampX - 1, y: groundY, z: lampZ)
        let rLeverCell = (x: lampX - 2, y: groundY, z: lampZ)
        let rLeverKey = SignalNetwork.Key(rLeverCell.x, rLeverCell.y, rLeverCell.z)

        world.setBlock(worldX: rLampCell.x, y: rLampCell.y, worldZ: rLampCell.z, to: .signalLamp)
        world.setBlock(worldX: rWireCell.x, y: rWireCell.y, worldZ: rWireCell.z, to: .wireOff)
        world.setBlock(worldX: rLeverCell.x, y: rLeverCell.y, worldZ: rLeverCell.z, to: .leverOff)

        let lampSignals = SignalNetwork()
        lampSignals.lampPlaced(at: rLampKey)
        lampSignals.leverPlaced(at: rLeverKey)
        lampSignals.recompute(world: world, fuses: fuses)

        let initialBlock = world.block(worldX: rLampCell.x, y: rLampCell.y, worldZ: rLampCell.z)
        let initialLight = world.lightLevel(worldX: rLampCell.x, y: rLampCell.y, worldZ: rLampCell.z)
        let initialAdjLight = world.lightLevel(worldX: rLampCell.x + 1, y: rLampCell.y, worldZ: rLampCell.z)

        report.check(
            "signal lamp starts unlit with light emission 0",
            initialBlock == .signalLamp && initialLight == 0 && initialAdjLight == 0,
            "block: \(initialBlock), light: \(initialLight), adjacent light: \(initialAdjLight)"
        )

        // Throw lever ON to power the lamp
        world.setBlock(worldX: rLeverCell.x, y: rLeverCell.y, worldZ: rLeverCell.z, to: .leverOn)
        lampSignals.recompute(world: world, fuses: fuses)

        let litBlock = world.block(worldX: rLampCell.x, y: rLampCell.y, worldZ: rLampCell.z)
        let litSource = world.lightLevel(worldX: rLampCell.x, y: rLampCell.y, worldZ: rLampCell.z)

        var falloff: [UInt8] = []
        for step in 0...5 {
            falloff.append(world.lightLevel(worldX: rLampCell.x + step, y: rLampCell.y, worldZ: rLampCell.z))
        }
        let stepsDown = zip(falloff, falloff.dropFirst()).allSatisfy { $0 == $1 + 1 }

        report.check(
            "signal lamp illuminates to light 15 and propagates light outward with 1-level falloff",
            litBlock == .signalLampLit && litSource == 15 && stepsDown,
            "lit block: \(litBlock), source light: \(litSource), falloff: \(falloff.map(String.init).joined(separator: " -> "))"
        )

        // Throw lever OFF to disconnect power
        world.setBlock(worldX: rLeverCell.x, y: rLeverCell.y, worldZ: rLeverCell.z, to: .leverOff)
        lampSignals.recompute(world: world, fuses: fuses)

        let revertedBlock = world.block(worldX: rLampCell.x, y: rLampCell.y, worldZ: rLampCell.z)
        let revertedLight = world.lightLevel(worldX: rLampCell.x, y: rLampCell.y, worldZ: rLampCell.z)
        let revertedPoolCleared = (1...5).allSatisfy {
            world.lightLevel(worldX: rLampCell.x + $0, y: rLampCell.y, worldZ: rLampCell.z) == 0
        }

        report.check(
            "signal lamp reverts to unlit and unspreads light back to 0",
            revertedBlock == .signalLamp && revertedLight == 0 && revertedPoolCleared,
            "reverted: \(revertedBlock), lamp light: \(revertedLight), pool cleared: \(revertedPoolCleared)"
        )

        // =========================================================================
        // MARK: - Test 5: Universal Pressure Plate Entity Actuation
        // =========================================================================
        let plateX = originX - 8
        let plateZ = originZ - 8
        let plateCell = (x: plateX, y: groundY, z: plateZ)
        let plateKey = SignalNetwork.Key(plateCell.x, plateCell.y, plateCell.z)
        let pWireCell = (x: plateX + 1, y: groundY, z: plateZ)
        let pDoorCell = (x: plateX + 2, y: groundY, z: plateZ)

        world.setBlock(worldX: plateCell.x, y: plateCell.y, worldZ: plateCell.z, to: .pressurePlateOff)
        world.setBlock(worldX: pWireCell.x, y: pWireCell.y, worldZ: pWireCell.z, to: .wireOff)
        world.setBlock(worldX: pDoorCell.x, y: pDoorCell.y, worldZ: pDoorCell.z,
                       to: .oakDoor(.lower, facing: .north, open: false))
        world.setBlock(worldX: pDoorCell.x, y: pDoorCell.y + 1, worldZ: pDoorCell.z,
                       to: .oakDoor(.upper, facing: .north, open: false))

        let plateSignals = SignalNetwork()
        plateSignals.platePlaced(at: plateKey)
        plateSignals.recompute(world: world, fuses: fuses)

        // 5a. Fizzler stands on pressure plate
        let plateCenter = Vector3(CGFloat(plateCell.x) + 0.5, CGFloat(plateCell.y), CGFloat(plateCell.z) + 0.5)
        var fizzler = Fizzler(position: plateCenter, seed: 101)

        let fizzlerActivated = plateSignals.updatePlates(world: world, fuses: fuses) { key in
            OccupancyQuery.isOccupied(key: key, fizzlers: [fizzler])
        }
        let plateOnFizzler = world.block(worldX: plateCell.x, y: plateCell.y, worldZ: plateCell.z) == .pressurePlateOn
        let doorOpenFizzler = world.block(worldX: pDoorCell.x, y: pDoorCell.y, worldZ: pDoorCell.z).doorIsOpen

        report.check(
            "universal pressure plate activates (.pressurePlateOn) and opens door when Fizzler stands on it",
            fizzlerActivated && plateOnFizzler && doorOpenFizzler,
            "activated: \(fizzlerActivated), plate: \(world.block(worldX: plateCell.x, y: plateCell.y, worldZ: plateCell.z)), door open: \(doorOpenFizzler)"
        )

        // 5b. Fizzler steps away
        fizzler = Fizzler(position: Vector3(CGFloat(plateCell.x + 5) + 0.5, CGFloat(plateCell.y), CGFloat(plateCell.z) + 0.5), seed: 101)
        let fizzlerDeactivated = plateSignals.updatePlates(world: world, fuses: fuses) { key in
            OccupancyQuery.isOccupied(key: key, fizzlers: [fizzler])
        }
        let plateOffFizzler = world.block(worldX: plateCell.x, y: plateCell.y, worldZ: plateCell.z) == .pressurePlateOff
        let doorShutFizzler = !world.block(worldX: pDoorCell.x, y: pDoorCell.y, worldZ: pDoorCell.z).doorIsOpen

        report.check(
            "universal pressure plate deactivates (.pressurePlateOff) when Fizzler steps away",
            fizzlerDeactivated && plateOffFizzler && doorShutFizzler,
            "deactivated: \(fizzlerDeactivated), plate: \(world.block(worldX: plateCell.x, y: plateCell.y, worldZ: plateCell.z)), door shut: \(doorShutFizzler)"
        )

        // 5c. Animal (Cow) stands on pressure plate
        var cow = Animal(kind: .cow, position: plateCenter, seed: 202)
        let animalActivated = plateSignals.updatePlates(world: world, fuses: fuses) { key in
            OccupancyQuery.isOccupied(key: key, animals: [cow])
        }
        let plateOnAnimal = world.block(worldX: plateCell.x, y: plateCell.y, worldZ: plateCell.z) == .pressurePlateOn
        let doorOpenAnimal = world.block(worldX: pDoorCell.x, y: pDoorCell.y, worldZ: pDoorCell.z).doorIsOpen

        report.check(
            "universal pressure plate activates (.pressurePlateOn) when Animal stands on it",
            animalActivated && plateOnAnimal && doorOpenAnimal,
            "activated: \(animalActivated), plate: \(world.block(worldX: plateCell.x, y: plateCell.y, worldZ: plateCell.z)), door open: \(doorOpenAnimal)"
        )

        // 5d. Animal steps away
        cow = Animal(kind: .cow, position: Vector3(CGFloat(plateCell.x) + 0.5, CGFloat(plateCell.y), CGFloat(plateCell.z + 5) + 0.5), seed: 202)
        let animalDeactivated = plateSignals.updatePlates(world: world, fuses: fuses) { key in
            OccupancyQuery.isOccupied(key: key, animals: [cow])
        }
        let plateOffAnimal = world.block(worldX: plateCell.x, y: plateCell.y, worldZ: plateCell.z) == .pressurePlateOff
        let doorShutAnimal = !world.block(worldX: pDoorCell.x, y: pDoorCell.y, worldZ: pDoorCell.z).doorIsOpen

        report.check(
            "universal pressure plate deactivates (.pressurePlateOff) when Animal steps away",
            animalDeactivated && plateOffAnimal && doorShutAnimal,
            "deactivated: \(animalDeactivated), plate: \(world.block(worldX: plateCell.x, y: plateCell.y, worldZ: plateCell.z)), door shut: \(doorShutAnimal)"
        )

        // 5e. Manager-based adopt and dead corpse check
        var fizzlerManager = FizzlerManager(mode: .survival, seed: 42)
        fizzlerManager.adopt([Fizzler(position: plateCenter, seed: 303)])
        let mgrActivated = plateSignals.updatePlates(world: world, fuses: fuses) { key in
            OccupancyQuery.isOccupied(cell: key, player: nil, fizzlers: fizzlerManager)
        }
        let plateOnMgr = world.block(worldX: plateCell.x, y: plateCell.y, worldZ: plateCell.z) == .pressurePlateOn

        if let fizzlerID = fizzlerManager.fizzlers.keys.first {
            _ = fizzlerManager.damage(id: fizzlerID, amount: 100, knockback: .zero)
        }
        let mgrDeadDeactivated = plateSignals.updatePlates(world: world, fuses: fuses) { key in
            OccupancyQuery.isOccupied(cell: key, player: nil, fizzlers: fizzlerManager)
        }
        let plateOffMgr = world.block(worldX: plateCell.x, y: plateCell.y, worldZ: plateCell.z) == .pressurePlateOff

        report.check(
            "manager-based occupancy query activates plate and dead corpse releases plate",
            mgrActivated && plateOnMgr && mgrDeadDeactivated && plateOffMgr,
            "mgrActivated: \(mgrActivated), plateOn: \(plateOnMgr), deadDeactivated: \(mgrDeadDeactivated), plateOff: \(plateOffMgr)"
        )

        // =========================================================================
        // MARK: - Test 6: Booster Rail Suppression via Nighttime & Occluded Daylight Sensor
        // =========================================================================
        let boosterOriginX = originX
        let boosterOriginZ = originZ + 12
        let bSensorCell = (x: boosterOriginX, y: groundY, z: boosterOriginZ)
        let bSensorKey = SignalNetwork.Key(bSensorCell.x, bSensorCell.y, bSensorCell.z)
        let bWire1 = (x: boosterOriginX, y: groundY, z: boosterOriginZ + 1)
        let bWire2 = (x: boosterOriginX, y: groundY, z: boosterOriginZ + 2)
        let bWire3 = (x: boosterOriginX, y: groundY, z: boosterOriginZ + 3)
        let bRailCell = (x: boosterOriginX, y: groundY, z: boosterOriginZ + 4)

        world.setBlock(worldX: bSensorCell.x, y: bSensorCell.y, worldZ: bSensorCell.z, to: .daylightSensor)
        world.setBlock(worldX: bWire1.x, y: bWire1.y, worldZ: bWire1.z, to: .wireOff)
        world.setBlock(worldX: bWire2.x, y: bWire2.y, worldZ: bWire2.z, to: .wireOff)
        world.setBlock(worldX: bWire3.x, y: bWire3.y, worldZ: bWire3.z, to: .wireOff)
        world.setBlock(worldX: bRailCell.x, y: bRailCell.y, worldZ: bRailCell.z, to: .boosterNorthSouth)

        let railSignals = SignalNetwork()
        railSignals.daylightSensorPlaced(at: bSensorKey)

        // 6a. Solar noon (power 15) -> wire is on, booster rail is active (not suppressed)
        sky.dayFraction = 0.25
        railSignals.updateDaylightSensors(world: world, fuses: fuses, sky: sky)
        let noonBoosterActive = world.boosterIsActive(worldX: bRailCell.x, y: bRailCell.y, worldZ: bRailCell.z)
        let noonWireLit = world.block(worldX: bWire3.x, y: bWire3.y, worldZ: bWire3.z) == .wireOn

        report.check(
            "booster rail wired to daylight sensor is active at solar noon",
            noonBoosterActive && noonWireLit,
            "booster active: \(noonBoosterActive), wire3: \(world.block(worldX: bWire3.x, y: bWire3.y, worldZ: bWire3.z))"
        )

        // 6b. Night (midnight, power 0) -> wire is off, booster rail is suppressed (held inert/braking)
        sky.dayFraction = 0.75
        railSignals.updateDaylightSensors(world: world, fuses: fuses, sky: sky)
        let midnightBoosterSuppressed = !world.boosterIsActive(worldX: bRailCell.x, y: bRailCell.y, worldZ: bRailCell.z)
        let midnightWireDark = world.block(worldX: bWire3.x, y: bWire3.y, worldZ: bWire3.z) == .wireOff

        report.check(
            "booster rail wired to daylight sensor is suppressed (held inert) at night",
            midnightBoosterSuppressed && midnightWireDark,
            "booster suppressed: \(midnightBoosterSuppressed), wire3: \(world.block(worldX: bWire3.x, y: bWire3.y, worldZ: bWire3.z))"
        )

        // 6c. Midday vertical occlusion -> sensor blocked at noon drops power to 0, suppresses booster rail
        sky.dayFraction = 0.25
        world.setBlock(worldX: bSensorCell.x, y: bSensorCell.y + 1, worldZ: bSensorCell.z, to: .stone)
        railSignals.updateDaylightSensors(world: world, fuses: fuses, sky: sky)
        let occludedBoosterSuppressed = !world.boosterIsActive(worldX: bRailCell.x, y: bRailCell.y, worldZ: bRailCell.z)

        // Unblock sensor -> power restored, booster rail becomes active again
        world.setBlock(worldX: bSensorCell.x, y: bSensorCell.y + 1, worldZ: bSensorCell.z, to: .air)
        railSignals.updateDaylightSensors(world: world, fuses: fuses, sky: sky)
        let unblockedBoosterActive = world.boosterIsActive(worldX: bRailCell.x, y: bRailCell.y, worldZ: bRailCell.z)

        report.check(
            "booster rail is suppressed when daylight sensor is occluded at noon, and restored when unblocked",
            occludedBoosterSuppressed && unblockedBoosterActive,
            "occluded suppressed: \(occludedBoosterSuppressed), restored active: \(unblockedBoosterActive)"
        )

        // 6d. Circuit disconnection -> breaking wire unlinks booster rail, reverting it to unwired default (always active)
        world.setBlock(worldX: bWire3.x, y: bWire3.y, worldZ: bWire3.z, to: .air)
        railSignals.recompute(world: world, fuses: fuses)
        let unwiredBoosterActive = world.boosterIsActive(worldX: bRailCell.x, y: bRailCell.y, worldZ: bRailCell.z)

        report.check(
            "breaking wire unlinks booster rail and unsuppresses it to active default",
            unwiredBoosterActive,
            "unwired booster active: \(unwiredBoosterActive)"
        )

        // Cleanup Test 6 components
        world.setBlock(worldX: bSensorCell.x, y: bSensorCell.y, worldZ: bSensorCell.z, to: .air)
        world.setBlock(worldX: bWire1.x, y: bWire1.y, worldZ: bWire1.z, to: .air)
        world.setBlock(worldX: bWire2.x, y: bWire2.y, worldZ: bWire2.z, to: .air)
        world.setBlock(worldX: bRailCell.x, y: bRailCell.y, worldZ: bRailCell.z, to: .air)
        railSignals.daylightSensorRemoved(at: bSensorKey)
        railSignals.recompute(world: world, fuses: fuses)

        // =========================================================================
        // MARK: - Test 7: World Reload & Edit Journal Reconstruction of Daylight Sensor & Lamp
        // =========================================================================
        let reloadSensorCell = (x: originX - 12, y: groundY, z: originZ)
        let reloadWire1 = (x: originX - 11, y: groundY, z: originZ)
        let reloadWire2 = (x: originX - 10, y: groundY, z: originZ)
        let reloadLampCell = (x: originX - 9, y: groundY, z: originZ)
        let reloadLampKey = SignalNetwork.Key(reloadLampCell.x, reloadLampCell.y, reloadLampCell.z)
        let reloadSensorKey = SignalNetwork.Key(reloadSensorCell.x, reloadSensorCell.y, reloadSensorCell.z)

        world.setBlock(worldX: reloadSensorCell.x, y: reloadSensorCell.y, worldZ: reloadSensorCell.z, to: .daylightSensor)
        world.setBlock(worldX: reloadWire1.x, y: reloadWire1.y, worldZ: reloadWire1.z, to: .wireOff)
        world.setBlock(worldX: reloadWire2.x, y: reloadWire2.y, worldZ: reloadWire2.z, to: .wireOff)
        world.setBlock(worldX: reloadLampCell.x, y: reloadLampCell.y, worldZ: reloadLampCell.z, to: .signalLamp)

        let journal = world.editJournal
        let restoredWorld = World(seed: world.seed, edits: journal)
        for dz in -2...2 {
            for dx in -2...2 {
                restoredWorld.forceGenerate(ChunkCoord(x: centre.x + dx, z: centre.z + dz))
            }
        }
        let restoredSignals = SignalNetwork()

        GameSession.registerJournalIndex(from: journal, signals: restoredSignals)

        let sensorRegistered = restoredSignals.daylightSensorCells.contains(reloadSensorKey)
        let lampRegistered = restoredSignals.lampCells.contains(reloadLampKey)

        report.check(
            "world reload journal indexer registers daylight sensor and signal lamp",
            sensorRegistered && lampRegistered,
            "sensor registered: \(sensorRegistered), lamp registered: \(lampRegistered)"
        )

        sky.dayFraction = 0.25
        restoredSignals.updateDaylightSensors(world: restoredWorld, fuses: fuses, sky: sky)
        let reloadedWireLit = restoredWorld.block(worldX: reloadWire2.x, y: reloadWire2.y, worldZ: reloadWire2.z) == .wireOn
        let reloadedLampLit = restoredWorld.block(worldX: reloadLampCell.x, y: reloadLampCell.y, worldZ: reloadLampCell.z) == .signalLampLit
        let reloadedLampLight = restoredWorld.lightLevel(worldX: reloadLampCell.x, y: reloadLampCell.y, worldZ: reloadLampCell.z)

        report.check(
            "reloaded daylight sensor powers reloaded signal lamp to light 15 at solar noon",
            reloadedWireLit && reloadedLampLit && reloadedLampLight == 15,
            "wire lit: \(reloadedWireLit), lamp lit: \(reloadedLampLit), emission: \(reloadedLampLight)"
        )

        sky.dayFraction = 0.75
        restoredSignals.updateDaylightSensors(world: restoredWorld, fuses: fuses, sky: sky)
        let reloadedWireDark = restoredWorld.block(worldX: reloadWire2.x, y: reloadWire2.y, worldZ: reloadWire2.z) == .wireOff
        let reloadedLampUnlit = restoredWorld.block(worldX: reloadLampCell.x, y: reloadLampCell.y, worldZ: reloadLampCell.z) == .signalLamp
        let reloadedLampDarkLight = restoredWorld.lightLevel(worldX: reloadLampCell.x, y: reloadLampCell.y, worldZ: reloadLampCell.z)

        report.check(
            "reloaded daylight sensor dims reloaded signal lamp to unlit (light 0) at midnight",
            reloadedWireDark && reloadedLampUnlit && reloadedLampDarkLight == 0,
            "wire dark: \(reloadedWireDark), lamp unlit: \(reloadedLampUnlit), emission: \(reloadedLampDarkLight)"
        )

        // Cleanup Test 7 components
        world.setBlock(worldX: reloadSensorCell.x, y: reloadSensorCell.y, worldZ: reloadSensorCell.z, to: .air)
        world.setBlock(worldX: reloadWire1.x, y: reloadWire1.y, worldZ: reloadWire1.z, to: .air)
        world.setBlock(worldX: reloadWire2.x, y: reloadWire2.y, worldZ: reloadWire2.z, to: .air)
        world.setBlock(worldX: reloadLampCell.x, y: reloadLampCell.y, worldZ: reloadLampCell.z, to: .air)

        // =========================================================================
        // MARK: - Reachable By A Player, Not Only By This Check
        // =========================================================================
        // Everything above writes its blocks straight into the world with
        // `setBlock`, which is exactly how this whole feature managed to
        // pass while being unplayable: neither block had an `ItemType`, so
        // nothing dropped one, nothing placed one, no recipe made one and
        // no palette listed one. Every placement branch in the game loop
        // was unreachable code. These four lines are the ones that would
        // have caught it.
        let sensorItem = ItemType.blockItem(for: .daylightSensor)
        let lampItem = ItemType.blockItem(for: .signalLamp)
        let litLampItem = ItemType.blockItem(for: .signalLampLit)
        report.check(
            "a daylight sensor and a signal lamp are things a player can hold",
            sensorItem == .daylightSensor && lampItem == .signalLamp && litLampItem == .signalLamp,
            "sensor \(String(describing: sensorItem)), lamp \(String(describing: lampItem)), "
                + "lit lamp \(String(describing: litLampItem))"
        )

        report.check(
            "breaking one hands it back, and the item puts the same block down",
            BlockType.daylightSensor.drop == .daylightSensor
                && BlockType.signalLamp.drop == .signalLamp
                && BlockType.signalLampLit.drop == .signalLamp
                && ItemType.daylightSensor.placedBlock == .daylightSensor
                && ItemType.signalLamp.placedBlock == .signalLamp,
            "sensor drop \(String(describing: BlockType.daylightSensor.drop)), "
                + "lit lamp drop \(String(describing: BlockType.signalLampLit.drop))"
        )

        let sensorRecipe = RecipeBook.all.contains { $0.output.type == .daylightSensor }
        let lampRecipe = RecipeBook.all.contains { $0.output.type == .signalLamp }
        report.check(
            "both can be crafted",
            sensorRecipe && lampRecipe,
            "sensor recipe: \(sensorRecipe), lamp recipe: \(lampRecipe)"
        )

        report.check(
            "both are on the creative palette, under a name worth reading",
            CreativeCatalogue.allItems.contains(.daylightSensor)
                && CreativeCatalogue.allItems.contains(.signalLamp)
                && ItemType.daylightSensor.displayName == "Daylight Sensor"
                && ItemType.signalLamp.displayName == "Signal Lamp",
            "sensor: \(ItemType.daylightSensor.displayName), lamp: \(ItemType.signalLamp.displayName)"
        )

        // =========================================================================
        // MARK: - Verdict Reporting
        // =========================================================================
        for line in report.lines { StandardError.write(Data((line + "\n").utf8)) }
        let verdict = report.failed
            ? "[check] FAILED — the sensor\n"
            : "[check] all passed — the sensor\n"
        StandardError.write(Data(verdict.utf8))
        exit(report.failed ? 1 : 0)
    }
}
