import Foundation

/// Small BER codec for SNMP v1/v2c messages. Only the subset needed by the
/// Printer MIB supply columns is implemented.
public enum SNMPBER {
    public struct TLV: Hashable, Sendable {
        public var tag: UInt8
        public var value: Data

        public init(tag: UInt8, value: Data) {
            self.tag = tag
            self.value = value
        }
    }

    public enum BERError: Error, Equatable, CustomStringConvertible {
        case truncated
        case invalidLength
        case invalidInteger
        case invalidOID
        case invalidSequence

        public var description: String {
            switch self {
            case .truncated: return "The BER value ended unexpectedly."
            case .invalidLength: return "The BER length is invalid."
            case .invalidInteger: return "The BER integer is invalid."
            case .invalidOID: return "The BER object identifier is invalid."
            case .invalidSequence: return "The BER sequence is invalid."
            }
        }
    }

    public static func encodeLength(_ length: Int) -> Data {
        guard length >= 0 else { return Data([0]) }
        if length < 0x80 {
            return Data([UInt8(length)])
        }

        var bytes: [UInt8] = []
        var value = length
        while value > 0 {
            bytes.insert(UInt8(value & 0xFF), at: 0)
            value >>= 8
        }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }

    public static func encodeTLV(tag: UInt8, value: Data) -> Data {
        var data = Data([tag])
        data.append(encodeLength(value.count))
        data.append(value)
        return data
    }

    public static func sequenceContent(_ children: [Data]) -> Data {
        var data = Data()
        for child in children {
            data.append(child)
        }
        return data
    }

    public static func encodeSequence(_ children: [Data]) -> Data {
        encodeTLV(tag: 0x30, value: sequenceContent(children))
    }

    /// Minimal two's-complement content octets for a BER INTEGER.
    public static func integerContent(_ value: Int) -> Data {
        if value == 0 { return Data([0]) }

        if value > 0 {
            var bytes: [UInt8] = []
            var current = value
            while current > 0 {
                bytes.append(UInt8(current & 0xFF))
                current >>= 8
            }
            if let last = bytes.last, last & 0x80 != 0 {
                bytes.append(0)
            }
            return Data(bytes.reversed())
        }

        var bytes: [UInt8] = []
        var current = value
        while true {
            bytes.append(UInt8(current & 0xFF))
            current >>= 8
            if current == -1, let last = bytes.last, last & 0x80 != 0 {
                break
            }
            if bytes.count >= 8 {
                break
            }
        }
        return Data(bytes.reversed())
    }

    public static func encodeInteger(_ value: Int) -> Data {
        encodeTLV(tag: 0x02, value: integerContent(value))
    }

    public static func encodeOctetString(_ value: String) -> Data {
        encodeTLV(tag: 0x04, value: Data(value.utf8))
    }

    public static func encodeNull() -> Data {
        encodeTLV(tag: 0x05, value: Data())
    }

    /// Content octets for an OBJECT IDENTIFIER, or nil when the string is not
    /// a valid dotted OID.
    public static func oidContent(_ oid: String) -> Data? {
        var raw = oid.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix(".") {
            raw.removeFirst()
        }
        let parts = raw.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }

        var arcs: [Int] = []
        arcs.reserveCapacity(parts.count)
        for part in parts {
            guard !part.isEmpty, let value = Int(part), value >= 0 else { return nil }
            arcs.append(value)
        }
        guard let first = arcs.first, first >= 0, first <= 2 else { return nil }
        guard arcs.count >= 2 else { return nil }
        let second = arcs[1]
        guard first == 2 || second < 40 else { return nil }

