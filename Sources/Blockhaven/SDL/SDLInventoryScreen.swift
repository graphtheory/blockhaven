#if canImport(CSDL3)
import Foundation
import CSDL3

/// The inventory, crafting table and chest screen — `InventoryView` on the
/// Mac, with every click going through the same `InventoryInteraction`.
///
/// Beside the panel: what the bag can make right now (click one to lay it
/// out on the grid), and in creative, every block in the game.
final class SDLInventoryScreen {
    private let model: InventoryInteraction
    private let creative: Bool
    private var pointer = SDLPointer()
    private var shiftHeld = false
    private var paletteScroll = 0
    private var craftableScroll = 0
    /// A recipe the bag could not cover, flashed red for a moment.
    private var refused: (index: Int, timer: Double)?

    private static let slot: Float = 44
    private static let gap: Float = 4
    private static var step: Float { slot + gap }

    init(inventory: Inventory, gridSize: Int, creative: Bool, chest: Chest?) {
        model = InventoryInteraction(inventory: inventory, gridSize: gridSize, chest: chest)
        self.creative = creative
        // Opening the inventory is what retires the HUD's crafting hint — but
        // not from a screenshot run, which must leave the player's settings
        // exactly as it found them.
        if ProcessInfo.processInfo.environment["BLOCKHAVEN_SDL_SCREENSHOT"] == nil {
            GameSettings.craftingHintShown = true
        }
    }

    func returnHeldItems() {
        model.returnHeldItems()
    }

    func handle(_ event: SDL_Event, app: SDLApp) {
        pointer.handle(event)
        switch eventType(event) {
        case SDL_EVENT_KEY_DOWN, SDL_EVENT_KEY_UP:
            let down = eventType(event) == SDL_EVENT_KEY_DOWN
            if event.key.scancode == SDL_SCANCODE_LSHIFT || event.key.scancode == SDL_SCANCODE_RSHIFT {
                shiftHeld = down
            }
        default:
            break
        }
    }

    private var title: String {
        if model.chest != nil { return L10n.t("Chest", "Kista") }
        return model.craftingGrid.size >= 3
            ? L10n.t("Crafting Table", "Arbetsbänk")
            : L10n.t("Inventory", "Förråd")
    }

