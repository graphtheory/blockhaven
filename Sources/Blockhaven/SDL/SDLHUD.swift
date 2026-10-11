#if canImport(CSDL3)
import Foundation

/// Small pixel-art sprites the overlay draws: hearts, drumsticks, bubbles.
/// The Mac draws these as vector paths; here they are drawn the way the
/// rest of this front end draws everything, a pixel at a time.
final class SDLSprites {
    enum Sprite: Int, CaseIterable {
        case heart, halfHeart, emptyHeart
        case drumstick, halfDrumstick, emptyDrumstick
        case bubble
    }

    private static let size = 9

    /// `#` outline, `r` red, `p` pale red, `b` brown, `l` light brown,
    /// `w` white, `c` cyan, `e` empty grey.
    private static let art: [Sprite: [String]] = [
        .heart: [
            ".##...##.",
            "#rp#.#rr#",
            "#rprrrrr#",
            "#rrrrrrr#",
            ".#rrrrr#.",
            "..#rrr#..",
            "...#r#...",
            "....#....",
            ".........",
        ],
        .halfHeart: [
            ".##...##.",
            "#rp#.#ee#",
            "#rprreee#",
            "#rrrreee#",
            ".#rrree#.",
            "..#rre#..",
            "...#e#...",
            "....#....",
            ".........",
        ],
        .emptyHeart: [
            ".##...##.",
            "#ee#.#ee#",
            "#eeeeeee#",
            "#eeeeeee#",
            ".#eeeee#.",
            "..#eee#..",
            "...#e#...",
            "....#....",
            ".........",
        ],
        .drumstick: [
            "....####.",
            "...#bllb#",
            "..#bbllb#",
            "..#bbbbb#",
            "..#bbbb#.",
            ".#w###...",
            "#ww#.....",
            "#w#......",
            ".#.......",
        ],
        .halfDrumstick: [
            "....####.",
            "...#eeee#",
            "..#beeee#",
            "..#bbeee#",
            "..#bbbe#.",
            ".#w###...",
            "#ww#.....",
            "#w#......",
            ".#.......",
        ],
        .emptyDrumstick: [
            "....####.",
            "...#eeee#",
            "..#eeeee#",
            "..#eeeee#",
            "..#eeee#.",
            ".#e###...",
            "#ee#.....",
            "#e#......",
            ".#.......",
        ],
        .bubble: [
            "..###....",
            ".#cccc#..",
            "#cwcccc#.",
            "#wccccc#.",
            "#ccccc#..",
            ".#ccc#...",
            "..###....",
            ".........",
            ".........",
        ],
    ]

    let texture: GLTexture

    init() {
        let count = Sprite.allCases.count
        var image = RGBAImage(width: count * SDLSprites.size, height: SDLSprites.size)
        let palette: [Character: (UInt8, UInt8, UInt8, UInt8)] = [
            "#": (16, 10, 10, 230),
            "r": (220, 38, 38, 255),
            "p": (255, 160, 160, 255),
            "b": (184, 122, 51, 255),
            "l": (230, 180, 110, 255),
            "w": (240, 236, 224, 255),
            "c": (140, 216, 255, 255),
            "e": (40, 40, 40, 170),
        ]
        for sprite in Sprite.allCases {
            for (y, row) in (SDLSprites.art[sprite] ?? []).enumerated() {
                for (x, character) in row.enumerated() {
                    guard let colour = palette[character] else { continue }
                    let i = (y * image.width + sprite.rawValue * SDLSprites.size + x) * 4
                    image.pixels[i] = colour.0; image.pixels[i + 1] = colour.1
                    image.pixels[i + 2] = colour.2; image.pixels[i + 3] = colour.3
                }
            }
        }
        texture = GLTexture(image: image, nearest: true)
    }

    func draw(_ ui: UIRenderer, _ sprite: Sprite, x: Float, y: Float, size: Float) {
        let count = Float(Sprite.allCases.count)
        ui.image(texture, x: x, y: y, width: size, height: size,
                 u0: Float(sprite.rawValue) / count, v0: 0,
                 u1: Float(sprite.rawValue + 1) / count, v1: 1)
    }
}

/// The in-play overlay: crosshair, hotbar, hearts and hunger, the lines
/// that flash up over the hotbar, the compass, and the debug text — the
/// same layout `HUDView` draws on the Mac.
final class SDLHUD {
    private let sprites = SDLSprites()
    private var craftingHintDismissed = GameSettings.craftingHintShown

