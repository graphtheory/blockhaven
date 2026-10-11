import Foundation

extension Bundle {
    /// Where `default.metallib` lives. A packaged `.app` carries it in its
    /// own Resources, because code signing refuses SwiftPM's resource bundle
    /// at the root of an app, which is the only place the generated
    /// `Bundle.module` looks outside the build folder. A plain `swift build`
    /// keeps using `Bundle.module`.
    static let shaders: Bundle = {
        if Bundle.main.url(forResource: "default", withExtension: "metallib") != nil {
            return .main
        }
        return .module
    }()
}
