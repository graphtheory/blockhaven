#if canImport(CSDL3)
import Foundation
import CSDL3

// OpenGL 3.3 core, loaded by hand.
//
// Windows' opengl32.dll exports nothing past OpenGL 1.1, so every modern
// entry point has to be asked for at run time, through the context SDL
// made. Doing the asking here, for exactly the functions this game calls,
// keeps the build free of a generated loader and of any OpenGL headers —
// the Mac has its own, Windows has none worth using, and both answer
// `SDL_GL_GetProcAddress` the same way.

typealias GLenum = UInt32
typealias GLuint = UInt32
typealias GLint = Int32
typealias GLsizei = Int32
typealias GLfloat = Float
typealias GLboolean = UInt8
typealias GLbitfield = UInt32
typealias GLsizeiptr = Int
typealias GLintptr = Int

let GL_FALSE: GLboolean = 0
let GL_TRUE: GLboolean = 1

let GL_DEPTH_BUFFER_BIT: GLbitfield = 0x0000_0100
let GL_COLOR_BUFFER_BIT: GLbitfield = 0x0000_4000

let GL_TRIANGLES: GLenum = 0x0004
let GL_LINES: GLenum = 0x0001

let GL_NEVER: GLenum = 0x0200
let GL_LESS: GLenum = 0x0201
let GL_LEQUAL: GLenum = 0x0203
let GL_ALWAYS: GLenum = 0x0207

let GL_SRC_ALPHA: GLenum = 0x0302
let GL_ONE_MINUS_SRC_ALPHA: GLenum = 0x0303
let GL_ONE: GLenum = 1
let GL_ZERO: GLenum = 0

let GL_FRONT: GLenum = 0x0404
let GL_BACK: GLenum = 0x0405
let GL_CW: GLenum = 0x0900
let GL_CCW: GLenum = 0x0901

let GL_CULL_FACE: GLenum = 0x0B44
let GL_DEPTH_TEST: GLenum = 0x0B71
let GL_BLEND: GLenum = 0x0BE2
let GL_SCISSOR_TEST: GLenum = 0x0C11
let GL_POLYGON_OFFSET_FILL: GLenum = 0x8037
let GL_MULTISAMPLE: GLenum = 0x809D
let GL_FRAMEBUFFER_SRGB: GLenum = 0x8DB9

let GL_UNPACK_ALIGNMENT: GLenum = 0x0CF5
let GL_PACK_ALIGNMENT: GLenum = 0x0D05

let GL_TEXTURE_2D: GLenum = 0x0DE1
let GL_UNSIGNED_BYTE: GLenum = 0x1401
let GL_UNSIGNED_SHORT: GLenum = 0x1403
let GL_INT: GLenum = 0x1404
let GL_UNSIGNED_INT: GLenum = 0x1405
let GL_FLOAT: GLenum = 0x1406

let GL_RED: GLenum = 0x1903
let GL_RGB: GLenum = 0x1907
let GL_RGBA: GLenum = 0x1908
let GL_RGBA8: GLenum = 0x8058
let GL_RGBA16F: GLenum = 0x881A
let GL_MAX_SAMPLES: GLenum = 0x8D57
let GL_SRGB8_ALPHA8: GLenum = 0x8C43
let GL_DEPTH_COMPONENT24: GLenum = 0x81A6
let GL_DEPTH_COMPONENT: GLenum = 0x1902
let GL_DEPTH24_STENCIL8: GLenum = 0x88F0

let GL_VENDOR: GLenum = 0x1F00
let GL_RENDERER: GLenum = 0x1F01
let GL_VERSION: GLenum = 0x1F02

