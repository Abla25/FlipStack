import Foundation

private struct PPDCacheKey: Hashable {
    var path: String
    var modified: Date?
    var size: Int?
}

private struct PPDCandidate {
    var url: URL
    var exactNickname: Bool
    var exactModel: Bool
    var exactQueue: Bool
    var score: Int
    var longestMatch: Int
    var modelLength: Int

    /// Negative when this candidate ranks ahead of `other`. `.orderedSame`
    /// means the two cannot be distinguished without guessing.
    func rankComparison(to other: PPDCandidate) -> ComparisonResult {
        if exactNickname != other.exactNickname {
            return exactNickname ? .orderedAscending : .orderedDescending
        }
        if exactModel != other.exactModel {
            return exactModel ? .orderedAscending : .orderedDescending
        }
        if exactQueue != other.exactQueue {
            return exactQueue ? .orderedAscending : .orderedDescending
        }
        if score != other.score {
            return score > other.score ? .orderedAscending : .orderedDescending
        }
        if longestMatch != other.longestMatch {
            return longestMatch > other.longestMatch ? .orderedAscending : .orderedDescending
        }
        if modelLength != other.modelLength {
            return modelLength < other.modelLength ? .orderedAscending : .orderedDescending
        }
        return .orderedSame
    }

    func isOrderedBefore(_ other: PPDCandidate) -> Bool {
        let comparison = rankComparison(to: other)
        if comparison != .orderedSame {
            return comparison == .orderedAscending
        }
        return url.path < other.url.path
    }
}

private final class PPDDocumentCache: @unchecked Sendable {
    private let lock = NSLock()
    private var documents: [PPDCacheKey: PPDDocument] = [:]

    func document(for key: PPDCacheKey) -> PPDDocument? {
        lock.lock()
        defer { lock.unlock() }
        return documents[key]
    }

    func insert(_ document: PPDDocument, for key: PPDCacheKey) {
        lock.lock()
        documents[key] = document
        lock.unlock()
    }
}

/// Finds the PPD that belongs to a queue and parses it. The configured CUPS
/// path is authoritative; searching the system PPD library is only a fallback,
/// and a candidate must share meaningful tokens with the queue or its model.
public struct PPDLoader: PPDProviding {
    private let searchDirectories: [URL]
    private let cache = PPDDocumentCache()

    public init(searchDirectories: [URL]? = nil) {
        self.searchDirectories = searchDirectories ?? [
            URL(fileURLWithPath: "/Library/Printers/PPDs", isDirectory: true)
        ]
    }

    public func locatePPD(for printer: Printer) -> URL? {
        if let configured = configuredPPD(for: printer), isReadableRegularFile(configured) {
            return configured
        }

        if let ppdPath = printer.ppdPath,
           let path = normalizedPath(ppdPath),
           isReadableRegularFile(URL(fileURLWithPath: path)),
           isAllowedPPDPath(URL(fileURLWithPath: path)) {
            return URL(fileURLWithPath: path)
        }

        let candidates = collectPPDFiles(in: searchDirectories)
        return bestCandidate(for: printer, among: candidates)
    }

    public func parsePPD(at url: URL) throws -> PPDDocument {
        let key = cacheKey(for: url)
        if let cached = cache.document(for: key) {
            return cached
        }

        let document = try PPDParser().parse(url: url)
        cache.insert(document, for: key)
        return document
    }

    // MARK: - Configured paths

    private func configuredPPD(for printer: Printer) -> URL? {
        let queue = printer.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !queue.isEmpty, !queue.contains("/"), queue != ".", queue != ".." else {
            return nil
        }

        let directory = URL(fileURLWithPath: "/etc/cups/ppd", isDirectory: true)
        for suffix in [".ppd", ".ppd.gz"] {
            let candidate = directory.appendingPathComponent(queue + suffix)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    /// A queue response must not be able to point the parser at an arbitrary
    /// readable file (for example a document or keychain export). Only the
    /// CUPS PPD directories (plus explicitly injected test/search roots) are
    /// valid PPD locations.
    private func isAllowedPPDPath(_ url: URL) -> Bool {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
        let allowedRoots = [
            "/etc/cups/ppd",
            "/private/etc/cups/ppd",
            "/Library/Printers/PPDs"
        ] + searchDirectories.map {
            $0.resolvingSymlinksInPath().standardizedFileURL.path
        }
        return allowedRoots.contains { root in
            resolved == root || resolved.hasPrefix(root + "/")
        }
    }

    private func normalizedPath(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.lowercased().hasPrefix("file://") {
            return URL(string: trimmed)?.path
        }
        return (trimmed as NSString).expandingTildeInPath
    }

    // MARK: - Search

    private func collectPPDFiles(in roots: [URL]) -> [URL] {
        var visited: Set<String> = []
        var results: [URL] = []
        for root in roots {
            walk(root, depth: 0, visited: &visited, results: &results)
        }
        return results
    }

    private func walk(
        _ url: URL,
        depth: Int,
        visited: inout Set<String>,
        results: inout [URL]
    ) {
        guard depth <= 12 else { return }

        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        guard visited.insert(resolved.path).inserted else { return }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return
        }

        if !isDirectory.boolValue {
            if isPPDFile(url), isReadableRegularFile(url) {
                results.append(url)
            }
            return
        }

        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            // Permission denied or a disappearing directory: simply treat it
            // as having no PPDs.
            return
        }

        for child in contents {
            walk(child, depth: depth + 1, visited: &visited, results: &results)
        }
    }

