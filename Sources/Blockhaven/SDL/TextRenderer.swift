#if canImport(CSDL3)
import Foundation

/// Draws `PixelFont` text through the overlay.
final class TextRenderer {
    private struct Glyph {
        var u0: Float, v0: Float, u1: Float, v1: Float
        var width: Int
    }

    private let texture: GLTexture
    private var glyphs: [Character: Glyph] = [:]
    private let fallback: Glyph

    /// Rasterises every glyph into one sheet, once.
    init() {
        let rows = PixelFont.cellRows
        var cells: [(Character, [[Bool]])] = []
        func parse(_ spec: String) -> [[Bool]] {
            spec.split(separator: "/", omittingEmptySubsequences: false).map { row in row.map { $0 == "#" } }
        }
        for (character, spec) in PixelFont.glyphs {
            var bitmap = [[Bool]](repeating: [], count: PixelFont.accentRows)
            bitmap += parse(spec)
            cells.append((character, bitmap))
        }
        for (character, entry) in PixelFont.accented {
            guard let base = PixelFont.glyphs[entry.base] else { continue }
            cells.append((character, parse(entry.accent) + parse(base)))
        }

        let cellWidth = 6, cellHeight = rows
        let columns = 16
        let sheetRows = (cells.count + 1 + columns - 1) / columns
        var image = RGBAImage(width: columns * cellWidth, height: sheetRows * cellHeight)
        func put(_ bitmap: [[Bool]], at index: Int) -> Glyph {
            let ox = (index % columns) * cellWidth, oy = (index / columns) * cellHeight
            var width = 0
            for (y, row) in bitmap.enumerated() where y < cellHeight {
                width = max(width, row.count)
                for (x, on) in row.enumerated() where on && x < cellWidth {
                    let i = ((oy + y) * image.width + ox + x) * 4
                    image.pixels[i] = 255; image.pixels[i + 1] = 255
                    image.pixels[i + 2] = 255; image.pixels[i + 3] = 255
                }
            }
            return Glyph(
                u0: Float(ox) / Float(image.width), v0: Float(oy) / Float(image.height),
                u1: Float(ox + max(1, width)) / Float(image.width), v1: Float(oy + cellHeight) / Float(image.height),
                width: width
            )
        }
        for (index, cell) in cells.enumerated() {
            glyphs[cell.0] = put(cell.1, at: index)
        }
        // An unknown character draws as a hollow box, so a missing glyph is
        // visible rather than silently eaten.
        let box = [[Bool]](repeating: [], count: PixelFont.accentRows)
            + [[true, true, true, true]] + [[Bool]](repeating: [true, false, false, true], count: 5) + [[true, true, true, true]]
        fallback = put(box, at: cells.count)
        texture = GLTexture(image: image, nearest: true)
    }

    /// One font pixel, in points, for a line `size` points tall — the
    /// height of a capital letter.
    private func pixel(_ size: Float) -> Float { size / Float(PixelFont.bodyRows) }

    func width(_ string: String, size: Float) -> Float {
        let p = pixel(size)
        var total: Float = 0
        for character in string {
            total += Float((glyphs[character] ?? fallback).width + 1) * p
        }
        return max(0, total - p)
    }

    /// Draws one line with its top-left at `x`, `y`, where `y` is the top of
    /// the capitals. A shadow one font pixel down and right, the way the
    /// games this one follows draws all of its text, keeps it legible
    /// over a bright sky.
    func draw(_ ui: UIRenderer, _ string: String, x: Float, y: Float, size: Float,
              color: UIRenderer.Color = .white, shadow: Bool = true) {
        let p = pixel(size)
        if shadow {
            let dark = UIRenderer.Color(color.r * 0.25, color.g * 0.25, color.b * 0.25, color.a)
            drawRun(ui, string, x: x + p, y: y + p, pixel: p, color: dark)
        }
        drawRun(ui, string, x: x, y: y, pixel: p, color: color)
    }

    func drawCentered(_ ui: UIRenderer, _ string: String, centreX: Float, y: Float, size: Float,
                      color: UIRenderer.Color = .white, shadow: Bool = true) {
        draw(ui, string, x: (centreX - width(string, size: size) / 2).rounded(), y: y, size: size, color: color, shadow: shadow)
    }

    private func drawRun(_ ui: UIRenderer, _ string: String, x: Float, y: Float, pixel p: Float, color: UIRenderer.Color) {
        var cursor = x
        let top = y - Float(PixelFont.accentRows) * p
        let height = Float(PixelFont.cellRows) * p
        for character in string {
            let glyph = glyphs[character] ?? fallback
            if glyph.width > 0, character != " " {
                ui.image(texture, x: cursor, y: top, width: Float(glyph.width) * p, height: height,
                         u0: glyph.u0, v0: glyph.v0, u1: glyph.u1, v1: glyph.v1, color: color)
            }
            cursor += Float(glyph.width + 1) * p
        }
    }

    /// Breaks `string` into lines no wider than `maxWidth`, at spaces.
    func wrap(_ string: String, size: Float, maxWidth: Float) -> [String] {
        var lines: [String] = []
        for paragraph in string.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = ""
            for word in paragraph.split(separator: " ") {
                let candidate = line.isEmpty ? String(word) : line + " " + word
                if width(candidate, size: size) > maxWidth, !line.isEmpty {
                    lines.append(line)
                    line = String(word)
                } else {
                    line = candidate
                }
            }
            lines.append(line)
        }
        return lines
    }
}
#endif
