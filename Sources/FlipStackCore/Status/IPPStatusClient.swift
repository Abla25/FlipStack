import Foundation

/// Direct IPP status client for local CUPS queues.
///
/// The client sends `Get-Printer-Attributes` over HTTP to CUPS and falls back
/// to an SNMP walk of the Printer MIB for supply levels when IPP works but
/// reports no markers, or when IPP itself is unavailable. It never throws and
/// never waits longer than its configured timeout for the IPP request.
public struct IPPStatusClient: PrinterStatusProviding, Sendable {
    private let cupsHost: String?
    private let snmpEnabled: Bool
    private let timeout: TimeInterval
    private let snmpCommunity: String
    private let session: IPPSession
    private let requestCounter: IPPRequestCounter

    public init() {
        self.init(cupsHost: nil, snmpEnabled: true, timeout: 2.5)
    }

    public init(
        cupsHost: String? = nil,
        snmpEnabled: Bool = true,
        timeout: TimeInterval = 2.5,
        snmpCommunity: String = "public"
    ) {
        self.cupsHost = cupsHost
        self.snmpEnabled = snmpEnabled
        self.timeout = max(timeout, 0.1)
        self.snmpCommunity = snmpCommunity
        self.session = IPPSession(timeout: max(timeout, 0.1))
        self.requestCounter = IPPRequestCounter()
    }

    public func status(for printer: Printer) async -> PrinterStatus {
        guard !Task.isCancelled else {
            return IPPStatusMapper.unavailable(for: printer, note: "Status request was cancelled.")
        }

        let url = Self.endpointURL(queue: printer.id, cupsHost: cupsHost)
        let requestID = requestCounter.next()
        let ippRequest = IPPRequest(
            printerURI: Self.ippPrinterURI(for: url),
            requestID: requestID
        )

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/ipp", forHTTPHeaderField: "Content-Type")
        request.setValue("application/ipp", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpBody = ippRequest.encoded()

        do {
            let result = try await fetch(request)
            let response = try Self.response(from: result)
            return await status(for: printer, response: response)
        } catch {
            if Task.isCancelled {
                return IPPStatusMapper.unavailable(for: printer, note: "Status request was cancelled.")
            }
            let note = Self.note(for: error, host: url.host, port: url.port)
            let snmpSupplies = await snmpSupplies(for: printer)
            return IPPStatusMapper.fallback(
                for: printer,
                note: note,
                snmpSupplies: snmpSupplies
            )
        }
    }

    // MARK: - Response handling

    private func status(for printer: Printer, response: IPPResponse) async -> PrinterStatus {
        guard response.isSuccess else {
            let snmpSupplies = await snmpSupplies(for: printer)
            return IPPStatusMapper.status(
                from: response,
                printer: printer,
                snmpSupplies: snmpSupplies
            )
        }

        let base = IPPStatusMapper.status(from: response, printer: printer)
        guard base.supplies.isEmpty, snmpEnabled else { return base }

        let supplies = await snmpSupplies(for: printer)
        guard !supplies.isEmpty else { return base }

        return IPPStatusMapper.status(
            from: response,
            printer: printer,
            snmpSupplies: supplies
        )
    }

    private static func response(from result: HTTPResult) throws -> IPPResponse {
        if let parsed = IPPResponseParser.parseOrNil(result.data),
           result.statusCode == 200 || !parsed.isSuccess {
            return parsed
        }
        if result.statusCode != 200 {
            throw StatusFetchError.http(result.statusCode)
        }
        throw StatusFetchError.invalidResponse
    }

    // MARK: - SNMP fallback

    private func snmpSupplies(for printer: Printer) async -> [SupplyLevel] {
        guard snmpEnabled, let host = Self.snmpHost(from: printer.deviceURI) else {
            return []
        }

        let budget = min(timeout, 1.5)
        let probe = SNMPProbe(host: host, community: snmpCommunity, timeout: budget)

        // A continuation race guarantees the caller resumes within the budget
        // even if DNS or a blocking socket call inside the detached probe
        // stalls. The losing side resumes the continuation as a no-op.
        return await withCheckedContinuation { continuation in
            let state = SNMPResumeState()
            Task.detached(priority: .utility) {
                state.resume(continuation, with: probe.run())
            }
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + budget + 0.2
            ) {
                state.resume(continuation, with: [])
            }
        }
    }

    // MARK: - Networking

    private func fetch(_ request: URLRequest) async throws -> HTTPResult {
        let session = self.session
        let timeout = self.timeout
        let timeoutNanoseconds = UInt64(min(timeout, 300) * 1_000_000_000)

        return try await withThrowingTaskGroup(of: HTTPResult.self) { group in
            group.addTask {
                let (data, response) = try await session.session.data(for: request)
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 200
                return HTTPResult(data: data, statusCode: statusCode)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                throw StatusFetchError.timedOut
            }

            guard let result = try await group.next() else {
                throw StatusFetchError.timedOut
            }
            group.cancelAll()
            return result
        }
    }

