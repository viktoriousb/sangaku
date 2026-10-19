import AppKit
import Foundation

/// The fonts math depends on, and whether they are present.
nonisolated enum FontRegistry {
    static let textFamily = "STIX Two Text"
    static let mathFamily = "STIX Two Math"

    /// Tier 1 needs both STIX Two families; macOS ships them in /System/Library/Fonts/Supplemental.
    static let typographicFontsAvailable: Bool = {
        let families = Set(NSFontManager.shared.availableFontFamilies)
        return families.contains(textFamily) && families.contains(mathFamily)
    }()

    /// The `.clm2` math font for MicroTeX. Synchronized groups flatten resources, so look up by name only.
    static func microTeXFontData(in bundle: Bundle = .main) -> Data? {
        guard let url = bundle.url(forResource: "XITSMath-Regular", withExtension: "clm2") else { return nil }
        return try? Data(contentsOf: url)
    }
}