let GL_NEAREST: GLint = 0x2600
let GL_LINEAR: GLint = 0x2601
let GL_LINEAR_MIPMAP_LINEAR: GLint = 0x2703
let GL_NEAREST_MIPMAP_LINEAR: GLint = 0x2702
let GL_TEXTURE_MAG_FILTER: GLenum = 0x2800
let GL_TEXTURE_MIN_FILTER: GLenum = 0x2801
let GL_TEXTURE_WRAP_S: GLenum = 0x2802
let GL_TEXTURE_WRAP_T: GLenum = 0x2803
let GL_TEXTURE_MAX_LEVEL: GLenum = 0x813D
let GL_REPEAT: GLint = 0x2901
let GL_CLAMP_TO_EDGE: GLint = 0x812F

let GL_TEXTURE0: GLenum = 0x84C0

let GL_ARRAY_BUFFER: GLenum = 0x8892
let GL_ELEMENT_ARRAY_BUFFER: GLenum = 0x8893
let GL_STREAM_DRAW: GLenum = 0x88E0
let GL_STATIC_DRAW: GLenum = 0x88E4
let GL_DYNAMIC_DRAW: GLenum = 0x88E8

let GL_FRAGMENT_SHADER: GLenum = 0x8B30
let GL_VERTEX_SHADER: GLenum = 0x8B31
let GL_COMPILE_STATUS: GLenum = 0x8B81
let GL_LINK_STATUS: GLenum = 0x8B82
let GL_INFO_LOG_LENGTH: GLenum = 0x8B84

let GL_FRAMEBUFFER: GLenum = 0x8D40
let GL_READ_FRAMEBUFFER: GLenum = 0x8CA8
let GL_DRAW_FRAMEBUFFER: GLenum = 0x8CA9
let GL_RENDERBUFFER: GLenum = 0x8D41
let GL_COLOR_ATTACHMENT0: GLenum = 0x8CE0
let GL_DEPTH_ATTACHMENT: GLenum = 0x8D00
let GL_DEPTH_STENCIL_ATTACHMENT: GLenum = 0x821A
let GL_FRAMEBUFFER_COMPLETE: GLenum = 0x8CD5

private func loadGL<T>(_ name: String) -> T {
    guard let pointer = SDL_GL_GetProcAddress(name) else {
        SDLApp.fail("The graphics driver is missing the OpenGL function \(name), which the game needs (OpenGL 3.3). Updating the graphics driver usually fixes this.")
    }
    return unsafeBitCast(pointer, to: T.self)
}

// Every entry point as a global, so call sites read as plain OpenGL. Filled
// by `loadOpenGL()`, which runs once, straight after the context is made.
nonisolated(unsafe) var glViewport: (@convention(c) (GLint, GLint, GLsizei, GLsizei) -> Void)!
nonisolated(unsafe) var glScissor: (@convention(c) (GLint, GLint, GLsizei, GLsizei) -> Void)!
nonisolated(unsafe) var glClearColor: (@convention(c) (GLfloat, GLfloat, GLfloat, GLfloat) -> Void)!
nonisolated(unsafe) var glClear: (@convention(c) (GLbitfield) -> Void)!
nonisolated(unsafe) var glEnable: (@convention(c) (GLenum) -> Void)!
nonisolated(unsafe) var glDisable: (@convention(c) (GLenum) -> Void)!
nonisolated(unsafe) var glBlendFunc: (@convention(c) (GLenum, GLenum) -> Void)!
nonisolated(unsafe) var glBlendFuncSeparate: (@convention(c) (GLenum, GLenum, GLenum, GLenum) -> Void)!
nonisolated(unsafe) var glDepthFunc: (@convention(c) (GLenum) -> Void)!
nonisolated(unsafe) var glDepthMask: (@convention(c) (GLboolean) -> Void)!
nonisolated(unsafe) var glColorMask: (@convention(c) (GLboolean, GLboolean, GLboolean, GLboolean) -> Void)!
nonisolated(unsafe) var glCullFace: (@convention(c) (GLenum) -> Void)!
nonisolated(unsafe) var glFrontFace: (@convention(c) (GLenum) -> Void)!
nonisolated(unsafe) var glPolygonOffset: (@convention(c) (GLfloat, GLfloat) -> Void)!
nonisolated(unsafe) var glPixelStorei: (@convention(c) (GLenum, GLint) -> Void)!
nonisolated(unsafe) var glReadPixels: (@convention(c) (GLint, GLint, GLsizei, GLsizei, GLenum, GLenum, UnsafeMutableRawPointer?) -> Void)!
nonisolated(unsafe) var glGetError: (@convention(c) () -> GLenum)!
nonisolated(unsafe) var glGetString: (@convention(c) (GLenum) -> UnsafePointer<UInt8>?)!

