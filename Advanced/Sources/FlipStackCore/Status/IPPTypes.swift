import Foundation

/// IPP tag constants used by the small CUPS status client.
public enum IPPTag {
    // Delimiter tags.
    public static let operationAttributes: UInt8 = 0x01
    public static let jobAttributes: UInt8 = 0x02
    public static let endOfAttributes: UInt8 = 0x03
    public static let printerAttributes: UInt8 = 0x04
    public static let unsupportedAttributes: UInt8 = 0x05
    public static let subscriptionAttributes: UInt8 = 0x06
    public static let eventNotificationAttributes: UInt8 = 0x07
    public static let resourceAttributes: UInt8 = 0x08
    public static let documentAttributes: UInt8 = 0x09
    public static let systemAttributes: UInt8 = 0x0A

    // Out-of-band value tags.
    public static let unsupportedValue: UInt8 = 0x10
    public static let defaultValue: UInt8 = 0x11
    public static let unknownValue: UInt8 = 0x12
    public static let noValue: UInt8 = 0x13

    // Value tags.
    public static let integer: UInt8 = 0x21
    public static let boolean: UInt8 = 0x22
    public static let enumeration: UInt8 = 0x23
    public static let octetString: UInt8 = 0x30
    public static let dateTime: UInt8 = 0x31
    public static let resolution: UInt8 = 0x32
    public static let rangeOfInteger: UInt8 = 0x33
    public static let beginCollection: UInt8 = 0x34
    public static let textWithLanguage: UInt8 = 0x35
    public static let nameWithLanguage: UInt8 = 0x36
    public static let endCollection: UInt8 = 0x37

    public static let textWithoutLanguage: UInt8 = 0x41
    public static let nameWithoutLanguage: UInt8 = 0x42
    public static let keyword: UInt8 = 0x44
    public static let uri: UInt8 = 0x45
    public static let uriScheme: UInt8 = 0x46
    public static let charset: UInt8 = 0x47
    public static let naturalLanguage: UInt8 = 0x48
    public static let mimeMediaType: UInt8 = 0x49
    public static let memberAttrName: UInt8 = 0x4A

    public static func isDelimiter(_ tag: UInt8) -> Bool {
        tag >= operationAttributes && tag <= systemAttributes
    }

    public static func isOutOfBand(_ tag: UInt8) -> Bool {
        tag >= unsupportedValue && tag <= noValue
    }

    public static func isString(_ tag: UInt8) -> Bool {
        switch tag {
        case textWithoutLanguage, nameWithoutLanguage, keyword, uri, uriScheme,
             charset, naturalLanguage, mimeMediaType, memberAttrName:
            return true
        default:
            return false
        }
    }
}

/// A decoded IPP value. Collections and out-of-band values are kept rather
/// than discarded so diagnostics can still inspect a response.
public enum IPPValue: Hashable, Sendable {
    case integer(Int32)
    case boolean(Bool)
    case enumeration(Int32)
    case string(String)
    case rangeOfInteger(Int32, Int32)
    case resolution(x: Int32, y: Int32, units: UInt8)
    case collection([IPPCollectionMember])
    case outOfBand(UInt8)
    case raw(tag: UInt8, data: Data)

    public var stringValue: String? {
        switch self {
        case .string(let value):
            return value
        case .raw(_, let data):
            return String(data: data, encoding: .utf8)
        case .integer(let value), .enumeration(let value):
            return String(value)
        default:
            return nil
        }
    }

