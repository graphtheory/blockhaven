import Foundation

/// The two places a save can hold. The home world is the one every save
/// already had; the Moon is generated the first time a rocket lands on it.
enum Destination: String, Codable {
    case home, moon
}

/// The three pieces of the old network the radio can hear — each the
/// knowledge one part of a rocket needs, each kept by a different kind of
/// place: a climb, a wall, a dive.
enum StoryPiece: String, Codable, CaseIterable {
    case navigation, cabin, engine

    var title: String {
        switch self {
        case .navigation: return L10n.t("Navigation", "Navigering")
        case .cabin: return L10n.t("Cabin", "Kabin")
        case .engine: return L10n.t("Engine", "Motor")
        }
    }

    /// The kind of place, in the words the journal and the tracker use.
    var place: String {
        switch self {
        case .navigation: return L10n.t("the spire", "tornet")
        case .cabin: return L10n.t("the vault", "valvet")
        case .engine: return L10n.t("the wreck", "vraket")
        }
    }

    /// What KEEPER says when the piece is recorded.
    var lesson: String {
        switch self {
        case .navigation: return L10n.t("THE MOON IS ONE LIGHT-SECOND AWAY. AIM FOR THE BLINK.",
                                        "MÅNEN ÄR EN LJUSSEKUND BORT. SIKTA PÅ BLINKET.")
        case .cabin: return L10n.t("AIR STAYS IN A ROOM WITH NO HOLES.",
                                   "LUFT STANNAR I ETT RUM UTAN HÅL.")
        case .engine: return L10n.t("ICE IS FUEL. SO IS SUNLIGHT.",
                                    "IS ÄR BRÄNSLE. DET ÄR SOLLJUS OCKSÅ.")
        }
    }
}

/// The three things the garden is missing.
enum GardenFault: String, Codable, CaseIterable {
    case light, water, growth

    var panelText: String {
        switch self {
        case .light: return L10n.t("NO LIGHT", "INGET LJUS")
        case .water: return L10n.t("NO WATER", "INGET VATTEN")
        case .growth: return L10n.t("NOTHING GROWS", "INGET VÄXER")
        }
    }

    var fixedText: String {
        switch self {
        case .light: return L10n.t("LIGHT RESTORED. THANK YOU.", "LJUSET ÄR TILLBAKA. TACK.")
        case .water: return L10n.t("WATER FLOWS AGAIN.", "VATTNET RINNER IGEN.")
        case .growth: return L10n.t("SOMETHING IS GROWING. I HAD FORGOTTEN THE COLOUR.",
                                    "NÅGOT VÄXER. JAG HADE GLÖMT FÄRGEN.")
        }
    }
}

/// A cell, the way the story files one away.
struct StoryCell: Codable, Equatable, Hashable {
    var x: Int
    var y: Int
    var z: Int

    init(_ x: Int, _ y: Int, _ z: Int) {
        self.x = x
        self.y = y
        self.z = z
    }

    var centre: Vector3 { Vector3(CGFloat(x) + 0.5, CGFloat(y) + 0.5, CGFloat(z) + 0.5) }

    func distanceSquared(to other: StoryCell) -> Int {
        let dx = x - other.x, dy = y - other.y, dz = z - other.z
        return dx * dx + dy * dy + dz * dz
    }
}

/// Where one of the three pieces is kept, once the story has built it.
struct StorySite: Codable, Equatable {
    var piece: StoryPiece
    /// The radio that holds the piece.
    var radio: StoryCell
}

/// The garden's layout, decided once when the Moon is first built. Every
/// fault check reads cells from here, so the checks can never disagree
/// with what was built.
struct GardenPlan: Codable, Equatable {
    var panel: StoryCell
    var lamps: [StoryCell]
    var reservoir: [StoryCell]
    /// Inclusive corners of the nursery hall's air.
    var nurseryMin: StoryCell
    var nurseryMax: StoryCell
    var seal: [StoryCell]
    var lever: StoryCell
    var shutters: [StoryCell]
    var collector: StoryCell
    var vaultChest: StoryCell
}

/// Everything the storyline remembers. It belongs to the player, not to a
/// world: it travels in the rocket with the inventory, and is written into
/// whichever world the player is standing in.
struct StoryState: Codable, Equatable {
    // Chapter 1
    var station: StoryCell?
    var radioRepaired = false
    // Chapter 2
    var sites: [StorySite] = []
    var pieces: [StoryPiece] = []
    // Chapter 3
    var homePad: StoryCell?
    var launched = false
    /// A fuel cell set aside for the way home, loaded at launch. Nothing
    /// on the Moon can take it back out.
    var returnCellLoaded = false
    // Chapter 4
    var moonPad: StoryCell?
    var breathedOnMoon = false
    // Chapter 5
    var garden: GardenPlan?
    var faultsFixed: [GardenFault] = []
    var gardenOpened = false
    // Chapter 6
    var gardenWoken = false
    var seedsTaken = false
    var complete = false

    init() {}