    private func isPPDFile(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return name.hasSuffix(".ppd") || name.hasSuffix(".ppd.gz")
    }

    private func isReadableRegularFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let path = url.path
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              FileManager.default.isReadableFile(atPath: path) else {
            return false
        }
        return true
    }

    // MARK: - Matching

    private func bestCandidate(for printer: Printer, among urls: [URL]) -> URL? {
        let queryTexts = [printer.id, printer.name, printer.model]
            .compactMap { $0 }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !queryTexts.isEmpty else { return nil }

        var queryTokens: Set<String> = []
        for text in queryTexts {
            queryTokens.formUnion(tokens(in: text))
        }
        queryTokens.subtract(Self.genericTokens)

        let queuePhrase = normalizedPhrase(printer.id)
        let namePhrase = normalizedPhrase(printer.name)
        let modelPhrase = normalizedPhrase(printer.model ?? "")
        let queryPhrases = [queuePhrase, namePhrase, modelPhrase].filter { !$0.isEmpty }
        let queryHasDistinctiveToken = queryTokens.contains { token in
            token.count >= 4 && token.rangeOfCharacter(from: .decimalDigits) != nil
        }

        var candidates: [PPDCandidate] = []

        for url in urls {
            // Reading the PPD metadata makes matching work even when a vendor
            // file is named after a driver family rather than the queue.
            let document = try? parsePPD(at: url)
            let stem = fileStem(url)
            let stemTokens = Set(tokens(in: stem))
            let nickname = document?.nickname ?? ""
            let makeModel = document?.makeAndModel ?? ""
            let manufacturer = document?.manufacturer ?? ""

            var candidateTokens = stemTokens
            candidateTokens.formUnion(tokens(in: nickname))
            candidateTokens.formUnion(tokens(in: makeModel))
            candidateTokens.formUnion(tokens(in: manufacturer))
            candidateTokens.subtract(Self.genericTokens)

            let modelTokens = stemTokens
                .union(tokens(in: nickname))
                .union(tokens(in: makeModel))
            let matched = candidateTokens.intersection(queryTokens)
            guard !matched.isEmpty else { continue }

            let stemPhrase = normalizedPhrase(stem)
            let nicknamePhrase = normalizedPhrase(nickname)
            let makeModelPhrase = normalizedPhrase(makeModel)

            let exactNickname = !nicknamePhrase.isEmpty && queryPhrases.contains(nicknamePhrase)
            let exactModel = !makeModelPhrase.isEmpty && queryPhrases.contains(makeModelPhrase)
            let exactQueue = (!queuePhrase.isEmpty && stemPhrase == queuePhrase)
                || (!namePhrase.isEmpty && stemPhrase == namePhrase)

            let longestMatch = matched.map(\.count).max() ?? 0
            let hasDistinctiveMatch = matched.contains { token in
                token.count >= 4 && token.rangeOfCharacter(from: .decimalDigits) != nil
            }

            // When the queue or model contains a model number, at least one
            // numeric token must match. Otherwise a similar sibling model
            // (for example HL-L2300DW vs HL-L2350DW) would look like a match
            // merely because it shares the manufacturer and family tokens.
            let strongEnough = !queryHasDistinctiveToken || hasDistinctiveMatch
            let matchedModelToken = !modelTokens.intersection(queryTokens).isEmpty
            let qualifies = exactNickname || exactModel || exactQueue
                || (matched.count >= 2 && matchedModelToken && strongEnough)
                || (matched.count == 1 && hasDistinctiveMatch)
            guard qualifies else { continue }

            let modelLength = makeModelPhrase.isEmpty
                ? (nicknamePhrase.isEmpty ? stemPhrase.count : nicknamePhrase.count)
                : makeModelPhrase.count

            candidates.append(PPDCandidate(
                url: url,
                exactNickname: exactNickname,
                exactModel: exactModel,
                exactQueue: exactQueue,
                score: matched.count,
                longestMatch: longestMatch,
                modelLength: modelLength
            ))
        }

        candidates.sort { $0.isOrderedBefore($1) }
        guard let best = candidates.first else { return nil }

        // Two indistinguishable vendor PPDs are an ambiguous match. Picking
        // one would expose the wrong option set, so return no PPD instead.
        if candidates.dropFirst().contains(where: { $0.rankComparison(to: best) == .orderedSame }) {
            return nil
        }
        return best.url
    }

    private func fileStem(_ url: URL) -> String {
        var name = url.lastPathComponent
        let lower = name.lowercased()
        if lower.hasSuffix(".ppd.gz") {
            name = String(name.dropLast(7))
        } else if lower.hasSuffix(".ppd") {
            name = String(name.dropLast(4))
        }
        return name
    }

    private func normalizedPhrase(_ text: String) -> String {
        let folded = text
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
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

    private func tokens(in text: String) -> [String] {
        normalizedPhrase(text)
            .split(separator: " ")
            .map(String.init)
    }

    private static let genericTokens: Set<String> = [
        "a", "an", "and", "the", "of", "for", "with", "printer", "print",
        "printing", "driver", "drivers", "cups", "ppd", "series", "model",
        "inc", "corp", "corporation", "company", "system", "default"
    ]

    // MARK: - Cache

    private func cacheKey(for url: URL) -> PPDCacheKey {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return PPDCacheKey(
            path: url.standardizedFileURL.path,
            modified: values?.contentModificationDate,
            size: values?.fileSize
        )
    }
}