    public var intValue: Int? {
        switch self {
        case .integer(let value), .enumeration(let value):
            return Int(value)
        case .boolean(let value):
            return value ? 1 : 0
        case .string(let value):
            return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        case .raw(_, let data):
            return Int(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    public var collectionValue: [IPPCollectionMember]? {
        if case .collection(let members) = self { return members }
        return nil
    }
}

public struct IPPCollectionMember: Hashable, Sendable {
    public var name: String
    public var value: IPPValue

    public init(name: String, value: IPPValue) {
        self.name = name
        self.value = value
    }
}

public struct IPPAttribute: Hashable, Sendable {
    public var name: String
    public var value: IPPValue
    public var groupTag: UInt8

    public init(name: String, value: IPPValue, groupTag: UInt8 = 0) {
        self.name = name
        self.value = value
        self.groupTag = groupTag
    }
}

public struct IPPGroup: Hashable, Sendable {
    public var tag: UInt8
    public var attributes: [IPPAttribute]

    public init(tag: UInt8, attributes: [IPPAttribute]) {
        self.tag = tag
        self.attributes = attributes
    }
}

public struct IPPResponse: Hashable, Sendable {
    public var versionMajor: UInt8
    public var versionMinor: UInt8
    public var statusCode: UInt16
    public var requestID: UInt32
    public var groups: [IPPGroup]

    public init(
        versionMajor: UInt8,
        versionMinor: UInt8,
        statusCode: UInt16,
        requestID: UInt32,
        groups: [IPPGroup]
    ) {
        self.versionMajor = versionMajor
        self.versionMinor = versionMinor
        self.statusCode = statusCode
        self.requestID = requestID
        self.groups = groups
    }

    public var attributes: [IPPAttribute] {
        groups.flatMap(\.attributes)
    }

    public var isSuccess: Bool {
        statusCode <= 0x00FF
    }

    public func values(named name: String) -> [IPPValue] {
        let wanted = name.lowercased()
        return attributes.compactMap { attribute in
            attribute.name.lowercased() == wanted ? attribute.value : nil
        }
    }

    public func firstValue(named name: String) -> IPPValue? {
        values(named: name).first
    }

    /// A concise, user-facing description for non-success status codes.
    public var statusNote: String? {
        guard !isSuccess else { return nil }
        switch statusCode {
        case 0x0400:
            return "CUPS rejected the status request."
        case 0x0401:
            return "CUPS denied access to the printer."
        case 0x0402:
            return "CUPS requires authentication."
        case 0x0403:
            return "CUPS refused the status request."
        case 0x0404:
            return "CUPS could not perform the status request."
        case 0x0405:
            return "CUPS timed out while reading the printer."
        case 0x0406:
            return "The printer was not found in CUPS."
        case 0x0407:
            return "The printer is no longer available."
        case 0x0408:
            return "The status request was too large for CUPS."
        case 0x0409:
            return "A status request value was too long."
        case 0x040A:
            return "The printer does not support this document format."
        case 0x040B:
            return "The printer did not accept a requested attribute."
        case 0x040C:
            return "The printer URI scheme is not supported."
        case 0x040D:
            return "The printer does not support the requested character set."
        case 0x040E:
            return "The status request contained conflicting attributes."
        case 0x040F:
            return "The printer does not support compression."
        case 0x0410:
            return "The printer reported a compression error."
        case 0x0411:
            return "The printer reported a document format error."
        case 0x0412:
            return "The printer could not access the document."
        case 0x0500:
            return "CUPS reported an internal error."
        case 0x0501:
            return "The printer does not support status requests."
        case 0x0502:
            return "The CUPS service is unavailable."
        case 0x0503:
            return "The printer does not support this IPP version."
        case 0x0504:
            return "The printer reported a device error."
        case 0x0505:
            return "The printer reported a temporary error."
        case 0x0506:
            return "The printer is not accepting jobs."
        case 0x0507:
            return "The request was canceled by CUPS."
        case 0x0508:
            return "The printer does not support multiple documents."
        default:
            return String(format: "CUPS returned IPP status 0x%04X.", statusCode)
        }
    }
}

/// Builds a binary IPP/2.0 Get-Printer-Attributes request.
public struct IPPRequest: Hashable, Sendable {
    public var versionMajor: UInt8
    public var versionMinor: UInt8
    public var operationID: UInt16
    public var requestID: UInt32
    public var printerURI: String
    public var requestedAttributes: [String]

    public static let defaultRequestedAttributes: [String] = [
        "printer-state",
        "printer-state-reasons",
        "printer-state-message",
        "printer-is-accepting-jobs",
        "queued-job-count",
        "printer-info",
        "printer-make-and-model",
        "printer-marker-supplies",
        "printer-supply",
        "printer-supply-description",
        "marker-names",
        "marker-colors",
        "marker-levels",
        "marker-high-levels",
        "marker-low-levels",
        "marker-types",
        "printer-alerts",
        "printer-alert-description"
    ]

    public init(
        printerURI: String,
        requestID: UInt32,
        operationID: UInt16 = 0x000B,
        versionMajor: UInt8 = 2,
        versionMinor: UInt8 = 0,
        requestedAttributes: [String] = IPPRequest.defaultRequestedAttributes
    ) {
        self.printerURI = printerURI
        self.requestID = requestID
        self.operationID = operationID
        self.versionMajor = versionMajor
        self.versionMinor = versionMinor
        self.requestedAttributes = requestedAttributes
    }

    public func encoded() -> Data {
        var data = Data()
        data.append(contentsOf: [versionMajor, versionMinor])
        appendUInt16(operationID, to: &data)
        appendUInt32(requestID, to: &data)
        data.append(IPPTag.operationAttributes)

        appendStringAttribute(IPPTag.charset, name: "attributes-charset", value: "utf-8", to: &data)
        appendStringAttribute(IPPTag.naturalLanguage, name: "attributes-natural-language", value: "en", to: &data)
        appendStringAttribute(IPPTag.uri, name: "printer-uri", value: printerURI, to: &data)
        for (index, attribute) in requestedAttributes.enumerated() {
            appendStringAttribute(
                IPPTag.keyword,
                name: index == 0 ? "requested-attributes" : "",
                value: attribute,
                to: &data
            )
        }

        data.append(IPPTag.endOfAttributes)
        return data
    }

    /// Alias used by tests and callers that prefer a property.
    public var data: Data { encoded() }

    private func appendStringAttribute(_ tag: UInt8, name: String, value: String, to data: inout Data) {
        appendAttribute(tag, name: name, value: Data(value.utf8), to: &data)
    }

    private func appendAttribute(_ tag: UInt8, name: String, value: Data, to data: inout Data) {
        let nameData = Data(name.utf8)
        data.append(tag)
        appendUInt16(UInt16(clamping: nameData.count), to: &data)
        data.append(nameData)
        appendUInt16(UInt16(clamping: value.count), to: &data)
        data.append(value)
    }

    private func appendUInt16(_ value: UInt16, to data: inout Data) {
        data.append(contentsOf: [UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)])
    }

    private func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(contentsOf: [
            UInt8(truncatingIfNeeded: value >> 24),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value)
        ])
    }
}

