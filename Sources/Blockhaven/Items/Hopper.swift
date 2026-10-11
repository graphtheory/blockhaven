import Foundation

/// Every hopper's clock — the same split `FurnaceStore` and `CropStore`
/// both use, a store beside the world for the one number a block cannot
/// hold. A hopper's cooldown is not "empty or full" the way a chest's
/// contents are, so unlike those two this never drops an entry just for
/// reading zero — only `prune` ever removes one, when the block itself
/// is gone.
final class HopperStore {
    struct Key: Hashable {
        var x: Int
        var y: Int
        var z: Int

        init(_ x: Int, _ y: Int, _ z: Int) {
            self.x = x
            self.y = y
            self.z = z
        }
    }

    /// Seconds between transfers. Slower than a furnace's smelt so a line
    /// of them reads as a belt moving rather than a shelf emptying itself
    /// in a blink, and quick enough that a short session still sees a
    /// chest fill up.
    static let transferInterval: Double = 1.0

    private(set) var cooldown: [Key: Double] = [:]
    private(set) var facings: [Key: BlockFacing] = [:]
    private(set) var items: [Key: ItemStack] = [:]

    func hopperPlaced(at key: Key, facing: BlockFacing? = nil) {
        cooldown[key] = 0
        if let facing { facings[key] = facing }
    }

    /// Forgets a hopper, handing back whatever was still sitting in its
    /// buffer so the caller can drop it.
    ///
    /// The buffer is invisible — a hopper aimed at a full chest holds one
    /// item indefinitely with nothing on screen to say so — and this used
    /// to delete it outright, so mining that hopper quietly destroyed a
    /// stack the player never knew it was carrying.
    @discardableResult
    func hopperRemoved(at key: Key) -> ItemStack? {
        cooldown.removeValue(forKey: key)
        facings.removeValue(forKey: key)
        return items.removeValue(forKey: key)
    }

    /// Writes back one hopper's remaining cooldown — the only mutation
    /// `GameViewController.updateHoppers` needs, once a frame per hopper.
    func setCooldown(_ value: Double, at key: Key) {
        guard cooldown[key] != nil else { return }
        cooldown[key] = value
    }

    func setFacing(_ facing: BlockFacing?, at key: Key) {
        if let facing {
            facings[key] = facing
        } else {
            facings.removeValue(forKey: key)
        }
    }

    func facing(at key: Key) -> BlockFacing? {
        facings[key]
    }

    /// Every hopper this store knows about. `cooldown` gains its entry the
    /// moment a hopper is placed and loses it only when the block goes, so
    /// it is the store's roll call — `facings` and `items` are both sparse.
    var allKeys: [Key] { Array(cooldown.keys) }

    func item(at key: Key) -> ItemStack? {
        items[key]
    }

    func setItem(_ stack: ItemStack?, at key: Key) {
        if let stack, stack.count > 0 {
            items[key] = stack
        } else {
            items.removeValue(forKey: key)
        }
    }

    @discardableResult
    func addItem(_ stack: ItemStack, at key: Key) -> Bool {
        if let existing = items[key] {
            guard existing.type == stack.type, existing.count + stack.count <= existing.maxStack else {
                return false
            }
            items[key] = ItemStack(existing.type, count: existing.count + stack.count, wear: existing.wear)
            return true
        } else {
            items[key] = stack
            return true
        }
    }

    @discardableResult
    func removeItem(at key: Key, count: Int = 1) -> ItemStack? {
        guard let existing = items[key], existing.count >= count else { return nil }
        let pulled = ItemStack(existing.type, count: count, wear: existing.wear)
        if existing.count > count {
            items[key] = ItemStack(existing.type, count: existing.count - count, wear: existing.wear)
        } else {
            items.removeValue(forKey: key)
        }
        return pulled
    }

    /// Drops every hopper no longer standing where it says it is — the
    /// same sweep every other per-cell store runs after an explosion.
    func prune(where blockIsGone: (Key) -> Bool) {
        for key in cooldown.keys where blockIsGone(key) {
            cooldown.removeValue(forKey: key)
            facings.removeValue(forKey: key)
            items.removeValue(forKey: key)
        }
    }

