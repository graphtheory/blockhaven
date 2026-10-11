#if canImport(AppKit)
import RealityKit
import AppKit

/// The visible animal: a long body on four legs with a head at the front,
/// built from boxes because that is all an animal in this kind of game is.
///
/// One of these is kept per live animal and moved each frame; the
/// simulation in `Animal` never touches RealityKit.
@MainActor
final class AnimalEntity {
    /// Box sizes in blocks. Length runs along local +z, which is the way
    /// the root is yawed to face, so the head goes on the front.
    private struct Build {
        let bodyWidth: Float
        let bodyHeight: Float
        let bodyLength: Float
        let headSize: Float
        let legWidth: Float
        let legHeight: Float
        /// How far the head sits above the top of the body.
        let headRise: Float
    }

    /// The three quadrupeds' proportions. Only they use `Build`; the other
    /// four each have their own builder and their own dimensions, which is
    /// why this is a value handed to `buildQuadruped` rather than a switch
    /// over every kind with four arms nothing reads.
    private static let pigShape = Build(
        bodyWidth: 0.50, bodyHeight: 0.50, bodyLength: 0.80,
        headSize: 0.42, legWidth: 0.16, legHeight: 0.35, headRise: 0
    )
    private static let cowShape = Build(
        bodyWidth: 0.62, bodyHeight: 0.62, bodyLength: 1.00,
        headSize: 0.50, legWidth: 0.20, legHeight: 0.62, headRise: 0.08
    )
    private static let sheepShape = Build(
        bodyWidth: 0.55, bodyHeight: 0.60, bodyLength: 0.85,
        headSize: 0.42, legWidth: 0.17, legHeight: 0.55, headRise: 0.04
    )

    private static let wolfShape = Build(
        bodyWidth: 0.36, bodyHeight: 0.40, bodyLength: 0.72,
        headSize: 0.34, legWidth: 0.13, legHeight: 0.42, headRise: 0.10
    )

    let root = Entity()
    /// Bobbed and tinted; separate from `root` so the walk bob doesn't
    /// fight the position and yaw set on the root.
    private let body = Entity()
    /// Every box of the model, each remembering the two sets of materials
    /// it swaps between. Keeping them per part is what lets the axolotl's
    /// gills be a different pink from its belly without the tint swap
    /// having to know which index is which.
    private var parts: [Part] = []
    /// Hip pivots, one per leg, each rotated about x for the walk gait.
    /// Empty for the kinds that don't animate their legs.
    private var legPivots: [(entity: Entity, phase: Float)] = []
    /// Rotated about y for the tail sway; nil for the kinds without one.
    private var tailPivot: Entity?
    /// The chicken's two wings, each rotated about z so they beat out and
    /// down. Empty for everything else.
    private var wingPivots: [(entity: Entity, side: Float)] = []
    /// The squid's arms, each rotated about its own outward axis so the
    /// whole crown folds and spreads together.
    private var armPivots: [(entity: Entity, axis: SIMD3<Float>)] = []
    private let kind: AnimalKind
    private let morph: AnimalMorph
    /// Advances with distance covered, so the bob keeps time with the legs
    /// rather than with the clock.
    private var bobPhase: Double = 0
    /// Advances with the clock: a hovering axolotl still waves its tail.
    private var swayPhase: Double = 0
    /// Advances with the clock while a bird is beating its wings.
    private var flapPhase: Double = 0
    /// The nose-up angle a swimmer is holding, eased toward the one its
    /// velocity implies so a fish banks into a dive instead of snapping.
    private var pitch: Float = 0

    private struct Part {
        let entity: ModelEntity
        let plain: [any Material]
        let hurt: [any Material]
    }

    init(kind: AnimalKind, morph: AnimalMorph = .common) {
        self.kind = kind
        self.morph = morph
        root.addChild(body)
        // A switch on the kind, not on `isAquatic`, which is what this was
        // when there was one swimmer: that fork silently built any later
        // water animal as an axolotl, gill fronds and all.
        switch kind {
        case .pig: buildQuadruped(AnimalEntity.pigShape)
        case .cow: buildQuadruped(AnimalEntity.cowShape)
        case .sheep: buildQuadruped(AnimalEntity.sheepShape)
        case .chicken: buildChicken()
        case .axolotl: buildAxolotl()
        case .cod: buildCod()
        case .squid: buildSquid()
        case .wolf: buildWolf()
        }
    }

