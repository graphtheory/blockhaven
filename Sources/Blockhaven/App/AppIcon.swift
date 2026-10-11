#if canImport(AppKit)
import AppKit

/// The game's icon: a little house on a floating island, against a sky
/// tile. Pixel art on a 32×32 grid, drawn by code like every other picture
/// in the project, and baked by `AssetBake` into `icon.png` (the window
/// icon), `Blockhaven.ico` (Windows) and `AppIcon.icns` (the Mac app).
enum AppIcon {
    static let grid = 32

    /// The icon at `size` pixels square.
    static func image(size: Int) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        if let context = NSGraphicsContext.current?.cgContext {
            NSGraphicsContext.current?.imageInterpolation = .none
            context.setShouldAntialias(size % grid != 0)
            let scale = CGFloat(size) / CGFloat(grid)
            context.scaleBy(x: scale, y: scale)
            draw(context)
        }
        image.unlockFocus()
        return image
    }

    /// Top-left origin, row by row, as pixel art is usually drawn.
    private static func draw(_ context: CGContext) {
        func fill(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ color: NSColor) {
            context.setFillColor(color.cgColor)
            context.fill(CGRect(x: x, y: grid - y - h, width: w, height: h))
        }

        // The sky tile, rounded, lighter at the top.
        let tile = CGPath(roundedRect: CGRect(x: 1, y: 1, width: grid - 2, height: grid - 2),
                          cornerWidth: 6, cornerHeight: 6, transform: nil)
        context.saveGState()
        context.addPath(tile)
        context.clip()
        for row in 0..<grid {
            let t = CGFloat(row) / CGFloat(grid - 1)
            fill(0, row, grid, 1, NSColor(calibratedRed: 0.42 + 0.20 * t, green: 0.66 + 0.16 * t, blue: 0.96, alpha: 1))
        }
        // A cloud drifting behind the house.
        let cloud = NSColor(calibratedWhite: 0.97, alpha: 1)
        fill(4, 7, 6, 2, cloud); fill(3, 8, 9, 2, cloud); fill(22, 10, 5, 2, cloud); fill(21, 11, 8, 1, cloud)

        // The island: a grass top with a ragged edge, earth and stone
        // tapering underneath to a point, and a root hanging off it.
        let grass = NSColor(calibratedRed: 0.36, green: 0.66, blue: 0.24, alpha: 1)
        let grassDark = NSColor(calibratedRed: 0.27, green: 0.52, blue: 0.18, alpha: 1)
        let earth = NSColor(calibratedRed: 0.52, green: 0.36, blue: 0.22, alpha: 1)
        let earthDark = NSColor(calibratedRed: 0.40, green: 0.27, blue: 0.16, alpha: 1)
        let stone = NSColor(calibratedRed: 0.50, green: 0.50, blue: 0.52, alpha: 1)
        fill(5, 19, 22, 2, grass)
        for x in stride(from: 6, to: 26, by: 3) { fill(x, 21, 1, 1, grassDark) }
        let taper: [(Int, Int)] = [(6, 20), (7, 18), (9, 15), (11, 11), (13, 7), (15, 3)]
        for (index, (x, width)) in taper.enumerated() {
            fill(x, 21 + index, width, 1, index % 2 == 0 ? earth : earthDark)
        }
        fill(10, 23, 2, 1, stone); fill(18, 22, 3, 1, stone); fill(14, 25, 2, 1, stone)
        fill(22, 23, 1, 3, earthDark)

        // The house: plank walls, a door, a lit window, a red roof.
        let wall = NSColor(calibratedRed: 0.86, green: 0.70, blue: 0.46, alpha: 1)
        let wallDark = NSColor(calibratedRed: 0.70, green: 0.54, blue: 0.33, alpha: 1)
        fill(10, 13, 12, 6, wall)
        for y in [14, 16] { fill(10, y, 12, 1, wallDark) }
        fill(17, 15, 3, 4, NSColor(calibratedRed: 0.36, green: 0.22, blue: 0.12, alpha: 1))
        fill(12, 14, 3, 3, NSColor(calibratedRed: 1.0, green: 0.86, blue: 0.40, alpha: 1))
        let roof = NSColor(calibratedRed: 0.82, green: 0.24, blue: 0.18, alpha: 1)
        let roofDark = NSColor(calibratedRed: 0.64, green: 0.16, blue: 0.12, alpha: 1)
        for step in 0..<6 {
            fill(8 + step, 12 - step, 16 - step * 2, 1, step % 2 == 0 ? roof : roofDark)
        }
        fill(19, 6, 2, 4, NSColor(calibratedRed: 0.45, green: 0.45, blue: 0.47, alpha: 1))
        context.restoreGState()
    }

    // MARK: - Containers

    /// A Windows icon holding one PNG per size — the format Windows has
    /// read since Vista, and the simplest one to write.
    static func ico(sizes: [Int], png: (Int) -> Data) -> Data {
        var data = Data()
        func le16(_ v: Int) { var x = UInt16(v).littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
        func le32(_ v: Int) { var x = UInt32(v).littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
        let images = sizes.map(png)
        le16(0); le16(1); le16(sizes.count)
        var offset = 6 + 16 * sizes.count
        for (size, image) in zip(sizes, images) {
            data.append(UInt8(size >= 256 ? 0 : size)); data.append(UInt8(size >= 256 ? 0 : size))
            data.append(0); data.append(0)
            le16(1); le16(32); le32(image.count); le32(offset)
            offset += image.count
        }
        for image in images { data.append(image) }
        return data
    }

    /// A Mac icon file holding one PNG per size, under the element types
    /// macOS reads PNG data from.
    static func icns(png: (Int) -> Data) -> Data {
        let types: [(String, Int)] = [
            ("icp4", 16), ("icp5", 32), ("icp6", 64), ("ic07", 128),
            ("ic08", 256), ("ic09", 512), ("ic10", 1024),
        ]
        var body = Data()
        func be32(_ v: Int, into data: inout Data) {
            var x = UInt32(v).bigEndian
            withUnsafeBytes(of: &x) { data.append(contentsOf: $0) }
        }
        for (type, size) in types {
            let image = png(size)
            body.append(contentsOf: Array(type.utf8))
            be32(8 + image.count, into: &body)
            body.append(image)
        }
        var data = Data("icns".utf8)
        be32(8 + body.count, into: &data)
        data.append(body)
        return data
    }
}
#endif
