import CoreGraphics
import Foundation

/// Standard page sizes in PostScript points (1/72 inch), used when a PPD does
/// not carry a `*PaperDimension` for a page-size keyword. CUPS and driver PPDs
/// use many keyword spellings for the same sheet (`A4`, `na-letter`,
/// `iso-a4`, `oe_photo-4x6`), so keywords are normalized before lookup.
public enum PaperSizeCatalog {
    /// Width × height in points for the long edge × short edge, portrait.
    private static let portraitSizes: [String: CGSize] = [
        "a3": CGSize(width: 841.89, height: 1190.55),
        "a4": CGSize(width: 595.28, height: 841.89),
        "a5": CGSize(width: 419.53, height: 595.28),
        "a6": CGSize(width: 297.64, height: 419.53),
        "b4": CGSize(width: 708.66, height: 1000.63),
        "b5": CGSize(width: 498.90, height: 708.66),
        "letter": CGSize(width: 612, height: 792),
        "legal": CGSize(width: 612, height: 1008),
        "executive": CGSize(width: 522, height: 756),
        "tabloid": CGSize(width: 792, height: 1224),
        "11x17": CGSize(width: 792, height: 1224),
        "ledger": CGSize(width: 1224, height: 792),
        "env10": CGSize(width: 297, height: 684),
        "envelope10": CGSize(width: 297, height: 684),
        "envdl": CGSize(width: 312, height: 624),
        "envc5": CGSize(width: 459, height: 649),
        "envmonarch": CGSize(width: 279, height: 540),
        "4x6": CGSize(width: 288, height: 432),
        "5x7": CGSize(width: 360, height: 504),
        "8x10": CGSize(width: 576, height: 720),
        "10x14": CGSize(width: 720, height: 1008),
        "11x14": CGSize(width: 792, height: 1008),
        "12x18": CGSize(width: 864, height: 1296),
        "superb": CGSize(width: 936, height: 1296)
    ]

    /// Normalizes a PPD page-size keyword to a catalog key: lowercase, strip
    /// common vendor prefixes (`na-`, `iso-`, `oe_`, `om_`, `es_`, `gov-`,
    /// `photo-`, `c2s-`) and suffixes (`.borderless`, `.fullbleed`, …).
    public static func normalize(_ keyword: String) -> String {
        var key = keyword
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if key.count >= 2, key.hasPrefix("\""), key.hasSuffix("\"") {
            key = String(key.dropFirst().dropLast())
        }
        let prefixes = ["na-", "iso-", "oe_", "om_", "es_", "gov-", "photo-", "c2s-", "roc-", "jis-"]
        for prefix in prefixes where key.hasPrefix(prefix) {
            key = String(key.dropFirst(prefix.count))
        }
        if let dot = key.firstIndex(of: ".") {
            key = String(key[..<dot])
        }
        return key
    }

    /// The size for a page-size keyword, or nil when unknown. Sizes are
    /// returned in the sheet's own orientation (Ledger is wider than tall).
    public static func size(forKeyword keyword: String) -> CGSize? {
        portraitSizes[normalize(keyword)]
    }

    /// True when the keyword explicitly asks for a landscape sheet.
    public static func isLandscapeKeyword(_ keyword: String) -> Bool {
        keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().contains("landscape")
    }
}
