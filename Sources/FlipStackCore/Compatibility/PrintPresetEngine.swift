import Foundation

/// A user-facing printing quality preset.
///
/// Presets are resolved against the real options advertised by a printer's
/// PPD. A preset never invents an option or a choice: if the PPD does not
/// expose a relevant capability, the preset simply does not set it and the
/// application is reported as incomplete.
public enum PrintQualityPreset: String, CaseIterable, Codable, Sendable, Identifiable {
    case eco
    case standard
    case high
    case photo

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .eco: return L("Eco")
        case .standard: return L("Standard")
        case .high: return L("High")
        case .photo: return L("Photo")
        }
    }

    public var detail: String {
        switch self {
        case .eco:
            return L("A lighter draft with usable text and less ink than Photo.")
        case .standard:
            return L("Balanced resolution and speed for everyday documents.")
        case .high:
            return L("Highest practical resolution for crisp text and detailed graphics.")
        case .photo:
            return L("Maximum detail with photo media and color when the printer supports it.")
        }
    }
}

/// The result of applying a preset to a dictionary of `lp` driver options.
public struct PrintPresetApplication: Equatable, Sendable {
    /// PPD keyword to PPD choice keyword. Values are always real choices from
    /// the PPD (or unchanged values from the supplied base options).
    public var options: [String: String]

    /// Short, human-readable descriptions of the choices that were applied,
    /// suitable for a settings summary in a user interface.
    public var appliedLabels: [String]

    /// True when every capability group the preset controls was found in the
    /// PPD and resolved to a real choice. A preset can be usable while this is
    /// false: the missing groups keep their base/system values.
    public var isComplete: Bool

    public init(
        options: [String: String] = [:],
        appliedLabels: [String] = [],
        isComplete: Bool = false
    ) {
        self.options = options
        self.appliedLabels = appliedLabels
        self.isComplete = isComplete
    }
}

/// Resolves quality presets against one parsed PPD.
///
/// The resolver is deterministic: choices are ranked by their real PPD
/// keyword/label content, and ties keep the PPD's declaration order.
public struct PrintPresetResolver: Sendable {
    private struct RankedChoice: Sendable {
        var choice: PPDChoice
        var rank: Double
        var semanticTier: Int?
        var isPhotoSpecific: Bool
        var ppdIndex: Int
    }

    private struct QualityGroup: Sendable {
        var option: PPDOption
        var rankedChoices: [RankedChoice]
    }

    private let qualityGroups: [QualityGroup]
    private let mediaOption: PPDOption?
    private let colorOption: PPDOption?
    private let profileOptions: [PPDOption]

    public init(ppd: PPDDocument) {
        let options = ppd.options.filter { !$0.choices.isEmpty }

        qualityGroups = options
            .filter { $0.group == .quality }
            .map { option in
                QualityGroup(
                    option: option,
                    rankedChoices: Self.rankedChoices(in: option)
                )
            }
            .filter { !$0.rankedChoices.isEmpty }

        if let mediaType = Self.firstOption(in: options, keyword: "MediaType") {
            mediaOption = mediaType
        } else if let inputSlot = Self.firstOption(in: options, keyword: "InputSlot"),
                  Self.hasMediaVocabulary(inputSlot) {
            mediaOption = inputSlot
        } else {
            mediaOption = options.first {
                $0.group == .mediaType
                    && !Self.isInputSlot($0)
            }
        }

        colorOption = Self.preferredColorOption(in: options)

        let controlledKeywords = Set(
            qualityGroups.map { $0.option.keyword.lowercased() }
                + [mediaOption?.keyword.lowercased(), colorOption?.keyword.lowercased()]
                    .compactMap { $0 }
        )

        profileOptions = options.filter { option in
            let keyword = option.keyword.lowercased()
            guard !controlledKeywords.contains(keyword) else { return false }
            guard option.group != .duplex, option.group != .paperSize else { return false }
            let text = Self.normalized(option.keyword + " " + option.label)
            return text.contains("profile") || text.contains("icc")
        }
    }

    /// Presets that can affect at least one real PPD choice. An empty PPD, or
    /// one that only advertises paper size/duplex, returns no presets.
    public var availablePresets: [PrintQualityPreset] {
        guard !qualityGroups.isEmpty || mediaOption != nil || colorOption != nil else {
            return []
        }
        return PrintQualityPreset.allCases
    }