nonisolated(unsafe) var glGenVertexArrays: (@convention(c) (GLsizei, UnsafeMutablePointer<GLuint>?) -> Void)!
nonisolated(unsafe) var glDeleteVertexArrays: (@convention(c) (GLsizei, UnsafePointer<GLuint>?) -> Void)!
nonisolated(unsafe) var glBindVertexArray: (@convention(c) (GLuint) -> Void)!
nonisolated(unsafe) var glGenBuffers: (@convention(c) (GLsizei, UnsafeMutablePointer<GLuint>?) -> Void)!
nonisolated(unsafe) var glDeleteBuffers: (@convention(c) (GLsizei, UnsafePointer<GLuint>?) -> Void)!
nonisolated(unsafe) var glBindBuffer: (@convention(c) (GLenum, GLuint) -> Void)!
nonisolated(unsafe) var glBufferData: (@convention(c) (GLenum, GLsizeiptr, UnsafeRawPointer?, GLenum) -> Void)!
nonisolated(unsafe) var glBufferSubData: (@convention(c) (GLenum, GLintptr, GLsizeiptr, UnsafeRawPointer?) -> Void)!
nonisolated(unsafe) var glVertexAttribPointer: (@convention(c) (GLuint, GLint, GLenum, GLboolean, GLsizei, UnsafeRawPointer?) -> Void)!
nonisolated(unsafe) var glEnableVertexAttribArray: (@convention(c) (GLuint) -> Void)!
nonisolated(unsafe) var glDrawElements: (@convention(c) (GLenum, GLsizei, GLenum, UnsafeRawPointer?) -> Void)!
nonisolated(unsafe) var glDrawArrays: (@convention(c) (GLenum, GLint, GLsizei) -> Void)!

nonisolated(unsafe) var glCreateShader: (@convention(c) (GLenum) -> GLuint)!
nonisolated(unsafe) var glDeleteShader: (@convention(c) (GLuint) -> Void)!
nonisolated(unsafe) var glShaderSource: (@convention(c) (GLuint, GLsizei, UnsafePointer<UnsafePointer<CChar>?>?, UnsafePointer<GLint>?) -> Void)!
nonisolated(unsafe) var glCompileShader: (@convention(c) (GLuint) -> Void)!
nonisolated(unsafe) var glGetShaderiv: (@convention(c) (GLuint, GLenum, UnsafeMutablePointer<GLint>?) -> Void)!
nonisolated(unsafe) var glGetShaderInfoLog: (@convention(c) (GLuint, GLsizei, UnsafeMutablePointer<GLsizei>?, UnsafeMutablePointer<CChar>?) -> Void)!
nonisolated(unsafe) var glCreateProgram: (@convention(c) () -> GLuint)!
nonisolated(unsafe) var glDeleteProgram: (@convention(c) (GLuint) -> Void)!
nonisolated(unsafe) var glAttachShader: (@convention(c) (GLuint, GLuint) -> Void)!
nonisolated(unsafe) var glBindAttribLocation: (@convention(c) (GLuint, GLuint, UnsafePointer<CChar>?) -> Void)!
nonisolated(unsafe) var glLinkProgram: (@convention(c) (GLuint) -> Void)!
nonisolated(unsafe) var glGetProgramiv: (@convention(c) (GLuint, GLenum, UnsafeMutablePointer<GLint>?) -> Void)!
nonisolated(unsafe) var glGetProgramInfoLog: (@convention(c) (GLuint, GLsizei, UnsafeMutablePointer<GLsizei>?, UnsafeMutablePointer<CChar>?) -> Void)!
nonisolated(unsafe) var glUseProgram: (@convention(c) (GLuint) -> Void)!
nonisolated(unsafe) var glGetUniformLocation: (@convention(c) (GLuint, UnsafePointer<CChar>?) -> GLint)!
nonisolated(unsafe) var glUniform1i: (@convention(c) (GLint, GLint) -> Void)!
nonisolated(unsafe) var glUniform1f: (@convention(c) (GLint, GLfloat) -> Void)!
nonisolated(unsafe) var glUniform2f: (@convention(c) (GLint, GLfloat, GLfloat) -> Void)!
nonisolated(unsafe) var glUniform3f: (@convention(c) (GLint, GLfloat, GLfloat, GLfloat) -> Void)!
nonisolated(unsafe) var glUniform4f: (@convention(c) (GLint, GLfloat, GLfloat, GLfloat, GLfloat) -> Void)!
nonisolated(unsafe) var glUniform4fv: (@convention(c) (GLint, GLsizei, UnsafePointer<GLfloat>?) -> Void)!
nonisolated(unsafe) var glUniformMatrix4fv: (@convention(c) (GLint, GLsizei, GLboolean, UnsafePointer<GLfloat>?) -> Void)!