        let subidentifiers = [first * 40 + second] + arcs.dropFirst(2)
        var data = Data()
        for identifier in subidentifiers {
            appendBase128(identifier, to: &data)
        }
        return data
    }

    public static func encodeOID(_ oid: String) -> Data {
        guard let content = oidContent(oid) else {
            return Data()
        }
        return encodeTLV(tag: 0x06, value: content)
    }

    public static func decodeTLV(_ data: Data, at index: inout Int) throws -> TLV {
        try decodeTLV([UInt8](data), at: &index)
    }

    static func decodeTLV(_ bytes: [UInt8], at index: inout Int) throws -> TLV {
        guard index >= 0, index < bytes.count else {
            throw BERError.truncated
        }
        let tag = bytes[index]
        index += 1

        guard index < bytes.count else {
            throw BERError.truncated
        }
        let firstLength = bytes[index]
        index += 1

        let length: Int
        if firstLength & 0x80 == 0 {
            length = Int(firstLength)
        } else {
            let count = Int(firstLength & 0x7F)
            guard count > 0, count <= 4 else {
                throw BERError.invalidLength
            }
            guard index + count <= bytes.count else {
                throw BERError.truncated
            }
            var value = 0
            for _ in 0..<count {
                value = (value << 8) | Int(bytes[index])
                index += 1
            }
            length = value
        }

        guard length <= bytes.count - index else {
            throw BERError.truncated
        }
        let value = Data(bytes[index..<(index + length)])
        index += length
        return TLV(tag: tag, value: value)
    }

    public static func decodeIntegerContent(_ data: Data) -> Int? {
        let bytes = [UInt8](data)
        guard !bytes.isEmpty, bytes.count <= MemoryLayout<Int>.size else {
            return nil
        }

        var value: Int = (bytes[0] & 0x80) != 0 ? -1 : 0
        for byte in bytes {
            value = (value << 8) | Int(byte)
        }
        return value
    }

    public static func decodeInteger(_ tlv: Data) throws -> Int {
        var index = 0
        let decoded = try decodeTLV(tlv, at: &index)
        guard decoded.tag == 0x02, let value = decodeIntegerContent(decoded.value) else {
            throw BERError.invalidInteger
        }
        return value
    }

    public static func decodeOIDContent(_ data: Data) -> String? {
        let bytes = [UInt8](data)
        guard !bytes.isEmpty else { return nil }

        var values: [Int] = []
        var current = 0
        var hasPending = false

        for byte in bytes {
            if current > (Int.max >> 7) { return nil }
            current = (current << 7) | Int(byte & 0x7F)
            hasPending = true
            if byte & 0x80 == 0 {
                values.append(current)
                current = 0
                hasPending = false
            }
        }

        guard !hasPending, let first = values.first else { return nil }

        let firstArc: Int
        let secondArc: Int
        if first < 40 {
            firstArc = 0
            secondArc = first
        } else if first < 80 {
            firstArc = 1
            secondArc = first - 40
        } else {
            firstArc = 2
            secondArc = first - 80
        }

        var arcs = [firstArc, secondArc]
        arcs.append(contentsOf: values.dropFirst())
        return arcs.map(String.init).joined(separator: ".")
    }

    public static func decodeOID(_ tlv: Data) throws -> String {
        var index = 0
        let decoded = try decodeTLV(tlv, at: &index)
        guard decoded.tag == 0x06, let oid = decodeOIDContent(decoded.value) else {
            throw BERError.invalidOID
        }
        return oid
    }

    public static func decodeString(_ tlv: Data) throws -> String {
        var index = 0
        let decoded = try decodeTLV(tlv, at: &index)
        guard decoded.tag == 0x04 else {
            throw BERError.invalidSequence
        }
        return String(data: decoded.value, encoding: .utf8)
            ?? String(data: decoded.value, encoding: .isoLatin1)
            ?? ""
    }

    private static func appendBase128(_ value: Int, to data: inout Data) {
        var current = value
        var bytes: [UInt8] = [UInt8(current & 0x7F)]
        current >>= 7
        while current > 0 {
            bytes.append(UInt8(current & 0x7F) | 0x80)
            current >>= 7
        }
        data.append(contentsOf: bytes.reversed())
    }
}
