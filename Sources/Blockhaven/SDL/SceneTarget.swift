#if canImport(CSDL3)
import Foundation

/// Where the 3D passes draw: a linear-light, multisampled, half-float
/// buffer of the window's size, resolved and handed to `PostChain`, which
/// grades it and encodes it to sRGB on its way into the window.
///
/// The passes light in linear light, as RealityKit does on the Mac. Asking
/// the driver for an sRGB window and `GL_FRAMEBUFFER_SRGB` is the textbook
/// way to encode that, and some Windows drivers quietly give a window
/// without it — the world then comes out dark and murky. A buffer of our
/// own and an encode of our own come out the same on every driver.
final class SceneTarget {
    private var multisampled: GLuint = 0
    private var colorSamples: GLuint = 0
    private var depthSamples: GLuint = 0
    private var resolved: GLuint = 0
    private var resolvedTexture: GLuint = 0
    private var resolvedDepth: GLuint = 0
    private var width = 0, height = 0
    private let post = PostChain()

    /// Binds the scene buffer, sized to the drawable, for the 3D passes.
    func begin(width: Int, height: Int) {
        if width != self.width || height != self.height { rebuild(width: width, height: height) }
        glBindFramebuffer(GL_FRAMEBUFFER, multisampled)
        glViewport(0, 0, GLsizei(width), GLsizei(height))
    }

    /// Resolves the samples — colour, and depth for the god rays' sky
    /// test — and runs the post chain into the window.
    func present(sun: PostChain.Sun?) {
        glBindFramebuffer(GL_READ_FRAMEBUFFER, multisampled)
        glBindFramebuffer(GL_DRAW_FRAMEBUFFER, resolved)
        glBlitFramebuffer(0, 0, GLint(width), GLint(height), 0, 0, GLint(width), GLint(height),
                          GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT, GLenum(GL_NEAREST))
        post.run(scene: resolvedTexture, depth: resolvedDepth, width: width, height: height, sun: sun)
    }

    private func rebuild(width: Int, height: Int) {
        release()
        self.width = width
        self.height = height
        let w = GLsizei(width), h = GLsizei(height)
        var samples: GLint = 0
        glGetIntegerv(GL_MAX_SAMPLES, &samples)
        let count = GLsizei(min(4, max(1, samples)))

        glGenRenderbuffers(1, &colorSamples)
        glBindRenderbuffer(GL_RENDERBUFFER, colorSamples)
        glRenderbufferStorageMultisample(GL_RENDERBUFFER, count, GL_RGBA16F, w, h)
        glGenRenderbuffers(1, &depthSamples)
        glBindRenderbuffer(GL_RENDERBUFFER, depthSamples)
        glRenderbufferStorageMultisample(GL_RENDERBUFFER, count, GL_DEPTH_COMPONENT24, w, h)
        glGenFramebuffers(1, &multisampled)
        glBindFramebuffer(GL_FRAMEBUFFER, multisampled)
        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, colorSamples)
        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, depthSamples)
        if glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE {
            SDLApp.fail("The graphics driver could not make the game's drawing buffer (\(width)×\(height)).")
        }

        resolvedTexture = Self.texture(width: w, height: h, internalFormat: GL_RGBA16F, format: GL_RGBA, type: GL_FLOAT,
                                       filter: GL_LINEAR)
        // The same format as the samples it is resolved from, which a depth
        // blit requires.
        resolvedDepth = Self.texture(width: w, height: h, internalFormat: GL_DEPTH_COMPONENT24,
                                     format: GL_DEPTH_COMPONENT, type: GL_UNSIGNED_INT, filter: GL_NEAREST)
        glGenFramebuffers(1, &resolved)
        glBindFramebuffer(GL_FRAMEBUFFER, resolved)
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, resolvedTexture, 0)
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_TEXTURE_2D, resolvedDepth, 0)
        if glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE {
            SDLApp.fail("The graphics driver could not make the game's drawing buffer (\(width)×\(height)).")
        }
        glBindFramebuffer(GL_FRAMEBUFFER, 0)
    }

    private static func texture(width: GLsizei, height: GLsizei, internalFormat: GLenum, format: GLenum,
                                type: GLenum, filter: GLint) -> GLuint {
        var texture: GLuint = 0
        glGenTextures(1, &texture)
        glBindTexture(GL_TEXTURE_2D, texture)
        glTexImage2D(GL_TEXTURE_2D, 0, GLint(internalFormat), width, height, 0, format, type, nil)
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, filter)
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, filter)
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE)
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE)
        return texture
    }

    private func release() {
        if multisampled != 0 { glDeleteFramebuffers(1, &multisampled); multisampled = 0 }
        if resolved != 0 { glDeleteFramebuffers(1, &resolved); resolved = 0 }
        if colorSamples != 0 { glDeleteRenderbuffers(1, &colorSamples); colorSamples = 0 }
        if depthSamples != 0 { glDeleteRenderbuffers(1, &depthSamples); depthSamples = 0 }
        if resolvedTexture != 0 { glDeleteTextures(1, &resolvedTexture); resolvedTexture = 0 }
        if resolvedDepth != 0 { glDeleteTextures(1, &resolvedDepth); resolvedDepth = 0 }
    }

    deinit { release() }
}
#endif
