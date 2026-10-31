import Foundation

/// Shared normalization for IPP marker supplies and SNMP printer MIB values.
enum IPPSupplyNormalizer {
    /// Converts a raw level and optional capacity to 0...100.
    /// Negative values and values above 100 without a capacity are treated as
    /// the common "unknown" sentinels and dropped.
    static func normalizedPercent(level: Int?, capacity: Int?) -> Int? {
        guard let level, level >= 0 else { return nil }

        if let capacity, capacity > 0 {
            let percent = (Double(level) / Double(capacity)) * 100.0
            guard percent.isFinite else { return nil }
            return min(100, max(0, Int(percent.rounded())))
        }

        guard level <= 100 else { return nil }
        return level
    }

    /// Normalizes a marker color token such as `#000000`, `cyan`, or
    /// `lightCyan` into a short display name.
    static func colorName(fromToken raw: String?) -> String? {
        guard var token = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            return nil
        }
        if token.hasPrefix("#") {
            token = String(token.dropFirst())
            let upper = token.uppercased()
            if upper.count == 3 {
                let expanded = upper.map { "\($0)\($0)" }.joined()
                if let name = namedHexColors[expanded] { return name }
                return "#" + expanded
            }
            if upper.count == 6 {
                if let name = namedHexColors[upper] { return name }
                return "#" + upper
            }
            return raw
        }

        let key = normalizedToken(token)
        if key == "none" || key == "unknown" || key == "na" || key == "notapplicable" {
            return nil
        }
        if let name = namedColorTokens[key] {
            return name
        }
        // Some devices report values such as "CyanInk" or "Black Toner".
        if let name = colorName(inText: raw) {
            return name
        }
        return token
    }

    /// Finds a known color word in free text such as a marker description.
    static func colorName(inText text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        let key = normalizedToken(text)
        guard !key.isEmpty else { return nil }

        // Check multi-word colors before their base color.
        let ordered: [(String, String)] = [
            ("photoblack", "Photo Black"),
            ("matteblack", "Matte Black"),
            ("lightblack", "Light Black"),
            ("lightcyan", "Light Cyan"),
            ("lightmagenta", "Light Magenta"),
            ("darkgray", "Dark Gray"),
            ("darkgrey", "Dark Gray"),
            ("lightgray", "Light Gray"),
            ("lightgrey", "Light Gray"),
            ("black", "Black"),
            ("cyan", "Cyan"),
            ("magenta", "Magenta"),
            ("yellow", "Yellow"),
            ("white", "White"),
            ("gray", "Gray"),
            ("grey", "Gray"),
            ("red", "Red"),
            ("green", "Green"),
            ("blue", "Blue"),
            ("orange", "Orange"),
            ("violet", "Violet"),
            ("purple", "Purple"),
            ("silver", "Silver"),
            ("gold", "Gold"),
            ("clear", "Clear"),
            ("gloss", "Gloss")
        ]
        for (needle, name) in ordered where key.contains(needle) {
            return name
        }
        return nil
    }

    static func kind(typeTokens: [String], name: String, color: String?) -> SupplyKind {
        for token in typeTokens {
            if let code = Int(token.trimmingCharacters(in: .whitespaces)),
               let kind = kind(typeCode: code) {
                return kind
            }
            if let kind = kind(inToken: token) {
                return kind
            }
        }
        if let kind = kind(inToken: name) {
            return kind
        }
        return color == nil ? .other : .ink
    }

    static func kind(typeCode: Int?, name: String, color: String?) -> SupplyKind {
        if let typeCode, let kind = kind(typeCode: typeCode) {
            return kind
        }
        return kind(typeTokens: [], name: name, color: color)
    }

    static func kind(typeCode: Int) -> SupplyKind? {
        switch typeCode {
        case 3, 21:
            return .toner
        case 4, 8, 14:
            return .waste
        case 5, 6, 7, 12, 13:
            return .ink
        case 9:
            return .drum
        case 10, 11, 15, 16, 17, 18, 19, 20, 22:
            return .maintenance
        default:
            return nil
        }
    }

    static func kind(inToken raw: String) -> SupplyKind? {
        let key = normalizedToken(raw)
        guard !key.isEmpty else { return nil }
        if key.contains("waste") { return .waste }
        if key.contains("toner") { return .toner }
        if key.contains("ink") { return .ink }
        if key.contains("drum") || key.contains("opc") || key.contains("photoconductor") {
            return .drum
        }
        if key.contains("fuser")
            || key.contains("maintenance")
            || key.contains("cleaner")
            || key.contains("developer")
            || key.contains("transfer")
            || key.contains("ribbon") {
            return .maintenance
        }
        return nil
    }

    private static func normalizedToken(_ raw: String) -> String {
        raw.lowercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
    }

    private static let namedColorTokens: [String: String] = [
        "black": "Black",
        "cyan": "Cyan",
        "magenta": "Magenta",
        "yellow": "Yellow",
        "lightcyan": "Light Cyan",
        "lightmagenta": "Light Magenta",
        "photoblack": "Photo Black",
        "matteblack": "Matte Black",
        "lightblack": "Light Black",
        "gray": "Gray",
        "grey": "Gray",
        "darkgray": "Dark Gray",
        "darkgrey": "Dark Gray",
        "lightgray": "Light Gray",
        "lightgrey": "Light Gray",
        "red": "Red",
        "green": "Green",
        "blue": "Blue",
        "orange": "Orange",
        "violet": "Violet",
        "purple": "Purple",
        "white": "White",
        "gold": "Gold",
        "silver": "Silver",
        "clear": "Clear",
        "gloss": "Gloss"
    ]

    private static let namedHexColors: [String: String] = [
        "000000": "Black",
        "FFFFFF": "White",
        "00FFFF": "Cyan",
        "FF00FF": "Magenta",
        "FFFF00": "Yellow",
        "E0FFFF": "Light Cyan",
        "FF80FF": "Light Magenta",
        "808080": "Gray",
        "404040": "Dark Gray",
        "C0C0C0": "Silver",
        "FF0000": "Red",
        "00FF00": "Green",
        "0000FF": "Blue",
        "FFA500": "Orange",
        "800080": "Purple"
    ]
}

/// Builds deterministic, stable supply identifiers.
enum SupplyFactory {
    static func make(
        prefix: String,
        name: String,
        kind: SupplyKind,
        colorName: String?,
        levelPercent: Int?,
        index: Int,
        usedIDs: inout Set<String>
    ) -> SupplyLevel {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = trimmed.isEmpty ? "Supply \(index + 1)" : trimmed

        let slug = slug(displayName)
        let root = slug.isEmpty ? "\(prefix)-supply-\(index + 1)" : "\(prefix)-\(slug)"
        var identifier = root
        var suffix = 2
        while usedIDs.contains(identifier) {
            identifier = "\(root)-\(suffix)"
            suffix += 1
        }
        usedIDs.insert(identifier)

        return SupplyLevel(
            id: identifier,
            name: displayName,
            kind: kind,
            colorName: colorName,
            levelPercent: levelPercent,
            isEstimated: false
        )
    }

    private static func slug(_ text: String) -> String {
        text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
    }
}