    /// Applies a preset while preserving every base value the preset does not
    /// control. Missing capabilities leave the base value in place and make
    /// `isComplete` false.
    public func apply(
        _ preset: PrintQualityPreset,
        to base: [String: String]
    ) -> PrintPresetApplication {
        var options = base
        var labels: [String] = []
        var seenLabels = Set<String>()
        var isComplete = true

        func appendLabel(_ value: String) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            if seenLabels.insert(trimmed.lowercased()).inserted {
                labels.append(trimmed)
            }
        }

        if qualityGroups.isEmpty {
            isComplete = false
        }

        for group in qualityGroups {
            guard let selected = selectQuality(preset, in: group) else {
                isComplete = false
                continue
            }
            Self.setOption(
                selected.choice.keyword,
                for: group.option.keyword,
                in: &options
            )
            appendLabel(Self.qualityLabel(option: group.option, choice: selected.choice))
        }

        if let mediaOption {
            if let selected = selectMedia(preset, from: mediaOption) {
                Self.setOption(selected.keyword, for: mediaOption.keyword, in: &options)
                appendLabel(selected.displayLabel)
            } else {
                isComplete = false
            }
        } else {
            isComplete = false
        }

        if let colorOption {
            if let selected = selectColor(from: colorOption) {
                Self.setOption(selected.keyword, for: colorOption.keyword, in: &options)
                appendLabel(selected.displayLabel)
            } else {
                isComplete = false
            }
        }

        // ICC/color-profile options are optional. Only the Photo preset uses
        // them, and their absence never makes an otherwise complete preset
        // incomplete.
        if preset == .photo {
            for option in profileOptions {
                guard let selected = Self.selectProfile(from: option) else { continue }
                Self.setOption(selected.keyword, for: option.keyword, in: &options)
                appendLabel("\(selected.displayLabel) profile")
            }
        }

