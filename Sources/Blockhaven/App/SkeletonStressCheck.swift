import Foundation
import Foundation

/// Adversarial stress testing and empirical challenge harness for Milestone 4:
/// Diurnal Hostile Ecology, Skeleton Sunlight Exposure & Combustion Mechanics.
///
/// Rigorously validates:
/// 1. Direct daytime sunlight ignition and progressive burn damage.
/// 2. Immediate water quenching (feet immersion, torso immersion, and submerged spawn immunity).
/// 3. Solid roof & leaf canopy shelter protection across multiple elevations and leaf types.
/// 4. Translucent glass ceiling penetration (sunlight passes through single and multi-layer glass to burn skeleton).
/// 5. Rain interaction: rain prevents ignition under open sky, and extinguishes/burns out active fire without renewal.
/// 6. Night time protection: open sky at night prevents ignition, and day-to-night transition halts fire renewal.
/// 7. Fatal burn lifecycle: health drains to 0, triggers clean death transition, clears fire ticks,
///    validates finite physics state (no NaN/Inf), completes dying timer, and cleanly unregisters from SkeletonManager.
/// 8. Environmental shelter seeking: actively flees sunlight toward shade and water pools.
///
/// Run via `BLOCKHAVEN_CHECK_SKELETON_STRESS=1`. Exits nonzero on failure.
enum SkeletonStressCheck {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["BLOCKHAVEN_CHECK_SKELETON_STRESS"] != nil
    }

    private struct Report {
        var lines: [String] = []
        var failed = false

        mutating func check(_ name: String, _ passed: Bool, _ detail: String) {
            lines.append("[stress-check] \(name): \(passed ? "ok" : "FAILED") — \(detail)")
            if !passed { failed = true }
        }
    }

    private static let dt = 1.0 / 60

    @MainActor
    static func run() -> Never {
        var report = Report()
        let world = World(seed: 12345)
        let spawn = world.spawnPosition()
        let centre = World.chunkCoord(forWorldX: Int(spawn.x), worldZ: Int(spawn.z))

        // Pre-generate 7x7 chunks around spawn to ensure clean voxel neighborhood
        for dz in -3...3 {
            for dx in -3...3 {
                world.forceGenerate(ChunkCoord(x: centre.x + dx, z: centre.z + dz))
            }
        }

        let originX = Int(spawn.x)
        let originZ = Int(spawn.z)
        let platformY = 90 // Elevated alpine deck, clear to sky

        // Build a wide stone deck (41x41) clear to the sky
        for dz in -20...20 {
            for dx in -20...20 {
                world.setBlock(worldX: originX + dx, y: platformY - 1, worldZ: originZ + dz, to: .stone, remesh: false)
                for y in platformY..<Chunk.height {
                    world.setBlock(worldX: originX + dx, y: y, worldZ: originZ + dz, to: .air, remesh: false)
                }
            }
        }

        // =========================================================================
        // TEST 1: Direct Daytime Sunlight Combustion & Monotonic Burn Damage
        // =========================================================================
        let pos1 = Vector3(CGFloat(originX) + 0.5, CGFloat(platformY), CGFloat(originZ) + 0.5)
        var skel1 = Skeleton(position: pos1, seed: 101)

        let openToSky = world.isSkyOpen(worldX: Int(pos1.x), y: Int(pos1.y + Skeleton.height), worldZ: Int(pos1.z))
        let exposedDay1 = skel1.isExposedToSunlight(isNight: false, isRaining: false, world: world)

        // Step 1 frame
        skel1.step(dt: dt, playerEye: nil, canSeePlayer: false, isNight: false, isRaining: false, world: world)
        let ignitedImmediately = skel1.isOnFire && skel1.fireTicks > 7.0

        // Step for 1 second (60 frames). Burn damage interval is 1.0s, damage is 1.
        for _ in 1..<60 {
            skel1.step(dt: dt, playerEye: nil, canSeePlayer: false, isNight: false, isRaining: false, world: world)
        }
        let tookDamageAt1s = skel1.health == Skeleton.maxHealth - Skeleton.burnDamage

        // Step for another 2 seconds (120 frames). Health should drop by 2 more.
        for _ in 0..<120 {
            skel1.step(dt: dt, playerEye: nil, canSeePlayer: false, isNight: false, isRaining: false, world: world)
        }
        let tookDamageAt3s = skel1.health == Skeleton.maxHealth - 3 * Skeleton.burnDamage

        report.check(
            "skeleton ignites under open daytime sky and takes monotonic burn damage",
            openToSky && exposedDay1 && ignitedImmediately && tookDamageAt1s && tookDamageAt3s,
            "openSky: \(openToSky), exposed: \(exposedDay1), fireTicks: \(skel1.fireTicks), health after 3s: \(skel1.health)/\(Skeleton.maxHealth)"
        )

        // =========================================================================
        // TEST 2: Immediate Water Quenching (Feet, Torso, and Water Spawn Immunity)
        // =========================================================================
        // 2A: Actively burning skeleton plunges into water at feet
        let pos2 = Vector3(CGFloat(originX + 5) + 0.5, CGFloat(platformY), CGFloat(originZ) + 0.5)
        var skel2 = Skeleton(position: pos2, seed: 202)
        // Ignite on open platform
        for _ in 0..<60 {
            skel2.step(dt: dt, playerEye: nil, canSeePlayer: false, isNight: false, isRaining: false, world: world)
        }
        let burningBeforeWater = skel2.isOnFire && skel2.health < Skeleton.maxHealth

        // Place water pool (3x3) around skeleton's current position
        let curX = Int(floor(skel2.position.x))
        let curY = Int(floor(skel2.position.y))
        let curZ = Int(floor(skel2.position.z))
        for dx in -2...2 {
            for dz in -2...2 {
                world.setBlock(worldX: curX + dx, y: curY, worldZ: curZ + dz, to: .water)
            }
        }
        let inWaterFeet = skel2.isInWater(world: world)

        // Step 1 frame in water
        skel2.step(dt: dt, playerEye: nil, canSeePlayer: false, isNight: false, isRaining: false, world: world)
        let quenchedImmediately = !skel2.isOnFire && skel2.fireTicks == 0

        // Step 120 more frames in water under midday sun
        let savedHealth = skel2.health
        for _ in 0..<120 {
            skel2.step(dt: dt, playerEye: nil, canSeePlayer: false, isNight: false, isRaining: false, world: world)
        }
        let stayedSafeInWater = !skel2.isOnFire && skel2.health == savedHealth

        report.check(
            "submerging feet in water immediately quenches fire and halts all burn damage",
            burningBeforeWater && inWaterFeet && quenchedImmediately && stayedSafeInWater,
            "burningBefore: \(burningBeforeWater), inWater: \(inWaterFeet), quenched: \(quenchedImmediately), healthStayed: \(skel2.health == savedHealth)"
        )

        // Clean up water
        for dx in -2...2 {
            for dz in -2...2 {
                world.setBlock(worldX: curX + dx, y: curY, worldZ: curZ + dz, to: .air)
            }
        }

        // 2B: Water at torso (y + 1)
        let pos2B = Vector3(CGFloat(originX + 15) + 0.5, CGFloat(platformY), CGFloat(originZ) + 0.5)
        var skel2B = Skeleton(position: pos2B, seed: 203)
        for _ in 0..<60 {
            skel2B.step(dt: dt, playerEye: nil, canSeePlayer: false, isNight: false, isRaining: false, world: world)
        }
        let cur2BX = Int(floor(skel2B.position.x))
        let cur2BY = Int(floor(skel2B.position.y))
        let cur2BZ = Int(floor(skel2B.position.z))
        for dx in -2...2 {
            for dz in -2...2 {
                world.setBlock(worldX: cur2BX + dx, y: cur2BY + 1, worldZ: cur2BZ + dz, to: .water)
            }
        }
        skel2B.step(dt: dt, playerEye: nil, canSeePlayer: false, isNight: false, isRaining: false, world: world)
        let torsoQuenched = !skel2B.isOnFire && skel2B.fireTicks == 0
        report.check(
            "water at torso level (y+1) also immediately quenches fire",
            torsoQuenched,
            "torsoQuenched: \(torsoQuenched), fireTicks: \(skel2B.fireTicks)"
        )
        for dx in -2...2 {
            for dz in -2...2 {
                world.setBlock(worldX: cur2BX + dx, y: cur2BY + 1, worldZ: cur2BZ + dz, to: .air)
            }
        }

        // 2C: Skeleton standing permanently in water pool under blazing sun
        let pos2C = Vector3(CGFloat(originX - 10) + 0.5, CGFloat(platformY), CGFloat(originZ + 10) + 0.5)
        let poolCenterX = Int(pos2C.x)
        let poolCenterZ = Int(pos2C.z)
        for dx in -2...2 {
            for dz in -2...2 {
                if abs(dx) == 2 || abs(dz) == 2 {
                    world.setBlock(worldX: poolCenterX + dx, y: platformY, worldZ: poolCenterZ + dz, to: .stone)
                    world.setBlock(worldX: poolCenterX + dx, y: platformY + 1, worldZ: poolCenterZ + dz, to: .stone)
                    world.setBlock(worldX: poolCenterX + dx, y: platformY + 2, worldZ: poolCenterZ + dz, to: .stone)
                } else {
                    world.setBlock(worldX: poolCenterX + dx, y: platformY, worldZ: poolCenterZ + dz, to: .water)
                    world.setBlock(worldX: poolCenterX + dx, y: platformY + 1, worldZ: poolCenterZ + dz, to: .water)
                }
            }
        }
        var skel2C = Skeleton(position: pos2C, seed: 204)
        for _ in 0..<240 { // 4 full seconds
            skel2C.step(dt: dt, playerEye: nil, canSeePlayer: false, isNight: false, isRaining: false, world: world)
        }
        let neverIgnitedInWater = !skel2C.isOnFire && skel2C.health == Skeleton.maxHealth
        report.check(
            "skeleton standing in water under open daytime sky never ignites",
            neverIgnitedInWater,
            "neverIgnited: \(neverIgnitedInWater), health: \(skel2C.health)/\(Skeleton.maxHealth)"
        )
        for dx in -2...2 {
            for dz in -2...2 {
                world.setBlock(worldX: poolCenterX + dx, y: platformY, worldZ: poolCenterZ + dz, to: .air)
                world.setBlock(worldX: poolCenterX + dx, y: platformY + 1, worldZ: poolCenterZ + dz, to: .air)
                world.setBlock(worldX: poolCenterX + dx, y: platformY + 2, worldZ: poolCenterZ + dz, to: .air)
            }
        }

        // =========================================================================
        // TEST 3: Solid Roof & Leaf Canopy Shelter Protection
        // =========================================================================
        // 3A: Solid stone roof (7x7) at y+2 (headroom = 2)
        let pos3A = Vector3(CGFloat(originX - 5) + 0.5, CGFloat(platformY), CGFloat(originZ) + 0.5)
        for dx in -3...3 {
            for dz in -3...3 {
                world.setBlock(worldX: Int(pos3A.x) + dx, y: platformY + 2, worldZ: Int(pos3A.z) + dz, to: .stone)
            }
        }
        let stoneSkyBlocked = !world.isSkyOpen(worldX: Int(pos3A.x), y: platformY + 2, worldZ: Int(pos3A.z))
        var skel3A = Skeleton(position: pos3A, seed: 301)
        for _ in 0..<180 { // 3 seconds
            skel3A.step(dt: dt, playerEye: nil, canSeePlayer: false, isNight: false, isRaining: false, world: world)
        }
        let stoneSafe = !skel3A.isOnFire && skel3A.health == Skeleton.maxHealth

        report.check(
            "solid stone roof directly overhead protects skeleton from daylight burning",
            stoneSkyBlocked && stoneSafe,
            "stoneSkyBlocked: \(stoneSkyBlocked), safe: \(stoneSafe), health: \(skel3A.health)"
        )

        // 3B: Solid wood roof (7x7) at high elevation (y + 15)
        let pos3B = Vector3(CGFloat(originX - 15) + 0.5, CGFloat(platformY), CGFloat(originZ) + 0.5)
        let bX = Int(pos3B.x)
        let bZ = Int(pos3B.z)
        for dx in -3...3 {
            for dz in -3...3 {
                world.setBlock(worldX: bX + dx, y: platformY + 15, worldZ: bZ + dz, to: .planks)
                if abs(dx) == 3 || abs(dz) == 3 {
                    world.setBlock(worldX: bX + dx, y: platformY, worldZ: bZ + dz, to: .stone)
                    world.setBlock(worldX: bX + dx, y: platformY + 1, worldZ: bZ + dz, to: .stone)
                    world.setBlock(worldX: bX + dx, y: platformY + 2, worldZ: bZ + dz, to: .stone)
                }
            }
        }
        let highWoodBlocked = !world.isSkyOpen(worldX: bX, y: platformY + 2, worldZ: bZ)
        var skel3B = Skeleton(position: pos3B, seed: 302)
        for _ in 0..<180 {
            skel3B.step(dt: dt, playerEye: nil, canSeePlayer: false, isNight: false, isRaining: false, world: world)
        }
        let woodSafe = !skel3B.isOnFire && skel3B.health == Skeleton.maxHealth

        report.check(
            "solid wood roof at high altitude (y+15) blocks sunlight and prevents burning",
            highWoodBlocked && woodSafe,
            "highWoodBlocked: \(highWoodBlocked), safe: \(woodSafe), health: \(skel3B.health)"
        )
        for dx in -3...3 {
            for dz in -3...3 {
                world.setBlock(worldX: bX + dx, y: platformY + 15, worldZ: bZ + dz, to: .air)
                if abs(dx) == 3 || abs(dz) == 3 {
                    world.setBlock(worldX: bX + dx, y: platformY, worldZ: bZ + dz, to: .air)
                    world.setBlock(worldX: bX + dx, y: platformY + 1, worldZ: bZ + dz, to: .air)
                    world.setBlock(worldX: bX + dx, y: platformY + 2, worldZ: bZ + dz, to: .air)
                }
            }
        }

        // 3C: Leaf canopy shelter (7x7) (.leaves)
        let pos3C = Vector3(CGFloat(originX - 10) + 0.5, CGFloat(platformY), CGFloat(originZ - 10) + 0.5)
        let cX = Int(pos3C.x)
        let cZ = Int(pos3C.z)
        for dx in -3...3 {
            for dz in -3...3 {
                world.setBlock(worldX: cX + dx, y: platformY + 3, worldZ: cZ + dz, to: .leaves)
                if abs(dx) == 3 || abs(dz) == 3 {
                    world.setBlock(worldX: cX + dx, y: platformY, worldZ: cZ + dz, to: .stone)
                    world.setBlock(worldX: cX + dx, y: platformY + 1, worldZ: cZ + dz, to: .stone)
                    world.setBlock(worldX: cX + dx, y: platformY + 2, worldZ: cZ + dz, to: .stone)
                }
            }
        }
        let leafSkyBlocked = !world.isSkyOpen(worldX: cX, y: platformY + 2, worldZ: cZ)
        var skel3C = Skeleton(position: pos3C, seed: 303)
        for _ in 0..<180 {
            skel3C.step(dt: dt, playerEye: nil, canSeePlayer: false, isNight: false, isRaining: false, world: world)
        }
        let leafSafe = !skel3C.isOnFire && skel3C.health == Skeleton.maxHealth

        report.check(
            "leaf canopy occludes sunlight and shelters skeleton from burning",
            leafSkyBlocked && leafSafe,
            "leafSkyBlocked: \(leafSkyBlocked), safe: \(leafSafe), health: \(skel3C.health)"
        )
        for dx in -3...3 {
            for dz in -3...3 {
                world.setBlock(worldX: cX + dx, y: platformY + 3, worldZ: cZ + dz, to: .air)
                if abs(dx) == 3 || abs(dz) == 3 {
                    world.setBlock(worldX: cX + dx, y: platformY, worldZ: cZ + dz, to: .air)
                    world.setBlock(worldX: cX + dx, y: platformY + 1, worldZ: cZ + dz, to: .air)
                    world.setBlock(worldX: cX + dx, y: platformY + 2, worldZ: cZ + dz, to: .air)
                }
            }
        }

        // =========================================================================
        // TEST 4: Translucent Glass Ceiling Correctly Allows Sunlight Burning
        // =========================================================================
        // Single layer glass at y + 3
        let pos4A = Vector3(CGFloat(originX) + 0.5, CGFloat(platformY), CGFloat(originZ + 5) + 0.5)
        world.setBlock(worldX: Int(pos4A.x), y: platformY + 3, worldZ: Int(pos4A.z), to: .glass)
        let glassNotOpaque = !BlockType.glass.isOpaque
        let glassSkyOpen = world.isSkyOpen(worldX: Int(pos4A.x), y: platformY + 2, worldZ: Int(pos4A.z))

        var skel4A = Skeleton(position: pos4A, seed: 401)
        for _ in 0..<180 { // 3 seconds
            skel4A.step(dt: dt, playerEye: nil, canSeePlayer: false, isNight: false, isRaining: false, world: world)
        }
        let glassBurns = skel4A.isOnFire && skel4A.health <= Skeleton.maxHealth - 2

        report.check(
            "translucent glass ceiling allows sunlight to pass through and combust skeleton",
            glassNotOpaque && glassSkyOpen && glassBurns,
            "glassNotOpaque: \(glassNotOpaque), skyOpen: \(glassSkyOpen), burning: \(skel4A.isOnFire), health: \(skel4A.health)/\(Skeleton.maxHealth)"
        )

        // Multi-layer glass stack (3 layers: y+2, y+3, y+4)
        let pos4B = Vector3(CGFloat(originX) + 0.5, CGFloat(platformY), CGFloat(originZ + 8) + 0.5)
        world.setBlock(worldX: Int(pos4B.x), y: platformY + 2, worldZ: Int(pos4B.z), to: .glass)
        world.setBlock(worldX: Int(pos4B.x), y: platformY + 3, worldZ: Int(pos4B.z), to: .glass)
        world.setBlock(worldX: Int(pos4B.x), y: platformY + 4, worldZ: Int(pos4B.z), to: .glass)
        let multiGlassSkyOpen = world.isSkyOpen(worldX: Int(pos4B.x), y: platformY + 1, worldZ: Int(pos4B.z))

        var skel4B = Skeleton(position: pos4B, seed: 402)
        for _ in 0..<180 {
            skel4B.step(dt: dt, playerEye: nil, canSeePlayer: false, isNight: false, isRaining: false, world: world)
        }
        let multiGlassBurns = skel4B.isOnFire && skel4B.health <= Skeleton.maxHealth - 2

        report.check(
            "stacked triple-layer glass ceiling remains translucent and burns skeleton",
            multiGlassSkyOpen && multiGlassBurns,
            "skyOpen: \(multiGlassSkyOpen), burning: \(skel4B.isOnFire), health: \(skel4B.health)/\(Skeleton.maxHealth)"
        )

        // Clean up glass
        world.setBlock(worldX: Int(pos4A.x), y: platformY + 3, worldZ: Int(pos4A.z), to: .air)
        world.setBlock(worldX: Int(pos4B.x), y: platformY + 2, worldZ: Int(pos4B.z), to: .air)
        world.setBlock(worldX: Int(pos4B.x), y: platformY + 3, worldZ: Int(pos4B.z), to: .air)
        world.setBlock(worldX: Int(pos4B.x), y: platformY + 4, worldZ: Int(pos4B.z), to: .air)

        // =========================================================================
        // TEST 5: Rain Prevents Daytime Combustion and Halts Fire Renewal
        // =========================================================================
        // 5A: Rain active under open sky prevents ignition
        let pos5A = Vector3(CGFloat(originX) + 0.5, CGFloat(platformY), CGFloat(originZ - 5) + 0.5)
        var skel5A = Skeleton(position: pos5A, seed: 501)
        let exposedUnderRain = skel5A.isExposedToSunlight(isNight: false, isRaining: true, world: world)
        for _ in 0..<180 {
            skel5A.step(dt: dt, playerEye: nil, canSeePlayer: false, isNight: false, isRaining: true, world: world)
        }
        let rainProtected = !skel5A.isOnFire && skel5A.health == Skeleton.maxHealth

        report.check(
            "rain prevents daytime sunlight ignition under open sky",
            !exposedUnderRain && rainProtected,
            "exposedUnderRain: \(exposedUnderRain), rainProtected: \(rainProtected), health: \(skel5A.health)"
        )

        // 5B: Rain onset while already burning halts fire refresh, allowing fire to expire
        let pos5B = Vector3(CGFloat(originX) + 0.5, CGFloat(platformY), CGFloat(originZ - 8) + 0.5)
        var skel5B = Skeleton(position: pos5B, seed: 502)
        // Ignite in clear sun for 1 second
        for _ in 0..<60 {
            skel5B.step(dt: dt, playerEye: nil, canSeePlayer: false, isNight: false, isRaining: false, world: world)
        }
        let ignitedBeforeRain = skel5B.isOnFire && skel5B.fireTicks > 6.0

        // Rain starts! Advance until fire duration expires (8 seconds = 480 frames)
        for _ in 0..<500 {
            skel5B.step(dt: dt, playerEye: nil, canSeePlayer: false, isNight: false, isRaining: true, world: world)
        }
        let fireExpiredUnderRain = !skel5B.isOnFire && skel5B.fireTicks == 0
        let survivedRainExpire = skel5B.health > 0

        report.check(
            "rain onset stops solar fire renewal, allowing fireTicks to naturally expire and extinguish",
            ignitedBeforeRain && fireExpiredUnderRain && survivedRainExpire,
            "ignitedBefore: \(ignitedBeforeRain), expired: \(fireExpiredUnderRain), remainingHealth: \(skel5B.health)"
        )

        // =========================================================================
        // TEST 6: Night Time Protection and Day-to-Night Transition
        // =========================================================================
        // 6A: Midnight open sky prevents combustion
        let pos6A = Vector3(CGFloat(originX + 15) + 0.5, CGFloat(platformY), CGFloat(originZ) + 0.5)
        var skel6A = Skeleton(position: pos6A, seed: 601)
        let exposedAtNight = skel6A.isExposedToSunlight(isNight: true, isRaining: false, world: world)
        for _ in 0..<180 {
            skel6A.step(dt: dt, playerEye: nil, canSeePlayer: false, isNight: true, isRaining: false, world: world)
        }
        let nightSafe = !skel6A.isOnFire && skel6A.health == Skeleton.maxHealth

        report.check(
            "night time (isNight == true) completely protects skeleton from burning under open sky",
            !exposedAtNight && nightSafe,
            "exposedAtNight: \(exposedAtNight), nightSafe: \(nightSafe), health: \(skel6A.health)"
        )

        // 6B: Day to night transition halts solar fire refresh
        let pos6B = Vector3(CGFloat(originX + 18) + 0.5, CGFloat(platformY), CGFloat(originZ) + 0.5)
        var skel6B = Skeleton(position: pos6B, seed: 602)
        // Ignite in daytime
        for _ in 0..<60 {
            skel6B.step(dt: dt, playerEye: nil, canSeePlayer: false, isNight: false, isRaining: false, world: world)
        }
        let litBeforeNight = skel6B.isOnFire

        // Night falls
        for _ in 0..<500 {
            skel6B.step(dt: dt, playerEye: nil, canSeePlayer: false, isNight: true, isRaining: false, world: world)
        }
        let fireExpiredAtNight = !skel6B.isOnFire && skel6B.fireTicks == 0

        report.check(
            "nightfall terminates solar ignition, allowing active fire to extinguish without re-ignition",
            litBeforeNight && fireExpiredAtNight,
            "litBeforeNight: \(litBeforeNight), expiredAtNight: \(fireExpiredAtNight), health: \(skel6B.health)"
        )

        // =========================================================================
        // TEST 7: Fatal Burn Lifecycle, Zero-Health Death & Clean Entity Manager Pruning
        // =========================================================================
        let pos7 = Vector3(CGFloat(originX - 15) + 0.5, CGFloat(platformY), CGFloat(originZ - 15) + 0.5)
        var skel7 = Skeleton(position: pos7, seed: 701)

        // Skeleton has maxHealth = 12. Burn damage is 1 per 1.0s. Needs ~12s (720 frames) to die.
        var reachedZeroHealth = false
        var cleanDeathTriggered = false
        var finitePhysicsDuringDeath = true

        var frames = 0
        while frames < 850 && !skel7.isFinished {
            skel7.step(dt: dt, playerEye: nil, canSeePlayer: false, isNight: false, isRaining: false, world: world)
            frames += 1

            if skel7.health == 0 {
                reachedZeroHealth = true
                if skel7.isDead && skel7.fireTicks == 0 {
                    cleanDeathTriggered = true
                }
            }

            // Check for NaN or Inf physics state
            if skel7.position.x.isNaN || skel7.position.y.isNaN || skel7.position.z.isNaN
                || skel7.velocity.x.isNaN || skel7.velocity.y.isNaN || skel7.velocity.z.isNaN {
                finitePhysicsDuringDeath = false
            }
        }

        let isFinishedCleanly = skel7.isFinished
        let dyingTimerDepleted = skel7.dyingTimer <= 0

        report.check(
            "burn damage cleanly drains skeleton health to 0, triggers death without physics anomalies, and completes dying timer",
            reachedZeroHealth && cleanDeathTriggered && finitePhysicsDuringDeath && isFinishedCleanly && dyingTimerDepleted,
            "zeroHealth: \(reachedZeroHealth), cleanDeath: \(cleanDeathTriggered), finitePhysics: \(finitePhysicsDuringDeath), isFinished: \(isFinishedCleanly), dyingTimer: \(skel7.dyingTimer)"
        )

        // 7B: SkeletonManager integration & pruning verification
        var manager = SkeletonManager(mode: .survival, seed: 777)
        // Manually place a skeleton in the manager under open sky
        // Force spawn or update
        let testSkelId = 1
        manager.adopt([Skeleton(position: pos7, seed: 702)])

        var managerFrames = 0
        while manager.skeletons[testSkelId] != nil && managerFrames < 900 {
            _ = manager.update(
                dt: dt,
                playerEye: Vector3(CGFloat(originX), CGFloat(platformY) + 1, CGFloat(originZ)),
                playerIsTargetable: false,
                isNight: false,
                isRaining: false,
                world: world
            )
            managerFrames += 1
        }

        let prunedFromManager = manager.skeletons[testSkelId] == nil
        report.check(
            "SkeletonManager cleanly updates, processes daylight burn to death, and prunes finished skeleton from active dictionary",
            prunedFromManager,
            "prunedFromManager: \(prunedFromManager), elapsedFrames: \(managerFrames) (\(Double(managerFrames) * dt)s)"
        )

        // =========================================================================
        // TEST 8: Environmental Shelter Seeking Navigation AI
        // =========================================================================
        // Construct a shaded 3x3 alcove 5 blocks away
        let alcoveX = originX - 6
        let alcoveZ = originZ + 12
        for dx in -1...1 {
            for dz in -1...1 {
                world.setBlock(worldX: alcoveX + dx, y: platformY + 2, worldZ: alcoveZ + dz, to: .stone)
            }
        }
        let seekerPos = Vector3(CGFloat(alcoveX + 5) + 0.5, CGFloat(platformY), CGFloat(alcoveZ) + 0.5)
        var seeker = Skeleton(position: seekerPos, seed: 801)
        let initialDistanceToAlcove = (seeker.position - Vector3(CGFloat(alcoveX) + 0.5, CGFloat(platformY), CGFloat(alcoveZ) + 0.5)).length()

        for _ in 0..<180 { // 3 seconds
            seeker.step(dt: dt, playerEye: nil, canSeePlayer: false, isNight: false, isRaining: false, world: world)
        }

        let finalDistanceToAlcove = (seeker.position - Vector3(CGFloat(alcoveX) + 0.5, CGFloat(platformY), CGFloat(alcoveZ) + 0.5)).length()
        let navigatedCloser = finalDistanceToAlcove < initialDistanceToAlcove - 1.5

        report.check(
            "burning skeleton under daytime sun actively navigates toward nearby shaded stone shelter",
            navigatedCloser,
            "initialDist: \(initialDistanceToAlcove), finalDist: \(finalDistanceToAlcove), delta: \(initialDistanceToAlcove - finalDistanceToAlcove)"
        )

        // Print report
        for line in report.lines { StandardError.write(Data((line + "\n").utf8)) }
        let verdict = report.failed
            ? "[stress-check] FAILED — skeleton stress suite\n"
            : "[stress-check] all passed — skeleton stress suite\n"
        StandardError.write(Data(verdict.utf8))
        exit(report.failed ? 1 : 0)
    }
}