public enum IPPParseError: Error, Equatable, CustomStringConvertible {
    case truncated(offset: Int)
    case malformed(String)
    case collectionTooDeep

    public var description: String {
        switch self {
        case .truncated(let offset):
            return "The IPP response ended unexpectedly at byte \(offset)."
        case .malformed(let message):
            return "The IPP response is malformed: \(message)"
        case .collectionTooDeep:
            return "The IPP response contains collections nested too deeply."
        }
    }
}

/// Parses binary IPP responses from CUPS/printer daemons.
public enum IPPResponseParser {
    public static func parse(_ data: Data) throws -> IPPResponse {
        var reader = ByteReader(bytes: [UInt8](data))
        guard reader.remaining >= 8 else {
            throw IPPParseError.truncated(offset: reader.index)
        }

        let major = try reader.readUInt8()
        let minor = try reader.readUInt8()
        guard major == 1 || major == 2 else {
            throw IPPParseError.malformed("unsupported IPP version \(major).\(minor)")
        }
        let statusCode = try reader.readUInt16()
        let requestID = try reader.readUInt32()

        var groups: [IPPGroup] = []
        var currentGroup: UInt8?
        var pending: [IPPAttribute] = []
        var sawEnd = false

        func flushGroup() {
            if !pending.isEmpty {
                groups.append(IPPGroup(tag: currentGroup ?? 0, attributes: pending))
            }
            pending.removeAll(keepingCapacity: true)
        }

        while reader.remaining > 0 {
            let tag = try reader.readUInt8()

            if tag == IPPTag.endOfAttributes {
                flushGroup()
                sawEnd = true
                break
            }

            if IPPTag.isDelimiter(tag) {
                flushGroup()
                currentGroup = tag
                continue
            }

            if tag == IPPTag.endCollection {
                try skipCollectionTerminator(reader: &reader)
                continue
            }

            let attribute = try parseAttribute(
                tag: tag,
                reader: &reader,
                groupTag: currentGroup ?? 0
            )
            pending.append(attribute)
        }

        guard sawEnd else {
            throw IPPParseError.truncated(offset: reader.index)
        }

        return IPPResponse(
            versionMajor: major,
            versionMinor: minor,
            statusCode: statusCode,
            requestID: requestID,
            groups: groups
        )
    }