        return PrintPresetApplication(
            options: options,
            appliedLabels: labels,
            isComplete: isComplete
        )
    }

    /// Returns the preset whose controlled PPD choices match `options`, or
    /// `nil` when the selection is custom or matches more than one preset.
    /// Unrelated options (paper size, duplex, tray, and so on) are ignored.
    public func matchingPreset(for options: [String: String]) -> PrintQualityPreset? {
        let presets = availablePresets
        guard !presets.isEmpty else { return nil }

        var normalized: [String: String] = [:]
        for (key, value) in options {
            normalized[Self.normalizedKeyword(key)] = value
        }

        let controlledKeywords = controlKeywords()
        var matches: [PrintQualityPreset] = []

        for preset in presets {
            let expected = apply(preset, to: [:])
            if Self.matches(
                expected: expected.options,
                actual: normalized,
                controlledKeywords: controlledKeywords
            ) {
                matches.append(preset)
            }
        }

        return matches.count == 1 ? matches[0] : nil
    }

    // MARK: - Quality selection

    private func controlKeywords() -> Set<String> {
        var keywords = Set(qualityGroups.map { Self.normalizedKeyword($0.option.keyword) })
        if let mediaOption {
            keywords.insert(Self.normalizedKeyword(mediaOption.keyword))
        }
        // Color mode is an independent user choice (Color/B&W), not a
        // quality dimension. A grayscale document can still use Standard,
        // High, or Photo quality without losing its color mode.
        return keywords
    }

    private static func matches(
        expected: [String: String],
        actual: [String: String],
        controlledKeywords: Set<String>
    ) -> Bool {
        for keyword in controlledKeywords {
            let expectedValue = expected.first {
                normalizedKeyword($0.key) == keyword
            }?.value
            let actualValue = actual[keyword]

            switch (expectedValue, actualValue) {
            case (nil, nil):
                continue
            case (let expectedValue?, let actualValue?):
                guard valuesMatch(expectedValue, actualValue) else { return false }
            default:
                return false
            }
        }
        return true
    }

    private static func valuesMatch(_ lhs: String, _ rhs: String) -> Bool {
        lhs.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(rhs.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
    }

    private func selectQuality(
        _ preset: PrintQualityPreset,
        in group: QualityGroup
    ) -> RankedChoice? {
        let ranked = group.rankedChoices
        guard !ranked.isEmpty else { return nil }

        switch preset {
        case .eco:
            // A usable draft, not the absolute lowest resolution. When the PPD
            // exposes a choice at or above 300 dpi, prefer it so Eco does not
            // look like a fax.
            return ranked.first(where: { $0.rank >= 300 }) ?? ranked.first

        case .standard:
            if let normal = ranked.first(where: { $0.semanticTier == 1 }) {
                return normal
            }
            return ranked[(ranked.count - 1) / 2]

        case .high:
            let nonPhoto = ranked.filter { !$0.isPhotoSpecific }
            return Self.highest(nonPhoto.isEmpty ? ranked : nonPhoto)

        case .photo:
            let photo = ranked.filter(\.isPhotoSpecific)
            return Self.highest(photo.isEmpty ? ranked : photo)
        }
    }

    /// Highest rank, with the first PPD choice winning ties.
    private static func highest(_ choices: [RankedChoice]) -> RankedChoice? {
        guard var best = choices.first else { return nil }
        for choice in choices.dropFirst() where choice.rank > best.rank {
            best = choice
        }
        return best
    }

    private static func rankedChoices(in option: PPDOption) -> [RankedChoice] {
        let entries = option.choices.enumerated().map { index, choice -> RankedChoice in
            RankedChoice(
                choice: choice,
                rank: 0,
                semanticTier: semanticTier(for: choice),
                isPhotoSpecific: isPhotoSpecific(choice),
                ppdIndex: index
            )
        }

        let numericValues = entries.compactMap { numericValue(for: $0.choice) }
        let minNumeric = numericValues.min()
        let maxNumeric = numericValues.max()

        var ranked = entries.map { entry -> RankedChoice in
            var entry = entry
            if let numeric = numericValue(for: entry.choice) {
                entry.rank = Double(numeric)
            } else if let minNumeric, let maxNumeric {
                // A mixed list (for example numeric resolutions plus an
                // "Auto" choice). Place semantic choices relative to the real
                // numeric range without inventing a resolution value.
                let midpoint = Double(minNumeric + maxNumeric) / 2
                switch entry.semanticTier {
                case 0:
                    entry.rank = Double(minNumeric) - 1
                case 1:
                    entry.rank = midpoint
                case 2:
                    entry.rank = (midpoint + Double(maxNumeric)) / 2
                default:
                    entry.rank = Double(maxNumeric) + 1
                }
            } else {
                // Pure label-based quality option (Draft/Normal/High/Best).
                entry.rank = Double(entry.semanticTier ?? 0)
            }
            return entry
        }

        ranked.sort { lhs, rhs in
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
            let leftTier = lhs.semanticTier ?? 0
            let rightTier = rhs.semanticTier ?? 0
            if leftTier != rightTier { return leftTier < rightTier }
            return lhs.ppdIndex < rhs.ppdIndex
        }
        return ranked
    }

    private static func semanticTier(for choice: PPDChoice) -> Int? {
        let text = normalized(choice.keyword + " " + choice.label)
        let tokens = Set(text.split(separator: " ").map(String.init))

        if tokens.contains("photo") || tokens.contains("prophoto") ||
            tokens.contains("best") || tokens.contains("maximum") ||
            tokens.contains("max") || tokens.contains("ultra") ||
            tokens.contains("highest") || tokens.contains("presentation") ||
            tokens.contains("premium") {
            return 3
        }
        // Speed/economy words win over the generic word "quality", so a
        // "Draft Quality" choice is still ranked below "Normal Quality".
        if tokens.contains("draft") || tokens.contains("fast") ||
            tokens.contains("speed") || tokens.contains("quick") ||
            tokens.contains("economy") || tokens.contains("eco") ||
            tokens.contains("low") || tokens.contains("toner") ||
            tokens.contains("save") || tokens.contains("sketch") {
            return 0
        }
        if tokens.contains("normal") || tokens.contains("standard") ||
            tokens.contains("default") || tokens.contains("medium") ||
            tokens.contains("auto") || tokens.contains("regular") {
            return 1
        }
        if tokens.contains("high") || tokens.contains("fine") ||
            tokens.contains("good") || tokens.contains("quality") {
            return 2
        }
        return nil
    }

    private static func isPhotoSpecific(_ choice: PPDChoice) -> Bool {
        normalized(choice.keyword + " " + choice.label).contains("photo")
    }

    private static func numericValue(for choice: PPDChoice) -> Int? {
        let text = choice.keyword + " " + choice.label
        let numbers = text
            .components(separatedBy: CharacterSet.decimalDigits.inverted)
            .compactMap { Int($0) }
        return numbers.max()
    }

    // MARK: - Media selection

    private func selectMedia(
        _ preset: PrintQualityPreset,
        from option: PPDOption
    ) -> PPDChoice? {
        switch preset {
        case .eco, .standard:
            return Self.bestChoice(in: option.choices) { choice in
                let score = Self.plainScore(choice)
                return score >= 2 ? score : nil
            }

        case .high:
            if let plain = Self.bestChoice(in: option.choices, score: { choice in
                let score = Self.plainScore(choice)
                return score >= 2 ? score : nil
            }) {
                return plain
            }
            let nonPhoto = option.choices.filter { Self.photoScore($0) == 0 }
            if let fallback = Self.bestChoice(in: nonPhoto, score: Self.generalMediaScore) {
                return fallback
            }
            // Photo-only media remains usable for a high-quality job.
            return Self.bestChoice(in: option.choices, score: { choice in
                let score = Self.photoScore(choice)
                return score > 0 ? score : nil
            })

        case .photo:
            return Self.bestChoice(in: option.choices, score: { choice in
                let score = Self.photoScore(choice)
                return score > 0 ? score : nil
            })
        }
    }

    private static func plainScore(_ choice: PPDChoice) -> Int {
        let text = normalized(choice.keyword + " " + choice.label)
        let tokens = Set(text.split(separator: " ").map(String.init))

        if text.contains("plain") { return 4 }
        if tokens.contains("normal") || tokens.contains("standard") { return 3 }
        if tokens.contains("recycled") || tokens.contains("bond") ||
            tokens.contains("copy") || tokens.contains("multipurpose") ||
            tokens.contains("office") || tokens.contains("uncoated") {
            return 2
        }
        if tokens.contains("auto") { return 1 }
        return 0
    }

    private static func photoScore(_ choice: PPDChoice) -> Int {
        let text = normalized(choice.keyword + " " + choice.label)
        let tokens = Set(text.split(separator: " ").map(String.init))

        if text.contains("photo") {
            if text.contains("gloss") { return 6 }
            return 5
        }
        if text.contains("gloss") || tokens.contains("satin") ||
            tokens.contains("lustre") || tokens.contains("luster") ||
            tokens.contains("semigloss") {
            return 4
        }
        if text.contains("matte") { return 3 }
        if text.contains("premium") || text.contains("fine art") ||
            tokens.contains("canvas") || tokens.contains("coated") ||
            tokens.contains("inkjet") {
            return 2
        }
        return 0
    }

    private static func generalMediaScore(_ choice: PPDChoice) -> Int? {
        let text = normalized(choice.keyword + " " + choice.label)
        let tokens = Set(text.split(separator: " ").map(String.init))
        if tokens.contains("normal") || tokens.contains("standard") { return 3 }
        if tokens.contains("thin") || tokens.contains("thick") ||
            tokens.contains("cardstock") || tokens.contains("card") {
            return 2
        }
        if tokens.contains("auto") { return 1 }
        return 0
    }

    private static func hasMediaVocabulary(_ option: PPDOption) -> Bool {
        option.choices.contains { choice in
            let text = normalized(choice.keyword + " " + choice.label)
            let tokens = Set(text.split(separator: " ").map(String.init))
            let words: Set<String> = [
                "plain", "normal", "standard", "recycled", "bond", "copy",
                "photo", "glossy", "gloss", "matte", "satin", "lustre",
                "luster", "semigloss", "thin", "thick", "cardstock", "card",
                "transparency", "label", "envelope", "coated", "premium"
            ]
            return text.contains("photo") || text.contains("gloss") ||
                !tokens.isDisjoint(with: words)
        }
    }

    // MARK: - Color selection

    private static func preferredColorOption(in options: [PPDOption]) -> PPDOption? {
        for keyword in PPDOptionGroup.color.preferredKeywords {
            if let option = firstOption(in: options, keyword: keyword) {
                return option
            }
        }
        return options.first { $0.group == .color }
    }

    private func selectColor(from option: PPDOption) -> PPDChoice? {
        if let color = Self.bestChoice(in: option.choices, score: { choice in
            let score = Self.colorScore(choice)
            return score > 0 ? score : nil
        }) {
            return color
        }

        if option.choices.count == 1 {
            return option.choices[0]
        }

        if let gray = Self.bestChoice(in: option.choices, score: { choice in
            Self.grayScore(choice) > 0 ? Self.grayScore(choice) : nil
        }) {
            return gray
        }

        if let defaultChoice = option.defaultChoice,
           let choice = option.choice(keyword: defaultChoice) {
            return choice
        }
        return nil
    }

    private static func colorScore(_ choice: PPDChoice) -> Int {
        let text = normalized(choice.keyword + " " + choice.label)
        let tokens = Set(text.split(separator: " ").map(String.init))

        if tokens.contains("color") || tokens.contains("colour") { return 5 }
        if text.contains("color") || text.contains("colour") { return 4 }
        if tokens.contains("rgb") || tokens.contains("cmyk") ||
            tokens.contains("cmy") || tokens.contains("composite") ||
            tokens.contains("vivid") || tokens.contains("full") {
            return 3
        }
        return 0
    }

    private static func grayScore(_ choice: PPDChoice) -> Int {
        let text = normalized(choice.keyword + " " + choice.label)
        let tokens = Set(text.split(separator: " ").map(String.init))

        if tokens.contains("grayscale") || tokens.contains("greyscale") { return 3 }
        if tokens.contains("gray") || tokens.contains("grey") { return 2 }
        if tokens.contains("mono") || tokens.contains("monochrome") ||
            tokens.contains("black") || tokens.contains("bw") {
            return 1
        }
        return 0
    }

    // MARK: - Profile selection

    private static func selectProfile(from option: PPDOption) -> PPDChoice? {
        if let profile = bestChoice(in: option.choices, score: { choice in
            let score = profileScore(choice)
            return score > 0 ? score : nil
        }) {
            return profile
        }
        if option.choices.count == 1 {
            return option.choices[0]
        }
        return nil
    }

    private static func profileScore(_ choice: PPDChoice) -> Int {
        let text = normalized(choice.keyword + " " + choice.label)
        let tokens = Set(text.split(separator: " ").map(String.init))

        if text.contains("photo") { return 4 }
        if text.contains("adobe rgb") || text.contains("adobergb") ||
            (tokens.contains("adobe") && tokens.contains("rgb")) {
            return 3
        }
        if tokens.contains("srgb") || tokens.contains("rgb") { return 2 }
        if tokens.contains("color") || tokens.contains("colour") { return 1 }
        return 0
    }

    // MARK: - Shared helpers

    private static func bestChoice(
        in choices: [PPDChoice],
        score: (PPDChoice) -> Int?
    ) -> PPDChoice? {
        var best: PPDChoice?
        var bestScore = Int.min
        for choice in choices {
            guard let value = score(choice) else { continue }
            if value > bestScore {
                best = choice
                bestScore = value
            }
        }
        return best
    }

    /// Replaces any base spelling of the same PPD keyword, so a caller that
    /// stored `resolution` does not end up sending both `resolution` and
    /// `Resolution` to CUPS.
    private static func setOption(
        _ value: String,
        for keyword: String,
        in options: inout [String: String]
    ) {
        let variants = options.keys.filter {
            $0.caseInsensitiveCompare(keyword) == .orderedSame
        }
        for variant in variants {
            options.removeValue(forKey: variant)
        }
        options[keyword] = value
    }

    private static func bestChoice(in choices: [PPDChoice], score: (PPDChoice) -> Int) -> PPDChoice? {
        bestChoice(in: choices) { choice in
            let value = score(choice)
            return value > 0 ? value : nil
        }
    }

    private static func firstOption(in options: [PPDOption], keyword: String) -> PPDOption? {
        options.first { $0.keyword.caseInsensitiveCompare(keyword) == .orderedSame }
    }

    private static func isInputSlot(_ option: PPDOption) -> Bool {
        option.keyword.caseInsensitiveCompare("InputSlot") == .orderedSame
    }

    private static func qualityLabel(option: PPDOption, choice: PPDChoice) -> String {
        let key = option.keyword.lowercased()
        let display = choice.displayLabel
        let normalizedDisplay = display.lowercased()

        if key.contains("resolution") || key.contains("raster") {
            if normalizedDisplay.contains("dpi") ||
                normalizedDisplay.contains("resolution") ||
                display.contains(where: { $0.isNumber }) {
                return display
            }
            return "\(display) resolution"
        }
        if key.contains("quality") {
            if normalizedDisplay.contains("quality") { return display }
            return "\(display) quality"
        }
        return "\(option.displayLabel): \(display)"
    }

    private static func normalized(_ value: String) -> String {
        let folded = value
            .folding(
                options: [.diacriticInsensitive, .caseInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased()
        var characters: [Character] = []
        characters.reserveCapacity(folded.count)
        for character in folded {
            characters.append(character.isLetter || character.isNumber ? character : " ")
        }
        return String(characters)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private static func normalizedKeyword(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