    /// Every field is optional on the way in, so a journal written by an
    /// earlier build of the storyline still opens: a missing flag is a
    /// flag not yet earned.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        station = try c.decodeIfPresent(StoryCell.self, forKey: .station)
        radioRepaired = try c.decodeIfPresent(Bool.self, forKey: .radioRepaired) ?? false
        sites = try c.decodeIfPresent([StorySite].self, forKey: .sites) ?? []
        pieces = try c.decodeIfPresent([StoryPiece].self, forKey: .pieces) ?? []
        homePad = try c.decodeIfPresent(StoryCell.self, forKey: .homePad)
        launched = try c.decodeIfPresent(Bool.self, forKey: .launched) ?? false
        returnCellLoaded = try c.decodeIfPresent(Bool.self, forKey: .returnCellLoaded) ?? false
        moonPad = try c.decodeIfPresent(StoryCell.self, forKey: .moonPad)
        breathedOnMoon = try c.decodeIfPresent(Bool.self, forKey: .breathedOnMoon) ?? false
        garden = try? c.decodeIfPresent(GardenPlan.self, forKey: .garden)
        faultsFixed = try c.decodeIfPresent([GardenFault].self, forKey: .faultsFixed) ?? []
        gardenOpened = try c.decodeIfPresent(Bool.self, forKey: .gardenOpened) ?? false
        gardenWoken = try c.decodeIfPresent(Bool.self, forKey: .gardenWoken) ?? false
        seedsTaken = try c.decodeIfPresent(Bool.self, forKey: .seedsTaken) ?? false
        complete = try c.decodeIfPresent(Bool.self, forKey: .complete) ?? false
    }

    func hasPiece(_ piece: StoryPiece) -> Bool { pieces.contains(piece) }
    var hasAllPieces: Bool { StoryPiece.allCases.allSatisfy(hasPiece) }
    func isFixed(_ fault: GardenFault) -> Bool { faultsFixed.contains(fault) }
    var allFaultsFixed: Bool { GardenFault.allCases.allSatisfy(isFixed) }

    /// Which chapter the player is in, 1…6, or 7 once it is over.
    var chapter: Int {
        if complete { return 7 }
        if gardenOpened { return 6 }
        if breathedOnMoon { return 5 }
        if launched { return 4 }
        if hasAllPieces { return 3 }
        if radioRepaired { return 2 }
        return 1
    }
}

/// KEEPER's lines that are not tied to a piece or a fault.
enum Keeper {
    static let name = "KEEPER"

    static var stationWakes: [String] {
        [
            L10n.t("GROUND LINK LOST. NURSERY DORMANT.", "MARKLÄNK BRUTEN. PLANTSKOLAN SOVER."),
            L10n.t("…SOMEONE IS LISTENING? GOOD.", "…NÅGON LYSSNAR? BRA."),
            L10n.t("I CAN HEAR THREE OLD MACHINES. FIND THEM.", "JAG HÖR TRE GAMLA MASKINER. HITTA DEM."),
        ]
    }

    static var radioNeedsCrystal: String {
        L10n.t("The radio is dead. Use a glow crystal on it (stone + 2 torches).",
               "Radion är död. Använd en glödkristall på den (sten + 2 facklor).")
    }

    static var allPieces: [String] {
        [
            L10n.t("NAVIGATION, CABIN, ENGINE. YOU HAVE EVERYTHING.", "NAVIGERING, KABIN, MOTOR. DU HAR ALLT."),
            L10n.t("BUILD A LAUNCH PAD. BUILD A ROCKET. COME.", "BYGG EN STARTPLATTA. BYGG EN RAKET. KOM."),
        ]
    }

    static var landed: [String] {
        [
            L10n.t("YOU CAME. YOU ACTUALLY CAME.", "DU KOM. DU KOM PÅ RIKTIGT."),
            L10n.t("THERE IS NO AIR OUT THERE. KEEP YOUR SUIT ON.", "DET FINNS INGEN LUFT DÄR UTE. BEHÅLL DRÄKTEN PÅ."),
            L10n.t("SEAL A ROOM. PUT AN AIR MAKER IN IT. POWER IT.", "TÄT ETT RUM. STÄLL EN LUFTMASKIN DÄR. GE DEN STRÖM."),
        ]
    }

    static var firstBreath: [String] {
        [
            L10n.t("YOU ARE BREATHING ON THE MOON. WELL DONE.", "DU ANDAS PÅ MÅNEN. BRA GJORT."),
            L10n.t("NOW COME TO THE GARDEN. FOLLOW THE BLINK.", "KOM NU TILL TRÄDGÅRDEN. FÖLJ BLINKET."),
        ]
    }

    static var gardenOpens: [String] {
        [
            L10n.t("LIGHT. WATER. SOMETHING ALIVE. THE DOOR IS OPEN.", "LJUS. VATTEN. NÅGOT LEVANDE. DÖRREN ÄR ÖPPEN."),
            L10n.t("PULL THE LEVER IN THE SEED VAULT.", "DRA I SPAKEN I FRÖVALVET."),
        ]
    }

    static var waking: [String] {
        [
            L10n.t("CIRCULATION…", "CIRKULATION…"),
            L10n.t("GROWING LIGHT…", "VÄXTLJUS…"),
            L10n.t("BEACON…", "FYR…"),
            L10n.t("NURSERY ACTIVE. TAKE ONE. GROW IT WHERE YOU LIVE.", "PLANTSKOLAN LEVER. TA ETT. ODLA DET DÄR DU BOR."),
        ]
    }

    static var ending: [String] {
        [
            L10n.t("GROUND LINK AVAILABLE.", "MARKLÄNK TILLGÄNGLIG."),
            L10n.t("LOOK UP. THE LIGHT IS STEADY NOW. THANK YOU.", "TITTA UPP. LJUSET ÄR STADIGT NU. TACK."),
        ]
    }

    static var rocketGuardsHome: String {
        L10n.t("THAT ROCKET IS YOUR WAY HOME. I WILL NOT LET YOU BREAK IT.",
               "DEN RAKETEN ÄR DIN VÄG HEM. JAG LÅTER DIG INTE FÖRSTÖRA DEN.")
    }

    static var sealHolds: String {
        L10n.t("THE INNER DOOR OPENS WHEN THE GARDEN IS WELL.", "INNERDÖRREN ÖPPNAS NÄR TRÄDGÅRDEN MÅR BRA.")
    }
}