    /// A wolf: the quadruped, plus the three things that make a box of fur
    /// read as a dog rather than as a small pale cow — a snout, pricked
    /// ears, and a tail that sways.
    ///
    /// It goes through `buildQuadruped` rather than duplicating it, so the
    /// hips and the walk cycle come for free and a dog trotting after you
    /// moves its legs like everything else on four of them.
    private func buildWolf() {
        let shape = AnimalEntity.wolfShape
        buildQuadruped(shape)

        let skin = AnimalEntity.skinMaterial(for: key)
        let flash = AnimalEntity.hurtMaterial(for: key)
        let headY = shape.legHeight + shape.bodyHeight - shape.headSize / 2 + shape.headRise
        let headZ = shape.bodyLength / 2 + shape.headSize / 2 - 0.05

        // The snout, out of the front of the head and a little below its
        // middle, which is what stops the face reading as a cube with eyes.
        addBox(
            size: SIMD3(0.15, 0.13, 0.16),
            at: SIMD3(0, headY - 0.06, headZ + shape.headSize / 2 + 0.06),
            materials: AnimalEntity.snoutMaterial(for: key), hurt: flash
        )
        // Two ears, pricked. Small enough that they are a silhouette rather
        // than a feature, which is all a 16-pixel dog needs.
        for side in [-1.0, 1.0] as [Float] {
            addBox(
                size: SIMD3(0.09, 0.13, 0.06),
                at: SIMD3(side * 0.10, headY + shape.headSize / 2 + 0.04, headZ - 0.02),
                materials: skin, hurt: flash
            )
        }

        // The tail, on a pivot so it can wag. Hung off the back of the body
        // and angled up, because a tail that hangs straight down is a tail
        // on an unhappy dog.
        let pivot = Entity()
        pivot.position = SIMD3(0, shape.legHeight + shape.bodyHeight - 0.06,
                               -shape.bodyLength / 2)
        body.addChild(pivot)
        tailPivot = pivot
        addBox(
            size: SIMD3(0.09, 0.09, 0.30),
            at: SIMD3(0, 0.06, -0.13),
            materials: skin, hurt: flash, parent: pivot
        )
    }

    /// What the shared material caches below are keyed on: which animal,
    /// and which of its colours.
    private struct Skin: Hashable {
        let kind: AnimalKind
        let morph: AnimalMorph
    }

    private var key: Skin { Skin(kind: kind, morph: morph) }

    private func buildQuadruped(_ shape: Build) {
        let skin = AnimalEntity.skinMaterial(for: key)
        let flash = AnimalEntity.hurtMaterial(for: key)
        let bodyY = shape.legHeight + shape.bodyHeight / 2
        let headY = shape.legHeight + shape.bodyHeight - shape.headSize / 2 + shape.headRise
        let headZ = shape.bodyLength / 2 + shape.headSize / 2 - 0.05

        addBox(
            size: SIMD3(shape.bodyWidth, shape.bodyHeight, shape.bodyLength),
            at: SIMD3(0, bodyY, 0), materials: skin, hurt: flash
        )
        addBox(
            size: SIMD3(repeating: shape.headSize),
            at: SIMD3(0, headY, headZ),
            materials: AnimalEntity.headMaterials(for: key),
            hurt: AnimalEntity.hurtHeadMaterial(for: key),
            splitFaces: true
        )

        // Four legs, one under each corner of the body, each hung off a hip
        // pivot at the top of the leg so it swings from the shoulder rather
        // than about its own middle.
        //
        // These used to be plain boxes and the animation gate above used to
        // read `guard kind.isAquatic`, which meant the pig, the cow and the
        // sheep slid across the ground with their legs rigid from the day
        // they shipped. Four pivots is the whole fix, and it is the single
        // largest difference between a field of animals and a field of
        // furniture.
        let legX = (shape.bodyWidth - shape.legWidth) / 2
        let legZ = shape.bodyLength / 2 - shape.legWidth / 2 - 0.02
        for (index, offset) in [(-legX, legZ), (legX, legZ), (-legX, -legZ), (legX, -legZ)]
            .enumerated() {
            let hip = Entity()
            hip.position = SIMD3(offset.0, shape.legHeight, offset.1)
            body.addChild(hip)
            // Opposite corners in step, the way a walk cycle pairs them:
            // front-left with back-right.
            legPivots.append((hip, index == 0 || index == 3 ? 0 : .pi))
            addBox(
                size: SIMD3(shape.legWidth, shape.legHeight, shape.legWidth),
                at: SIMD3(0, -shape.legHeight / 2, 0),
                materials: skin, hurt: flash, parent: hip
            )
        }
    }

