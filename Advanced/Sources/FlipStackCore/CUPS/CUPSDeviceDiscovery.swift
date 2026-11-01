import Foundation

/// The physical connection used by a discovered printer device.
public enum PrinterTransport: String, Codable, Sendable {
    case wifi
    case ethernet
    case usb
    case network
    case unknown
}

/// A device reported by `lpinfo -v`. It is a discovery candidate, not a CUPS
/// queue: FlipStack prints through queues, so a candidate must be added as a
/// queue with the system print settings before it can receive jobs.
public struct DiscoveredPrinter: Identifiable, Hashable, Sendable {
    public var id: String { uri }
    public var name: String
    public var model: String?
    public var uri: String
    public var transport: PrinterTransport

    public init(
        name: String,
        model: String? = nil,
        uri: String,
        transport: PrinterTransport
    ) {
        self.name = name
        self.model = model
        self.uri = uri
        self.transport = transport
    }
}

/// A source of printer device candidates. Implementations must not require a
/// configured CUPS queue.
public protocol PrinterDiscovering: Sendable {
    func discoverDevices() async throws -> [DiscoveredPrinter]
}

/// Discovery failures are reported as values, never crashes. Callers can show
/// the localized description directly in an error banner.
public enum PrinterDiscoveryError: LocalizedError, Equatable, Sendable {
    case toolNotFound(String)
    case timedOut(String)
    case commandFailed(status: Int32, message: String)

    public var errorDescription: String? {
        switch self {
        case .toolNotFound(let path):
            return "Printer discovery is unavailable because lpinfo was not found at \(path)."
        case .timedOut(let tool):
            return "\(tool) did not respond in time while listing available printers."
        case .commandFailed(let status, let message):
            let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
            if status < 0 {
                return detail.isEmpty
                    ? "Printer discovery could not run lpinfo."
                    : "Printer discovery could not run lpinfo: \(detail)"
            }
            return detail.isEmpty
                ? "lpinfo could not list available printers (exit status \(status))."
                : "lpinfo could not list available printers (exit status \(status)): \(detail)"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .toolNotFound:
            return "Install or repair the CUPS command-line tools, then try again."
        case .timedOut:
            return "Wait a moment and refresh the printer list. USB and network backends may be slow to answer."
        case .commandFailed:
            return "Check that the CUPS service is running and that this user can query it, then try again."
        }
    }
}

/// Discovers printer devices through `/usr/sbin/lpinfo -v`.
///
/// The command is launched directly, without a shell, with a C/English locale
/// and a bounded timeout long enough for the CUPS backends to answer. Output is parsed defensively; malformed lines
/// are ignored and a failed command is surfaced as `PrinterDiscoveryError`.
public struct CUPSDeviceDiscovery: PrinterDiscovering {
    private static let lpinfoURL = URL(fileURLWithPath: "/usr/sbin/lpinfo")
    private static let defaultTimeout: TimeInterval = 25

    private let runner: any CUPSCommandRunning
    private let timeout: TimeInterval

    public init() {
        self.runner = CUPSProcessRunner()
        self.timeout = Self.defaultTimeout
    }

    init(runner: any CUPSCommandRunning, timeout: TimeInterval = 25) {
        self.runner = runner
        self.timeout = timeout
    }