    public static func parseOrNil(_ data: Data) -> IPPResponse? {
        try? parse(data)
    }

    private static func parseAttribute(
        tag: UInt8,
        reader: inout ByteReader,
        groupTag: UInt8
    ) throws -> IPPAttribute {
        let nameLength = try reader.readUInt16()
        let name = decodeString(try reader.readBytes(Int(nameLength)))
        let valueLength = try reader.readUInt16()

        if tag == IPPTag.beginCollection {
            // The value-length field of a collection is zero. The members
            // follow and are terminated by an endCollection tag.
            let members = try parseCollection(reader: &reader, depth: 0)
            return IPPAttribute(name: name, value: .collection(members), groupTag: groupTag)
        }

        let valueBytes = try reader.readBytes(Int(valueLength))
        return IPPAttribute(
            name: name,
            value: decodeValue(tag: tag, bytes: valueBytes),
            groupTag: groupTag
        )
    }

    private static func parseCollection(
        reader: inout ByteReader,
        depth: Int
    ) throws -> [IPPCollectionMember] {
        guard depth <= 32 else { throw IPPParseError.collectionTooDeep }

        var members: [IPPCollectionMember] = []
        var pendingName: String?

        while true {
            guard reader.remaining > 0 else {
                throw IPPParseError.truncated(offset: reader.index)
            }
            let tag = try reader.readUInt8()

            if tag == IPPTag.endOfAttributes {
                throw IPPParseError.malformed("end-of-attributes inside a collection")
            }
            if IPPTag.isDelimiter(tag) {
                throw IPPParseError.malformed("attribute group delimiter inside a collection")
            }

            let nameLength = try reader.readUInt16()
            let name = decodeString(try reader.readBytes(Int(nameLength)))
            let valueLength = try reader.readUInt16()

            if tag == IPPTag.endCollection {
                if valueLength > 0 {
                    _ = try reader.readBytes(Int(valueLength))
                }
                return members
            }

            if tag == IPPTag.memberAttrName {
                pendingName = decodeString(try reader.readBytes(Int(valueLength)))
                continue
            }

            if tag == IPPTag.beginCollection {
                let nested = try parseCollection(reader: &reader, depth: depth + 1)
                let memberName = name.isEmpty ? (pendingName ?? "") : name
                members.append(IPPCollectionMember(name: memberName, value: .collection(nested)))
                pendingName = nil
                continue
            }

            let raw = try reader.readBytes(Int(valueLength))
            let memberName = name.isEmpty ? (pendingName ?? "") : name
            members.append(
                IPPCollectionMember(
                    name: memberName,
                    value: decodeValue(tag: tag, bytes: raw)
                )
            )
            pendingName = nil
        }
    }

