import Foundation

// MARK: - PPD choices

/// Option values a queue actually advertises (parsed from `lpoptions -p -l`).
///
/// The print engine never guesses PPD keywords any more: unsupported values are
/// either mapped to an advertised equivalent or omitted, because CUPS silently
/// ignores invalid choices (the v1.0.1 B&W bug class).
struct PPDChoices: Equatable {
    /// The advertised color option keyword (`ColorModel`, `ColorMode`,
    /// `cupsColorModel`, …) exactly as printed by CUPS, or `nil` if the queue
    /// has no color option at all.
    var colorOptionKeyword: String? = nil
    /// Advertised color values, e.g. `["RGB", "Mono"]` or `["Gray", "RGB"]`.
    var colorValues: [String] = []
    /// Advertised resolution keywords, e.g. `["360x360dpi", "720x720dpi"]`.
    var resolutionValues: [String] = []
    /// Advertised `PageSize` keywords, when the queue advertises the option.
    var mediaValues: [String]?
    /// Advertised `MediaType` keywords (glossy/plain/…), when advertised.
    var mediaTypeValues: [String]?
    /// Advertised `InputSlot` keywords (tray names), when advertised.
    var inputSlotValues: [String]?
    /// Advertised `cupsPrintQuality` keywords, when advertised.
    var printQualityValues: [String]?

    static let none = PPDChoices()

    var hasColorOption: Bool { colorOptionKeyword != nil && !colorValues.isEmpty }

    // MARK: Grayscale / color keyword

    /// The queue's grayscale keyword. Epson ESC/P-R PPDs expose `Mono`; HP and
    /// most AirPrint drivers expose `Gray`. Falls back to `Gray` only when the
    /// PPD advertised no recognizable grayscale value (the value is then
    /// harmless: CUPS ignores unknown choices, and callers still get a color
    /// job instead of a crash).
    func grayscaleKeyword() -> String {
        let grays = colorValues.filter {
            let lower = $0.lowercased()
            return lower.contains("gray") || lower.contains("grey") || lower.contains("mono")
                || lower.contains("black")
        }
        // Prefer the plain "Gray"/"Mono" choice over 16-bit/variant entries.
        let plain = grays.first {
            let lower = $0.lowercased()
            return lower == "gray" || lower == "grey" || lower == "mono" || lower == "black"
        }
        return plain ?? grays.first ?? "Gray"
    }

    /// The queue's color keyword (`RGB`, `CMYK`, `Color`).
    func colorKeyword() -> String {
        let colors = colorValues.filter {
            let lower = $0.lowercased()
            return lower.contains("rgb") || lower.contains("cmyk")
                || lower.contains("color") || lower.contains("colour")
        }
        let plain = colors.first {
            let lower = $0.lowercased()
            return lower == "rgb" || lower == "cmyk" || lower == "color" || lower == "colour"
        }
        return plain ?? colors.first ?? "RGB"
    }

    /// Advertised resolution keyword nearest to `targetDPI` (locale-safe: the
    /// PPD keyword is always the part before a localized label).
    func resolutionKeyword(forTargetDPI targetDPI: Int) -> String? {
        let options: [(keyword: String, dpi: Int)] = resolutionValues.compactMap {
            guard let dpi = PPDChoices.dpi(forResolutionKeyword: $0) else { return nil }
            return (keyword: $0, dpi: dpi)
        }
        guard !options.isEmpty else { return nil }
        return options.min {
            abs($0.dpi - targetDPI) < abs($1.dpi - targetDPI)
        }?.keyword
    }

    /// DPI value of a `360x360dpi`/`600dpi` style keyword.
    static func dpi(forResolutionKeyword keyword: String) -> Int? {
        let lower = keyword.lowercased()
        guard lower.hasSuffix("dpi") else { return nil }
        let numeric = lower.dropLast(3)
        let first = numeric.split(separator: "x").first.map(String.init) ?? String(numeric)
        return Int(first)
    }

    // MARK: Media type / tray mapping

    /// Maps the app's media choice to an advertised `MediaType` keyword.
    /// `nil` means "do not send the option" (default/unsupported).
    func mediaTypeKeyword(for media: String) -> String? {
        guard let choices = mediaTypeValues, !choices.isEmpty else { return nil }
        func first(containing needles: [String]) -> String? {
            choices.first { choice in
                let lower = choice.lowercased()
                return needles.contains { lower.contains($0) }
            }
        }
        switch media {
        case "Glossy":
            return first(containing: ["glossy", "photo"])
        case "Photo":
            return first(containing: ["photo", "glossy"])
        case "Recycled":
            return first(containing: ["recycled", "recycle"])
        default:
            // "Plain" is the driver default: sending a concrete MediaType is
            // unnecessary and can surprise drivers with a "any"/numeric menu.
            return nil
        }
    }

