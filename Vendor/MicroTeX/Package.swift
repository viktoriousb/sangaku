// swift-tools-version: 6.2
// MicroTeX (MIT), vendored from github.com/NanoMichael/MicroTeX, branch openmath, commit 086f4eb7.
// Our changes are listed in PATCHES.md. Only the C API in include/CMicroTeX.h is public.
import PackageDescription

let package = Package(
    name: "MicroTeX",
    platforms: [.macOS(.v26)],
    products: [.library(name: "CMicroTeX", targets: ["CMicroTeX"])],
    targets: [
        .target(
            name: "CMicroTeX",
            path: "Sources/CMicroTeX",
            sources: ["lib", "safe_parse.cpp"],
            publicHeadersPath: "include",
            cxxSettings: [
                .define("HAVE_CWRAPPER"),
                .define("GLYPH_RENDER_TYPE", to: "1"), // glyphs as paths only, from .clm2 fonts
                .headerSearchPath("lib"),
                .unsafeFlags(["-w"]), // upstream code; its warnings are not ours to fix
            ]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
