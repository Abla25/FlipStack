import CoreGraphics
import Foundation

/// Parses the subset of the Adobe PPD format that describes user-selectable
/// options. Only options declared with `*OpenUI` and carrying at least one
/// real choice are returned; nothing is invented for a sparse PPD.
public struct PPDParser: Sendable {
    public init() {}

    public func parse(contents: String, sourcePath: String? = nil) -> PPDDocument {
        var builder = PPDBuilder(sourcePath: sourcePath)
        let normalized = contents
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        for line in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            builder.consume(String(line))
        }
        return builder.document()
    }

    public func parse(data: Data, sourcePath: String? = nil) throws -> PPDDocument {
        if data.count >= 2, data[data.startIndex] == 0x1f, data[data.startIndex + 1] == 0x8b {
            let text = try decompressGzip(data)
            return parse(contents: text, sourcePath: sourcePath)
        }
        return parse(contents: String(decoding: data, as: UTF8.self), sourcePath: sourcePath)
    }

    public func parse(url: URL) throws -> PPDDocument {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw PPDError.fileNotFound(url.path)
        }
        guard !isDirectory.boolValue, FileManager.default.isReadableFile(atPath: url.path) else {
            throw PPDError.unreadableFile(url.path)
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw PPDError.unreadableFile(url.path)
        }
        return try parse(data: data, sourcePath: url.path)
    }

    private func decompressGzip(_ data: Data) throws -> String {
        let directory = try SecureTemp.makeDirectory(prefix: "PPD")
        let temporaryURL = directory.appendingPathComponent("\(UUID().uuidString).ppd.gz")
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            try SecureTemp.write(data, to: temporaryURL)
        } catch {
            throw PPDError.decompressionFailed(error.localizedDescription)
        }

        let runner = CUPSProcessRunner()
        let result: CUPSCommandResult
        do {
            result = try runner.runSynchronously(
                executable: URL(fileURLWithPath: "/usr/bin/gzip"),
                arguments: ["-dc", temporaryURL.path],
                timeout: 20
            )
        } catch let error as CUPSProcessError {
            switch error {
            case .executableNotFound(let path):
                throw PPDError.toolNotFound((path as NSString).lastPathComponent)
            case .timedOut(let tool):
                throw PPDError.timedOut(tool)
            case .launchFailed(let message):
                throw PPDError.decompressionFailed(message)
            }
        } catch {
            throw PPDError.decompressionFailed(error.localizedDescription)
        }

        guard result.status == 0 else {
            throw PPDError.decompressionFailed(result.combinedMessage)
        }
        guard result.stdout.count <= 16 * 1024 * 1024 else {
            throw PPDError.decompressionFailed("The decompressed PPD is larger than 16 MB.")
        }
        return String(decoding: result.stdout, as: UTF8.self)
    }
}

// MARK: - Builder

private struct PPDBuilder {
    private struct RawOption {
        var keyword: String
        var label: String
        var group: PPDOptionGroup
        var choices: [PPDChoice]
        var choiceKeys: Set<String>
    }

    private let sourcePath: String?
    private var options: [RawOption] = []
    private var optionIndexByKeyword: [String: Int] = [:]
    private var currentOptionIndex: Int?
    private var defaults: [String: String] = [:]

    private var nickname: String?
    private var manufacturer: String?
    private var makeModel: String?
    private var modelName: String?
    private var paperDimensions: [String: CGSize] = [:]
    private var imageableAreas: [String: CGRect] = [:]

    init(sourcePath: String?) {
        self.sourcePath = sourcePath
    }

    mutating func consume(_ rawLine: String) {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.hasPrefix("*"), !line.hasPrefix("*%") else { return }

        let body = String(line.dropFirst())
        guard let split = Self.splitHeaderAndValue(body) else { return }
        let header = split.header.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = split.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !header.isEmpty, let token = Self.firstWord(header) else { return }

        let lowerToken = token.lowercased()

        switch lowerToken {
        case "openui":
            beginOption(header: header)
        case "closeui":
            currentOptionIndex = nil
        case "nickname":
            nickname = Self.nonEmptyCleanText(value)
        case "manufacturer":
            manufacturer = Self.nonEmptyCleanText(value)
        case "makemodel":
            makeModel = Self.nonEmptyCleanText(value)
        case "modelname":
            modelName = Self.nonEmptyCleanText(value)
        case "paperdimension":
            let keyword = Self.cleanText(Self.remainder(afterFirstWordIn: header) ?? "")
            if !keyword.isEmpty, let size = Self.parsePointPair(value) {
                paperDimensions[keyword.lowercased()] = size
            }
        case "imageablearea":
            let keyword = Self.cleanText(Self.remainder(afterFirstWordIn: header) ?? "")
            if !keyword.isEmpty, let rect = Self.parseImageableArea(value) {
                imageableAreas[keyword.lowercased()] = rect
            }
        default:
            if lowerToken.hasPrefix("default"), token.count > "default".count {
                let keyword = String(token.dropFirst("default".count))
                if !keyword.isEmpty {
                    defaults[keyword.lowercased()] = Self.cleanText(value)
                }
            } else if let index = currentOptionIndex,
                      options[index].keyword.caseInsensitiveCompare(token) == .orderedSame {
                addChoice(from: header, value: value, to: index)
            }
        }
    }

