import Foundation

/// Every item creative mode hands out, filed on a shelf.
///
/// Creative used to hand them out by *filling the bag with them* — all
/// thirty-six slots, one item each. That is a palette in the sense that a
/// paint tin poured over the table is a palette: nothing could be crafted,
/// because a crafted thing has nowhere to land; nothing could be kept,
/// because there was no empty slot to keep it in; and a stack thrown away
/// by accident was gone for the rest of the world's life.
///
/// So the palette moved out of the bag and onto its own shelf beside it.
/// The bag starts nearly empty, the palette is always there to take from,
/// and the two are different objects — which is the whole fix.
enum CreativeCatalogue {
    enum Shelf: Int, CaseIterable {
        case building, nature, light, moving, tools, materials

        var title: String {
            switch self {
            case .building: return L10n.t("Building", "Bygga")
            case .nature: return L10n.t("Nature", "Natur")
            case .light: return L10n.t("Light", "Ljus")
            case .moving: return L10n.t("Rails & Carts", "Räls & vagnar")
            case .tools: return L10n.t("Tools", "Verktyg")
            case .materials: return L10n.t("Materials", "Material")
            }
        }
    }

    /// Which shelf an item sits on. Every item in the game reaches one —
    /// `.materials` is the catch-all, and `CreativeCheck` asserts that
    /// nothing lands there that should have been filed somewhere better.
    static func shelf(for item: ItemType) -> Shelf {
        if item.toolClass != nil { return .tools }
        switch item {
        case .hoe, .bucket, .waterBucket, .lavaBucket, .compass, .masonLine, .blueprint, .ironChestplate, .diamondChestplate:
            return .tools
        case .torch, .glowCrystal, .seaLantern, .pearlLight, .signalLamp,
             .radiantRed, .radiantYellow, .radiantGreen, .radiantCyan:
            return .light
        case .rail, .poweredRail, .detectorRail, .minecart:
            return .moving
        case .leaves, .birchLeaves, .spruceLeaves, .cactus,
             .tallGrass, .poppy, .dandelion, .cornflower, .deadBush,
             .sapling, .birchSapling, .spruceSapling,
             .coalOreBlock, .ironOreBlock:
            return .nature
        default:
            return item.placedBlock != nil || ShapedPlacement.places(item) ? .building : .materials
        }
    }

    /// The shelves in the order the panel lists them, each in `ItemType`
    /// declaration order — which is already the order the blocks were
    /// added to the game, so the plain building blocks come first and the
    /// ornamental ones after, without a second list to keep in step.
    static let shelves: [(shelf: Shelf, items: [ItemType])] = Shelf.allCases.compactMap { shelf in
        let items = ItemType.allCases.filter { CreativeCatalogue.shelf(for: $0) == shelf }
        return items.isEmpty ? nil : (shelf, items)
    }

    /// Flat, for the checks and for anything that only wants "is this
    /// item reachable in creative at all".
    static let allItems: [ItemType] = shelves.flatMap(\.items)
}