    /// The chicken: a plump body on two legs, a small head with a beak, a
    /// comb and a wattle, and a wing down each side that beats when it is
    /// falling. The comb and the beak are the whole silhouette — without
    /// them this is a very small sheep.
    private func buildChicken() {
        let skin = AnimalEntity.skinMaterial(for: key)
        let flash = AnimalEntity.hurtMaterial(for: key)
        let beak = AnimalEntity.beakMaterial
        let comb = AnimalEntity.combMaterial

        let legHeight: Float = 0.20
        let legWidth: Float = 0.055
        let bodyWidth: Float = 0.28
        let bodyHeight: Float = 0.26
        let bodyLength: Float = 0.36
        let headSize: Float = 0.19

        let bodyY = legHeight + bodyHeight / 2
        let headY = legHeight + bodyHeight + headSize / 2 - 0.04
        let headZ = bodyLength / 2 - 0.02

        addBox(
            size: SIMD3(bodyWidth, bodyHeight, bodyLength),
            at: SIMD3(0, bodyY, 0), materials: skin, hurt: flash
        )
        addBox(
            size: SIMD3(repeating: headSize),
            at: SIMD3(0, headY, headZ),
            materials: AnimalEntity.headMaterials(for: key),
            hurt: AnimalEntity.hurtHeadMaterial(for: key),
            splitFaces: true
        )
        // Beak straight out in front, wattle hanging under it, comb along
        // the top of the skull. All three take the body's hurt flash: there
        // is no whitened beak texture, and at this size a red tint over
        // orange would land somewhere indistinguishable from red anyway.
        addBox(
            size: SIMD3(0.07, 0.05, 0.09),
            at: SIMD3(0, headY - 0.01, headZ + headSize / 2 + 0.03),
            materials: beak, hurt: flash
        )
        addBox(
            size: SIMD3(0.05, 0.06, 0.04),
            at: SIMD3(0, headY - 0.07, headZ + headSize / 2 + 0.01),
            materials: comb, hurt: flash
        )
        addBox(
            size: SIMD3(0.04, 0.07, 0.13),
            at: SIMD3(0, headY + headSize / 2 + 0.02, headZ - 0.01),
            materials: comb, hurt: flash
        )

        // A wing a side, on a pivot at the shoulder so the beat swings the
        // far edge down rather than sliding the whole slab.
        for side in [Float(1), Float(-1)] {
            let shoulder = Entity()
            shoulder.position = SIMD3(side * bodyWidth / 2, bodyY + bodyHeight / 2 - 0.04, 0)
            body.addChild(shoulder)
            wingPivots.append((shoulder, side))
            addBox(
                size: SIMD3(0.035, 0.16, 0.28),
                at: SIMD3(side * 0.02, -0.08, -0.02),
                materials: skin, hurt: flash, parent: shoulder
            )
        }

        // Two legs, half a body apart, in step opposite one another.
        for (index, dx) in [-bodyWidth / 4, bodyWidth / 4].enumerated() {
            let hip = Entity()
            hip.position = SIMD3(dx, legHeight, -0.02)
            body.addChild(hip)
            legPivots.append((hip, index == 0 ? 0 : .pi))
            addBox(
                size: SIMD3(legWidth, legHeight, legWidth),
                at: SIMD3(0, -legHeight / 2, 0),
                materials: beak, hurt: flash, parent: hip
            )
            // A foot, so the leg ends in something rather than stopping.
            addBox(
                size: SIMD3(legWidth, 0.03, 0.09),
                at: SIMD3(0, -legHeight + 0.015, 0.02),
                materials: beak, hurt: flash, parent: hip
            )
        }
    }

