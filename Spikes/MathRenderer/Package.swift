// swift-tools-version: 6.2
// Throwaway spike comparing SwiftMath and KaTeX for sangaku's MathText. Never linked into the app.
import PackageDescription

let package = Package(
    name: "RendererSpike",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/mgriebling/SwiftMath", exact: "1.7.3"),
    ],
    targets: [
        // MicroTeX (MIT, NanoMichael/MicroTeX, openmath branch, 2024-08-06), vendored for the spike.
        .target(
            name: "CMicroTeX",
            path: "Sources/CMicroTeX",
            exclude: ["LICENSE"],
            sources: ["lib", "spike_safe.cpp"],
            publicHeadersPath: "include",
            cxxSettings: [
                .define("HAVE_CWRAPPER"),
                .define("GLYPH_RENDER_TYPE", to: "1"),
                .headerSearchPath("lib"),
                // The Command Line Tools here carry a stale usr/include/c++/v1 that shadows the SDK's libc++.
                .unsafeFlags(["-w", "-nostdinc++", "-isystem",
                              "/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk/usr/include/c++/v1"]),
            ]
        ),
        .executableTarget(
            name: "RendererSpike",
            dependencies: [.product(name: "SwiftMath", package: "SwiftMath"), "CMicroTeX"],
            resources: [.copy("Resources/katex"), .copy("Resources/microtex"), .copy("Resources/mathjax")],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