    /// Maps the app's tray choice to an advertised `InputSlot` keyword.
    /// `nil` means "let the driver decide".
    func inputSlotKeyword(for tray: String) -> String? {
        guard let choices = inputSlotValues, !choices.isEmpty else { return nil }
        switch tray {
        case "tray1", "tray2":
            return choices.first { $0.caseInsensitiveCompare(tray) == .orderedSame }
        case "auto":
            return nil
        default:
            return choices.first { $0.caseInsensitiveCompare(tray) == .orderedSame }
        }
    }
}

// MARK: - lpoptions parser

enum PPDOptionParser {
    /// Parses `lpoptions -p <queue> -l` output.
    ///
    /// CUPS localizes the label after the `/` in `Keyword/Label:`; the keyword
    /// before it is stable, so only that part is compared. Choice tokens may be
    /// `value`, `*value` (default) or `value/Localized Label`; only the keyword
    /// before `/` is kept.
    static func parse(_ lpoptionsOutput: String) -> PPDChoices {
        var parsed = PPDChoices.none
        for rawLine in lpoptionsOutput.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, let colon = line.firstIndex(of: ":") else { continue }
            let keyPart = String(line[..<colon])
            let keyword = keyPart.split(separator: "/").first
                .map { String($0).trimmingCharacters(in: .whitespaces) } ?? keyPart
            let lowerKey = keyword.lowercased()
            let valuePart = String(line[line.index(after: colon)...])
            let tokens = valuePart
                .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "," })
                .map { String($0).replacingOccurrences(of: "*", with: "") }
                .filter { !$0.isEmpty }
            let choices = tokens.map { token in
                token.split(separator: "/").first.map(String.init) ?? token
            }

            switch lowerKey {
            case "colormodel", "colormode", "cupscolormodel":
                if parsed.colorOptionKeyword == nil, !choices.isEmpty {
                    parsed.colorOptionKeyword = keyword
                    parsed.colorValues = choices
                }
            case "resolution", "outputresolution", "cupsresolution":
                let resolutions = choices.filter { PPDChoices.dpi(forResolutionKeyword: $0) != nil }
                if !resolutions.isEmpty { parsed.resolutionValues = resolutions }
            case "pagesize":
                if !choices.isEmpty { parsed.mediaValues = choices }
            case "mediatype":
                if !choices.isEmpty { parsed.mediaTypeValues = choices }
            case "inputslot":
                if !choices.isEmpty { parsed.inputSlotValues = choices }
            case "cupsprintquality", "printquality":
                if !choices.isEmpty { parsed.printQualityValues = choices }
            default:
                break
            }
        }
        return parsed
    }
}

// MARK: - lp argument builder

/// Pure builder for the `lp` arguments of one manual-duplex pass.
///
/// Invariants (v1.0.2):
/// - always `sides=one-sided`: manual duplex prints one side per pass, so no
///   `Duplex=`/`DuplexNoTumble` style option is ever emitted (the old code sent
///   non-existent PPD keywords);
/// - every optional option is validated against the queue's advertised choices
///   and omitted when unsupported;
/// - orientation and scale are passed verbatim by the caller (the flow planner
///   computes them with `PrintMath`);
/// - color uses the queue's advertised color option keyword and value.
enum PrintOptionBuilder {
    static func arguments(
        file: URL,
        printer: String,
        pageRange: String?,
        paperMediaName: String,
        orientationRequested: Int?,
        scale: Int,
        color: Bool,
        copies: Int,
        media: String,
        tray: String,
        title: String,
        ppd: PPDChoices,
        targetDPI: Int? = nil
    ) -> [String] {
        var args: [String] = [
            "-d", printer,
            "-t", title,
            "-n", "\(max(copies, 1))",
            "-o", "media=\(paperMediaName)",
            "-o", "page-set=all",
            "-o", "number-up=1",
        ]
        if let orientationRequested {
            args += ["-o", "orientation-requested=\(orientationRequested)"]
        }
        args += [
            "-o", "fit-to-page=false",
            "-o", "scaling=\(scale)",
            "-o", "sides=one-sided",
        ]

        // Color: never guess a keyword the queue does not advertise. When the
        // queue exposes no color option we still send the conventional
        // ColorModel so the intent survives (CUPS ignores unknown values).
        let colorOption = ppd.colorOptionKeyword ?? "ColorModel"
        let colorValue = color ? ppd.colorKeyword() : ppd.grayscaleKeyword()
        args += ["-o", "\(colorOption)=\(colorValue)"]

        // Resolution when the queue advertises one; otherwise fall back to the
        // integer print-quality attribute (IPP, locale-independent).
        if let targetDPI {
            if let resolution = ppd.resolutionKeyword(forTargetDPI: targetDPI) {
                args += ["-o", "Resolution=\(resolution)"]
            } else {
                args += ["-o", "print-quality=\(qualityLevel(forDPI: targetDPI))"]
            }
        }

        if let range = pageRange, !range.isEmpty {
            args += ["-o", "page-ranges=\(range)"]
        }
        if let mediaType = ppd.mediaTypeKeyword(for: media) {
            args += ["-o", "MediaType=\(mediaType)"]
        }
        if let slot = ppd.inputSlotKeyword(for: tray) {
            args += ["-o", "InputSlot=\(slot)"]
        }
        args.append(file.path)
        return args
    }