    /// The axolotl, which is not a quadruped with a cube for a head: a flat
    /// wide head carrying three gill fronds a side, a pill of a body on
    /// four stubby legs, and a tall flat tail fin behind it. The fronds are
    /// the whole silhouette — without them this is a small pink pig.
    private func buildAxolotl() {
        let skin = AnimalEntity.skinMaterial(for: key)
        let flash = AnimalEntity.hurtMaterial(for: key)
        let gill = AnimalEntity.frillMaterial(for: key)
        let belly = AnimalEntity.bellyMaterial(for: key)

        let legHeight: Float = 0.10
        let legWidth: Float = 0.07
        let bodyWidth: Float = 0.26
        let bodyHeight: Float = 0.20
        let bodyLength: Float = 0.42
        let headWidth: Float = 0.34
        let headHeight: Float = 0.16
        let headDepth: Float = 0.26

        let bodyY = legHeight + bodyHeight / 2
        let headZ = bodyLength / 2 + headDepth / 2 - 0.03

        addBox(
            size: SIMD3(bodyWidth, bodyHeight, bodyLength),
            at: SIMD3(0, bodyY, 0), materials: skin, hurt: flash
        )
        // The head is flatter and wider than the body, which is what makes
        // the profile an axolotl's rather than a piglet's.
        addBox(
            size: SIMD3(headWidth, headHeight, headDepth),
            at: SIMD3(0, bodyY, headZ),
            materials: AnimalEntity.headMaterials(for: key),
            hurt: AnimalEntity.hurtHeadMaterial(for: key),
            splitFaces: true
        )
        // A pale slab along the underside, so a low view of it isn't one
        // unbroken slab of pink.
        addBox(
            size: SIMD3(bodyWidth * 0.92, 0.05, bodyLength * 0.86),
            at: SIMD3(0, legHeight + 0.02, 0), materials: belly, hurt: flash
        )

        // Three fronds a side, fanned up, level and down, each swept back
        // from the corner of the head. Built on a pivot at the attachment
        // point with the box hung off its local +x, so one pair of angles
        // aims each one.
        let frondLength: Float = 0.17
        let frondThickness: Float = 0.055
        for side in [Float(1), Float(-1)] {
            for pitch in [Float(0.42), 0, -0.42] {
                let pivot = Entity()
                pivot.position = SIMD3(side * headWidth / 2, bodyY + pitch * 0.05, headZ - 0.03)
                // Right side sweeps +x and back; left is the mirror of it.
                let sweep: Float = side > 0 ? 0.55 : .pi - 0.55
                pivot.orientation = simd_quatf(angle: sweep, axis: SIMD3(0, 1, 0))
                    * simd_quatf(angle: pitch, axis: SIMD3(0, 0, 1))
                body.addChild(pivot)
                // Hurt, the fronds take the body's flash rather than one of
                // their own: there is no whitened frond texture, and at
                // 0.055 thick under a red tint there would be nothing to
                // see if there were.
                addBox(
                    size: SIMD3(frondLength, frondThickness, frondThickness),
                    at: SIMD3(frondLength / 2, 0, 0),
                    materials: gill, hurt: flash, parent: pivot
                )
            }
        }

        // Tail: a stub of body, then a tall flat fin. Both hang off one
        // pivot at the back of the body so the whole thing sways together.
        let tail = Entity()
        tail.position = SIMD3(0, bodyY, -bodyLength / 2)
        body.addChild(tail)
        tailPivot = tail
        addBox(
            size: SIMD3(0.11, 0.13, 0.20),
            at: SIMD3(0, 0, -0.09), materials: skin, hurt: flash, parent: tail
        )
        // The fin is body-coloured, not frond-coloured: a darker slab out
        // there reads as a separate object floating behind the animal
        // rather than as the end of its tail.
        addBox(
            size: SIMD3(0.03, 0.28, 0.30),
            at: SIMD3(0, 0.02, -0.32), materials: skin, hurt: flash, parent: tail
        )

        // Four stubby legs on hip pivots, opposite corners in step, the way
        // a walk cycle pairs them.
        let legX = (bodyWidth + legWidth) / 2 - 0.01
        let legZ = bodyLength / 2 - legWidth
        for (index, offset) in [(-legX, legZ), (legX, legZ), (-legX, -legZ), (legX, -legZ)]
            .enumerated() {
            let hip = Entity()
            hip.position = SIMD3(offset.0, legHeight, offset.1)
            body.addChild(hip)
            legPivots.append((hip, index == 0 || index == 3 ? 0 : .pi))
            addBox(
                size: SIMD3(legWidth, legHeight, legWidth),
                at: SIMD3(0, -legHeight / 2, 0), materials: skin, hurt: flash, parent: hip
            )
        }
    }

    /// The cod: a flat deep body with a pale belly, a dorsal fin, a pair of
    /// pectorals and a tail that never stops. Its eyes are their own little
    /// boxes on the sides of the head rather than a face texture, because a
    /// fish is nearly always seen side-on and the split-face head only ever
    /// paints its front.
    private func buildCod() {
        let skin = AnimalEntity.skinMaterial(for: key)
        let flash = AnimalEntity.hurtMaterial(for: key)
        let fin = AnimalEntity.frillMaterial(for: key)
        let belly = AnimalEntity.bellyMaterial(for: key)
        let eye = AnimalEntity.eyeMaterial

        // Long and narrow, and deeper than it is wide. A fish that is as
        // wide as it is deep is a lump from every angle; the proportions
        // are what make this read as a fish before the fins do.
        let bodyWidth: Float = 0.10
        let bodyHeight: Float = 0.18
        let bodyLength: Float = 0.34
        let headWidth: Float = 0.10
        let headHeight: Float = 0.15
        let headDepth: Float = 0.12
        let bodyY = Float(kind.height) / 2

        addBox(
            size: SIMD3(bodyWidth, bodyHeight, bodyLength),
            at: SIMD3(0, bodyY, 0), materials: skin, hurt: flash
        )
        let headZ = bodyLength / 2 + headDepth / 2 - 0.02
        addBox(
            size: SIMD3(headWidth, headHeight, headDepth),
            at: SIMD3(0, bodyY, headZ), materials: skin, hurt: flash
        )
        for side in [Float(1), Float(-1)] {
            addBox(
                size: SIMD3(0.015, 0.04, 0.04),
                at: SIMD3(side * headWidth / 2, bodyY + 0.025, headZ + 0.02),
                materials: eye, hurt: flash
            )
        }
        // A pale slab along the underside — the same trick the axolotl's
        // belly plays, and the reason a fish seen from below is not one
        // unbroken slab of olive.
        addBox(
            size: SIMD3(bodyWidth * 0.9, 0.04, bodyLength * 0.88),
            at: SIMD3(0, bodyY - bodyHeight / 2 + 0.02, 0), materials: belly, hurt: flash
        )
        // Dorsal along the spine, and a pectoral a side swept back.
        addBox(
            size: SIMD3(0.02, 0.07, 0.18),
            at: SIMD3(0, bodyY + bodyHeight / 2 + 0.03, -0.01), materials: fin, hurt: flash
        )
        for side in [Float(1), Float(-1)] {
            addBox(
                size: SIMD3(0.07, 0.02, 0.09),
                at: SIMD3(side * (bodyWidth / 2 + 0.03), bodyY - 0.03, 0.05),
                materials: fin, hurt: flash
            )
        }

        // The tail, on one pivot at the back of the body so the whole fin
        // sweeps rather than sliding.
        let tail = Entity()
        tail.position = SIMD3(0, bodyY, -bodyLength / 2)
        body.addChild(tail)
        tailPivot = tail
        addBox(
            size: SIMD3(0.02, 0.19, 0.14),
            at: SIMD3(0, 0, -0.08), materials: fin, hurt: flash, parent: tail
        )
    }

