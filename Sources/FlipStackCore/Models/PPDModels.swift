import Foundation

public enum PPDOptionGroup: String, Codable, Sendable, CaseIterable {
    case color
    case paperSize
    case mediaType
    case quality
    case duplex
    case other

    public var title: String {
        switch self {
        case .color: return L("Color")
        case .paperSize: return L("Paper")
        case .mediaType: return L("Media")
        case .quality: return L("Quality")
        case .duplex: return L("Duplex")
        case .other: return L("Other")
        }
    }

    /// Preferred PPD UI keywords, in lookup order.
    public var preferredKeywords: [String] {
        switch self {
        case .color:
            return ["ColorModel", "ColorMode", "cupsColorModel"]
        case .paperSize:
            return ["PageSize", "MediaSize", "PageRegion"]
        case .mediaType:
            return ["MediaType", "InputSlot"]
        case .quality:
            return ["Resolution", "PrintQuality", "RasterQuality", "cupsPrintQuality"]
        case .duplex:
            return ["Duplex"]
        case .other:
            return []
        }
    }
}

public struct PPDChoice: Identifiable, Hashable, Codable, Sendable {
    public var keyword: String
    public var label: String
    /// The raw PPD value (usually a PostScript dictionary or quoted string).
    public var value: String

    public var id: String { keyword }

    public init(keyword: String, label: String, value: String = "") {
        self.keyword = keyword
        self.label = label
        self.value = value
    }

    public var displayLabel: String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? keyword : trimmed
    }
}

public struct PPDOption: Identifiable, Hashable, Codable, Sendable {
    public var keyword: String
    public var label: String
    public var group: PPDOptionGroup
    public var choices: [PPDChoice]
    public var defaultChoice: String?
    public var isPseudoOption: Bool

    public var id: String { keyword }

    public init(
        keyword: String,
        label: String,
        group: PPDOptionGroup = .other,
        choices: [PPDChoice],
        defaultChoice: String? = nil,
        isPseudoOption: Bool = false
    ) {
        self.keyword = keyword
        self.label = label
        self.group = group
        self.choices = choices
        self.defaultChoice = defaultChoice
        self.isPseudoOption = isPseudoOption
    }

    public var displayLabel: String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? keyword : trimmed
    }

    public var selectedDefault: String? {
        if let defaultChoice, choices.contains(where: { $0.keyword == defaultChoice }) {
            return defaultChoice
        }
        return choices.first?.keyword
    }

    public func choice(keyword: String) -> PPDChoice? {
        choices.first { $0.keyword == keyword }
    }
}

/// The driver capabilities we can use, parsed from a real PPD.
public struct PPDDocument: Hashable, Codable, Sendable {
    public var nickname: String?
    public var makeAndModel: String?
    public var manufacturer: String?
    public var options: [PPDOption]
    public var supportsHardwareDuplex: Bool
    public var sourcePath: String?

    public init(
        nickname: String? = nil,
        makeAndModel: String? = nil,
        manufacturer: String? = nil,
        options: [PPDOption] = [],
        supportsHardwareDuplex: Bool = false,
        sourcePath: String? = nil
    ) {
        self.nickname = nickname
        self.makeAndModel = makeAndModel
        self.manufacturer = manufacturer
        self.options = options
        self.supportsHardwareDuplex = supportsHardwareDuplex
        self.sourcePath = sourcePath
    }

    public func option(keyword: String) -> PPDOption? {
        options.first { $0.keyword == keyword }
    }

    public func option(in group: PPDOptionGroup) -> PPDOption? {
        for keyword in group.preferredKeywords {
            if let option = option(keyword: keyword) {
                return option
            }
        }
        return options.first { $0.group == group }
    }

    public var colorOption: PPDOption? { option(in: .color) }
    public var paperSizeOption: PPDOption? { option(in: .paperSize) }
    public var mediaTypeOption: PPDOption? { option(in: .mediaType) }
    public var qualityOption: PPDOption? { option(in: .quality) }
    public var duplexOption: PPDOption? { option(in: .duplex) }

    public var displayName: String? {
        nickname ?? makeAndModel
    }

    public var isEmpty: Bool {
        options.isEmpty && nickname == nil && makeAndModel == nil
    }
}