    /// IPP `print-quality`: 3 draft, 4 normal, 5 high.
    static func qualityLevel(forDPI dpi: Int) -> Int {
        dpi <= 180 ? 3 : dpi <= 366 ? 4 : 5
    }
}

// MARK: - Submission output parsing

enum SubmittedJobParser {
    /// Extracts the CUPS job id from `lp` output.
    ///
    /// Mirrors FlipStackCore's `LPStatParser.parseSubmittedJob` (which is
    /// module-internal): the queue-id/file-count shape is locale independent,
    /// so it is tried first, then the localized "request id is" phrases.
    static func parse(_ output: String, printerID: String) -> (id: Int, documentCount: Int?)? {
        guard !output.isEmpty else { return nil }
        let detailed = #"([A-Za-z0-9_.-]+)-(\d+)\s*\((\d+)\s+files?"#
        if let regex = try? NSRegularExpression(pattern: detailed, options: [.caseInsensitive]) {
            let range = NSRange(output.startIndex..<output.endIndex, in: output)
            for match in regex.matches(in: output, options: [], range: range) {
                guard let queueRange = Range(match.range(at: 1), in: output),
                      let idRange = Range(match.range(at: 2), in: output),
                      let countRange = Range(match.range(at: 3), in: output) else { continue }
                let queue = String(output[queueRange])
                guard queue.caseInsensitiveCompare(printerID) == .orderedSame,
                      let id = Int(output[idRange]),
                      let count = Int(output[countRange]) else { continue }
                return (id, count)
            }
        }

        let plain = #"(?:request id is|id della richiesta(?: è| e)?|id richiesta(?: è| e)?|richiesta(?: id)?(?: è| e)?)\s+(?:([A-Za-z0-9_.-]+)-)?(\d+)"#
        if let regex = try? NSRegularExpression(pattern: plain, options: [.caseInsensitive]) {
            let range = NSRange(output.startIndex..<output.endIndex, in: output)
            for match in regex.matches(in: output, options: [], range: range) {
                let queue: String?
                if match.range(at: 1).location == NSNotFound {
                    queue = printerID
                } else {
                    queue = Range(match.range(at: 1), in: output).map { String(output[$0]) }
                }
                guard let idRange = Range(match.range(at: 2), in: output),
                      let id = Int(output[idRange]),
                      queue?.caseInsensitiveCompare(printerID) == .orderedSame else { continue }
                return (id, nil)
            }
        }
        return nil
    }
}

// MARK: - Submission evaluation

/// Pure decision of whether an `lp` invocation spooled a job.
///
/// v1.0.2: success is derived from the process exit status **and** a parsed job
/// id — never from a substring such as `contains("error")`, which is
/// locale-dependent and used to report failed prints as successes.
enum PrintSubmissionEvaluator {
    static func evaluate(exitStatus: Int32, output: String, printerID: String) -> PrintSubmissionResult {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard exitStatus == 0 else {
            let message = trimmed.isEmpty
                ? "Print failed: lp exited with status \(exitStatus)."
                : trimmed
            return PrintSubmissionResult(jobID: nil, succeeded: false, message: message)
        }
        guard let submitted = SubmittedJobParser.parse(trimmed, printerID: printerID) else {
            // A zero exit status without a job id is not a success: the job may
            // not exist at all (broken/missing lp, swallowed output, wrong
            // locale). Fail closed so the UI never claims a print that did not
            // happen.
            let message = trimmed.isEmpty
                ? "Print failed: lp did not report a job id."
                : "Print failed: unexpected lp output: \(trimmed)"
            return PrintSubmissionResult(jobID: nil, succeeded: false, message: message)
        }
        return PrintSubmissionResult(
            jobID: submitted.id,
            succeeded: true,
            message: trimmed.isEmpty ? "Job \(submitted.id) submitted." : trimmed
        )
    }
}