    /// The squid: a tapered mantle with a fin a side and eight arms hanging
    /// under it, each on its own pivot so the whole crown folds shut on the
    /// stroke and spreads again as it coasts.
    private func buildSquid() {
        let skin = AnimalEntity.skinMaterial(for: key)
        let flash = AnimalEntity.hurtMaterial(for: key)
        let arm = AnimalEntity.frillMaterial(for: key)
        let eye = AnimalEntity.eyeMaterial

        let mantleWidth: Float = 0.34
        let mantleHeight: Float = 0.34
        let mantleDepth: Float = 0.34
        // The arms hang below the mantle, so the mantle sits high in the
        // box and the origin — the animal's feet — is the tips of the arms.
        let mantleY = Float(kind.height) - mantleHeight / 2

        addBox(
            size: SIMD3(mantleWidth, mantleHeight, mantleDepth),
            at: SIMD3(0, mantleY, 0), materials: skin, hurt: flash
        )
        // A narrower cap on top, which is what turns a cube into something
        // that reads as tapered.
        addBox(
            size: SIMD3(mantleWidth * 0.66, 0.10, mantleDepth * 0.66),
            at: SIMD3(0, mantleY + mantleHeight / 2 + 0.04, 0), materials: skin, hurt: flash
        )
        // The big eyes, high on the sides where a squid's are.
        for side in [Float(1), Float(-1)] {
            addBox(
                size: SIMD3(0.02, 0.09, 0.09),
                at: SIMD3(side * mantleWidth / 2, mantleY + 0.05, 0.06),
                materials: eye, hurt: flash
            )
        }
        // Fins either side of the cap.
        for side in [Float(1), Float(-1)] {
            addBox(
                size: SIMD3(0.09, 0.03, 0.14),
                at: SIMD3(side * (mantleWidth / 2 + 0.04), mantleY + mantleHeight / 2 - 0.02, -0.04),
                materials: arm, hurt: flash
            )
        }

        // Eight arms in a ring under the mantle. Each pivot is rotated to
        // face outward first, so one angle about its local x folds it in
        // and out whichever way round the ring it sits.
        let armLength: Float = 0.30
        let ring: Float = 0.11
        for index in 0..<8 {
            let angle = Float(index) / 8 * 2 * .pi
            let socket = Entity()
            socket.position = SIMD3(
                sin(angle) * ring, mantleY - mantleHeight / 2, cos(angle) * ring
            )
            socket.orientation = simd_quatf(angle: angle, axis: SIMD3(0, 1, 0))
            body.addChild(socket)
            armPivots.append((socket, SIMD3(1, 0, 0)))
            addBox(
                size: SIMD3(0.05, armLength, 0.05),
                at: SIMD3(0, -armLength / 2, 0), materials: arm, hurt: flash, parent: socket
            )
        }
    }

    /// `splitFaces` gives each of the six faces its own material slot
    /// instead of stretching one texture over the whole box — only the head
    /// needs that, so a face texture can land on the front and nowhere
    /// else. Every other part stays a single untextured-per-face box: six
    /// materials per part, times every body and leg, would multiply draw
    /// calls for a distinction nothing there needs.
    private func addBox(
        size: SIMD3<Float>, at position: SIMD3<Float>,
        materials: [any Material], hurt: [any Material],
        splitFaces: Bool = false, parent: Entity? = nil
    ) {
        let mesh = splitFaces
            ? MeshResource.generateBox(width: size.x, height: size.y, depth: size.z, splitFaces: true)
            : MeshResource.generateBox(size: size)
        let part = ModelEntity(mesh: mesh, materials: materials)
        part.position = position
        (parent ?? body).addChild(part)
        parts.append(Part(entity: part, plain: materials, hurt: hurt))
    }