    /// One hopper's whole job: pull a single item from whatever sits above
    /// it and hand it to whatever sits below — a chest's stocked slot into
    /// another chest, a furnace's finished output down into a chest
    /// waiting under it, a chest's contents straight into a furnace's ore
    /// or fuel slot exactly the way a player's own hand already can, or —
    /// the one thing not a block — a cart's cargo, for whichever side of
    /// the rail it happens to be riding past. Nothing moves if either end
    /// has nothing to give, has nowhere to put it, or is not a container
    /// at all.
    ///
    /// A free function over `World`, `ChestStore`, `FurnaceStore` and
    /// `MinecartManager` rather than a method tucked inside
    /// `GameViewController` — the same reason `SignalNetwork.recompute`
    /// takes its collaborators as parameters instead of reaching for them
    /// off a view controller: it is the only way `HopperCheck` can drive
    /// one transfer at a time without a window.
    /// Moves at most one item along this hopper, and reports whether it
    /// actually moved anything.
    ///
    /// The return value is what tells a caller a hopper is *working* rather
    /// than merely ticking. A locked hopper, or one with nothing to carry
    /// and nothing above it, does the same amount of nothing as a hopper
    /// that isn't there.
    @discardableResult
    static func transfer(
        at key: Key,
        world: World,
        chests: ChestStore,
        furnaces: FurnaceStore,
        minecarts: inout MinecartManager,
        hoppers: HopperStore? = nil,
        direction: BlockFacing? = nil,
        signals: SignalNetwork? = nil
    ) -> Bool {
        // Signal locking check
        if let signals, signals.isPowered(at: SignalNetwork.Key(key.x, key.y, key.z)) {
            return false
        }

        // 1. Determine delivery destination
        let chosenFacing = direction ?? hoppers?.facing(at: key)
        var target: (x: Int, y: Int, z: Int)
        if let f = chosenFacing {
            target = (x: key.x + f.dx, y: key.y, z: key.z + f.dz)
        } else {
            let belowBlock = world.block(worldX: key.x, y: key.y - 1, worldZ: key.z)
            if belowBlock == .chest || belowBlock == .furnace || belowBlock == .furnaceLit || belowBlock == .hopper
                || minecarts.cartID(at: (key.x, key.y - 1, key.z)) != nil {
                target = (x: key.x, y: key.y - 1, z: key.z)
            } else {
                // Fallback auto-discovery for adjacent containers
                var found: (x: Int, y: Int, z: Int)?
                for f in [BlockFacing.east, .west, .south, .north] {
                    let nx = key.x + f.dx
                    let nz = key.z + f.dz
                    let b = world.block(worldX: nx, y: key.y, worldZ: nz)
                    if b == .chest || b == .furnace || b == .furnaceLit || b == .hopper {
                        found = (x: nx, y: key.y, z: nz)
                        break
                    }
                }
                target = found ?? (x: key.x, y: key.y - 1, z: key.z)
            }
        }

        func deliver(_ item: ItemStack, to target: (x: Int, y: Int, z: Int)) -> Bool {
            let targetBlock = world.block(worldX: target.x, y: target.y, worldZ: target.z)
            if targetBlock == .chest {
                return chests.chest(at: ChestStore.Key(target.x, target.y, target.z)).add(item) == nil
            } else if targetBlock == .furnace || targetBlock == .furnaceLit {
                let fKey = FurnaceStore.Key(target.x, target.y, target.z)
                var state = furnaces.state(at: fKey)
                var accepted = false
                if FurnaceRecipe.output(for: item.type) != nil,
                   state.oreType == nil || state.oreType == item.type, state.oreCount < 64 {
                    state.oreType = item.type
                    state.oreCount += 1
                    accepted = true
                } else if FurnaceRecipe.burnSeconds(for: item.type) != nil,
                          state.fuelType == nil || state.fuelType == item.type, state.fuelCount < item.type.maxStack {
                    state.fuelType = item.type
                    state.fuelCount += 1
                    accepted = true
                }
                if accepted { furnaces.set(state, at: fKey) }
                return accepted
            } else if targetBlock == .hopper, let hoppers {
                let dstKey = Key(target.x, target.y, target.z)
                return hoppers.addItem(item, at: dstKey)
            } else if let cartTarget = minecarts.cartID(at: target) {
                let existing = minecarts.cart(cartTarget)?.cargo
                if existing == nil || (existing?.type == item.type && (existing?.count ?? 0) < item.type.maxStack) {
                    let count = (existing?.count ?? 0) + 1
                    minecarts.setCargo(ItemStack(item.type, count: count, wear: item.wear), for: cartTarget)
                    return true
                }
            }
            return false
        }

        // 2. If we have an item in internal buffer, try to deliver it to target
        if let hoppers, let buf = hoppers.item(at: key), buf.count > 0 {
            let itemToPush = ItemStack(buf.type, count: 1, wear: buf.wear)
            if deliver(itemToPush, to: target) {
                hoppers.removeItem(at: key, count: 1)
                return true
            }
            return false
        }

        // 3. Otherwise (buffer empty), try to pull from above
        let above = (x: key.x, y: key.y + 1, z: key.z)
        let aboveBlock = world.block(worldX: above.x, y: above.y, worldZ: above.z)
        let cartAbove = minecarts.cartID(at: above)
        enum PullSource {
            case chest(Chest)
            case furnaceOutput(FurnaceStore.Key)
            case furnaceFuel(FurnaceStore.Key)
            case hopperAbove(Key)
            case cartAbove(Int)
        }
        var pulled: ItemStack?
        var pullSource: PullSource?

        if aboveBlock == .chest, let chest = chests.existing(at: ChestStore.Key(above.x, above.y, above.z)),
           let index = chest.slots.firstIndex(where: { $0 != nil }), let stack = chest[index] {
            let item = ItemStack(stack.type, count: 1, wear: stack.wear)
            pulled = item
            chest[index] = stack.count > 1
                ? ItemStack(stack.type, count: stack.count - 1, wear: stack.wear)
                : nil
            pullSource = .chest(chest)
        } else if aboveBlock == .furnace || aboveBlock == .furnaceLit {
            let fKey = FurnaceStore.Key(above.x, above.y, above.z)
            var state = furnaces.state(at: fKey)
            if let output = state.outputType, state.outputCount > 0 {
                let item = ItemStack(output, count: 1)
                pulled = item
                state.outputCount -= 1
                if state.outputCount == 0 { state.outputType = nil }
                furnaces.set(state, at: fKey)
                pullSource = .furnaceOutput(fKey)
            } else if let fuel = state.fuelType, fuel == .bucket, state.fuelCount > 0 {
                let item = ItemStack(fuel, count: 1)
                pulled = item
                state.fuelCount -= 1
                if state.fuelCount == 0 { state.fuelType = nil }
                furnaces.set(state, at: fKey)
                pullSource = .furnaceFuel(fKey)
            }
        } else if aboveBlock == .hopper, let hoppers {
            let aboveKey = Key(above.x, above.y, above.z)
            if let item = hoppers.removeItem(at: aboveKey, count: 1) {
                pulled = item
                pullSource = .hopperAbove(aboveKey)
            }
        } else if let cartAbove, let cargo = minecarts.cart(cartAbove)?.cargo {
            let item = ItemStack(cargo.type, count: 1, wear: cargo.wear)
            pulled = item
            minecarts.setCargo(
                cargo.count > 1 ? ItemStack(cargo.type, count: cargo.count - 1, wear: cargo.wear) : nil,
                for: cartAbove
            )
            pullSource = .cartAbove(cartAbove)
        }

        guard let item = pulled else { return false }

        // Attempt to deliver pulled item directly to target
        if deliver(item, to: target) {
            return true
        }

        // Target could not accept it:
        // If this hopper has a buffer (hoppers != nil), store it into our own buffer!
        if let hoppers, hoppers.addItem(item, at: key) {
            return true
        }

        // Target could not accept it and buffer could not accept (or hoppers == nil): roll back to source
        switch pullSource {
        case .chest(let chest):
            chest.add(item)
        case .furnaceOutput(let fKey):
            var s = furnaces.state(at: fKey)
            if s.outputType == nil || s.outputType == item.type {
                s.outputType = item.type
                s.outputCount += item.count
                furnaces.set(s, at: fKey)
            }
        case .furnaceFuel(let fKey):
            var s = furnaces.state(at: fKey)
            if s.fuelType == nil || s.fuelType == item.type {
                s.fuelType = item.type
                s.fuelCount += item.count
                furnaces.set(s, at: fKey)
            }
        case .hopperAbove(let aboveKey):
            hoppers?.addItem(item, at: aboveKey)
        case .cartAbove(let cartID):
            let cur = minecarts.cart(cartID)?.cargo
            let cnt = (cur?.count ?? 0) + item.count
            minecarts.setCargo(ItemStack(item.type, count: cnt, wear: item.wear), for: cartID)
        case nil:
            break
        }
        return false
    }
}
