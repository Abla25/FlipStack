import Foundation

/// Parsed detail from `lpstat -p <queue> -l`.
struct LPStatPrinterDetail {
    var description: String?
    var location: String?
    var model: String?
    var ppdPath: String?
    var state: PrinterState
    var stateReasons: [String]
    var acceptsJobs: Bool
    var printingJobID: Int?
}

/// Parser for the human-readable `lpstat` output. CUPS localizes some labels,
/// so the important ones are recognised in English and Italian. Dates are
/// parsed conservatively: failure to understand a date leaves `createdAt` nil
/// without losing the job's id, owner, or title.
enum LPStatParser {
    // MARK: - Queue lists

    static func parsePrinterNames(_ output: String) -> [String] {
        output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { line in
                guard !line.isEmpty else { return false }
                let lower = line.lowercased()
                if lower.hasPrefix("lpstat:") { return false }
                if lower.contains("no destinations added") { return false }
                if lower.contains("nessuna destinazione") { return false }
                if lower.contains("no printers") { return false }
                return true
            }
    }

    static func parseDefaultPrinter(_ output: String) -> String? {
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = trimmed.lowercased()
            guard lower.contains("default") || lower.contains("predefinita") else { continue }
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            var value = String(trimmed[trimmed.index(after: colon)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let last = value.split(whereSeparator: { $0.isWhitespace }).last {
                value = String(last)
            }
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: ".\""))
            if value.isEmpty { return nil }
            let valueLower = value.lowercased()
            if valueLower == "none" || valueLower == "nessuna" { return nil }
            return value
        }
        return nil
    }

    static func parseDeviceURI(_ output: String, queue: String) -> String? {
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if trimmed.lowercased().hasPrefix("lpstat:") { continue }
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let value = String(trimmed[trimmed.index(after: colon)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            return value
        }
        return nil
    }

    // MARK: - Printer details

    /// BSD `getopt` stops at the first positional argument, so on macOS
    /// `lpstat -p <queue> -l` omits the long listing. The client retries with
    /// `lpstat -l -p <queue>` only when this returns false.
    static func hasDetailedPrinterOutput(_ output: String) -> Bool {
        output
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .count > 1
    }

    static func parsePrinterDetail(_ output: String, queue: String) -> LPStatPrinterDetail? {
        let lines = output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let first = lines.first else { return nil }

        let firstLower = first.lowercased()
        var state: PrinterState = .unknown
        var acceptsJobs = true

        if containsAny(firstLower, ["disabled", "disabilitat", "disattivat", "stopped", "arrestat", "in pausa"]) {
            state = .stopped
            acceptsJobs = false
        } else if containsAny(firstLower, ["now printing", "is printing", "printing", "sta stampando", "in stampa"]) {
            state = .processing
        } else if containsAny(firstLower, ["is idle", "idle", "in attesa", "pronta", "attesa"]) {
            state = .idle
        }

        if containsAny(firstLower, ["not accepting", "non accetta", "rifiuta"]) {
            acceptsJobs = false
        }

        var description: String?
        var location: String?
        var model: String?
        var ppdPath: String?
        var reasons: [String] = []

        for line in lines.dropFirst() {
            if let reason = reasonFromBareLine(line) {
                appendReasons(reason, to: &reasons)
                continue
            }

            guard let colon = line.firstIndex(of: ":") else { continue }
            let rawLabel = String(line[..<colon])
            let label = normalizedLabel(rawLabel)
            let value = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)

            switch label {
            case "description", "descrizione":
                description = cleanedDetail(value)
            case "location", "posizione", "luogo":
                location = cleanedDetail(value)
            case "interface", "interfaccia", "ppd", "file ppd":
                if let path = cleanedDetail(value), path.contains("/") {
                    ppdPath = path
                }
            case "makemodel", "make/model", "make and model", "model", "modello", "modello e tipo":
                model = cleanedDetail(value)
            case "alerts", "avvisi", "state reasons", "reasons", "reason", "motivi", "motivo":
                appendReasons(value, to: &reasons)
            case "accepting requests", "accetta richieste":
                if containsAny(value.lowercased(), ["no", "false", "non"]) {
                    acceptsJobs = false
                }
            default:
                break
            }
        }

        // A disabled queue often prints "- reason unknown" or "- reason media-empty".
        if let range = firstLower.range(of: " - ") {
            var tail = String(first[range.upperBound...])
            // "- enabled since <date>" / "- abilitata da <data>" is not a reason:
            // strip the whole date phrase so its tokens never reach stateReasons.
            let lowerTail = tail.lowercased()
            for prefix in ["enabled since", "disabled since", "abilitata da", "disabilitata da"] {
                if lowerTail.hasPrefix(prefix) { tail = ""; break }
            }
            appendReasons(tail, to: &reasons)
        }

        let printingJobID = parsePrintingJobID(from: first)

        return LPStatPrinterDetail(
            description: description,
            location: location,
            model: model,
            ppdPath: ppdPath,
            state: state,
            stateReasons: deduplicated(reasons),
            acceptsJobs: acceptsJobs,
            printingJobID: printingJobID
        )
    }

    private static func parsePrintingJobID(from firstLine: String) -> Int? {
        let lower = firstLine.lowercased()
        guard containsAny(lower, ["now printing", "is printing", "printing", "sta stampando", "in stampa"]) else {
            return nil
        }

        let pattern = #"([A-Za-z0-9_.-]+)-(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(firstLine.startIndex..<firstLine.endIndex, in: firstLine)
        guard let match = regex.firstMatch(in: firstLine, options: [], range: range) else {
            return nil
        }
        guard let idRange = Range(match.range(at: 2), in: firstLine) else { return nil }
        return Int(firstLine[idRange])
    }

    private static func reasonFromBareLine(_ line: String) -> String? {
        let lower = line.lowercased()
        for prefix in ["reason:", "reasons:", "motivo:", "motivi:"] {
            if lower.hasPrefix(prefix) {
                return String(line.dropFirst(prefix.count))
            }
        }
        for prefix in ["reason ", "motivo "] {
            if lower.hasPrefix(prefix) {
                return String(line.dropFirst(prefix.count))
            }
        }
        return nil
    }

    private static func appendReasons(_ value: String, to reasons: inout [String]) {
        let cleaned = value
            .replacingOccurrences(of: "(", with: " ")
            .replacingOccurrences(of: ")", with: " ")
            .replacingOccurrences(of: ",", with: " ")
            .replacingOccurrences(of: ";", with: " ")
        for token in cleaned.split(whereSeparator: { $0.isWhitespace }) {
            let reason = String(token).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !reason.isEmpty else { continue }
            let lower = reason.lowercased()
            if lower == "unknown" || lower == "sconosciuto" || lower == "sconosciuta" ||
                lower == "sconosciuti" || lower == "none" || lower == "nessuno" ||
                lower == "nessuna" || lower == "-" {
                continue
            }
            // date/time fragments from a trailing "since <date>" phrase
            if reason.allSatisfy({ $0.isNumber }) || reason.contains(":") ||
                ["mon","tue","wed","thu","fri","sat","sun","lun","mar","mer","gio","ven","sab","dom",
                 "jan","feb","mar","apr","may","jun","jul","aug","sep","oct","nov","dec",
                 "gen","feb","mag","giu","lug","ago","set","ott","nov","dic"].contains(lower) {
                continue
            }
            reasons.append(reason)
        }
    }

    private static func deduplicated(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values {
            let key = value.lowercased()
            if seen.insert(key).inserted {
                result.append(value)
            }
        }
        return result
    }

    private static func cleanedDetail(_ value: String) -> String? {
        let trimmed = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        let lower = trimmed.lowercased()
        if trimmed.isEmpty || lower == "none" || lower == "unknown" ||
            lower == "sconosciuto" || lower == "sconosciuta" || lower == "sconosciuti" ||
            lower == "nessuno" || lower == "nessuna" || lower == "(none)" ||
            lower == "(nessuno)" || lower == "not specified" {
            return nil
        }
        return trimmed
    }

    private static func normalizedLabel(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private static func containsAny(_ value: String, _ needles: [String]) -> Bool {
        needles.contains { value.contains($0) }
    }

    // MARK: - Jobs

    static func parseJobs(
        _ output: String,
        printerID: String,
        defaultState: JobState
    ) -> [PrintJob] {
        var records: [[String]] = []
        var current: [String]?

        for rawLine in output.components(separatedBy: .newlines) {
            if rawLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            let isIndented = rawLine.first == " " || rawLine.first == "\t"

            if !isIndented, let firstToken = rawLine.split(whereSeparator: { $0.isWhitespace }).first,
               jobIdentifier(String(firstToken)) != nil {
                if let current { records.append(current) }
                current = [rawLine]
            } else if current != nil {
                current?.append(rawLine)
            }
        }
        if let current { records.append(current) }

        return records.compactMap { record in
            parseJobRecord(record, requestedPrinterID: printerID, defaultState: defaultState)
        }
    }

    private static func parseJobRecord(
        _ record: [String],
        requestedPrinterID: String,
        defaultState: JobState
    ) -> PrintJob? {
        guard let header = record.first else { return nil }
        let tokens = header.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard let firstToken = tokens.first, let identifier = jobIdentifier(firstToken) else { return nil }

        let jobID = identifier.id
        let queue = identifier.queue ?? requestedPrinterID
        let owner = tokens.count > 1 && !tokens[1].isEmpty ? tokens[1] : nil

        var state = defaultState
        var stateReasons: [String] = []
        var documentCount: Int?

        if let headerState = stateFromJobHeader(header) {
            state = headerState
        }

        let status = parseStatusFromDetails(record)
        if let explicit = status.state {
            state = explicit
        }
        stateReasons.append(contentsOf: status.reasons)
        documentCount = status.documentCount

        let dateResult = parseDate(tokens: tokens)
        let createdAt = dateResult.date

        var title = ""
        if let dateEnd = dateResult.endIndex, dateEnd + 1 < tokens.count {
            let rest = Array(tokens[(dateEnd + 1)...])
            let numericPrefix = rest.prefix { Int($0) != nil }
            if !numericPrefix.isEmpty,
               numericPrefix.endIndex < rest.endIndex,
               rest[numericPrefix.endIndex] == "-",
               numericPrefix.endIndex + 1 < rest.endIndex {
                // Linux CUPS prints: <files> <copies> - <host> <title>.
                if documentCount == nil {
                    documentCount = numericPrefix.compactMap { Int($0) }.first
                }
                title = rest[(numericPrefix.endIndex + 2)...].joined(separator: " ")
            } else {
                title = rest.joined(separator: " ")
                if title == "-" { title = "" }
            }
        }

        return PrintJob(
            id: jobID,
            printerID: queue,
            title: title,
            state: state,
            stateReasons: deduplicated(stateReasons),
            impressionsCompleted: nil,
            impressionsTotal: nil,
            createdAt: createdAt,
            owner: owner,
            documentCount: documentCount
        )
    }

    /// Parses an optional first token like `L1800-42` or a bare numeric id.
    static func jobIdentifier(_ token: String) -> (queue: String?, id: Int)? {
        if let value = Int(token) {
            return (nil, value)
        }
        guard let dash = token.lastIndex(of: "-") else { return nil }
        let suffix = token[token.index(after: dash)...]
        guard !suffix.isEmpty, suffix.allSatisfy({ $0.isNumber }) else { return nil }
        let prefix = String(token[..<dash])
        guard !prefix.isEmpty else { return nil }
        guard let id = Int(suffix) else { return nil }
        return (prefix, id)
    }

    private struct ParsedJobStatus {
        var state: JobState?
        var reasons: [String]
        var documentCount: Int?
    }

    private static func stateFromJobHeader(_ header: String) -> JobState? {
        let lower = " \(header.lowercased()) "
        if containsAny(lower, [" now printing ", " is printing "]) { return .processing }
        if containsAny(lower, [" is held ", " has been held ", " job-held "]) { return .held }
        if containsAny(lower, [" has been canceled ", " has been cancelled ", " job-canceled "]) { return .canceled }
        if containsAny(lower, [" has aborted ", " job-aborted "]) { return .aborted }
        if containsAny(lower, [" is stopped ", " job-stopped "]) { return .stopped }
        if containsAny(lower, [" is completed ", " job-completed "]) { return .completed }
        return nil
    }

    private static func parseStatusFromDetails(_ record: [String]) -> ParsedJobStatus {
        var state: JobState?
        var reasons: [String] = []
        var documentCount: Int?

        for rawLine in record.dropFirst() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let colon = line.firstIndex(of: ":") else { continue }
            let label = normalizedLabel(String(line[..<colon]))
            let value = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }

            switch label {
            case "status", "stato", "job state", "stato processo":
                state = explicitJobState(value)
            case "alerts", "avvisi", "reasons", "motivi":
                appendReasons(value, to: &reasons)
                if let alertState = stateFromAlerts(value) {
                    state = alertState
                }
            case "files", "file":
                if documentCount == nil {
                    documentCount = Int(value.split(whereSeparator: { $0.isWhitespace }).first ?? "")
                }
            default:
                break
            }
        }

        return ParsedJobStatus(state: state, reasons: reasons, documentCount: documentCount)
    }

    private static func explicitJobState(_ value: String) -> JobState? {
        let lower = value.lowercased()
        if containsAny(lower, ["cancel", "annullat"]) { return .canceled }
        if containsAny(lower, ["abort", "interrott", "fallit"]) { return .aborted }
        if containsAny(lower, ["held", "hold", "sospes", "trattenut"]) { return .held }
        if containsAny(lower, ["processing", "printing", "in stampa", "stampando"]) { return .processing }
        if containsAny(lower, ["stopped", "fermat", "arrestat"]) { return .stopped }
        if containsAny(lower, ["completed", "completat", "terminat", "stampato"]) { return .completed }
        if containsAny(lower, ["pending", "waiting", "in attesa", "attesa"]) { return .pending }
        return nil
    }

    private static func stateFromAlerts(_ value: String) -> JobState? {
        let lower = value.lowercased()
        if lower.contains("job-canceled") || lower.contains("job-cancelled") { return .canceled }
        if lower.contains("job-aborted") { return .aborted }
        if lower.contains("job-held") || lower.contains("job-hold") { return .held }
        if lower.contains("job-printing") || lower.contains("job-processing") { return .processing }
        if lower.contains("job-completed") { return .completed }
        return nil
    }

    // MARK: - Dates

    private struct ParsedDate {
        var date: Date?
        var endIndex: Int?
    }

    private static func parseDate(tokens: [String]) -> ParsedDate {
        guard tokens.count >= 2 else { return ParsedDate(date: nil, endIndex: nil) }

        var startIndex: Int?
        for index in 1..<tokens.count {
            let token = normalizedWord(tokens[index])
            if weekdayTokens.contains(token) || monthTokens.contains(token) {
                startIndex = index
                break
            }
            if token.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil {
                startIndex = index
                break
            }
        }
        guard let start = startIndex else { return ParsedDate(date: nil, endIndex: nil) }

        // Try increasing windows and keep the longest successfully parsed
        // date. This covers the common `EEE MMM d HH:mm:ss yyyy` form and the
        // longer `EEE d MMM yyyy hh:mm:ss a zzz` form without guessing where
        // the title begins.
        var bestDate: Date?
        var bestEnd: Int?
        let maximumLength = min(9, tokens.count - start)
        if maximumLength >= 2 {
            for length in 2...maximumLength {
                let candidate = tokens[start..<(start + length)].joined(separator: " ")
                if let date = date(from: candidate) {
                    bestDate = date
                    bestEnd = start + length - 1
                }
            }
        }

        if bestEnd == nil {
            // Without a formatter match, at least locate a year token so the
            // title can still be extracted. Include a following clock time and
            // AM/PM marker when present.
            for index in start..<tokens.count {
                if isYear(tokens[index]) {
                    var end = index
                    if end + 1 < tokens.count, isClockTime(tokens[end + 1]) {
                        end += 1
                        if end + 1 < tokens.count, isMeridiem(tokens[end + 1]) {
                            end += 1
                        }
                    }
                    bestEnd = end
                    break
                }
            }
        }

        // A timezone abbreviation may follow an otherwise parsed date (for
        // example "Sat 31 Oct 2026 10:12:34 AM CET 1 1 - host Title"). Include
        // it so the title extraction does not mistake it for the first word.
        if let end = bestEnd {
            var extended = end
            while extended + 1 < tokens.count, isTimeZoneToken(tokens[extended + 1]) {
                extended += 1
            }
            bestEnd = extended
        }

        return ParsedDate(date: bestDate, endIndex: bestEnd)
    }

    private static let weekdayTokens: Set<String> = [
        "mon", "monday", "tue", "tues", "tuesday", "wed", "wednesday",
        "thu", "thur", "thurs", "thursday", "fri", "friday", "sat", "saturday",
        "sun", "sunday", "lun", "lunedi", "mar", "martedi", "mer", "mercoledi",
        "gio", "giovedi", "ven", "venerdi", "sab", "sabato", "dom", "domenica"
    ]

    private static let monthTokens: Set<String> = [
        "jan", "january", "feb", "february", "mar", "march", "apr", "april",
        "may", "jun", "june", "jul", "july", "aug", "august", "sep", "sept",
        "september", "oct", "october", "nov", "november", "dec", "december",
        "gen", "gennaio", "febbraio", "marzo", "apr", "aprile", "mag", "maggio",
        "giu", "giugno", "lug", "luglio", "ago", "agosto", "set", "settembre",
        "ott", "ottobre", "dic", "dicembre"
    ]

    private static let dateFormatterLock = NSLock()

    private static func date(from string: String) -> Date? {
        dateFormatterLock.lock()
        defer { dateFormatterLock.unlock() }
        for formatter in dateFormatters {
            if let date = formatter.date(from: string) {
                return date
            }
        }
        return nil
    }

    private static let dateFormatters: [DateFormatter] = {
        let formats = [
            "EEE MMM d HH:mm:ss yyyy",
            "EEE MMM d HH:mm:ss zzz yyyy",
            "EEE MMM d HH:mm:ss Z yyyy",
            "EEE MMM d HH:mm:ss yyyy zzz",
            "EEE MMM d HH:mm:ss yyyy Z",
            "EEE MMM d hh:mm:ss a yyyy",
            "EEE MMM d hh:mm:ss a zzz yyyy",
            "EEE d MMM yyyy HH:mm:ss",
            "EEE d MMM yyyy HH:mm:ss zzz",
            "EEE d MMM yyyy HH:mm:ss Z",
            "EEE d MMM yyyy hh:mm:ss a",
            "EEE d MMM yyyy hh:mm:ss a zzz",
            "EEE d MMM HH:mm:ss yyyy",
            "EEE d MMM HH:mm:ss yyyy zzz",
            "MMM d HH:mm:ss yyyy",
            "MMM d, yyyy HH:mm:ss",
            "d MMM yyyy HH:mm:ss",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd'T'HH:mm:ssZZZZZ"
        ]
        return formats.map { format in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone.current
            formatter.isLenient = false
            formatter.dateFormat = format
            return formatter
        }
    }()

    private static func normalizedWord(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .trimmingCharacters(in: .punctuationCharacters)
    }

    private static func isYear(_ value: String) -> Bool {
        guard value.count == 4, let year = Int(value) else { return false }
        return year >= 1900 && year <= 2200
    }

    private static func isClockTime(_ value: String) -> Bool {
        value.range(of: #"^\d{1,2}:\d{2}(:\d{2})?$"#, options: .regularExpression) != nil
    }

    private static func isMeridiem(_ value: String) -> Bool {
        let lower = value.lowercased()
        return lower == "am" || lower == "pm" || lower == "a.m." || lower == "p.m."
    }

    /// Looks like a timezone abbreviation or numeric UTC offset. Used only
    /// immediately after a date, so a document title that happens to start
    /// with a short capitalized word is not consumed.
    private static func isTimeZoneToken(_ value: String) -> Bool {
        // Case-sensitive on purpose: timezone tokens are printed in uppercase
        // ("CET", "UTC"), while a title such as "My" is mixed case.
        if value.range(of: #"^(?:[A-Z]{2,5}|(?:GMT|UTC)[+-]\d{1,2}(?::\d{2})?)$"#,
                       options: .regularExpression) != nil {
            return true
        }
        return false
    }

    // MARK: - Submission output

    static func parseSubmittedJob(
        _ output: String,
        printerID: String
    ) -> (id: Int, documentCount: Int?)? {
        // Most CUPS versions print: `request id is <queue>-<id> (1 file(s))`.
        // The localized text around it can change, but the queue-id and file
        // count shape does not.
        let detailedPattern = #"([A-Za-z0-9_.-]+)-(\d+)\s*\((\d+)\s+files?"#
        if let regex = try? NSRegularExpression(pattern: detailedPattern, options: [.caseInsensitive]) {
            let range = NSRange(output.startIndex..<output.endIndex, in: output)
            for match in regex.matches(in: output, options: [], range: range) {
                guard let queueRange = Range(match.range(at: 1), in: output),
                      let idRange = Range(match.range(at: 2), in: output),
                      let countRange = Range(match.range(at: 3), in: output) else { continue }
                let queue = String(output[queueRange])
                guard queue.caseInsensitiveCompare(printerID) == .orderedSame else { continue }
                guard let id = Int(output[idRange]), let count = Int(output[countRange]) else { continue }
                return (id, count)
            }
        }

        // Fallback for shorter or older messages. A bare numeric id is only
        // accepted when it follows the standard request-id phrase.
        let plainPattern = #"(?:request id is|id della richiesta(?: è| e)?|id richiesta(?: è| e)?)\s+(?:([A-Za-z0-9_.-]+)-)?(\d+)"#
        if let regex = try? NSRegularExpression(pattern: plainPattern, options: [.caseInsensitive]) {
            let range = NSRange(output.startIndex..<output.endIndex, in: output)
            for match in regex.matches(in: output, options: [], range: range) {
                let queueRange = match.range(at: 1)
                let queue = queueRange.location == NSNotFound
                    ? printerID
                    : Range(queueRange, in: output).map { String(output[$0]) }
                guard let idRange = Range(match.range(at: 2), in: output),
                      let id = Int(output[idRange]) else { continue }
                if let queue, queue.caseInsensitiveCompare(printerID) != .orderedSame {
                    continue
                }
                return (id, nil)
            }
        }

        return nil
    }
}