    /// Moves the entity to match one frame of simulation.
    func apply(_ animal: Animal, dt: Double) {
        place(position: animal.position, facing: animal.facing, hurt: animal.isHurt)

        // A gentle lift while it's actually walking. `1 - cos` only ever
        // rises, so the legs never sink into the ground at the bottom of
        // the bob, and the amplitude rides the speed so a standing animal
        // settles flat instead of freezing mid-bounce.
        let speed = Float(animal.horizontalSpeed)
        bobPhase += Double(speed) * dt * 7
        body.position.y = (1 - cos(Float(bobPhase))) * 0.02 * min(1, speed / 1.5)

        applyPitch(animal, dt: dt)

        if animal.isSwimming {
            swimAnimation(animal, dt: dt)
        } else {
            landAnimation(animal, dt: dt, speed: speed)
        }
    }

    /// Tips a swimmer's nose along the way it is actually going.
    ///
    /// On `body` rather than `root`, so it does not fight the yaw and so
    /// the tail and arm pivots — which are `body`'s children — sway in the
    /// tipped frame, which is the difference between a fish diving and a
    /// fish sliding downhill flat. Eased rather than set, because the
    /// vertical component of a swim heading changes far more sharply than
    /// the animal visibly can.
    private func applyPitch(_ animal: Animal, dt: Double) {
        guard kind.isAquatic else { return }
        let velocity = animal.velocity
        let magnitude = Float(
            sqrt(velocity.x * velocity.x + velocity.y * velocity.y + velocity.z * velocity.z)
        )
        // Under a crawl there is no heading worth tipping toward, and the
        // division would amplify noise into a twitch.
        let target = magnitude < 0.05
            ? 0
            : asin(max(-0.75, min(0.75, Float(velocity.y) / magnitude)))
        pitch += (target - pitch) * Float(min(1, 5 * dt))
        // Negative: a rotation about +x takes the model's forward (+z)
        // toward -y, so the sign has to be flipped for a rising animal to
        // point up rather than down.
        body.orientation = simd_quatf(angle: -pitch, axis: SIMD3(1, 0, 0))
    }

    /// Swimming: whatever this kind does with its moving parts in water.
    private func swimAnimation(_ animal: Animal, dt: Double) {
        switch kind {
        case .squid:
            // The arms fold shut on the stroke and spread as it coasts, so
            // the animation is driven by the simulation's pulse rather than
            // by a clock of its own — what you see is what is pushing it.
            let fold = 0.55 - Float(animal.jetPulse) * 0.95
            for arm in armPivots {
                arm.entity.orientation = simd_quatf(angle: fold, axis: arm.axis)
            }
        case .cod:
            // A fish's tail never stops, and it beats faster the faster it
            // is going — the one cue that tells a cruising cod from one
            // bolting away from a swing.
            swayPhase += dt * (4.0 + Double(animal.horizontalSpeed) * 3.0)
            tailPivot?.orientation = simd_quatf(
                angle: sin(Float(swayPhase)) * 0.55, axis: SIMD3(0, 1, 0)
            )
        case .wolf:
            // The wag, and it is the only thing in this game that says out
            // loud that an animal is yours. A tamed wolf wags hard and
            // fast; a wild one carries its tail like every other tail here.
            let wag = animal.isTamed ? 8.5 : 5.5
            let swing: Float = animal.isTamed ? 0.95 : 0.45
            swayPhase += dt * wag
            tailPivot?.orientation = simd_quatf(
                angle: sin(Float(swayPhase)) * swing, axis: SIMD3(0, 1, 0)
            )
            for leg in legPivots {
                leg.entity.orientation = simd_quatf(
                    angle: sin(Float(swayPhase) + leg.phase) * 0.12, axis: SIMD3(1, 0, 0)
                )
            }
        default:
            swayPhase += dt * 5.5
            tailPivot?.orientation = simd_quatf(
                angle: sin(Float(swayPhase)) * 0.45, axis: SIMD3(0, 1, 0)
            )
            for leg in legPivots {
                leg.entity.orientation = simd_quatf(
                    angle: sin(Float(swayPhase) + leg.phase) * 0.12, axis: SIMD3(1, 0, 0)
                )
            }
        }
    }

    /// On the ground — or, for a stranded swimmer, on the beach. The tail
    /// goes still and the legs take up the walk gait, which is what makes
    /// the flopping read as effort rather than as gliding.
    private func landAnimation(_ animal: Animal, dt: Double, speed: Float) {
        if kind.isAquatic {
            swayPhase += dt * 1.2
            tailPivot?.orientation = simd_quatf(
                angle: sin(Float(swayPhase)) * 0.1, axis: SIMD3(0, 1, 0)
            )
        }

        // A bird beating its way down flaps hard and holds its legs still;
        // one on its feet tucks the wings and walks.
        if !wingPivots.isEmpty {
            let beating = animal.isGliding
            flapPhase += dt * (beating ? 22.0 : 3.0)
            let sweep = beating
                ? 0.55 + sin(Float(flapPhase)) * 0.75
                : 0.06 + sin(Float(flapPhase)) * 0.05
            for wing in wingPivots {
                wing.entity.orientation = simd_quatf(
                    angle: wing.side * sweep, axis: SIMD3(0, 0, 1)
                )
            }
            // Legs dangle rather than stride while it is in the air.
            if beating {
                for leg in legPivots {
                    leg.entity.orientation = simd_quatf(angle: 0.35, axis: SIMD3(1, 0, 0))
                }
                return
            }
        }

        // The gait. `bobPhase` advances with distance covered rather than
        // with the clock, so the legs keep time with the ground and a
        // standing animal settles straight instead of freezing mid-stride.
        let reference = Float(kind.isAquatic ? kind.walkSpeed : kind.walkSpeed * 0.6)
        let swing = min(1, speed / max(0.05, reference))
        for leg in legPivots {
            leg.entity.orientation = simd_quatf(
                angle: sin(Float(bobPhase) + leg.phase) * 0.5 * swing, axis: SIMD3(1, 0, 0)
            )
        }
    }

