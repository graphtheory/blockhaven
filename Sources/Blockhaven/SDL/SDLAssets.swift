#if canImport(CSDL3)
import Foundation

/// The textures the Mac paints at run time, read back from the PNGs it
/// exported (see `AssetBake`).
final class SDLAssets {
    /// Where `Assets/` is: beside the executable in a packaged build, or in
    /// the source tree when running from `swift build`.
    static let directory: URL = {
        let executable = executableURL()
        let beside = executable.deletingLastPathComponent().appendingPathComponent("Assets", isDirectory: true)
        if FileManager.default.fileExists(atPath: beside.appendingPathComponent("atlas.png").path) {
            return beside
        }
        // Sources/Blockhaven/SDL/SDLAssets.swift → the package root.
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Assets", isDirectory: true)
    }()

    static func image(_ name: String) -> RGBAImage {
        let url = directory.appendingPathComponent(name)
        guard let image = RGBAImage(contentsOf: url) else {
            SDLApp.fail("A game file is missing or damaged: \(url.path)")
        }
        return image
    }

    /// The block atlas for the 3D passes: sRGB, so the shader lights in
    /// linear light the way RealityKit does.
    let atlas: GLTexture
    /// The same sheet for the overlay, sampled as-is.
    let atlasFlat: GLTexture
    /// Every item icon on one sheet, and where each one is on it.
    let items: GLTexture
    private let itemSlots: [ItemType: Int]
    /// Every mob skin on one strip, and each one's UV rectangle by name.
    let skins: GLTexture
    private let skinRects: [String: SIMD4<Float>]
    let windowIcon: RGBAImage
    private let itemColumns: Int
    private let itemRows: Int

    init() {
        let sheet = SDLAssets.image("atlas.png")
        atlas = GLTexture(image: sheet, nearest: true, srgb: true)
        atlasFlat = GLTexture(image: sheet, nearest: true)

        let icons = SDLAssets.image("items.png")
        items = GLTexture(image: icons, nearest: false, mipmaps: true)
        let names = (try? String(contentsOf: SDLAssets.directory.appendingPathComponent("items.txt"), encoding: .utf8)) ?? ""
        var slots: [ItemType: Int] = [:]
        for (index, name) in names.split(whereSeparator: \.isNewline).enumerated() {
            if let item = ItemType(rawValue: String(name)) { slots[item] = index }
        }
        itemSlots = slots
        itemColumns = icons.width / 64
        itemRows = icons.height / 64

        // The game's icon — the same picture the installer gives the
        // shortcuts (`AppIcon`).
        windowIcon = SDLAssets.image("icon.png")

        let strip = SDLAssets.image("skins.png")
        skins = GLTexture(image: strip, nearest: true, srgb: true)
        let skinNames = (try? String(contentsOf: SDLAssets.directory.appendingPathComponent("skins.txt"), encoding: .utf8)) ?? ""
        var rects: [String: SIMD4<Float>] = [:]
        let count = Float(max(1, strip.width / 16))
        for (index, name) in skinNames.split(whereSeparator: \.isNewline).enumerated() {
            // Half a texel in from each edge, so nearest sampling at a face's
            // border never reads the neighbouring skin.
            let inset = 0.5 / Float(strip.width)
            rects[String(name)] = SIMD4(Float(index) / count + inset, 0, Float(index + 1) / count - inset, 1)
        }
        skinRects = rects
    }

    /// The UV rectangle of a named skin on `skins` — see `AssetBake`.
    func skin(_ name: String) -> SIMD4<Float> {
        skinRects[name] ?? SIMD4(0, 0, 0, 0)
    }

    /// The UV rectangle of an item's icon on `items`, top-left origin.
    func iconRect(_ item: ItemType) -> (u0: Float, v0: Float, u1: Float, v1: Float)? {
        guard let slot = itemSlots[item] else { return nil }
        let column = slot % itemColumns, row = slot / itemColumns
        return (
            Float(column) / Float(itemColumns), Float(row) / Float(itemRows),
            Float(column + 1) / Float(itemColumns), Float(row + 1) / Float(itemRows)
        )
    }

    /// The UV rectangle of a block tile on `atlasFlat`, top-left origin.
    func tileRect(_ tile: AtlasTile) -> (u0: Float, v0: Float, u1: Float, v1: Float) {
        let r = TextureAtlas.uvRect(for: tile, shadeIndex: TextureAtlas.shadeLevels - 1)
        return (r.u0, 1 - r.v0, r.u1, 1 - r.v1)
    }
}

/// `BLOCKHAVEN_SDL_SCREENSHOT=<file.bmp>` writes the frame to disk after
/// `BLOCKHAVEN_SDL_SCREENSHOT_AFTER` seconds (default 6) and quits — the SDL
/// front end's counterpart to the Mac's snapshot harness.
enum SDLScreenshot {
    private static let path = ProcessInfo.processInfo.environment["BLOCKHAVEN_SDL_SCREENSHOT"]
    private static let after = Double(ProcessInfo.processInfo.environment["BLOCKHAVEN_SDL_SCREENSHOT_AFTER"] ?? "") ?? 6
    nonisolated(unsafe) private static var elapsed = 0.0

    static func captureIfDue(app: SDLApp, dt: Double) {
        guard let path else { return }
        elapsed += dt
        guard elapsed >= after else { return }
        let w = app.pixelWidth, h = app.pixelHeight
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        glPixelStorei(GL_PACK_ALIGNMENT, 1)
        glReadPixels(0, 0, GLsizei(w), GLsizei(h), GL_RGBA, GL_UNSIGNED_BYTE, &pixels)
        // BMP: bottom row first, which is the order GL reads in.
        var data = Data()
        func le32(_ v: Int) { var x = UInt32(v).littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
        func le16(_ v: Int) { var x = UInt16(v).littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
        let rowBytes = w * 3, padded = (rowBytes + 3) & ~3
        data.append(contentsOf: [0x42, 0x4D]); le32(54 + padded * h); le32(0); le32(54)
        le32(40); le32(w); le32(h); le16(1); le16(24); le32(0); le32(padded * h); le32(2835); le32(2835); le32(0); le32(0)
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                data.append(contentsOf: [pixels[i + 2], pixels[i + 1], pixels[i]])
            }
            data.append(contentsOf: [UInt8](repeating: 0, count: padded - rowBytes))
        }
        try? data.write(to: URL(fileURLWithPath: path))
        StandardError.write(Data("[sdl] screenshot \(w)x\(h) → \(path)\n".utf8))
        app.quit()
    }
}
#endif