    func draw(app: SDLApp) {
        defer { pointer.endFrame() }
        let ui = app.ui
        if let r = refused {
            refused = r.timer > 0 ? (r.index, r.timer - 1.0 / 60) : nil
        }
        ui.rect(x: 0, y: 0, width: ui.width, height: ui.height, color: .init(0, 0, 0, 0.6))

        let step = SDLInventoryScreen.step, size = SDLInventoryScreen.slot
        let gridSize = model.craftingGrid.size
        let rowWidth = Float(Inventory.hotbarSize) * step - SDLInventoryScreen.gap
        let topRows = model.chest != nil ? 3 : gridSize
        let bagGap: Float = model.chest != nil ? 32 : 16
        let panelWidth = rowWidth + 40
        let panelHeight = Float(topRows) * step + 4 * step + 10 + 54 + bagGap
        let panelX = ((ui.width - panelWidth) / 2).rounded()
        let panelY = ((ui.height - panelHeight) / 2).rounded()

        ui.rect(x: panelX, y: panelY, width: panelWidth, height: panelHeight, color: .init(0.13, 0.13, 0.13))
        ui.frame(x: panelX, y: panelY, width: panelWidth, height: panelHeight, color: .init(0.42, 0.42, 0.42), thickness: 2)
        app.text.draw(ui, title, x: panelX + 20, y: panelY + 16, size: 13)

        var slots: [(InventoryInteraction.SlotKind, Float, Float)] = []
        let left = panelX + 20
        var y = panelY + 44
        if model.chest != nil {
            for index in 0..<Chest.size {
                slots.append((.chest(index), left + Float(index % 9) * step, y + Float(index / 9) * step))
            }
        } else {
            for index in 0..<(gridSize * gridSize) {
                slots.append((.craft(index), left + Float(index % gridSize) * step, y + Float(index / gridSize) * step))
            }
            let outputX = left + Float(gridSize) * step + 44
            let outputY = y + Float(gridSize - 1) * step / 2
            slots.append((.craftOutput, outputX, outputY))
            // The arrow from the grid to what it makes.
            let tail = left + Float(gridSize - 1) * step + size + 10, head = outputX - 10
            ui.rect(x: tail, y: outputY + size / 2 - 3, width: head - tail - 9, height: 6, color: .init(0.62, 0.62, 0.62))
            for i in 0..<9 {
                let h = Float(16 - i * 2)
                ui.rect(x: head - 11 + Float(i), y: outputY + size / 2 - h / 2, width: 1.2, height: h, color: .init(0.62, 0.62, 0.62))
            }
        }
        y += Float(topRows) * step + bagGap
        if model.chest != nil {
            app.text.draw(ui, L10n.t("Your things", "Dina saker"), x: left, y: y - 18, size: 9, color: .init(0.62, 0.62, 0.62))
        }
        for index in Inventory.hotbarSize..<Inventory.totalSize {
            let offset = index - Inventory.hotbarSize
            slots.append((.inventory(index), left + Float(offset % 9) * step, y + Float(offset / 9) * step))
        }
        let hotbarY = y + 3 * step + 10
        for index in 0..<Inventory.hotbarSize {
            slots.append((.inventory(index), left + Float(index) * step, hotbarY))
        }

        var hoveredName: String?
        for (kind, sx, sy) in slots {
            let stack = model.stack(in: kind)
            let fill: UIRenderer.Color = kind == .craftOutput
                ? (stack == nil ? .init(0.20, 0.20, 0.20) : .init(0.24, 0.34, 0.22))
                : .init(0.28, 0.28, 0.28)
            let hovered = pointer.inside(sx, sy, size, size)
            ui.rect(x: sx, y: sy, width: size, height: size, color: hovered ? .init(fill.r + 0.08, fill.g + 0.08, fill.b + 0.08) : fill)
            ui.frame(x: sx, y: sy, width: size, height: size, color: .init(0.5, 0.5, 0.5), thickness: 1.5)
            if let stack { SDLHUD.drawItem(stack, x: sx, y: sy, size: size, app: app) }
            if hovered {
                if let stack, model.heldStack == nil { hoveredName = stack.type.displayName }
                if pointer.clicked || pointer.rightClicked {
                    model.click(kind, secondary: pointer.rightClicked, shiftHeld: shiftHeld)
                }
            }
        }

        let panel = (x: panelX, y: panelY, w: panelWidth, h: panelHeight)
        if let name = drawSidePanels(app: app, panel: panel) { hoveredName = name }

        if let name = hoveredName, model.heldStack == nil {
            let w = app.text.width(name, size: 10)
            let tx = pointer.x + 14, ty = pointer.y + 12
            ui.rect(x: tx, y: ty, width: w + 14, height: 22, color: .init(0.05, 0.05, 0.05, 0.94))
            ui.frame(x: tx, y: ty, width: w + 14, height: 22, color: .init(0.5, 0.5, 0.5), thickness: 1)
            app.text.draw(ui, name, x: tx + 7, y: ty + 6, size: 10)
        }
        if let held = model.heldStack {
            SDLHUD.drawItem(held, x: pointer.x - size / 2, y: pointer.y - size / 2, size: size, app: app)
        }
    }