    /// The posing primitive `apply` is built on, with no animation state,
    /// so an animal can also be placed for a still.
    func place(position: Vector3, facing: CGFloat, hurt: Bool = false) {
        root.position = SIMD3(Float(position.x), Float(position.y), Float(position.z))
        root.orientation = simd_quatf(angle: Float(facing), axis: SIMD3(0, 1, 0))
        setTint(hurt ? .hurt : .plain)
    }

    /// Poses the moving parts for a still, so a portrait can show the
    /// swimming shape — tail off to one side, legs trailing, a squid's arms
    /// part way through a stroke — without a simulation running behind it.
    func poseSwimming(_ phase: Float) {
        tailPivot?.orientation = simd_quatf(angle: sin(phase) * 0.45, axis: SIMD3(0, 1, 0))
        for leg in legPivots {
            leg.entity.orientation = simd_quatf(
                angle: sin(phase + leg.phase) * 0.14, axis: SIMD3(1, 0, 0)
            )
        }
        // Mid-spread, which is where a squid spends most of its cycle and
        // the only pose in which all eight arms are separately visible.
        for arm in armPivots {
            arm.entity.orientation = simd_quatf(
                angle: 0.35 + sin(phase) * 0.18, axis: arm.axis
            )
        }
        for wing in wingPivots {
            wing.entity.orientation = simd_quatf(
                angle: wing.side * (0.8 + sin(phase) * 0.5), axis: SIMD3(0, 0, 1)
            )
        }
    }

    /// The same, mid-stride on land: legs swung apart, tail nearly still,
    /// a bird's wings folded.
    func poseWalking(_ phase: Float) {
        tailPivot?.orientation = simd_quatf(angle: sin(phase) * 0.1, axis: SIMD3(0, 1, 0))
        for leg in legPivots {
            leg.entity.orientation = simd_quatf(
                angle: sin(phase + leg.phase) * 0.5, axis: SIMD3(1, 0, 0)
            )
        }
        for wing in wingPivots {
            wing.entity.orientation = simd_quatf(angle: wing.side * 0.08, axis: SIMD3(0, 0, 1))
        }
    }

    private enum Tint { case plain, hurt }
    private var tint = Tint.plain

    /// Swaps the whole model between its normal skin and the red hurt
    /// flash, which is also what a dying animal wears until it's cleared.
    private func setTint(_ next: Tint) {
        guard next != tint else { return }
        tint = next
        for part in parts {
            part.entity.model?.materials = next == .plain ? part.plain : part.hurt
        }
    }

    // MARK: - Materials

    /// Built once per kind-and-colour on first use and shared by every
    /// animal wearing it — five of these are cheap, one per animal would
    /// not be.
    ///
    /// Cached as the single-element arrays `ModelComponent.materials` wants
    /// rather than as bare materials, so swapping a tint allocates nothing:
    /// `place` asks for one on every animal on every frame, and the array
    /// literal it used to build was the only thing there that touched the
    /// heap.
    private static var skinMaterials: [Skin: [any Material]] = [:]
    private static var headMaterialCache: [Skin: [any Material]] = [:]
    private static var hurtMaterials: [Skin: [any Material]] = [:]
    private static var hurtHeadMaterials: [Skin: [any Material]] = [:]
    private static var frillMaterials: [Skin: [any Material]] = [:]
    private static var bellyMaterials: [Skin: [any Material]] = [:]

    /// The head box is built with `splitFaces: true`, which hands each of
    /// its six faces its own material slot instead of one texture stretched
    /// over the whole cube. This is the slot that lands on the box's local
    /// +Z face — the one `headZ` in the builders pushes forward, and the one
    /// `place`'s yaw turns to face the camera — measured empirically off a
    /// six-colour test box rendered through the snapshot harness rather
    /// than assumed: `generateBox`'s face order is not documented.
    private static let frontFaceIndex = 0

    private static func skinMaterial(for skin: Skin) -> [any Material] {
        if let cached = skinMaterials[skin] { return cached }
        let material: [any Material] = [unlit(
            texture(AnimalSkin.body(for: skin.kind, morph: skin.morph)), tint: .white
        )]
        skinMaterials[skin] = material
        return material
    }