nonisolated(unsafe) var glGenTextures: (@convention(c) (GLsizei, UnsafeMutablePointer<GLuint>?) -> Void)!
nonisolated(unsafe) var glDeleteTextures: (@convention(c) (GLsizei, UnsafePointer<GLuint>?) -> Void)!
nonisolated(unsafe) var glBindTexture: (@convention(c) (GLenum, GLuint) -> Void)!
nonisolated(unsafe) var glActiveTexture: (@convention(c) (GLenum) -> Void)!
nonisolated(unsafe) var glTexImage2D: (@convention(c) (GLenum, GLint, GLint, GLsizei, GLsizei, GLint, GLenum, GLenum, UnsafeRawPointer?) -> Void)!
nonisolated(unsafe) var glTexSubImage2D: (@convention(c) (GLenum, GLint, GLint, GLint, GLsizei, GLsizei, GLenum, GLenum, UnsafeRawPointer?) -> Void)!
nonisolated(unsafe) var glTexParameteri: (@convention(c) (GLenum, GLenum, GLint) -> Void)!
nonisolated(unsafe) var glGenerateMipmap: (@convention(c) (GLenum) -> Void)!

nonisolated(unsafe) var glGenFramebuffers: (@convention(c) (GLsizei, UnsafeMutablePointer<GLuint>?) -> Void)!
nonisolated(unsafe) var glDeleteFramebuffers: (@convention(c) (GLsizei, UnsafePointer<GLuint>?) -> Void)!
nonisolated(unsafe) var glBindFramebuffer: (@convention(c) (GLenum, GLuint) -> Void)!
nonisolated(unsafe) var glFramebufferTexture2D: (@convention(c) (GLenum, GLenum, GLenum, GLuint, GLint) -> Void)!
nonisolated(unsafe) var glCheckFramebufferStatus: (@convention(c) (GLenum) -> GLenum)!
nonisolated(unsafe) var glGenRenderbuffers: (@convention(c) (GLsizei, UnsafeMutablePointer<GLuint>?) -> Void)!
nonisolated(unsafe) var glDeleteRenderbuffers: (@convention(c) (GLsizei, UnsafePointer<GLuint>?) -> Void)!
nonisolated(unsafe) var glBindRenderbuffer: (@convention(c) (GLenum, GLuint) -> Void)!
nonisolated(unsafe) var glRenderbufferStorage: (@convention(c) (GLenum, GLenum, GLsizei, GLsizei) -> Void)!
nonisolated(unsafe) var glFramebufferRenderbuffer: (@convention(c) (GLenum, GLenum, GLenum, GLuint) -> Void)!
nonisolated(unsafe) var glRenderbufferStorageMultisample: (@convention(c) (GLenum, GLsizei, GLenum, GLsizei, GLsizei) -> Void)!
nonisolated(unsafe) var glBlitFramebuffer: (@convention(c) (GLint, GLint, GLint, GLint, GLint, GLint, GLint, GLint, GLbitfield, GLenum) -> Void)!
nonisolated(unsafe) var glGetIntegerv: (@convention(c) (GLenum, UnsafeMutablePointer<GLint>?) -> Void)!