    static let slotSize: Float = 44
    static let slotGap: Float = 4
    static let bottomMargin: Float = 22

    func draw(_ state: HUDState, app: SDLApp) {
        let ui = app.ui, text = app.text
        let width = ui.width, height = ui.height

        if state.isSubmerged { ui.rect(x: 0, y: 0, width: width, height: height, color: .init(0.10, 0.28, 0.62, 0.32)) }
        if state.isInLava { ui.rect(x: 0, y: 0, width: width, height: height, color: .init(0.85, 0.25, 0.05, 0.40)) }
        if state.showDamageFlash { ui.rect(x: 0, y: 0, width: width, height: height, color: .init(0.75, 0.05, 0.05, 0.30)) }

        // Crosshair. The Mac inverts what is under it; a white cross with a
        // dark edge reads on sky and stone alike without a blend mode.
        let cx = (width / 2).rounded(), cy = (height / 2).rounded()
        ui.rect(x: cx - 9, y: cy - 2, width: 18, height: 4, color: .init(0, 0, 0, 0.45))
        ui.rect(x: cx - 2, y: cy - 9, width: 4, height: 18, color: .init(0, 0, 0, 0.45))
        ui.rect(x: cx - 8, y: cy - 1, width: 16, height: 2, color: .white)
        ui.rect(x: cx - 1, y: cy - 8, width: 2, height: 16, color: .white)

        // Hotbar.
        let count = Inventory.hotbarSize
        let total = Float(count) * SDLHUD.slotSize + Float(count - 1) * SDLHUD.slotGap
        let originX = ((width - total) / 2).rounded()
        let originY = height - SDLHUD.bottomMargin - SDLHUD.slotSize
        for index in 0..<count {
            let x = originX + Float(index) * (SDLHUD.slotSize + SDLHUD.slotGap)
            ui.rect(x: x, y: originY, width: SDLHUD.slotSize, height: SDLHUD.slotSize, color: .init(0.10, 0.10, 0.10, 0.62))
            ui.frame(x: x, y: originY, width: SDLHUD.slotSize, height: SDLHUD.slotSize, color: .init(0.45, 0.45, 0.45, 0.85), thickness: 1.5)
            if index < state.hotbar.count, let stack = state.hotbar[index] {
                SDLHUD.drawItem(stack, x: x, y: originY, size: SDLHUD.slotSize, app: app)
            }
        }
        let selected = max(0, min(count - 1, state.selectedSlot))
        let sx = originX + Float(selected) * (SDLHUD.slotSize + SDLHUD.slotGap)
        ui.frame(x: sx - 3, y: originY - 3, width: SDLHUD.slotSize + 6, height: SDLHUD.slotSize + 6, color: .white, thickness: 2.5)

        // Hearts and hunger, ten each, over the two ends of the hotbar.
        let barY = originY - 12 - 14
        if state.showSurvivalBars {
            let spacing: Float = 18, icon: Float = 14
            for index in 0..<10 {
                let filled = state.health - index * 2
                sprites.draw(ui, filled >= 2 ? .heart : (filled == 1 ? .halfHeart : .emptyHeart),
                             x: originX + 2 + Float(index) * spacing, y: barY, size: icon)
                let food = state.hunger - index * 2
                sprites.draw(ui, food >= 2 ? .drumstick : (food == 1 ? .halfDrumstick : .emptyDrumstick),
                             x: originX + total - icon - 2 - Float(9 - index) * spacing, y: barY, size: icon)
            }
            if state.air < PlayerStats.maxAir {
                for index in 0..<10 where state.air > index * 2 {
                    sprites.draw(ui, .bubble, x: originX + total - icon - 2 - Float(9 - index) * spacing,
                                 y: barY - 20, size: icon)
                }
            }
            if let chestplate = state.equippedChestplate {
                SDLHUD.drawItem(ItemStack(chestplate), x: originX, y: barY - 40, size: 34, app: app)
            }
        }

        // The lines over the hotbar, highest last.
        let hotbarTop = originY
        if let name = state.itemName {
            text.drawCentered(ui, name, centreX: width / 2, y: hotbarTop - 62, size: 14)
        }
        if let toast = state.toast {
            panelLine(toast, centreY: hotbarTop - 82, app: app)
        }
        if !craftingHintDismissed { craftingHintDismissed = GameSettings.craftingHintShown }
        if !craftingHintDismissed {
            let hint = state.isCreative
                ? L10n.t("Press E for every block — F picks up the one you're looking at",
                         "Tryck E för alla block — F plockar upp det du tittar på")
                : L10n.t("Press E to craft — place the Crafting Table for more recipes",
                         "Tryck E för att tillverka — placera arbetsbänken för fler recept")
            panelLine(hint, centreY: hotbarTop - 104, app: app)
        }

        if let bearing = state.compassBearing { drawCompass(bearing: Float(bearing), state: state, app: app) }

        if let debug = state.debugText {
            var y: Float = 10
            for line in debug.split(separator: "\n") {
                let w = text.width(String(line), size: 9)
                ui.rect(x: 6, y: y - 3, width: w + 8, height: 15, color: .init(0, 0, 0, 0.45))
                text.draw(ui, String(line), x: 10, y: y, size: 9)
                y += 16
            }
        }

        if state.fadeToBlack > 0 {
            ui.rect(x: 0, y: 0, width: width, height: height, color: .init(0, 0, 0, Float(min(1, state.fadeToBlack))))
        }
    }