    public func discoverDevices() async throws -> [DiscoveredPrinter] {
        let result: CUPSCommandResult
        do {
            result = try await runner.run(
                executable: Self.lpinfoURL,
                arguments: ["-v"],
                timeout: timeout
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as CUPSProcessError {
            switch error {
            case .executableNotFound(let path):
                throw PrinterDiscoveryError.toolNotFound(path)
            case .timedOut(let tool):
                throw PrinterDiscoveryError.timedOut(tool)
            case .launchFailed(let message):
                throw PrinterDiscoveryError.commandFailed(status: -1, message: message)
            }
        } catch {
            throw PrinterDiscoveryError.commandFailed(
                status: -1,
                message: error.localizedDescription
            )
        }

        guard result.status == 0 else {
            throw PrinterDiscoveryError.commandFailed(
                status: result.status,
                message: result.combinedMessage
            )
        }

        return Self.parseDevices(from: result.stdoutText)
    }

    // MARK: - Parsing

    /// Parses the complete output of `lpinfo -v`, removing duplicates and
    /// returning a stable order: USB first, then Wi-Fi, Ethernet, other
    /// network transports, and finally unknown transports; ties sort by name
    /// and then URI.
    public static func parseDevices(from output: String) -> [DiscoveredPrinter] {
        var seen = Set<String>()
        var devices: [DiscoveredPrinter] = []

        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            let lower = line.lowercased()
            if lower.hasPrefix("lpinfo:") ||
                lower.hasPrefix("debug:") ||
                lower.hasPrefix("warning:") ||
                lower.hasPrefix("#") {
                continue
            }

            guard let device = parseDeviceLine(line) else { continue }
            let key = device.uri.lowercased()
            guard seen.insert(key).inserted else { continue }
            devices.append(device)
        }

        devices.sort(by: isOrderedBefore)
        return devices
    }

    static func parseDeviceLine(_ line: String) -> DiscoveredPrinter? {
        let parts = line.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
        guard parts.count == 2 else { return nil }

        let kind = parts[0].lowercased()
        let rawURI = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawURI.isEmpty else { return nil }

        // CUPS backends percent-encode spaces. Taking the first whitespace
        // token also tolerates a line that carries an unencoded trailing name.
        let uri = rawURI
            .split(whereSeparator: { $0.isWhitespace })
            .first
            .map(String.init) ?? rawURI

        guard hasValidPercentEncoding(uri),
              let (scheme, rest) = splitScheme(uri) else {
            return nil
        }

        let ignoredKinds: Set<String> = ["serial", "file", "scsi", "cups-brf", "parallel"]
        let ignoredSchemes: Set<String> = [
            "cups-brf", "file", "scsi", "serial", "parallel", "beh"
        ]
        guard !ignoredKinds.contains(kind), !ignoredSchemes.contains(scheme) else {
            return nil
        }

        switch scheme {
        case "dnssd", "mdns":
            return parseDNSSD(uri: uri, rest: rest)
        case "ipp", "ipps", "http", "https":
            return parseIPP(uri: uri, rest: rest)
        case "socket":
            return parseSocket(uri: uri, rest: rest)
        case "lpd":
            return parseLPD(uri: uri, rest: rest)
        case "usb":
            return parseUSB(uri: uri, rest: rest)
        case "hp":
            return parseHP(uri: uri, rest: rest)
        default:
            return nil
        }
    }

    private struct URIParts {
        var authority: String
        var path: String
        var query: String
    }

    private static func splitScheme(_ uri: String) -> (scheme: String, rest: String)? {
        guard let colon = uri.firstIndex(of: ":") else { return nil }
        let scheme = String(uri[..<colon]).lowercased()
        guard !scheme.isEmpty,
              scheme.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." }) else {
            return nil
        }

        var rest = String(uri[uri.index(after: colon)...])
        if rest.hasPrefix("//") {
            rest.removeFirst(2)
        }
        return (scheme, rest)
    }

    private static func splitRest(_ rest: String) -> URIParts {
        var value = rest
        var query = ""

        if let question = value.firstIndex(of: "?") {
            query = String(value[value.index(after: question)...])
            value = String(value[..<question])
        }
        if let fragment = value.firstIndex(of: "#") {
            value = String(value[..<fragment])
        }

        var path = ""
        if let slash = value.firstIndex(of: "/") {
            path = String(value[value.index(after: slash)...])
            value = String(value[..<slash])
        }

        return URIParts(authority: value, path: path, query: query)
    }

    private static func parseDNSSD(uri: String, rest: String) -> DiscoveredPrinter? {
        let parts = splitRest(rest)
        var instance = decoded(parts.authority)
        guard !instance.isEmpty else { return nil }

        instance = stripBonjourService(from: instance)
        let name = collapsed(instance)
        guard !name.isEmpty else { return nil }

        return DiscoveredPrinter(
            name: name,
            model: name,
            uri: uri,
            transport: .wifi
        )
    }

    private static func parseIPP(uri: String, rest: String) -> DiscoveredPrinter? {
        let parts = splitRest(rest)
        guard let initialHost = host(from: parts.authority) else { return nil }
        var host = initialHost
        guard !host.isEmpty else { return nil }

        let isBonjour = containsBonjourServiceType(host)
        if isBonjour {
            host = collapsed(stripBonjourService(from: host))
        }

        let segments = pathSegments(from: parts.path)
        let queue = segments.last { !genericIPPPathSegments.contains($0.lowercased()) }
        let name = collapsed(queue ?? host)
        guard !name.isEmpty else { return nil }

        return DiscoveredPrinter(
            name: name,
            model: nil,
            uri: uri,
            transport: isBonjour ? .wifi : .network
        )
    }

    private static func parseSocket(uri: String, rest: String) -> DiscoveredPrinter? {
        let parts = splitRest(rest)
        guard let host = host(from: parts.authority), !host.isEmpty else { return nil }

        return DiscoveredPrinter(
            name: collapsed(host),
            model: nil,
            uri: uri,
            transport: .network
        )
    }

    private static func parseLPD(uri: String, rest: String) -> DiscoveredPrinter? {
        let parts = splitRest(rest)
        guard let host = host(from: parts.authority) else { return nil }
        let segments = pathSegments(from: parts.path)
        let queue = segments.last

        guard !host.isEmpty || queue != nil else { return nil }
        let name = collapsed(queue ?? host)

        return DiscoveredPrinter(
            name: name,
            model: nil,
            uri: uri,
            transport: .network
        )
    }