/// Resolves every entry point above. Call once, with the context current.
func loadOpenGL() {
    glViewport = loadGL("glViewport")
    glScissor = loadGL("glScissor")
    glClearColor = loadGL("glClearColor")
    glClear = loadGL("glClear")
    glEnable = loadGL("glEnable")
    glDisable = loadGL("glDisable")
    glBlendFunc = loadGL("glBlendFunc")
    glBlendFuncSeparate = loadGL("glBlendFuncSeparate")
    glDepthFunc = loadGL("glDepthFunc")
    glDepthMask = loadGL("glDepthMask")
    glColorMask = loadGL("glColorMask")
    glCullFace = loadGL("glCullFace")
    glFrontFace = loadGL("glFrontFace")
    glPolygonOffset = loadGL("glPolygonOffset")
    glPixelStorei = loadGL("glPixelStorei")
    glReadPixels = loadGL("glReadPixels")
    glGetError = loadGL("glGetError")
    glGetString = loadGL("glGetString")

    glGenVertexArrays = loadGL("glGenVertexArrays")
    glDeleteVertexArrays = loadGL("glDeleteVertexArrays")
    glBindVertexArray = loadGL("glBindVertexArray")
    glGenBuffers = loadGL("glGenBuffers")
    glDeleteBuffers = loadGL("glDeleteBuffers")
    glBindBuffer = loadGL("glBindBuffer")
    glBufferData = loadGL("glBufferData")
    glBufferSubData = loadGL("glBufferSubData")
    glVertexAttribPointer = loadGL("glVertexAttribPointer")
    glEnableVertexAttribArray = loadGL("glEnableVertexAttribArray")
    glDrawElements = loadGL("glDrawElements")
    glDrawArrays = loadGL("glDrawArrays")

    glCreateShader = loadGL("glCreateShader")
    glDeleteShader = loadGL("glDeleteShader")
    glShaderSource = loadGL("glShaderSource")
    glCompileShader = loadGL("glCompileShader")
    glGetShaderiv = loadGL("glGetShaderiv")
    glGetShaderInfoLog = loadGL("glGetShaderInfoLog")
    glCreateProgram = loadGL("glCreateProgram")
    glDeleteProgram = loadGL("glDeleteProgram")
    glAttachShader = loadGL("glAttachShader")
    glBindAttribLocation = loadGL("glBindAttribLocation")
    glLinkProgram = loadGL("glLinkProgram")
    glGetProgramiv = loadGL("glGetProgramiv")
    glGetProgramInfoLog = loadGL("glGetProgramInfoLog")
    glUseProgram = loadGL("glUseProgram")
    glGetUniformLocation = loadGL("glGetUniformLocation")
    glUniform1i = loadGL("glUniform1i")
    glUniform1f = loadGL("glUniform1f")
    glUniform2f = loadGL("glUniform2f")
    glUniform3f = loadGL("glUniform3f")
    glUniform4f = loadGL("glUniform4f")
    glUniform4fv = loadGL("glUniform4fv")
    glUniformMatrix4fv = loadGL("glUniformMatrix4fv")

    glGenTextures = loadGL("glGenTextures")
    glDeleteTextures = loadGL("glDeleteTextures")
    glBindTexture = loadGL("glBindTexture")
    glActiveTexture = loadGL("glActiveTexture")
    glTexImage2D = loadGL("glTexImage2D")
    glTexSubImage2D = loadGL("glTexSubImage2D")
    glTexParameteri = loadGL("glTexParameteri")
    glGenerateMipmap = loadGL("glGenerateMipmap")

    glGenFramebuffers = loadGL("glGenFramebuffers")
    glDeleteFramebuffers = loadGL("glDeleteFramebuffers")
    glBindFramebuffer = loadGL("glBindFramebuffer")
    glFramebufferTexture2D = loadGL("glFramebufferTexture2D")
    glCheckFramebufferStatus = loadGL("glCheckFramebufferStatus")
    glGenRenderbuffers = loadGL("glGenRenderbuffers")
    glDeleteRenderbuffers = loadGL("glDeleteRenderbuffers")
    glBindRenderbuffer = loadGL("glBindRenderbuffer")
    glRenderbufferStorage = loadGL("glRenderbufferStorage")
    glFramebufferRenderbuffer = loadGL("glFramebufferRenderbuffer")
    glRenderbufferStorageMultisample = loadGL("glRenderbufferStorageMultisample")
    glBlitFramebuffer = loadGL("glBlitFramebuffer")
    glGetIntegerv = loadGL("glGetIntegerv")
}

