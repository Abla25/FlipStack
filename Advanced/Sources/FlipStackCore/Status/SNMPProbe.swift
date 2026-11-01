import Darwin
import Foundation

enum PrinterMIBColumns {
    static let suppliesType = "1.3.6.1.2.1.43.11.1.1.5"
    static let suppliesDescription = "1.3.6.1.2.1.43.11.1.1.6"
    static let suppliesUnit = "1.3.6.1.2.1.43.11.1.1.7"
    static let suppliesMaxCapacity = "1.3.6.1.2.1.43.11.1.1.8"
    static let suppliesLevel = "1.3.6.1.2.1.43.11.1.1.9"
}

enum SNMPSupplyMapper {
    static func supplies(from varbinds: [SNMPVarBind]) -> [SupplyLevel] {
        var descriptions: [String: String] = [:]
        var capacities: [String: Int] = [:]
        var levels: [String: Int] = [:]
        var types: [String: Int] = [:]
        var units: [String: Int] = [:]

        for varbind in varbinds {
            if let index = index(after: PrinterMIBColumns.suppliesDescription, oid: varbind.oid) {
                if let value = varbind.value.stringValue, !value.isEmpty {
                    descriptions[index] = value
                }
            } else if let index = index(after: PrinterMIBColumns.suppliesMaxCapacity, oid: varbind.oid) {
                if let value = varbind.value.intValue {
                    capacities[index] = value
                }
            } else if let index = index(after: PrinterMIBColumns.suppliesLevel, oid: varbind.oid) {
                if let value = varbind.value.intValue {
                    levels[index] = value
                }
            } else if let index = index(after: PrinterMIBColumns.suppliesType, oid: varbind.oid) {
                if let value = varbind.value.intValue {
                    types[index] = value
                }
            } else if let index = index(after: PrinterMIBColumns.suppliesUnit, oid: varbind.oid) {
                if let value = varbind.value.intValue {
                    units[index] = value
                }
            }
        }

        var indexes = Set(descriptions.keys)
        indexes.formUnion(levels.keys)
        guard !indexes.isEmpty else { return [] }

        let sortedIndexes = indexes.sorted(by: compareIndexes)
        var supplies: [SupplyLevel] = []
        var usedIDs = Set<String>()

        for (position, index) in sortedIndexes.enumerated() {
            let description = descriptions[index]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let name: String
            if let description, !description.isEmpty {
                name = description
            } else {
                name = "Supply \(index)"
            }
            let color = IPPSupplyNormalizer.colorName(inText: name)
            let kind = IPPSupplyNormalizer.kind(
                typeCode: types[index],
                name: name,
                color: color
            )
            let percent: Int?
            if let capacity = capacities[index], capacity > 0 {
                percent = IPPSupplyNormalizer.normalizedPercent(
                    level: levels[index],
                    capacity: capacity
                )
            } else if let unit = units[index], unit != 19, unit != 2 {
                // Without a capacity, only a reported percentage (19) or an
                // unknown unit (2) can be treated as a 0...100 level.
                percent = nil
            } else {
                percent = IPPSupplyNormalizer.normalizedPercent(
                    level: levels[index],
                    capacity: nil
                )
            }

            supplies.append(
                SupplyFactory.make(
                    prefix: "snmp",
                    name: name,
                    kind: kind,
                    colorName: color,
                    levelPercent: percent,
                    index: position,
                    usedIDs: &usedIDs
                )
            )
        }

        return supplies
    }

    private static func index(after prefix: String, oid: String) -> String? {
        let marker = prefix + "."
        guard oid.hasPrefix(marker) else { return nil }
        let index = String(oid.dropFirst(marker.count))
        return index.isEmpty ? nil : index
    }

    private static func compareIndexes(_ lhs: String, _ rhs: String) -> Bool {
        let left = lhs.split(separator: ".").compactMap { Int($0) }
        let right = rhs.split(separator: ".").compactMap { Int($0) }
        for (a, b) in zip(left, right) where a != b {
            return a < b
        }
        if left.count != right.count { return left.count < right.count }
        return lhs < rhs
    }
}

/// Synchronous SNMP v2c probe. The caller runs this off the cooperative pool
/// and races it with a deadline so a DNS or UDP stall cannot block status.
struct SNMPProbe: Sendable {
    let host: String
    let community: String
    let timeout: TimeInterval
    let version: Int

    init(host: String, community: String, timeout: TimeInterval, version: Int = 1) {
        self.host = host
        self.community = community
        self.timeout = timeout
        self.version = version
    }

    func run() -> [SupplyLevel] {
        let started = Date()
        let total = max(timeout, 0.1)
        let deadline = started.addingTimeInterval(total)

        // Prefer v2c, then retry with v1 for older printers. The primary pass
        // only gets part of the budget so the fallback still has time to run.
        if version != 1 {
            return collect(version: version, deadline: deadline).supplies
        }

        let primaryDeadline = started.addingTimeInterval(total * 0.55)
        let primary = collect(version: 1, deadline: primaryDeadline)
        if !primary.supplies.isEmpty || primary.responded {
            return primary.supplies
        }

        guard deadline.timeIntervalSinceNow > 0.2 else { return [] }
        return collect(version: 0, deadline: deadline).supplies
    }

