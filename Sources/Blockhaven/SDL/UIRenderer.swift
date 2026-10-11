#if canImport(CSDL3)
import Foundation

/// The 2D overlay: rectangles, images and text, in window points with the
/// origin top-left. Everything queued in a frame is drawn in order by
/// `flush`, one draw call per change of texture.
final class UIRenderer {
    struct Color {
        var r: Float, g: Float, b: Float, a: Float
        init(_ r: Float, _ g: Float, _ b: Float, _ a: Float = 1) {
            self.r = r; self.g = g; self.b = b; self.a = a
        }
        static let white = Color(1, 1, 1)
        static let black = Color(0, 0, 0)
        func withAlpha(_ alpha: Float) -> Color { Color(r, g, b, a * alpha) }
    }

    private struct Vertex {
        var x: Float, y: Float, u: Float, v: Float
        var r: Float, g: Float, b: Float, a: Float
    }

    private let program: GLProgram
    private var vao: GLuint = 0
    private var vbo: GLuint = 0
    private var vertices: [Vertex] = []
    private var batches: [(texture: GLTexture, start: Int, count: Int, clip: (Float, Float, Float, Float)?)] = []
    /// A single white pixel: what a solid rectangle samples.
    let white: GLTexture
    /// Points to pixels — 2 on a Retina screen, often 1.25 or 1.5 on a
    /// Windows laptop.
    private(set) var scale: Float = 1
    private(set) var width: Float = 0
    private(set) var height: Float = 0
    private var clip: (Float, Float, Float, Float)?

    init() {
        program = GLProgram(
            name: "ui",
            vertex: """
            #version 330 core
            in vec2 aPosition;
            in vec2 aUV;
            in vec4 aColor;
            uniform mat4 uProjection;
            out vec2 vUV;
            out vec4 vColor;
            void main() {
                vUV = aUV;
                vColor = aColor;
                gl_Position = uProjection * vec4(aPosition, 0.0, 1.0);
            }
            """,
            fragment: """
            #version 330 core
            in vec2 vUV;
            in vec4 vColor;
            uniform sampler2D uTexture;
            out vec4 fragColor;
            void main() {
                fragColor = texture(uTexture, vUV) * vColor;
            }
            """,
            attributes: ["aPosition", "aUV", "aColor"]
        )
        var pixel: [UInt8] = [255, 255, 255, 255]
        white = GLTexture(width: 1, height: 1, pixels: &pixel)
        glGenVertexArrays(1, &vao)
        glBindVertexArray(vao)
        glGenBuffers(1, &vbo)
        glBindBuffer(GL_ARRAY_BUFFER, vbo)
        let stride = GLsizei(MemoryLayout<Vertex>.stride)
        glEnableVertexAttribArray(0)
        glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, stride, nil)
        glEnableVertexAttribArray(1)
        glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, stride, UnsafeRawPointer(bitPattern: 8))
        glEnableVertexAttribArray(2)
        glVertexAttribPointer(2, 4, GL_FLOAT, GL_FALSE, stride, UnsafeRawPointer(bitPattern: 16))
        glBindVertexArray(0)
    }

    /// Starts a frame `width` by `height` points, at `scale` pixels each.
    func begin(width: Float, height: Float, scale: Float) {
        self.width = width
        self.height = height
        self.scale = scale
        vertices.removeAll(keepingCapacity: true)
        batches.removeAll(keepingCapacity: true)
        clip = nil
    }

    /// Clips everything queued until `endClip` to a rectangle.
    func beginClip(x: Float, y: Float, width: Float, height: Float) {
        clip = (x, y, width, height)
    }

    func endClip() { clip = nil }

    func image(_ texture: GLTexture, x: Float, y: Float, width: Float, height: Float,
               u0: Float = 0, v0: Float = 0, u1: Float = 1, v1: Float = 1, color: Color = .white) {
        if let last = batches.last, last.texture === texture, last.start + last.count == vertices.count,
           last.clip.map({ c in clip.map { $0 == c } ?? false }) ?? (clip == nil) {
            batches[batches.count - 1].count += 6
        } else {
            batches.append((texture, vertices.count, 6, clip))
        }
        let x1 = x + width, y1 = y + height
        let a = Vertex(x: x, y: y, u: u0, v: v0, r: color.r, g: color.g, b: color.b, a: color.a)
        let b = Vertex(x: x1, y: y, u: u1, v: v0, r: color.r, g: color.g, b: color.b, a: color.a)
        let c = Vertex(x: x1, y: y1, u: u1, v: v1, r: color.r, g: color.g, b: color.b, a: color.a)
        let d = Vertex(x: x, y: y1, u: u0, v: v1, r: color.r, g: color.g, b: color.b, a: color.a)
        vertices += [a, b, c, a, c, d]
    }

    func rect(x: Float, y: Float, width: Float, height: Float, color: Color) {
        image(white, x: x, y: y, width: width, height: height, color: color)
    }

    /// A one-point outline just inside the rectangle.
    func frame(x: Float, y: Float, width: Float, height: Float, color: Color, thickness: Float = 1) {
        rect(x: x, y: y, width: width, height: thickness, color: color)
        rect(x: x, y: y + height - thickness, width: width, height: thickness, color: color)
        rect(x: x, y: y, width: thickness, height: height, color: color)
        rect(x: x + width - thickness, y: y, width: thickness, height: height, color: color)
    }

    /// Draws everything queued, over whatever is in the framebuffer.
    func flush(pixelWidth: Int, pixelHeight: Int) {
        guard !vertices.isEmpty else { return }
        glDisable(GL_DEPTH_TEST)
        glDisable(GL_CULL_FACE)
        glEnable(GL_BLEND)
        glBlendFuncSeparate(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA, GL_ONE, GL_ONE_MINUS_SRC_ALPHA)
        program.use()
        program.set("uProjection", Matrix4.orthographic(width: width, height: height))
        program.set("uTexture", Int32(0))
        glBindVertexArray(vao)
        glBindBuffer(GL_ARRAY_BUFFER, vbo)
        vertices.withUnsafeBytes { raw in
            glBufferData(GL_ARRAY_BUFFER, raw.count, raw.baseAddress, GL_STREAM_DRAW)
        }
        for batch in batches {
            if let c = batch.clip {
                glEnable(GL_SCISSOR_TEST)
                glScissor(
                    GLint(c.0 * scale), GLint(Float(pixelHeight) - (c.1 + c.3) * scale),
                    GLsizei(c.2 * scale), GLsizei(c.3 * scale)
                )
            } else {
                glDisable(GL_SCISSOR_TEST)
            }
            batch.texture.bind(unit: 0)
            glDrawArrays(GL_TRIANGLES, GLint(batch.start), GLsizei(batch.count))
        }
        glDisable(GL_SCISSOR_TEST)
        glDisable(GL_BLEND)
        glBindVertexArray(0)
    }
}
#endif