    /// "You can make" on one side and, in creative, the palette on the
    /// other. Returns the name under the pointer, for the tooltip.
    private func drawSidePanels(app: SDLApp, panel: (x: Float, y: Float, w: Float, h: Float)) -> String? {
        let ui = app.ui
        var hovered: String?
        let gap: Float = 16

        // What the bag can make, beside the panel. A click lays it out.
        if model.chest == nil {
            let width: Float = 230
            let x = panel.x + panel.w + gap
            if x + width <= ui.width - 8 {
                ui.rect(x: x, y: panel.y, width: width, height: panel.h, color: .init(0.13, 0.13, 0.13))
                ui.frame(x: x, y: panel.y, width: width, height: panel.h, color: .init(0.42, 0.42, 0.42), thickness: 2)
                app.text.draw(ui, L10n.t("You can make:", "Du kan tillverka:"), x: x + 12, y: panel.y + 14, size: 11)
                let recipes = RecipeBook.craftable(from: model.inventory, gridSize: model.craftingGrid.size)
                if recipes.isEmpty {
                    for (i, line) in app.text.wrap(L10n.t("Nothing yet \u{2014} gather materials!",
                                                          "Inget än \u{2014} samla material!"),
                                                   size: 9, maxWidth: width - 24).enumerated() {
                        app.text.draw(ui, line, x: x + 12, y: panel.y + 40 + Float(i) * 15, size: 9, color: .init(0.7, 0.7, 0.7))
                    }
                } else {
                    let rowHeight: Float = 34, top = panel.y + 36
                    let rows = max(1, Int((panel.h - 48) / rowHeight))
                    if pointer.inside(x, panel.y, width, panel.h) {
                        if pointer.wheel < -0.5 { craftableScroll += 1 }
                        if pointer.wheel > 0.5 { craftableScroll -= 1 }
                    }
                    craftableScroll = max(0, min(craftableScroll, recipes.count - rows))
                    for (offset, recipe) in recipes.dropFirst(craftableScroll).prefix(rows).enumerated() {
                        let ry = top + Float(offset) * rowHeight
                        let rowHovered = pointer.inside(x + 4, ry, width - 8, rowHeight)
                        let index = craftableScroll + offset
                        if refused?.index == index {
                            ui.rect(x: x + 4, y: ry, width: width - 8, height: rowHeight - 2, color: .init(0.55, 0.12, 0.10, 0.8))
                        } else if rowHovered {
                            ui.rect(x: x + 4, y: ry, width: width - 8, height: rowHeight - 2, color: .init(0.30, 0.30, 0.32))
                        }
                        SDLHUD.drawItem(recipe.output, x: x + 10, y: ry + 2, size: 30, app: app)
                        app.text.draw(ui, recipe.output.type.displayName, x: x + 48, y: ry + 12, size: 10)
                        if rowHovered, pointer.clicked {
                            if !model.fill(with: recipe) { refused = (index, 0.6) }
                        }
                    }
                    if recipes.count > rows {
                        app.text.draw(ui, L10n.t("scroll for more", "scrolla för fler"), x: x + 12, y: panel.y + panel.h - 18,
                                      size: 8, color: .init(0.6, 0.6, 0.6))
                    }
                }
            }
        }

        // Creative's palette: every item, on the other side.
        guard creative else { return hovered }
        let cell: Float = 40
        let columns = max(1, min(9, Int((panel.x - gap - 8) / cell)))
        let width = Float(columns) * cell + 16
        let x = panel.x - gap - width
        guard x >= 4 else { return hovered }
        let items = CreativeCatalogue.allItems
        ui.rect(x: x, y: panel.y, width: width, height: panel.h, color: .init(0.13, 0.13, 0.13))
        ui.frame(x: x, y: panel.y, width: width, height: panel.h, color: .init(0.42, 0.42, 0.42), thickness: 2)
        app.text.draw(ui, L10n.t("Every block", "Alla block"), x: x + 10, y: panel.y + 14, size: 11)
        // The bin, top right of the palette.
        let binX = x + width - 34, binY = panel.y + 8
        let binHovered = pointer.inside(binX, binY, 26, 26)
        ui.rect(x: binX, y: binY, width: 26, height: 26, color: binHovered ? .init(0.55, 0.15, 0.12) : .init(0.30, 0.12, 0.10))
        app.text.drawCentered(ui, "×", centreX: binX + 13, y: binY + 8, size: 11)
        if binHovered {
            hovered = L10n.t("Bin", "Papperskorg")
            if pointer.clicked { model.discardHeld() }
        }
        let top = panel.y + 40
        let rows = max(1, Int((panel.h - 48) / cell))
        let totalRows = (items.count + columns - 1) / columns
        if pointer.inside(x, panel.y, width, panel.h) {
            if pointer.wheel < -0.5 { paletteScroll += 1 }
            if pointer.wheel > 0.5 { paletteScroll -= 1 }
        }
        paletteScroll = max(0, min(paletteScroll, totalRows - rows))
        for (offset, item) in items.dropFirst(paletteScroll * columns).prefix(rows * columns).enumerated() {
            let cx = x + 8 + Float(offset % columns) * cell
            let cy = top + Float(offset / columns) * cell
            let cellHovered = pointer.inside(cx, cy, cell, cell)
            if cellHovered { ui.rect(x: cx, y: cy, width: cell, height: cell, color: .init(0.30, 0.30, 0.32)) }
            if let r = app.assets.iconRect(item) {
                ui.image(app.assets.items, x: cx + 4, y: cy + 4, width: cell - 8, height: cell - 8,
                         u0: r.u0, v0: r.v0, u1: r.u1, v1: r.v1)
            }
            if cellHovered {
                hovered = item.displayName
                if pointer.clicked || pointer.rightClicked {
                    model.takeFromPalette(item, secondary: pointer.rightClicked, shiftHeld: shiftHeld)
                }
            }
        }
        return hovered
    }
}
#endif