    private static func skipCollectionTerminator(reader: inout ByteReader) throws {
        let nameLength = try reader.readUInt16()
        _ = try reader.readBytes(Int(nameLength))
        let valueLength = try reader.readUInt16()
        _ = try reader.readBytes(Int(valueLength))
    }

    private static func decodeValue(tag: UInt8, bytes: [UInt8]) -> IPPValue {
        switch tag {
        case IPPTag.unsupportedValue, IPPTag.defaultValue, IPPTag.unknownValue, IPPTag.noValue:
            return .outOfBand(tag)

        case IPPTag.integer:
            guard bytes.count == 4 else {
                return .raw(tag: tag, data: Data(bytes))
            }
            return .integer(readInt32(bytes))

        case IPPTag.enumeration:
            guard bytes.count == 4 else {
                return .raw(tag: tag, data: Data(bytes))
            }
            return .enumeration(readInt32(bytes))

        case IPPTag.boolean:
            if bytes.count == 1 {
                return .boolean(bytes[0] != 0)
            }
            if bytes.count == 4 {
                return .boolean(readInt32(bytes) != 0)
            }
            return .raw(tag: tag, data: Data(bytes))

        case IPPTag.rangeOfInteger:
            guard bytes.count == 8 else {
                return .raw(tag: tag, data: Data(bytes))
            }
            return .rangeOfInteger(readInt32(Array(bytes[0..<4])), readInt32(Array(bytes[4..<8])))

        case IPPTag.resolution:
            guard bytes.count == 9 else {
                return .raw(tag: tag, data: Data(bytes))
            }
            return .resolution(
                x: readInt32(Array(bytes[0..<4])),
                y: readInt32(Array(bytes[4..<8])),
                units: bytes[8]
            )

        case IPPTag.octetString:
            // `printer-supply` uses an octet string with textual key/value
            // pairs. Keep genuinely binary values as raw bytes.
            if let string = String(bytes: bytes, encoding: .utf8) {
                return .string(string)
            }
            return .raw(tag: tag, data: Data(bytes))

        default:
            if IPPTag.isString(tag) || tag == 0x4B {
                return .string(decodeString(bytes))
            }
            return .raw(tag: tag, data: Data(bytes))
        }
    }

    private static func readInt32(_ bytes: [UInt8]) -> Int32 {
        let value = UInt32(bytes[0]) << 24
            | UInt32(bytes[1]) << 16
            | UInt32(bytes[2]) << 8
            | UInt32(bytes[3])
        return Int32(bitPattern: value)
    }

    private static func decodeString(_ bytes: [UInt8]) -> String {
        if bytes.isEmpty { return "" }
        if let string = String(bytes: bytes, encoding: .utf8) {
            return string
        }
        return String(bytes: bytes, encoding: .isoLatin1) ?? ""
    }
}

private struct ByteReader {
    let bytes: [UInt8]
    var index: Int = 0

    var remaining: Int { bytes.count - index }

    mutating func readUInt8() throws -> UInt8 {
        guard index < bytes.count else {
            throw IPPParseError.truncated(offset: index)
        }
        let value = bytes[index]
        index += 1
        return value
    }

    mutating func readUInt16() throws -> UInt16 {
        guard index + 2 <= bytes.count else {
            throw IPPParseError.truncated(offset: index)
        }
        let value = UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1])
        index += 2
        return value
    }

    mutating func readUInt32() throws -> UInt32 {
        guard index + 4 <= bytes.count else {
            throw IPPParseError.truncated(offset: index)
        }
        let value = UInt32(bytes[index]) << 24
            | UInt32(bytes[index + 1]) << 16
            | UInt32(bytes[index + 2]) << 8
            | UInt32(bytes[index + 3])
        index += 4
        return value
    }

    mutating func readBytes(_ count: Int) throws -> [UInt8] {
        guard count >= 0 else {
            throw IPPParseError.malformed("negative length")
        }
        guard index + count <= bytes.count else {
            throw IPPParseError.truncated(offset: index)
        }
        let value = Array(bytes[index..<(index + count)])
        index += count
        return value
    }
}
