import Foundation
import CStbImage

/// Tightly packed RGBA8 pixels, top row first.
struct RGBAImage {
    var width: Int
    var height: Int
    var pixels: [UInt8]

    init(width: Int, height: Int, fill: (UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 0)) {
        self.width = width
        self.height = height
        var row = [UInt8]()
        row.reserveCapacity(width * 4)
        for _ in 0..<width { row += [fill.0, fill.1, fill.2, fill.3] }
        pixels = Array([[UInt8]](repeating: row, count: height).joined())
    }

    /// Decodes a PNG. Nil if the bytes are not one.
    init?(png data: Data) {
        var w: Int32 = 0, h: Int32 = 0, channels: Int32 = 0
        let decoded: UnsafeMutablePointer<UInt8>? = data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
            return stbi_load_from_memory(base, Int32(raw.count), &w, &h, &channels, 4)
        }
        guard let decoded else { return nil }
        defer { stbi_image_free(decoded) }
        width = Int(w)
        height = Int(h)
        pixels = Array(UnsafeBufferPointer(start: decoded, count: Int(w) * Int(h) * 4))
    }

    init?(contentsOf url: URL) {
        guard let data = try? Data(contentsOf: url) else { return nil }
        self.init(png: data)
    }

    /// A rectangle of this image as its own image.
    func crop(x: Int, y: Int, width w: Int, height h: Int) -> RGBAImage {
        var out = RGBAImage(width: w, height: h)
        for row in 0..<h {
            let from = ((y + row) * width + x) * 4
            let to = row * w * 4
            out.pixels.replaceSubrange(to..<(to + w * 4), with: pixels[from..<(from + w * 4)])
        }
        return out
    }
}