    /// Six materials for the split-face head box: the face texture on the
    /// front, the plain hide (no facial features) on the other five, so a
    /// head reads as a face only when you're looking at it from the front.
    private static func headMaterials(for skin: Skin) -> [any Material] {
        if let cached = headMaterialCache[skin] { return cached }
        let face = unlit(texture(AnimalSkin.head(for: skin.kind, morph: skin.morph)), tint: .white)
        let fur = unlit(texture(AnimalSkin.body(for: skin.kind, morph: skin.morph)), tint: .white)
        var faces: [any Material] = Array(repeating: fur, count: 6)
        faces[frontFaceIndex] = face
        headMaterialCache[skin] = faces
        return faces
    }

    /// The hurt flash, built on the whitened hide: a tint can only
    /// multiply, so red over a pale skin lands on red, while red over a
    /// brown one would land on mud.
    private static func hurtMaterial(for skin: Skin) -> [any Material] {
        if let cached = hurtMaterials[skin] { return cached }
        let material: [any Material] = [unlit(
            texture(AnimalSkin.flash(for: skin.kind, morph: skin.morph)),
            tint: NSColor(calibratedRed: 1, green: 0.28, blue: 0.24, alpha: 1)
        )]
        hurtMaterials[skin] = material
        return material
    }

    /// The same flash, six times over: the flash texture carries no face
    /// either way, so the split-face head just needs the one material
    /// repeated into all six slots the mesh expects.
    private static func hurtHeadMaterial(for skin: Skin) -> [any Material] {
        if let cached = hurtHeadMaterials[skin] { return cached }
        let flash = hurtMaterial(for: skin)[0]
        let faces = Array(repeating: flash, count: 6)
        hurtHeadMaterials[skin] = faces
        return faces
    }

    /// The frilly bits a shade off the hide — the axolotl's gill fronds, a
    /// cod's fins, a squid's arms — and the pale belly under it.
    ///
    /// Both take the whole `Skin`, kind included. They used to pass only
    /// the morph down to `AnimalSkin`, from when the axolotl was the only
    /// animal with either: that spelling would have dressed the cod's fins
    /// and the squid's arms in axolotl pink, with a green build and nothing
    /// but a render to say so.
    private static func frillMaterial(for skin: Skin) -> [any Material] {
        if let cached = frillMaterials[skin] { return cached }
        let material: [any Material] =
            [unlit(texture(AnimalSkin.frill(for: skin.kind, morph: skin.morph)), tint: .white)]
        frillMaterials[skin] = material
        return material
    }

    /// The wolf's muzzle: the same pale grey its belly would be, which is
    /// what makes a grey dog's face read as a face at this size. Reuses the
    /// belly texture rather than adding a ninth one — a snout the colour of
    /// a pale underside is exactly right and costs nothing.
    private static func snoutMaterial(for skin: Skin) -> [any Material] {
        bellyMaterial(for: skin)
    }

    private static func bellyMaterial(for skin: Skin) -> [any Material] {
        if let cached = bellyMaterials[skin] { return cached }
        let material: [any Material] =
            [unlit(texture(AnimalSkin.belly(for: skin.kind, morph: skin.morph)), tint: .white)]
        bellyMaterials[skin] = material
        return material
    }

    /// The three parts that are the same colour on every animal that has
    /// them at all: the chicken's beak and feet, its comb and wattle, and
    /// the dark bead a fish or a squid wears for an eye. No kind and no
    /// morph, so these are plain shared values rather than caches.
    private static let beakMaterial: [any Material] =
        [unlit(texture(AnimalSkin.beak), tint: .white)]
    private static let combMaterial: [any Material] =
        [unlit(texture(AnimalSkin.comb), tint: .white)]
    private static let eyeMaterial: [any Material] =
        [unlit(texture(AnimalSkin.eye), tint: .white)]

    /// Unlit like the blocks, so animals sit in the same lighting model as
    /// everything else in the scene.
    private static func unlit(_ texture: TextureResource?, tint: NSColor) -> UnlitMaterial {
        var material = UnlitMaterial()
        if let texture {
            material.color = .init(tint: tint, texture: .init(texture, sampler: nearestSampler))
        } else {
            material.color = .init(tint: tint)
        }
        return material
    }

    private static let nearestSampler: MaterialParameters.Texture.Sampler = {
        let descriptor = MTLSamplerDescriptor()
        descriptor.minFilter = .nearest
        descriptor.magFilter = .nearest
        descriptor.mipFilter = .notMipmapped
        return MaterialParameters.Texture.Sampler(descriptor)
    }()

    private static func texture(_ image: NSImage) -> TextureResource? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        return try? TextureResource(
            image: cgImage,
            options: .init(semantic: .color, mipmapsMode: .none)
        )
    }
}
#endif
