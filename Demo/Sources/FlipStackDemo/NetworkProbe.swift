import Foundation
import Network

/// Real power-state probing for network printers. CUPS answers IPP for
/// dnssd/socket queues even when the printer is switched off, so the ground
/// truth for "online" is: the Bonjour service is advertised (matched by the
/// queue's uuid in the TXT record) AND its endpoint answers TCP.
enum NetworkProbe {
    /// Parse a dnssd device URI into (instance, service type, domain, uuid).
    static func parseDnssd(_ uri: String) -> (instance: String, type: String, domain: String, uuid: String?)? {
        guard uri.hasPrefix("dnssd://") else { return nil }
        let rest = String(uri.dropFirst("dnssd://".count))
        let pathPart = rest.components(separatedBy: "/").first ?? ""
        let query = rest.contains("?") ? String(rest.drop(while: { $0 != "?" }).dropFirst()) : ""
        let decoded = pathPart.removingPercentEncoding ?? pathPart
        let c = decoded.split(separator: ".").map(String.init).filter { !$0.isEmpty }
        guard c.count >= 4 else { return nil }
        let domain = c.last!
        let type = c[c.count - 3] + "." + c[c.count - 2]   // labels already carry the leading underscore
        let instance = c[0..<c.count - 3].joined(separator: ".")
        let uuid = query.components(separatedBy: "&").first(where: { $0.hasPrefix("uuid=") })?
            .dropFirst("uuid=".count).lowercased()
        return (instance, type, domain, uuid.map { String($0) })
    }

    /// socket://host:port/... → direct target. dnssd → matched by uuid in the
    /// Bonjour endpoint map (nil when the service is not advertised = off).
    static func target(for deviceURI: String,
                       endpoints: [String: (host: String, port: Int)]) -> (host: String, port: Int)? {
        if deviceURI.hasPrefix("socket://") {
            let rest = String(deviceURI.dropFirst("socket://".count))
            let hp = (rest.components(separatedBy: "/").first ?? "").components(separatedBy: ":")
            if let h = hp.first, !h.isEmpty {
                return (h, hp.count > 1 ? (Int(hp[1]) ?? 9100) : 9100)
            }
            return nil
        }
        if let d = parseDnssd(deviceURI), let uuid = d.uuid {
            return endpoints[uuid]
        }
        return nil
    }

    /// Browse Bonjour for IPP-ish services; collect uuid → endpoint from TXT records.
    static func bonjourEndpoints(timeout: TimeInterval = 3.0) async -> [String: (host: String, port: Int)] {
        var result: [String: (host: String, port: Int)] = [:]
        for type in ["_ipp._tcp", "_ipps._tcp", "_pdl-datastream._tcp"] {
            await browse(type: type, timeout: timeout) { uuid, host, port in
                if let uuid { result[uuid.lowercased()] = (host, port) }
            }
        }
        return result
    }

    private static func browse(type: String, timeout: TimeInterval,
                               onResult: @escaping (String?, String, Int) -> Void) async {
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: type, domain: "local"), using: params)
        let sem = DispatchSemaphore(value: 0)
        browser.stateUpdateHandler = { st in
            if case .failed = st { sem.signal() }
            if case .cancelled = st { sem.signal() }
        }
        browser.browseResultsChangedHandler = { results, _ in
            for r in results {
                guard case .bonjour(let txt) = r.metadata else { continue }
                guard case .hostPort(let h, let p) = r.endpoint else { continue }
                let uuid = txt["uuid"]
                onResult(uuid, "\(h)", Int(p.rawValue))
            }
        }
        browser.start(queue: .global())
        _ = sem.wait(timeout: .now() + timeout)
        browser.cancel()
    }

    /// Async TCP connect (does not block a thread); true only if the device answers.
    static func canReachAsync(host: String, port: Int, timeout: TimeInterval = 1.2) async -> Bool {
        await withCheckedContinuation { cont in
            let conn = NWConnection(host: NWEndpoint.Host(host),
                                    port: NWEndpoint.Port(integerLiteral: UInt16(port)),
                                    using: .tcp)
            var done = false
            func finish(_ ok: Bool) {
                if !done { done = true; conn.cancel(); cont.resume(returning: ok) }
            }
            conn.stateUpdateHandler = { st in
                switch st {
                case .ready: finish(true)
                case .failed, .cancelled: finish(false)
                default: break
                }
            }
            conn.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(false) }
        }
    }

    /// TCP connect with a deadline; true only if the device answers.
    static func canReach(host: String, port: Int, timeout: TimeInterval = 2.0) -> Bool {
        let conn = NWConnection(host: NWEndpoint.Host(host),
                                port: NWEndpoint.Port(integerLiteral: UInt16(port)),
                                using: .tcp)
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        conn.stateUpdateHandler = { st in
            switch st {
            case .ready: ok = true; sem.signal()
            case .failed, .cancelled: sem.signal()
            default: break
            }
        }
        conn.start(queue: .global())
        _ = sem.wait(timeout: .now() + timeout)
        conn.cancel()
        return ok
    }
}