/// A linked shader program and the uniform locations it was asked for.
final class GLProgram {
    let id: GLuint
    private var locations: [String: GLint] = [:]

    /// Compiles and links, or stops the game with the driver's log: a
    /// shader that does not build is not something to limp on from.
    /// `attributes` binds vertex attribute names to slots before linking,
    /// so every mesh layout can say which slot is which.
    init(name: String, vertex: String, fragment: String, attributes: [String] = []) {
        func compile(_ type: GLenum, _ source: String) -> GLuint {
            let shader = glCreateShader(type)
            source.withCString { text in
                var pointer: UnsafePointer<CChar>? = text
                glShaderSource(shader, 1, &pointer, nil)
            }
            glCompileShader(shader)
            var ok: GLint = 0
            glGetShaderiv(shader, GL_COMPILE_STATUS, &ok)
            if ok == 0 {
                SDLApp.fail("""
                    The graphics driver could not build the game's \(name) shader. \
                    Updating the graphics driver usually fixes this.

                    \(GLProgram.shaderLog(shader))
                    """)
            }
            return shader
        }
        let vs = compile(GL_VERTEX_SHADER, vertex)
        let fs = compile(GL_FRAGMENT_SHADER, fragment)
        id = glCreateProgram()
        glAttachShader(id, vs)
        glAttachShader(id, fs)
        for (index, attribute) in attributes.enumerated() {
            glBindAttribLocation(id, GLuint(index), attribute)
        }
        glLinkProgram(id)
        var ok: GLint = 0
        glGetProgramiv(id, GL_LINK_STATUS, &ok)
        if ok == 0 {
            var length: GLint = 0
            glGetProgramiv(id, GL_INFO_LOG_LENGTH, &length)
            var log = [CChar](repeating: 0, count: Int(max(1, length)))
            glGetProgramInfoLog(id, length, nil, &log)
            SDLApp.fail("The graphics driver could not link the game's \(name) shader. Updating the graphics driver usually fixes this.\n\n\(String(cString: log))")
        }
        glDeleteShader(vs)
        glDeleteShader(fs)
    }

    private static func shaderLog(_ shader: GLuint) -> String {
        var length: GLint = 0
        glGetShaderiv(shader, GL_INFO_LOG_LENGTH, &length)
        var log = [CChar](repeating: 0, count: Int(max(1, length)))
        glGetShaderInfoLog(shader, length, nil, &log)
        return String(cString: log)
    }

    func use() { glUseProgram(id) }

    func location(_ name: String) -> GLint {
        if let known = locations[name] { return known }
        let found = glGetUniformLocation(id, name)
        locations[name] = found
        return found
    }

