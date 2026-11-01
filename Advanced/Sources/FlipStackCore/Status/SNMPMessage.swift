import Foundation

public enum SNMPValue: Hashable, Sendable {
    case integer(Int)
    case octetString(Data)
    case objectIdentifier(String)
    case null
    case other(tag: UInt8, data: Data)

    public var stringValue: String? {
        switch self {
        case .octetString(let data):
            let value = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
            return value?.trimmingCharacters(
                in: CharacterSet(charactersIn: "\0").union(.whitespacesAndNewlines)
            )
        case .integer(let value):
            return String(value)
        case .objectIdentifier(let oid):
            return oid
        default:
            return nil
        }
    }

    public var intValue: Int? {
        switch self {
        case .integer(let value):
            return value
        case .octetString(let data):
            guard let string = String(data: data, encoding: .utf8) else { return nil }
            return Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }
}

public struct SNMPVarBind: Hashable, Sendable {
    public var oid: String
    public var value: SNMPValue

    public init(oid: String, value: SNMPValue) {
        self.oid = oid
        self.value = value
    }
}

public struct SNMPMessage: Hashable, Sendable {
    public var version: Int
    public var community: String
    public var pduType: UInt8
    public var requestID: Int
    public var errorStatus: Int
    public var errorIndex: Int
    public var varbinds: [SNMPVarBind]

    public init(
        version: Int,
        community: String,
        pduType: UInt8,
        requestID: Int,
        errorStatus: Int,
        errorIndex: Int,
        varbinds: [SNMPVarBind]
    ) {
        self.version = version
        self.community = community
        self.pduType = pduType
        self.requestID = requestID
        self.errorStatus = errorStatus
        self.errorIndex = errorIndex
        self.varbinds = varbinds
    }
}

public enum SNMPMessageParser {
    public static func parse(_ data: Data) throws -> SNMPMessage {
        var outerOffset = 0
        let outer = try SNMPBER.decodeTLV(data, at: &outerOffset)
        guard outer.tag == 0x30 else {
            throw SNMPBER.BERError.invalidSequence
        }

        var index = 0
        let versionTLV = try SNMPBER.decodeTLV(outer.value, at: &index)
        guard versionTLV.tag == 0x02,
              let version = SNMPBER.decodeIntegerContent(versionTLV.value) else {
            throw SNMPBER.BERError.invalidInteger
        }

        let communityTLV = try SNMPBER.decodeTLV(outer.value, at: &index)
        guard communityTLV.tag == 0x04 else {
            throw SNMPBER.BERError.invalidSequence
        }
        let community = String(data: communityTLV.value, encoding: .utf8)
            ?? String(data: communityTLV.value, encoding: .isoLatin1)
            ?? ""

        let pduTLV = try SNMPBER.decodeTLV(outer.value, at: &index)
        guard pduTLV.tag >= 0xA0, pduTLV.tag <= 0xA3 else {
            throw SNMPBER.BERError.invalidSequence
        }

        var pduIndex = 0
        let requestIDTLV = try SNMPBER.decodeTLV(pduTLV.value, at: &pduIndex)
        let errorStatusTLV = try SNMPBER.decodeTLV(pduTLV.value, at: &pduIndex)
        let errorIndexTLV = try SNMPBER.decodeTLV(pduTLV.value, at: &pduIndex)
        let varbindListTLV = try SNMPBER.decodeTLV(pduTLV.value, at: &pduIndex)

        guard requestIDTLV.tag == 0x02,
              let requestID = SNMPBER.decodeIntegerContent(requestIDTLV.value),
              errorStatusTLV.tag == 0x02,
              let errorStatus = SNMPBER.decodeIntegerContent(errorStatusTLV.value),
              errorIndexTLV.tag == 0x02,
              let errorIndex = SNMPBER.decodeIntegerContent(errorIndexTLV.value),
              varbindListTLV.tag == 0x30 else {
            throw SNMPBER.BERError.invalidSequence
        }

        var varbinds: [SNMPVarBind] = []
        var listIndex = 0
        while listIndex < varbindListTLV.value.count {
            let varbindTLV = try SNMPBER.decodeTLV(varbindListTLV.value, at: &listIndex)
            guard varbindTLV.tag == 0x30 else {
                throw SNMPBER.BERError.invalidSequence
            }

            var varbindIndex = 0
            let oidTLV = try SNMPBER.decodeTLV(varbindTLV.value, at: &varbindIndex)
            let valueTLV = try SNMPBER.decodeTLV(varbindTLV.value, at: &varbindIndex)
            guard oidTLV.tag == 0x06,
                  let oid = SNMPBER.decodeOIDContent(oidTLV.value) else {
                throw SNMPBER.BERError.invalidOID
            }

            varbinds.append(
                SNMPVarBind(oid: oid, value: value(from: valueTLV))
            )
        }

        return SNMPMessage(
            version: version,
            community: community,
            pduType: pduTLV.tag,
            requestID: requestID,
            errorStatus: errorStatus,
            errorIndex: errorIndex,
            varbinds: varbinds
        )
    }

    public static func parseOrNil(_ data: Data) -> SNMPMessage? {
        try? parse(data)
    }

    private static func value(from tlv: SNMPBER.TLV) -> SNMPValue {
        switch tlv.tag {
        case 0x02, 0x41, 0x42, 0x43, 0x46:
            if let value = SNMPBER.decodeIntegerContent(tlv.value) {
                return .integer(value)
            }
            return .other(tag: tlv.tag, data: tlv.value)
        case 0x04:
            return .octetString(tlv.value)
        case 0x05:
            return .null
        case 0x06:
            if let oid = SNMPBER.decodeOIDContent(tlv.value) {
                return .objectIdentifier(oid)
            }
            return .other(tag: tlv.tag, data: tlv.value)
        default:
            return .other(tag: tlv.tag, data: tlv.value)
        }
    }
}

enum SNMPRequestBuilder {
    static func getNext(
        community: String,
        oid: String,
        requestID: Int,
        version: Int = 1
    ) -> Data {
        let varbind = SNMPBER.encodeSequence([
            SNMPBER.encodeOID(oid),
            SNMPBER.encodeNull()
        ])
        let pdu = SNMPBER.encodeTLV(
            tag: 0xA1,
            value: SNMPBER.sequenceContent([
                SNMPBER.encodeInteger(requestID),
                SNMPBER.encodeInteger(0),
                SNMPBER.encodeInteger(0),
                SNMPBER.encodeSequence([varbind])
            ])
        )
        return SNMPBER.encodeSequence([
            SNMPBER.encodeInteger(version),
            SNMPBER.encodeOctetString(community),
            pdu
        ])
    }
}