    private static func parseUSB(uri: String, rest: String) -> DiscoveredPrinter? {
        let parts = splitRest(rest)
        let authority = decoded(parts.authority)
        guard !authority.isEmpty else { return nil }

        var segments = [authority]
        segments.append(contentsOf: pathSegments(from: parts.path))
        segments = segments.filter { !$0.isEmpty }
        guard let vendor = segments.first else { return nil }

        let product = collapsed(segments.dropFirst().joined(separator: " "))
        let name = collapsed([vendor, product].filter { !$0.isEmpty }.joined(separator: " "))
        guard !name.isEmpty else { return nil }

        return DiscoveredPrinter(
            name: name,
            model: product.isEmpty ? nil : product,
            uri: uri,
            transport: .usb
        )
    }

    private static func parseHP(uri: String, rest: String) -> DiscoveredPrinter? {
        let parts = splitRest(rest)
        var segments = pathSegments(from: parts.path)
        if segments.isEmpty, !parts.authority.isEmpty {
            segments = [decoded(parts.authority)]
        }

        let backendMarkers: Set<String> = ["usb", "net", "direct", "socket", "hp"]
        segments = segments.filter { !backendMarkers.contains($0.lowercased()) }
        guard !segments.isEmpty else { return nil }

        // HP backend names use underscores in place of spaces.
        let product = collapsed(
            segments
                .map { $0.replacingOccurrences(of: "_", with: " ") }
                .joined(separator: " ")
        )
        guard !product.isEmpty else { return nil }

        return DiscoveredPrinter(
            name: product,
            model: product,
            uri: uri,
            transport: .usb
        )
    }

    // MARK: - URI helpers

    private static func host(from authority: String) -> String? {
        var value = authority
        guard !value.isEmpty else { return nil }

        if let at = value.lastIndex(of: "@") {
            value = String(value[value.index(after: at)...])
        }

        if value.hasPrefix("["), let close = value.firstIndex(of: "]") {
            let start = value.index(after: value.startIndex)
            let host = decoded(String(value[start..<close]))
            return host.isEmpty ? nil : host
        }

        if let colon = value.lastIndex(of: ":"), colon < value.endIndex {
            let portStart = value.index(after: colon)
            let port = value[portStart...]
            guard !port.isEmpty, port.allSatisfy({ $0.isNumber }) else {
                return nil
            }
            value = String(value[..<colon])
        }

        let host = decoded(value)
        return host.isEmpty ? nil : host
    }

    private static func hasValidPercentEncoding(_ value: String) -> Bool {
        var index = value.startIndex
        while index < value.endIndex {
            if value[index] == "%" {
                let first = value.index(after: index)
                guard first < value.endIndex else { return false }
                let second = value.index(after: first)
                guard second < value.endIndex else { return false }
                guard value[first].isHexDigit, value[second].isHexDigit else {
                    return false
                }
                index = value.index(after: second)
            } else {
                index = value.index(after: index)
            }
        }
        return true
    }

    private static func pathSegments(from path: String) -> [String] {
        path
            .split(separator: "/")
            .map { decoded(String($0)) }
            .filter { !$0.isEmpty }
    }

    private static func decoded(_ value: String) -> String {
        let text = value.removingPercentEncoding ?? value
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func collapsed(_ value: String) -> String {
        value
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripBonjourService(from instance: String) -> String {
        var value = instance
        while value.hasSuffix(".") { value.removeLast() }

        let pattern = #"\._[A-Za-z0-9-]+\._(?:tcp|udp)(?:\.local)?$"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            if let match = regex.firstMatch(in: value, options: [], range: range),
               let matchRange = Range(match.range, in: value) {
                value = String(value[..<matchRange.lowerBound])
            }
        }

        if value.lowercased().hasSuffix(".local") {
            value = String(value.dropLast(6))
        }
        while value.hasSuffix(".") { value.removeLast() }
        return value
    }

    private static func containsBonjourServiceType(_ value: String) -> Bool {
        let lower = value.lowercased()
        return lower.contains("._ipp._tcp") ||
            lower.contains("._ipps._tcp") ||
            lower.contains("._airprint._tcp") ||
            lower.contains("airprint")
    }

    private static let genericIPPPathSegments: Set<String> = [
        "ipp", "ipps", "print", "printer", "printers", "queue", "queues",
        "rfc", "http", "https", "web", "auto"
    ]

    // MARK: - Ordering

    private static func isOrderedBefore(_ lhs: DiscoveredPrinter, _ rhs: DiscoveredPrinter) -> Bool {
        let leftRank = transportRank(lhs.transport)
        let rightRank = transportRank(rhs.transport)
        if leftRank != rightRank { return leftRank < rightRank }

        let leftName = sortKey(lhs.name)
        let rightName = sortKey(rhs.name)
        if leftName != rightName { return leftName < rightName }
        if lhs.name != rhs.name { return lhs.name < rhs.name }
        return lhs.uri < rhs.uri
    }

    private static func transportRank(_ transport: PrinterTransport) -> Int {
        switch transport {
        case .usb: return 0
        case .wifi: return 1
        case .ethernet: return 2
        case .network: return 3
        case .unknown: return 4
        }
    }

    private static func sortKey(_ value: String) -> String {
        value
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased()
    }
}
