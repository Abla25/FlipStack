import Foundation
@testable import FlipStackCore

/// Builds binary IPP response fixtures in code, with no network or files.
enum IPPFakes {
    static func attribute(tag: UInt8, name: String, value: Data) -> Data {
        var data = Data([tag])
        let nameData = Data(name.utf8)
        appendUInt16(UInt16(nameData.count), to: &data)
        data.append(nameData)
        appendUInt16(UInt16(value.count), to: &data)
        data.append(value)
        return data
    }

    static func string(
        _ tag: UInt8 = IPPTag.nameWithoutLanguage,
        name: String,
        value: String
    ) -> Data {
        attribute(tag: tag, name: name, value: Data(value.utf8))
    }

    static func integer(
        _ tag: UInt8 = IPPTag.integer,
        name: String,
        value: Int32
    ) -> Data {
        attribute(tag: tag, name: name, value: int32Data(value))
    }

    static func collection(
        name: String,
        members: [(name: String, tag: UInt8, value: Data)]
    ) -> Data {
        var data = attribute(tag: IPPTag.beginCollection, name: name, value: Data())
        for member in members {
            data.append(
                attribute(
                    tag: IPPTag.memberAttrName,
                    name: "",
                    value: Data(member.name.utf8)
                )
            )
            data.append(attribute(tag: member.tag, name: "", value: member.value))
        }
        data.append(attribute(tag: IPPTag.endCollection, name: "", value: Data()))
        return data
    }

    static func markerCollection(
        name: String,
        color: String,
        type: String = "ink",
        level: Int32,
        high: Int32? = nil,
        low: Int32? = nil
    ) -> Data {
        var members: [(name: String, tag: UInt8, value: Data)] = [
            ("marker-name", IPPTag.nameWithoutLanguage, Data(name.utf8)),
            ("marker-colors", IPPTag.keyword, Data(color.utf8)),
            ("marker-types", IPPTag.keyword, Data(type.utf8)),
            ("marker-levels", IPPTag.integer, int32Data(level))
        ]
        if let high {
            members.append(("marker-high-levels", IPPTag.integer, int32Data(high)))
        }
        if let low {
            members.append(("marker-low-levels", IPPTag.integer, int32Data(low)))
        }
        return collection(name: "printer-marker-supplies", members: members)
    }

    static func response(
        statusCode: UInt16 = 0,
        requestID: UInt32 = 1,
        groups: [(tag: UInt8, attributes: [Data])]
    ) -> Data {
        var data = Data([2, 0])
        appendUInt16(statusCode, to: &data)
        appendUInt32(requestID, to: &data)

        for group in groups {
            data.append(group.tag)
            for attribute in group.attributes {
                data.append(attribute)
            }
        }
        data.append(IPPTag.endOfAttributes)
        return data
    }

    static func int32Data(_ value: Int32) -> Data {
        let bits = UInt32(bitPattern: value)
        return Data([
            UInt8(truncatingIfNeeded: bits >> 24),
            UInt8(truncatingIfNeeded: bits >> 16),
            UInt8(truncatingIfNeeded: bits >> 8),
            UInt8(truncatingIfNeeded: bits)
        ])
    }

    private static func appendUInt16(_ value: UInt16, to data: inout Data) {
        data.append(contentsOf: [
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value)
        ])
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(contentsOf: [
            UInt8(truncatingIfNeeded: value >> 24),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value)
        ])
    }
}

enum SNMPFakes {
    static func response(
        varbinds: [(oid: String, value: SNMPValue)],
        pduTag: UInt8 = 0xA2,
        version: Int = 1,
        community: String = "public",
        requestID: Int = 7,
        errorStatus: Int = 0
    ) -> Data {
        let encodedVarbinds = varbinds.map { varbind in
            SNMPBER.encodeSequence([
                SNMPBER.encodeOID(varbind.oid),
                encodedValue(varbind.value)
            ])
        }
        let pdu = SNMPBER.encodeTLV(
            tag: pduTag,
            value: SNMPBER.sequenceContent([
                SNMPBER.encodeInteger(requestID),
                SNMPBER.encodeInteger(errorStatus),
                SNMPBER.encodeInteger(0),
                SNMPBER.encodeSequence(encodedVarbinds)
            ])
        )
        return SNMPBER.encodeSequence([
            SNMPBER.encodeInteger(version),
            SNMPBER.encodeOctetString(community),
            pdu
        ])
    }

    static func encodedValue(_ value: SNMPValue) -> Data {
        switch value {
        case .integer(let integer):
            return SNMPBER.encodeInteger(integer)
        case .octetString(let data):
            return SNMPBER.encodeTLV(tag: 0x04, value: data)
        case .objectIdentifier(let oid):
            return SNMPBER.encodeOID(oid)
        case .null:
            return SNMPBER.encodeNull()
        case .other(let tag, let data):
            return SNMPBER.encodeTLV(tag: tag, value: data)
        }
    }
}