    private func panelLine(_ line: String, centreY: Float, app: SDLApp) {
        let size: Float = 11
        let w = app.text.width(line, size: size)
        let x = ((app.ui.width - w) / 2).rounded()
        app.ui.rect(x: x - 10, y: centreY - 7, width: w + 20, height: size + 14, color: .init(0.04, 0.04, 0.04, 0.58))
        app.text.draw(app.ui, line, x: x, y: centreY, size: size)
    }

    private func drawCompass(bearing: Float, state: HUDState, app: SDLApp) {
        let ui = app.ui
        let cx = ui.width / 2, cy: Float = 54
        let radius: Float = 18
        ui.rect(x: cx - radius - 4, y: cy - radius - 4, width: (radius + 4) * 2, height: (radius + 4) * 2, color: .init(0.04, 0.04, 0.04, 0.5))
        ui.frame(x: cx - radius - 4, y: cy - radius - 4, width: (radius + 4) * 2, height: (radius + 4) * 2, color: .init(0.9, 0.9, 0.9, 0.8), thickness: 1.5)
        // The needle as a run of dots from the centre along the bearing:
        // zero is straight ahead, up the screen.
        let colour: UIRenderer.Color = state.compassTargetsGrave ? .init(0.75, 0.75, 0.85) : .init(0.92, 0.2, 0.2)
        for step in 0..<9 {
            let r = Float(step) * 2
            let x = cx + sin(bearing) * r, y = cy - cos(bearing) * r
            ui.rect(x: x - 1.5, y: y - 1.5, width: 3, height: 3, color: colour)
        }
        if let distance = state.compassDistance {
            app.text.drawCentered(ui, "\(Int(distance))m", centreX: cx, y: cy + radius + 10, size: 9)
        }
    }

    /// An item in a slot: its icon, a wear bar, and how many there are.
    static func drawItem(_ stack: ItemStack, x: Float, y: Float, size: Float, app: SDLApp) {
        let inset = size * 5 / 44
        if let rect = app.assets.iconRect(stack.type) {
            app.ui.image(app.assets.items, x: x + inset, y: y + inset, width: size - inset * 2, height: size - inset * 2,
                         u0: rect.u0, v0: rect.v0, u1: rect.u1, v1: rect.v1)
        }
        if let fraction = stack.wearFraction {
            let bx = x + inset, by = y + size - inset, bw = size - inset * 2
            app.ui.rect(x: bx - 1, y: by - 1, width: bw + 2, height: 5, color: .init(0.05, 0.05, 0.05, 0.85))
            let hue = Float(fraction) * 0.33
            app.ui.rect(x: bx, y: by, width: max(1, bw * Float(fraction)), height: 3, color: SDLHUD.hueColor(hue))
        }
        guard stack.count > 1 else { return }
        let label = "\(stack.count)"
        let w = app.text.width(label, size: 9)
        app.text.draw(app.ui, label, x: x + size - w - 4, y: y + size - 14, size: 9)
    }

    /// A saturated colour round the hue wheel, 0 red … 0.33 green.
    static func hueColor(_ hue: Float) -> UIRenderer.Color {
        let h = hue * 6
        let x = 1 - abs(h.truncatingRemainder(dividingBy: 2) - 1)
        let (r, g, b): (Float, Float, Float) = h < 1 ? (1, x, 0) : (h < 2 ? (x, 1, 0) : (0, 1, x))
        return .init(0.15 + r * 0.75, 0.15 + g * 0.75, 0.15 + b * 0.75)
    }
}
#endif