    func set(_ name: String, _ value: Float) { glUniform1f(location(name), value) }
    func set(_ name: String, _ value: Int32) { glUniform1i(location(name), value) }
    func set(_ name: String, _ value: SIMD2<Float>) { glUniform2f(location(name), value.x, value.y) }
    func set(_ name: String, _ value: SIMD3<Float>) { glUniform3f(location(name), value.x, value.y, value.z) }
    func set(_ name: String, _ value: SIMD4<Float>) { glUniform4f(location(name), value.x, value.y, value.z, value.w) }
    func set(_ name: String, _ value: Matrix4) {
        withUnsafeBytes(of: value.columns) { raw in
            glUniformMatrix4fv(location(name), 1, GL_FALSE, raw.bindMemory(to: Float.self).baseAddress)
        }
    }
}

/// An RGBA8 texture.
final class GLTexture {
    let id: GLuint
    let width: Int
    let height: Int

    /// `pixels` is tightly packed RGBA, top row first — the order an image
    /// file and every CPU-side drawing here use. GL's first row is `t = 0`,
    /// so a shader samples the top of the image at `t = 0`.
    /// `srgb` marks the pixels as sRGB-encoded colour, so sampling returns
    /// linear light — what the 3D passes light in. The 2D overlay samples
    /// its textures raw and draws them as they are.
    init(width: Int, height: Int, pixels: UnsafeRawPointer?, nearest: Bool = true, mipmaps: Bool = false, repeats: Bool = false, srgb: Bool = false) {
        self.width = width
        self.height = height
        var name: GLuint = 0
        glGenTextures(1, &name)
        id = name
        glBindTexture(GL_TEXTURE_2D, id)
        glPixelStorei(GL_UNPACK_ALIGNMENT, 1)
        glTexImage2D(GL_TEXTURE_2D, 0, GLint(srgb ? GL_SRGB8_ALPHA8 : GL_RGBA8), GLsizei(width), GLsizei(height), 0, GL_RGBA, GL_UNSIGNED_BYTE, pixels)
        let wrap = repeats ? GL_REPEAT : GL_CLAMP_TO_EDGE
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, wrap)
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, wrap)
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, nearest ? GL_NEAREST : GL_LINEAR)
        if mipmaps {
            glGenerateMipmap(GL_TEXTURE_2D)
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, nearest ? GL_NEAREST_MIPMAP_LINEAR : GL_LINEAR_MIPMAP_LINEAR)
        } else {
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, nearest ? GL_NEAREST : GL_LINEAR)
        }
    }

    convenience init(image: RGBAImage, nearest: Bool = true, mipmaps: Bool = false, repeats: Bool = false, srgb: Bool = false) {
        self.init(width: image.width, height: image.height, pixels: nil, nearest: nearest, mipmaps: false, repeats: repeats, srgb: srgb)
        replace(with: image)
        if mipmaps {
            glBindTexture(GL_TEXTURE_2D, id)
            glGenerateMipmap(GL_TEXTURE_2D)
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, nearest ? GL_NEAREST_MIPMAP_LINEAR : GL_LINEAR_MIPMAP_LINEAR)
        }
    }

    func replace(with image: RGBAImage) {
        precondition(image.width == width && image.height == height)
        glBindTexture(GL_TEXTURE_2D, id)
        glPixelStorei(GL_UNPACK_ALIGNMENT, 1)
        image.pixels.withUnsafeBytes { raw in
            glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, GLsizei(width), GLsizei(height), GL_RGBA, GL_UNSIGNED_BYTE, raw.baseAddress)
        }
    }

    func bind(unit: Int = 0) {
        glActiveTexture(GL_TEXTURE0 + GLenum(unit))
        glBindTexture(GL_TEXTURE_2D, id)
    }

    deinit {
        var name = id
        glDeleteTextures(1, &name)
    }
}
#endif