    private static func note(for error: Error, host: String?, port: Int?) -> String {
        let endpoint: String
        if let host, let port {
            endpoint = "\(host):\(port)"
        } else if let host {
            endpoint = host
        } else {
            endpoint = "CUPS"
        }

        if let error = error as? StatusFetchError {
            switch error {
            case .timedOut:
                return "CUPS did not respond in time."
            case .invalidResponse:
                return "The printer returned an unreadable IPP response."
            case .http(let code):
                switch code {
                case 401:
                    return "CUPS requires authentication (HTTP 401)."
                case 403:
                    return "CUPS denied access to the printer (HTTP 403)."
                default:
                    return "CUPS returned HTTP \(code)."
                }
            }
        }

        if error is IPPParseError {
            return "The printer returned an unreadable IPP response."
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return "CUPS did not respond in time."
            case .cancelled:
                return "Status request was cancelled."
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return "Could not reach CUPS at \(endpoint)."
            case .networkConnectionLost, .notConnectedToInternet:
                return "The network connection to \(endpoint) was lost."
            default:
                return "Could not reach CUPS at \(endpoint)."
            }
        }

        return "Live status is not available right now."
    }

    // MARK: - Endpoint helpers

    static func endpointURL(
        queue: String,
        cupsHost: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        let configured = cupsHost?.trimmingCharacters(in: .whitespacesAndNewlines)
        let environmentValue = environment["CUPS_SERVER"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let original: String
        if let configured, !configured.isEmpty {
            original = configured
        } else if let environmentValue, !environmentValue.isEmpty {
            original = environmentValue
        } else {
            original = "localhost:631"
        }

        // A UNIX domain socket cannot be reached through URLSession. Use the
        // conventional local CUPS TCP endpoint in that case.
        if original.hasPrefix("/") {
            return fallbackURL(queue: queue)
        }

        var server = original
        var hadScheme = false
        let lower = server.lowercased()

        if lower.hasPrefix("ipp://") {
            server = "http://" + String(server.dropFirst("ipp://".count))
        } else if lower.hasPrefix("ipps://") {
            server = "https://" + String(server.dropFirst("ipps://".count))
        } else if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            hadScheme = true
        } else {
            server = "http://" + server
        }

        while server.hasSuffix("/") {
            server.removeLast()
        }

        guard var components = URLComponents(string: server), components.host != nil else {
            return fallbackURL(queue: queue)
        }
        if components.scheme == nil {
            components.scheme = "http"
        }
        if !hadScheme && components.port == nil {
            components.port = 631
        }

        let encodedQueue = queue.addingPercentEncoding(withAllowedCharacters: pathSegmentAllowed)
            ?? queue
        let basePath = components.percentEncodedPath.hasSuffix("/")
            ? String(components.percentEncodedPath.dropLast())
            : components.percentEncodedPath
        components.percentEncodedPath = basePath + "/printers/" + encodedQueue

        return components.url ?? fallbackURL(queue: queue)
    }

    /// The `printer-uri` operation attribute uses the IPP URI scheme, while
    /// the HTTP POST itself still targets the CUPS web endpoint.
    static func ippPrinterURI(for url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        components.scheme = components.scheme?.lowercased() == "https" ? "ipps" : "ipp"
        return components.url?.absoluteString ?? url.absoluteString
    }

    static func snmpHost(from deviceURI: String?) -> String? {
        guard let raw = deviceURI?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              ["socket", "ipp", "ipps", "lpd", "http", "https"].contains(scheme),
              let host = url.host,
              !host.isEmpty else {
            return nil
        }

        let lower = host.lowercased()
        if lower == "localhost" || lower == "127.0.0.1" || lower == "::1" {
            return nil
        }
        return host
    }

    private static func fallbackURL(queue: String) -> URL {
        let encodedQueue = queue.addingPercentEncoding(withAllowedCharacters: pathSegmentAllowed)
            ?? queue
        return URL(string: "http://localhost:631/printers/\(encodedQueue)")
            ?? URL(string: "http://localhost:631/")!
    }

    private static let pathSegmentAllowed: CharacterSet = {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~!$&'()*+,;=:@")
        return allowed
    }()
}

private struct HTTPResult: Sendable {
    let data: Data
    let statusCode: Int
}

private enum StatusFetchError: Error, Sendable {
    case timedOut
    case invalidResponse
    case http(Int)
}

private final class IPPSession: @unchecked Sendable {
    let session: URLSession

    init(timeout: TimeInterval) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    deinit {
        session.invalidateAndCancel()
    }
}

private final class IPPRequestCounter: @unchecked Sendable {
    private var value: UInt32 = 1
    private let lock = NSLock()

    func next() -> UInt32 {
        lock.lock()
        defer { lock.unlock() }
        let current = value
        value &+= 1
        if value == 0 { value = 1 }
        return current
    }
}

private final class SNMPResumeState: @unchecked Sendable {
    private var resumed = false
    private let lock = NSLock()

    func resume(
        _ continuation: CheckedContinuation<[SupplyLevel], Never>,
        with value: [SupplyLevel]
    ) {
        lock.lock()
        guard !resumed else {
            lock.unlock()
            return
        }
        resumed = true
        lock.unlock()
        continuation.resume(returning: value)
    }
}
