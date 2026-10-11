#if canImport(AppKit)
import AppKit

/// Headless proof that creative mode hands blocks over without taking the
/// bag hostage, that a chest keeps what is put in it across a save, and
/// that both of the scrolling panels can actually be scrolled to the end.
///
/// Every claim here is one that a picture cannot make. A capture of the
/// creative screen shows the palette; it cannot show that clicking the
/// cell you aimed at gives you the item under it, that the bag is left
/// empty enough to craft into, or that a chest's contents survive the
/// round trip to disk and back. So those are asserted against the same
/// objects the screen draws with.
///
/// `BLOCKHAVEN_CHECK_CREATIVE=1`. Exits nonzero if any line fails.
enum CreativeCheck {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["BLOCKHAVEN_CHECK_CREATIVE"] != nil
    }

    private struct Report {
        var lines: [String] = []
        var failed = false

        mutating func check(_ name: String, _ passed: Bool, _ detail: String) {
            lines.append("[check] \(name): \(passed ? "ok" : "FAILED") — \(detail)")
            if !passed { failed = true }
        }
    }

    /// The bounds and panel rect the inventory screen lays out against at
    /// the default window size, so the panel under test is seated exactly
    /// where the real one is.
    private static let bounds = CGRect(x: 0, y: 0, width: 1280, height: 800)
    private static let panelRect = CGRect(x: 406, y: 192, width: 468, height: 416)

    static func run() -> Never {
        var report = Report()

        // MARK: every item is on a shelf, exactly once
        let listed = CreativeCatalogue.allItems
        let missing = ItemType.allCases.filter { !listed.contains($0) }
        let duplicated = listed.filter { item in listed.filter { $0 == item }.count > 1 }
        report.check(
            "every item is in the palette exactly once",
            missing.isEmpty && duplicated.isEmpty,
            missing.isEmpty && duplicated.isEmpty
                ? "\(listed.count) items on \(CreativeCatalogue.shelves.count) shelves"
                : "missing \(missing), duplicated \(Set(duplicated))"
        )

        // The five shaped items have no `placedBlock`, so a palette built
        // by walking the block list would silently drop them — which is
        // exactly what the old one did. They are the reason this line
        // exists.
        let shapedMissing = ShapedPlacement.placeableItems.filter { !listed.contains($0) }
        report.check(
            "stairs, doors, panes and beds reach the palette",
            shapedMissing.isEmpty,
            shapedMissing.isEmpty ? "all \(ShapedPlacement.placeableItems.count) shaped items listed"
                : "missing \(shapedMissing)"
        )

        // MARK: the creative bag has room to craft into
        let creative = Inventory()
        creative.grantCreativeKit()
        let freeSlots = (0..<Inventory.totalSize).count { creative[$0] == nil }
        report.check(
            "a creative bag opens with room in it",
            freeSlots >= Inventory.mainSize,
            "\(freeSlots) of \(Inventory.totalSize) slots free,"
                + " \(Inventory.totalSize - freeSlots) blocks on the hotbar"
        )
        // The old palette filled all thirty-six, which meant a crafted
        // item had nowhere to land. This is that bug, stated as a test:
        // craft something and it must be somewhere afterwards.
        var grid = CraftingGrid(size: 2)
        grid[0] = ItemStack(.log)
        let crafted = RecipeBook.match(grid)
        let leftover = crafted.flatMap { creative.add($0) }
        report.check(
            "a crafted stack has somewhere to go in creative",
            crafted != nil && leftover == nil && creative.count(of: .planks) >= 4,
            "\(crafted.map { "\($0.type)×\($0.count)" } ?? "nothing") crafted,"
                + " bag now holds \(creative.count(of: .planks)) planks"
        )

        // MARK: every cell is reachable, and clicking it hands over the
        // item it drew
        //
        // The palette is taller than the window, so this scrolls it from
        // top to bottom and aims a click at every cell that comes into
        // view. A cell whose centre never lands inside the viewport is an
        // item creative mode does not actually offer.
        let palette = CreativePalettePanel()
        palette.layout(in: bounds, beside: panelRect, gap: 16)
        var reached = Set<Int>()
        var mappingOK = palette.cellFrames.count == listed.count
        var offset: CGFloat = 0
        while true {
            palette.setScroll(offset)
            for index in palette.items.indices {
                guard let centre = palette.center(ofItem: index) else { continue }
                if palette.index(at: centre) == index {
                    reached.insert(index)
                } else {
                    mappingOK = false
                }
            }
            if palette.scrollOffset >= palette.scrollLimit { break }
            offset += palette.scrollStep / 2
        }
        report.check(
            "every palette cell can be reached and clicked",
            reached.count == listed.count && mappingOK,
            "\(reached.count) of \(listed.count) cells reachable,"
                + " scroll limit \(Int(palette.scrollLimit)) points"
        )

        // MARK: the scrollbar is a control, not a picture
        palette.setScroll(0)
        var scroller = palette.scroller
        let knob = scroller.knobRect
        let draggable = scroller.beginDrag(at: CGPoint(x: knob.midX, y: knob.midY))
        scroller.drag(to: CGPoint(x: knob.midX, y: scroller.trackRect.minY))
        let draggedToEnd = scroller.offset >= scroller.maximum - 0.5
        scroller.endDrag()
        var paged = PanelScroller()
        paged.viewport = CGRect(x: 0, y: 0, width: 200, height: 300)
        paged.contentHeight = 2000
        _ = PanelScroller.keyScroll(121, in: &paged) // page down
        let pagedDown = paged.offset > 200
        _ = PanelScroller.keyScroll(119, in: &paged) // end
        let wentToEnd = paged.offset == paged.maximum
        _ = PanelScroller.keyScroll(115, in: &paged) // home
        report.check(
            "the scrollbar drags and the keys page",
            draggable && draggedToEnd && pagedDown && wentToEnd && paged.offset == 0,
            "knob drag \(draggable ? "took" : "refused") the click,"
                + " page down moved \(Int(pagedDown ? 1 : 0) * 1) screenful,"
                + " End reached \(Int(paged.maximum)) and Home came back to \(Int(paged.offset))"
        )

        // The recipe book and the palette answer to the same keys — the
        // one thing that broke last time the two were maintained apart.
        let book = RecipeBookPanel()
        book.isOpen = true
        book.layout(in: bounds, beside: panelRect, gap: 16)
        let bookEnd = book.handleKey(119)
        let bookAtEnd = book.scrollOffset == book.scrollLimit
        report.check(
            "the recipe book scrolls by the same keys",
            bookEnd && bookAtEnd && book.scrollLimit > 0,
            "End took the book to \(Int(book.scrollOffset)) of \(Int(book.scrollLimit))"
        )

        // MARK: a chest keeps what is put in it
        let chest = Chest()
        chest.add(ItemStack(.diamond, count: 12))
        chest.add(ItemStack(.cobblestone, count: 64))
        chest.add(ItemStack(.cobblestone, count: 64))
        let stored = chest.contents.reduce(into: [ItemType: Int]()) { $0[$1.type, default: 0] += $1.count }
        report.check(
            "a chest stacks what goes into it",
            stored[.diamond] == 12 && stored[.cobblestone] == 128,
            "\(chest.contents.count) stacks: \(stored.map { "\($0.key)×\($0.value)" }.sorted().joined(separator: ", "))"
        )

        // MARK: chests survive the round trip to disk
        let store = ChestStore()
        let key = ChestStore.Key(12, 64, -37)
        let placed = store.chest(at: key)
        placed.add(ItemStack(.oakStairs, count: 9))
        placed.add(ItemStack(.ironPickaxe))
        let save = WorldSave(
            seed: 99,
            mode: .creative,
            name: "chest check",
            lastPlayed: 0,
            edits: [:],
            position: Vector3(0, 70, 0),
            yaw: 0,
            pitch: 0,
            inventory: Inventory(),
            stats: PlayerStats(),
            timeOfDay: 0.3,
            chests: store
        )
        var reloaded: WorldSave?
        do {
            let data = try JSONEncoder().encode(save)
            reloaded = try JSONDecoder().decode(WorldSave.self, from: data)
        } catch {
            report.check("a chest survives being written and read", false, "\(error)")
        }
        if let reloaded {
            let back = reloaded.chestStore.existing(at: key)
            let stairs = back?.contents.first { $0.type == .oakStairs }?.count
            let pick = back?.contents.contains { $0.type == .ironPickaxe } ?? false
            report.check(
                "a chest survives being written and read",
                back != nil && stairs == 9 && pick,
                "\(reloaded.chests?.count ?? 0) chests on disk,"
                    + " back with \(back?.contents.count ?? 0) stacks"
                    + " (\(stairs.map(String.init) ?? "no") stairs, pickaxe \(pick))"
            )
            // A save written before chests existed has no key at all, and
            // must still load — the whole reason the field is optional.
            report.check(
                "a world with no chests writes no chest key",
                WorldSave(
                    seed: 1, mode: .survival, name: "n", lastPlayed: 0, edits: [:],
                    position: Vector3(0, 70, 0), yaw: 0, pitch: 0,
                    inventory: Inventory(), stats: PlayerStats(), timeOfDay: 0
                ).chests == nil,
                "absent rather than an empty array, so the file is byte-identical to a v1 one"
            )
        }

        // MARK: the chest is a block you can get and open
        let craftable = RecipeBook.all.contains { $0.output.type == .chest }
        report.check(
            "a chest can be crafted, placed and opened",
            craftable && ItemType.chest.placedBlock == .chest
                && BlockType.chest.isInteractive && ItemType.blockItem(for: .chest) == .chest,
            "recipe \(craftable ? "listed" : "missing"),"
                + " places \(String(describing: ItemType.chest.placedBlock)),"
                + " right-click opens it: \(BlockType.chest.isInteractive)"
        )

        // MARK: pointing at a block and asking for it gives *it*
        //
        // `drop` is what mining yields, which is a different question:
        // stone yields cobblestone and grass yields dirt. Picked up with
        // F they have to come back as themselves, or the key that exists
        // to copy a wall builds a different wall.
        let picks: [(BlockType, ItemType?)] = [
            (.stone, .stone), (.grass, .grass), (.leaves, .leaves), (.snow, .snow),
            (.oakStairsEast, .oakStairs), (.oakDoorLowerNorth, .oakDoor),
            (.bedFootWest, .bed), (.glassPane, .glassPane), (.torch, .torch),
            (.chest, .chest), (.railEastWest, .rail), (.air, nil),
        ]
        let wrongPicks = picks.filter { $0.0.pickItem != $0.1 }
        report.check(
            "pick block hands over the block you pointed at",
            wrongPicks.isEmpty,
            wrongPicks.isEmpty
                ? "\(picks.count) blocks, stone and grass included"
                : wrongPicks.map { "\($0.0) gave \(String(describing: $0.0.pickItem))" }
                    .joined(separator: ", ")
        )

        // MARK: every recipe can say what it is made of, in words
        //
        // The book used to draw its ingredients only as 14-pixel cells,
        // which is a picture of a recipe rather than a reading of one.
        // Every row now prints names and counts, so every ingredient has
        // to have a name — and `BlockType.displayName` ends in a `default`
        // arm that answers the bare word "Block", which is what an
        // un-named new block would show up as in front of a child.
        let ingredients = Set(RecipeBook.all.flatMap { $0.ingredientCounts.keys })
        let unnamed = (ingredients.union(CreativeCatalogue.allItems)).filter {
            $0.displayName.isEmpty || $0.displayName == "Block"
        }
        report.check(
            "every ingredient and palette item has a name to print",
            unnamed.isEmpty,
            unnamed.isEmpty
                ? "\(ingredients.count) distinct ingredients across \(RecipeBook.all.count) recipes,"
                    + " \(CreativeCatalogue.allItems.count) palette items, all named"
                : "unnamed: \(unnamed)"
        )

        report.lines.append(
            "[check] " + (report.failed ? "FAILED" : "all passed")
                + " — \(listed.count) palette items, \(RecipeBook.all.count) recipes"
        )
        StandardError.write(Data((report.lines.joined(separator: "\n") + "\n").utf8))
        exit(report.failed ? 1 : 0)
    }
}
#endif