    func document() -> PPDDocument {
        var parsedOptions: [PPDOption] = []
        var supportsDuplex = false

        for raw in options where !raw.choices.isEmpty {
            let defaultChoice: String?
            if let rawDefault = defaults[raw.keyword.lowercased()] {
                defaultChoice = raw.choices.first {
                    $0.keyword.caseInsensitiveCompare(rawDefault) == .orderedSame
                }?.keyword
            } else {
                defaultChoice = nil
            }

            if raw.group == .duplex, raw.choices.contains(where: { Self.isHardwareDuplexChoice($0) }) {
                supportsDuplex = true
            }

            parsedOptions.append(PPDOption(
                keyword: raw.keyword,
                label: raw.label,
                group: raw.group,
                choices: raw.choices,
                defaultChoice: defaultChoice,
                isPseudoOption: raw.keyword.lowercased().hasPrefix("cups")
            ))
        }

        return PPDDocument(
            nickname: nickname,
            makeAndModel: makeModel ?? modelName,
            manufacturer: manufacturer,
            options: parsedOptions,
            supportsHardwareDuplex: supportsDuplex,
            sourcePath: sourcePath,
            paperDimensions: paperDimensions,
            imageableAreas: imageableAreas
        )
    }

    /// Parses `"<width> <height>"` in PostScript points. Numbers may be
    /// separated by any whitespace (spaces or tabs).
    private static func parsePointPair(_ value: String) -> CGSize? {
        let numbers = Self.cleanText(value)
            .split(whereSeparator: { $0.isWhitespace })
            .compactMap { Double($0) }
        guard numbers.count == 2, numbers[0] > 0, numbers[1] > 0 else { return nil }
        return CGSize(width: numbers[0], height: numbers[1])
    }

    /// Parses `"<left> <bottom> <right> <top>"` into a CGRect.
    private static func parseImageableArea(_ value: String) -> CGRect? {
        let numbers = Self.cleanText(value)
            .split(whereSeparator: { $0.isWhitespace })
            .compactMap { Double($0) }
        guard numbers.count == 4 else { return nil }
        let (left, bottom, right, top) = (numbers[0], numbers[1], numbers[2], numbers[3])
        guard right > left, top > bottom else { return nil }
        return CGRect(x: left, y: bottom, width: right - left, height: top - bottom)
    }

    private mutating func beginOption(header: String) {
        guard let operand = Self.operand(afterFirstWordIn: header),
              let parsed = Self.parseKeywordAndLabel(operand),
              !parsed.keyword.isEmpty else {
            currentOptionIndex = nil
            return
        }

        let key = parsed.keyword.lowercased()
        let label = parsed.label?.isEmpty == false ? parsed.label! : parsed.keyword
        let group = Self.group(for: parsed.keyword)

        if let index = optionIndexByKeyword[key] {
            if options[index].label == options[index].keyword, label != parsed.keyword {
                options[index].label = label
            }
            currentOptionIndex = index
            return
        }

        let option = RawOption(
            keyword: parsed.keyword,
            label: label,
            group: group,
            choices: [],
            choiceKeys: []
        )
        options.append(option)
        optionIndexByKeyword[key] = options.count - 1
        currentOptionIndex = options.count - 1
    }

    private mutating func addChoice(from header: String, value: String, to index: Int) {
        guard let remainder = Self.remainder(afterFirstWordIn: header) else { return }
        let trimmed = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        guard let parsed = Self.parseChoice(trimmed) else { return }
        guard !parsed.keyword.isEmpty else { return }

        let key = parsed.keyword.lowercased()
        guard options[index].choiceKeys.insert(key).inserted else { return }

        let label = parsed.label?.isEmpty == false ? parsed.label! : parsed.keyword
        options[index].choices.append(PPDChoice(
            keyword: parsed.keyword,
            label: label,
            value: value
        ))
    }