    private func collect(
        version: Int,
        deadline: Date
    ) -> (supplies: [SupplyLevel], responded: Bool) {
        var responded = false
        let descriptions = walk(
            column: PrinterMIBColumns.suppliesDescription,
            deadline: deadline,
            version: version,
            responded: &responded
        )

        let levels = walk(
            column: PrinterMIBColumns.suppliesLevel,
            deadline: deadline,
            version: version,
            responded: &responded
        )
        let capacities = walk(
            column: PrinterMIBColumns.suppliesMaxCapacity,
            deadline: deadline,
            version: version,
            responded: &responded
        )
        let types = walk(
            column: PrinterMIBColumns.suppliesType,
            deadline: deadline,
            version: version,
            responded: &responded
        )
        let units = walk(
            column: PrinterMIBColumns.suppliesUnit,
            deadline: deadline,
            version: version,
            responded: &responded
        )

        guard !descriptions.isEmpty || !levels.isEmpty || !types.isEmpty else {
            return ([], responded)
        }

        var varbinds: [SNMPVarBind] = []
        append(descriptions, column: PrinterMIBColumns.suppliesDescription, to: &varbinds)
        append(capacities, column: PrinterMIBColumns.suppliesMaxCapacity, to: &varbinds)
        append(levels, column: PrinterMIBColumns.suppliesLevel, to: &varbinds)
        append(types, column: PrinterMIBColumns.suppliesType, to: &varbinds)
        append(units, column: PrinterMIBColumns.suppliesUnit, to: &varbinds)

        return (SNMPSupplyMapper.supplies(from: varbinds), responded)
    }

    private func append(
        _ values: [String: SNMPValue],
        column: String,
        to varbinds: inout [SNMPVarBind]
    ) {
        for (index, value) in values {
            varbinds.append(SNMPVarBind(oid: "\(column).\(index)", value: value))
        }
    }

    private func walk(
        column: String,
        deadline: Date,
        version: Int,
        responded: inout Bool
    ) -> [String: SNMPValue] {
        var values: [String: SNMPValue] = [:]
        var currentOID = column
        var seen = Set<String>()

        // Safety limit for misbehaving agents.
        for _ in 0..<64 {
            guard deadline.timeIntervalSinceNow > 0.05 else { break }
            guard let message = getNext(oid: currentOID, deadline: deadline, version: version),
                  let varbind = message.varbinds.first else {
                break
            }
            responded = true

            let oid = varbind.oid
            let marker = column + "."
            guard oid.hasPrefix(marker) else { break }
            guard seen.insert(oid).inserted else { break }

            let index = String(oid.dropFirst(marker.count))
            guard !index.isEmpty else { break }

            values[index] = varbind.value
            currentOID = oid
        }

        return values
    }

    private func getNext(oid: String, deadline: Date, version: Int) -> SNMPMessage? {
        guard deadline.timeIntervalSinceNow > 0.05 else { return nil }
        let requestID = Int.random(in: 1...Int(Int32.max))
        let payload = SNMPRequestBuilder.getNext(
            community: community,
            oid: oid,
            requestID: requestID,
            version: version
        )
        guard let data = exchange(payload: payload, deadline: deadline),
              let message = SNMPMessageParser.parseOrNil(data),
              message.pduType == 0xA2,
              message.errorStatus == 0 else {
            return nil
        }
        return message
    }

    private func exchange(payload: Data, deadline: Date) -> Data? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_DGRAM
        hints.ai_protocol = IPPROTO_UDP

        var resolved: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, "161", &hints, &resolved) == 0,
              let first = resolved else {
            return nil
        }
        defer { freeaddrinfo(first) }

        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let address = cursor {
            cursor = address.pointee.ai_next

            let descriptor = socket(
                address.pointee.ai_family,
                address.pointee.ai_socktype,
                address.pointee.ai_protocol
            )
            guard descriptor >= 0, let socketAddress = address.pointee.ai_addr else {
                if descriptor >= 0 { close(descriptor) }
                continue
            }

            var received: Data?
            if connect(descriptor, socketAddress, address.pointee.ai_addrlen) == 0 {
                let sent = payload.withUnsafeBytes { raw -> Int in
                    guard let base = raw.baseAddress else { return 0 }
                    return send(descriptor, base, raw.count, 0)
                }

                if sent == payload.count {
                    let remaining = deadline.timeIntervalSinceNow
                    if remaining > 0 {
                        var pollDescriptor = pollfd(
                            fd: descriptor,
                            events: Int16(POLLIN),
                            revents: 0
                        )
                        let milliseconds = Int32(
                            min(max(remaining * 1000.0, 1.0), Double(Int32.max))
                        )
                        let polled = poll(&pollDescriptor, 1, milliseconds)
                        if polled > 0 {
                            var buffer = [UInt8](repeating: 0, count: 65_535)
                            let count = buffer.withUnsafeMutableBytes { raw -> Int in
                                guard let base = raw.baseAddress else { return 0 }
                                return recv(descriptor, base, raw.count, 0)
                            }
                            if count > 0 {
                                received = Data(buffer[0..<count])
                            }
                        }
                    }
                }
            }

            close(descriptor)
            if let received { return received }
        }

        return nil
    }
}
