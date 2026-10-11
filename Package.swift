// swift-tools-version:5.9
import PackageDescription

// `BLOCKHAVEN_MAC_APP=1` builds the Mac app that is handed out: no SDL, so
// it needs nothing from Homebrew and can be built for Intel as well as
// Apple silicon. SDL is the Windows front end and an opt-in extra here.
let macApp = Context.environment["BLOCKHAVEN_MAC_APP"] != nil

let package = Package(
    name: "Blockhaven",
    // RealityKit APIs this uses (faceCulling, LowLevelMesh) need macOS 15.
    // Spelled as a string because the CommandLineTools SwiftPM predates the
    // `.v15` enum case.
    platforms: [.macOS("15.0")],
    targets: [
        // SDL3 drives the window, input and OpenGL context of the front end
        // that runs everywhere — the only one on Windows, and an opt-in one
        // on the Mac (`BLOCKHAVEN_FRONTEND=sdl`).
        .systemLibrary(
            name: "CSDL3",
            path: "Sources/CSDL3",
            pkgConfig: "sdl3",
            providers: [.brew(["sdl3"])]
        ),
        // stb_image, vendored: the PNG decoder for the textures the SDL front
        // end loads. Public domain.
        .target(
            name: "CStbImage",
            path: "Sources/CStbImage",
            exclude: ["stb_image.h"],
            cSettings: [.unsafeFlags(["-Wno-everything"])]
        ),
        .executableTarget(
            name: "Blockhaven",
            dependencies: macApp ? ["CStbImage"] : ["CSDL3", "CStbImage"],
            path: "Sources/Blockhaven",
            // Compiled by `make shaders` and checked in, so a plain
            // `swift build` works without the Metal toolchain. SwiftPM
            // cannot build .metal sources itself under CommandLineTools.
            resources: [.copy("Resources/default.metallib")],
            linkerSettings: [
                // A game, not a console tool: no terminal window behind it
                // on Windows. `mainCRTStartup` keeps Swift's own `main` as
                // the entry point once the subsystem is no longer console.
                .unsafeFlags(
                    ["-Xlinker", "/SUBSYSTEM:WINDOWS", "-Xlinker", "/ENTRY:mainCRTStartup"],
                    .when(platforms: [.windows], configuration: .release)
                ),
            ]
        )
    ]
)
