import Foundation

/// Builds the deterministic `lp` argument list for a print request.
///
/// Page order is never reversed here. FlipStack handles the physical stack
/// after the first pass, so adding `output-order=reverse` (or any similar
/// option) would undo that work.
public enum CUPSOptionBuilder {
    /// Options owned by the request itself. They are ignored if a caller
    /// persisted one in `driverOptions`; in particular, page reversal is never
    /// accepted from a PPD selection.
    private static let reservedKeys: Set<String> = [
        "page-set", "pageset", "page-ranges", "pageranges",
        "number-up", "numberup", "orientation-requested", "orientationrequested",
        "output-order", "outputorder", "page-order", "pageorder",
        "reverse-order", "reverseorder", "page-reversal", "pagereversal", "reverse"
    ]

    /// The ordered `-o` pairs sent to `lp`.
    public static func optionPairs(for request: PrintRequest) -> [(String, String)] {
        var pairs: [(String, String)] = []

        if request.pageSet != .all {
            pairs.append(("page-set", request.pageSet.cupsValue))
        }

        if !request.pageRanges.isEmpty {
            let value = request.pageRanges.map(\.cupsValue).joined(separator: ",")
            pairs.append(("page-ranges", value))
        }

        if request.numberUp > 1 {
            pairs.append(("number-up", String(request.numberUp)))
        }

        if request.orientation != .portrait {
            pairs.append(("orientation-requested", request.orientation.cupsValue))
        }

        if request.fitToPage {
            pairs.append(("fit-to-page", "true"))
        }

        let driverOptions = request.driverOptions
            .filter { key, _ in !reservedKeys.contains(normalizedKey(key)) }
            .sorted { $0.key < $1.key }

        for (key, value) in driverOptions {
            pairs.append((key, value))
        }

        return pairs
    }

    /// The complete argument list after `lp`, with the input path last.
    public static func arguments(for request: PrintRequest) -> [String] {
        var arguments = ["-d", request.printerID, "-t", request.title]

        if request.copies > 1 {
            arguments.append("-n")
            arguments.append(String(request.copies))
        }

        for (key, value) in optionPairs(for: request) {
            arguments.append("-o")
            arguments.append("\(key)=\(value)")
        }

        arguments.append(request.fileURL.path)
        return arguments
    }

    private static func normalizedKey(_ key: String) -> String {
        key
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
    }
}
