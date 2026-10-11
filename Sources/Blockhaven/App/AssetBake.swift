#if canImport(AppKit)
import AppKit

/// `BLOCKHAVEN_BAKE_ASSETS=<dir>` writes every texture the SDL front end
/// needs as a PNG, then exits.
///
/// The Mac paints its textures at run time with CoreGraphics — the block
/// atlas, the item icons, the mob skins — and Windows has no CoreGraphics.
/// Porting several thousand lines of path drawing would buy a second copy
/// of every picture to keep in step; exporting them buys the same pixels
/// for free. They are checked in under `Assets/`, and `make assets`
/// refreshes them. `BLOCKHAVEN_CHECK_ASSETS=1` fails when what is checked in
/// no longer matches what this build paints.
enum AssetBake {
    static var isRequested: Bool { ProcessInfo.processInfo.environment["BLOCKHAVEN_BAKE_ASSETS"] != nil }
    static var isCheckRequested: Bool { ProcessInfo.processInfo.environment["BLOCKHAVEN_CHECK_ASSETS"] == "1" }

    /// Pixels per item icon in `items.png`. The Mac draws icons as vectors
    /// at 48 points; 64 keeps them sharp at the sizes the SDL HUD uses.
    static let iconPixels = 64

    static func run() -> Never {
        let path = ProcessInfo.processInfo.environment["BLOCKHAVEN_BAKE_ASSETS"]!
        let directory = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, data) in render() {
            do {
                try data.write(to: directory.appendingPathComponent(name))
                print("[bake] \(name) \(data.count) bytes")
            } catch {
                StandardError.write(Data("[bake] \(name): \(error)\n".utf8))
                exit(1)
            }
        }
        exit(0)
    }

    /// Compares a fresh bake against `Assets/` in the source tree.
    static func check() -> Never {
        let assets = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Assets")
        var stale: [String] = []
        for (name, data) in render() {
            let onDisk = try? Data(contentsOf: assets.appendingPathComponent(name))
            if onDisk != data { stale.append(name) }
        }
        if stale.isEmpty {
            print("[check] all passed — the baked assets match")
            exit(0)
        }
        print("[check] FAILED — stale in Assets/: \(stale.joined(separator: ", ")) — run `make assets`")
        exit(1)
    }

    /// Every file, by name.
    static func render() -> [(String, Data)] {
        var files: [(String, Data)] = []
        files.append(("atlas.png", png(TextureAtlas.image, width: TextureAtlas.sheetWidth, height: TextureAtlas.sheetHeight)))

        // Every item icon on one sheet, 16 to a row, in `ItemType.allCases`
        // order — and that order written beside it, so a sheet from a build
        // with different items can never be read against the wrong names.
        let items = ItemType.allCases
        let columns = 16
        let rows = (items.count + columns - 1) / columns
        let sheet = bitmap(width: columns * iconPixels, height: rows * iconPixels)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: sheet)
        NSGraphicsContext.current?.imageInterpolation = .high
        for (index, item) in items.enumerated() {
            let column = index % columns, row = index / columns
            // AppKit's origin is bottom-left; row 0 goes at the top.
            let rect = NSRect(
                x: column * iconPixels, y: (rows - 1 - row) * iconPixels,
                width: iconPixels, height: iconPixels
            )
            ItemIcons.icon(for: item).draw(in: rect)
        }
        NSGraphicsContext.restoreGraphicsState()
        files.append(("items.png", sheet.representation(using: .png, properties: [:])!))
        files.append(("items.txt", Data(items.map(\.rawValue).joined(separator: "\n").utf8)))

        // Every mob skin, each a 16-pixel tile, on one strip, named in
        // `skins.txt` in the same order.
        var skins: [(String, NSImage)] = [
            ("fizzler.body", FizzlerSkin.body), ("fizzler.face", FizzlerSkin.face), ("fizzler.flash", FizzlerSkin.flash),
            ("skeleton.body", SkeletonSkin.body), ("skeleton.face", SkeletonSkin.face), ("skeleton.flash", SkeletonSkin.flash),
            ("beak", AnimalSkin.beak), ("comb", AnimalSkin.comb), ("eye", AnimalSkin.eye),
        ]
        for kind in AnimalKind.allCases {
            for morph in [AnimalMorph.common, .rare] {
                let tag = "\(kind.rawValue).\(morph == .rare ? "rare" : "common")"
                skins.append(("\(tag).body", AnimalSkin.body(for: kind, morph: morph)))
                skins.append(("\(tag).head", AnimalSkin.head(for: kind, morph: morph)))
                skins.append(("\(tag).flash", AnimalSkin.flash(for: kind, morph: morph)))
                skins.append(("\(tag).frill", AnimalSkin.frill(for: kind, morph: morph)))
                skins.append(("\(tag).belly", AnimalSkin.belly(for: kind, morph: morph)))
            }
        }
        let tile = 16
        let strip = bitmap(width: skins.count * tile, height: tile)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: strip)
        NSGraphicsContext.current?.imageInterpolation = .none
        for (index, skin) in skins.enumerated() {
            skin.1.draw(in: NSRect(x: index * tile, y: 0, width: tile, height: tile))
        }
        NSGraphicsContext.restoreGraphicsState()
        files.append(("skins.png", strip.representation(using: .png, properties: [:])!))
        files.append(("skins.txt", Data(skins.map(\.0).joined(separator: "\n").utf8)))

        // The game's icon: the window icon, the Windows icon file and the
        // Mac app's — all one picture, see `AppIcon`.
        let iconPNG = { (size: Int) in png(AppIcon.image(size: size), width: size, height: size) }
        files.append(("icon.png", iconPNG(256)))
        files.append(("Blockhaven.ico", AppIcon.ico(sizes: [16, 24, 32, 48, 64, 128, 256], png: iconPNG)))
        files.append(("AppIcon.icns", AppIcon.icns(png: iconPNG)))
        return files
    }

    private static func bitmap(width: Int, height: Int) -> NSBitmapImageRep {
        NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32
        )!
    }

    /// An image drawn into exactly `width` by `height` pixels, nearest
    /// neighbour, so a pixel-art sheet keeps every texel.
    private static func png(_ image: NSImage, width: Int, height: Int) -> Data {
        let rep = bitmap(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .none
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }
}
#endif