    // MARK: Line scanning

    private static func splitHeaderAndValue(_ body: String) -> (header: String, value: String)? {
        var inQuotes = false
        var escaped = false
        var index = body.startIndex

        while index < body.endIndex {
            let character = body[index]
            if escaped {
                escaped = false
                index = body.index(after: index)
                continue
            }
            if character == "\\" {
                escaped = true
                index = body.index(after: index)
                continue
            }
            if character == "\"" {
                inQuotes.toggle()
                index = body.index(after: index)
                continue
            }
            if character == ":", !inQuotes {
                let header = String(body[..<index])
                let value = String(body[body.index(after: index)...])
                return (header, value)
            }
            index = body.index(after: index)
        }
        return nil
    }

    private static func firstWord(_ value: String) -> String? {
        guard let end = value.firstIndex(where: { $0.isWhitespace }) else {
            return value.isEmpty ? nil : value
        }
        let word = String(value[..<end])
        return word.isEmpty ? nil : word
    }

    private static func operand(afterFirstWordIn header: String) -> String? {
        remainder(afterFirstWordIn: header)
    }

    private static func remainder(afterFirstWordIn value: String) -> String? {
        guard let end = value.firstIndex(where: { $0.isWhitespace }) else { return nil }
        var index = end
        while index < value.endIndex, value[index].isWhitespace {
            index = value.index(after: index)
        }
        return index < value.endIndex ? String(value[index...]) : nil
    }

    /// Parses `*Keyword/Label` or `Keyword/Label`.
    private static func parseKeywordAndLabel(_ value: String) -> (keyword: String, label: String?)? {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("*") {
            text = String(text.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !text.isEmpty else { return nil }

        let (keywordToken, rest) = takeToken(text, stoppingAtSlash: true)
        let keyword = unescape(keywordToken)
        guard !keyword.isEmpty else { return nil }

        var after = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        var label: String?
        if after.hasPrefix("/") {
            after = String(after.dropFirst())
            label = cleanText(after)
        }
        return (keyword, label)
    }

    private static func parseChoice(_ value: String) -> (keyword: String, label: String?)? {
        let (choiceToken, rest) = takeToken(value, stoppingAtSlash: true)
        let keyword = unescape(choiceToken)
        guard !keyword.isEmpty else { return nil }

        var after = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        var label: String?
        if after.hasPrefix("/") {
            after = String(after.dropFirst())
            label = cleanText(after)
        }
        return (keyword, label)
    }

    private static func takeToken(_ value: String, stoppingAtSlash: Bool) -> (String, String) {
        var token = ""
        var index = value.startIndex
        var quoted = false

        if index < value.endIndex, value[index] == "\"" {
            quoted = true
            index = value.index(after: index)
        }

        while index < value.endIndex {
            let character = value[index]

            if !quoted, character.isWhitespace {
                break
            }
            if !quoted, stoppingAtSlash, character == "/" {
                break
            }
            if quoted, character == "\"" {
                index = value.index(after: index)
                break
            }
            if character == "\\" {
                token.append(character)
                index = value.index(after: index)
                if index < value.endIndex {
                    token.append(value[index])
                    index = value.index(after: index)
                }
                continue
            }
            token.append(character)
            index = value.index(after: index)
        }

        return (token, String(value[index...]))
    }

    private static func cleanText(_ value: String) -> String {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") {
            text = String(text.dropFirst().dropLast())
        }
        return unescape(text).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func nonEmptyCleanText(_ value: String) -> String? {
        let cleaned = cleanText(value)
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func unescape(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.count)
        var escaped = false
        for character in value {
            if escaped {
                result.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                result.append(character)
            }
        }
        if escaped { result.append("\\") }
        return result
    }

    private static func group(for keyword: String) -> PPDOptionGroup {
        switch keyword.lowercased() {
        case "colormodel", "colormode", "cupscolormodel":
            return .color
        case "pagesize", "mediasize", "pageregion":
            return .paperSize
        case "mediatype", "inputslot":
            return .mediaType
        case "resolution", "printquality", "rasterquality", "cupsprintquality":
            return .quality
        case "duplex":
            return .duplex
        default:
            return .other
        }
    }

    private static func isHardwareDuplexChoice(_ choice: PPDChoice) -> Bool {
        let keyword = choice.keyword.lowercased()
        let label = choice.label.lowercased()
        let nonDuplex = ["none", "simplex", "off", "false", "no", "1"]
        return !nonDuplex.contains(keyword) && !nonDuplex.contains(label)
    }
}
