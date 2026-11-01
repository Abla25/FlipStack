import Foundation
import XCTest
@testable import FlipStackCore

final class SNMPStatusTests: XCTestCase {
    func testBERIntegerAndLengthEncoding() throws {
        XCTAssertEqual(SNMPBER.integerContent(0), Data([0x00]))
        XCTAssertEqual(SNMPBER.integerContent(127), Data([0x7F]))
        XCTAssertEqual(SNMPBER.integerContent(128), Data([0x00, 0x80]))
        XCTAssertEqual(SNMPBER.integerContent(256), Data([0x01, 0x00]))
        XCTAssertEqual(SNMPBER.integerContent(-1), Data([0xFF]))
        XCTAssertEqual(SNMPBER.integerContent(-128), Data([0x80]))
        XCTAssertEqual(SNMPBER.integerContent(-129), Data([0xFF, 0x7F]))

        XCTAssertEqual(SNMPBER.decodeIntegerContent(Data([0x00, 0x80])), 128)
        XCTAssertEqual(SNMPBER.decodeIntegerContent(Data([0xFF])), -1)
        XCTAssertEqual(SNMPBER.decodeIntegerContent(Data([0xFF, 0x7F])), -129)
        XCTAssertNil(SNMPBER.decodeIntegerContent(Data()))
        XCTAssertEqual(try SNMPBER.decodeInteger(SNMPBER.encodeInteger(300)), 300)
        XCTAssertEqual(try SNMPBER.decodeInteger(SNMPBER.encodeInteger(-300)), -300)

        XCTAssertEqual(SNMPBER.encodeLength(0), Data([0x00]))
        XCTAssertEqual(SNMPBER.encodeLength(127), Data([0x7F]))
        XCTAssertEqual(SNMPBER.encodeLength(128), Data([0x81, 0x80]))
        XCTAssertEqual(SNMPBER.encodeLength(200), Data([0x81, 0xC8]))
        XCTAssertEqual(SNMPBER.encodeLength(300), Data([0x82, 0x01, 0x2C]))

        let longValue = Data(repeating: 0x41, count: 200)
        let longTLV = SNMPBER.encodeTLV(tag: 0x04, value: longValue)
        XCTAssertEqual(longTLV[1], 0x81)
        XCTAssertEqual(longTLV[2], 0xC8)
        var offset = 0
        let decoded = try SNMPBER.decodeTLV(longTLV, at: &offset)
        XCTAssertEqual(decoded.tag, 0x04)
        XCTAssertEqual(decoded.value, longValue)
        XCTAssertEqual(offset, longTLV.count)
    }

    func testBEROIDEncoding() throws {
        let oid = "1.3.6.1.2.1.43.11.1.1.6.1"
        XCTAssertEqual(try SNMPBER.decodeOID(SNMPBER.encodeOID(oid)), oid)

        let content = try XCTUnwrap(SNMPBER.oidContent("1.3.6.1"))
        XCTAssertEqual([UInt8](content), [0x2B, 0x06, 0x01])

        let largeArc = "2.999.3"
        XCTAssertEqual(try SNMPBER.decodeOID(SNMPBER.encodeOID(largeArc)), largeArc)
        XCTAssertNil(SNMPBER.oidContent("1"))
        XCTAssertNil(SNMPBER.oidContent("1.40"))
        XCTAssertNil(SNMPBER.oidContent("3.1"))
        XCTAssertNil(SNMPBER.decodeOIDContent(Data([0x80])))

        XCTAssertEqual(try SNMPBER.decodeString(SNMPBER.encodeOctetString("hello")), "hello")
    }

    func testBERTruncatedInputsThrow() {
        var offset = 0
        XCTAssertThrowsError(try SNMPBER.decodeTLV(Data([0x30, 0x05, 0x01]), at: &offset))

        offset = 0
        XCTAssertThrowsError(try SNMPBER.decodeTLV(Data([0x30, 0x82, 0x01]), at: &offset))

        offset = 0
        XCTAssertThrowsError(try SNMPBER.decodeTLV(Data([0x30, 0x80]), at: &offset))
    }

    func testGetNextResponseParsesAndAssemblesSupplies() throws {
        let varbinds: [(oid: String, value: SNMPValue)] = [
            ("1.3.6.1.2.1.43.11.1.1.6.1", .octetString(Data("Black Ink".utf8))),
            ("1.3.6.1.2.1.43.11.1.1.8.1", .integer(100)),
            ("1.3.6.1.2.1.43.11.1.1.9.1", .integer(80)),
            ("1.3.6.1.2.1.43.11.1.1.5.1", .integer(5)),
            ("1.3.6.1.2.1.43.11.1.1.7.1", .integer(19)),
            ("1.3.6.1.2.1.43.11.1.1.6.2", .octetString(Data("Cyan Ink".utf8))),
            ("1.3.6.1.2.1.43.11.1.1.8.2", .integer(100)),
            ("1.3.6.1.2.1.43.11.1.1.9.2", .integer(60)),
            ("1.3.6.1.2.1.43.11.1.1.5.2", .integer(5)),
            ("1.3.6.1.2.1.43.11.1.1.7.2", .integer(19))
        ]
        let data = SNMPFakes.response(varbinds: varbinds)

        let message = try SNMPMessageParser.parse(data)
        XCTAssertEqual(message.version, 1)
        XCTAssertEqual(message.community, "public")
        XCTAssertEqual(message.pduType, 0xA2)
        XCTAssertEqual(message.requestID, 7)
        XCTAssertEqual(message.errorStatus, 0)
        XCTAssertEqual(message.errorIndex, 0)
        XCTAssertEqual(message.varbinds.count, 10)

        let supplies = SNMPSupplyMapper.supplies(from: message.varbinds)
        XCTAssertEqual(supplies.count, 2)
        XCTAssertEqual(supplies[0].id, "snmp-black-ink")
        XCTAssertEqual(supplies[0].name, "Black Ink")
        XCTAssertEqual(supplies[0].kind, .ink)
        XCTAssertEqual(supplies[0].colorName, "Black")
        XCTAssertEqual(supplies[0].levelPercent, 80)
        XCTAssertEqual(supplies[1].id, "snmp-cyan-ink")
        XCTAssertEqual(supplies[1].colorName, "Cyan")
        XCTAssertEqual(supplies[1].levelPercent, 60)

        let repeatSupplies = SNMPSupplyMapper.supplies(from: message.varbinds)
        XCTAssertEqual(supplies.map(\.id), repeatSupplies.map(\.id))
    }

    func testSNMPTonerWasteAndUnknownLevels() throws {
        let varbinds: [(oid: String, value: SNMPValue)] = [
            ("1.3.6.1.2.1.43.11.1.1.6.1", .octetString(Data("Black Toner".utf8))),
            ("1.3.6.1.2.1.43.11.1.1.8.1", .integer(100)),
            ("1.3.6.1.2.1.43.11.1.1.9.1", .integer(100)),
            ("1.3.6.1.2.1.43.11.1.1.5.1", .integer(3)),
            ("1.3.6.1.2.1.43.11.1.1.6.2", .octetString(Data("Waste Ink Tank".utf8))),
            ("1.3.6.1.2.1.43.11.1.1.8.2", .integer(200)),
            ("1.3.6.1.2.1.43.11.1.1.9.2", .integer(50)),
            ("1.3.6.1.2.1.43.11.1.1.5.2", .integer(8)),
            ("1.3.6.1.2.1.43.11.1.1.6.3", .octetString(Data("Maintenance Kit".utf8))),
            ("1.3.6.1.2.1.43.11.1.1.8.3", .integer(100)),
            ("1.3.6.1.2.1.43.11.1.1.9.3", .integer(-3)),
            ("1.3.6.1.2.1.43.11.1.1.5.3", .integer(20))
        ]
        let message = try SNMPMessageParser.parse(SNMPFakes.response(varbinds: varbinds))
        let supplies = SNMPSupplyMapper.supplies(from: message.varbinds)

        XCTAssertEqual(supplies.count, 3)
        XCTAssertEqual(supplies[0].kind, .toner)
        XCTAssertEqual(supplies[0].levelPercent, 100)
        XCTAssertEqual(supplies[1].kind, .waste)
        XCTAssertEqual(supplies[1].levelPercent, 25)
        XCTAssertEqual(supplies[2].kind, .maintenance)
        XCTAssertNil(supplies[2].levelPercent)
    }

    func testSNMPOutOfBandValueIsIgnored() throws {
        let varbinds: [(oid: String, value: SNMPValue)] = [
            ("1.3.6.1.2.1.43.11.1.1.6.1", .octetString(Data())),
            ("1.3.6.1.2.1.43.11.1.1.9.1", .other(tag: 0x82, data: Data()))
        ]
        let message = try SNMPMessageParser.parse(SNMPFakes.response(varbinds: varbinds))
        let supplies = SNMPSupplyMapper.supplies(from: message.varbinds)

        // An empty description plus a noSuchObject level is not a usable
        // marker supply, and must not create a phantom row.
        XCTAssertTrue(supplies.isEmpty)
    }

    func testSNMPRequestUsesConfiguredVersionAndCommunity() throws {
        for version in [0, 1] {
            let data = SNMPRequestBuilder.getNext(
                community: "public",
                oid: "1.3.6.1.2.1.43.11.1.1.6",
                requestID: 42,
                version: version
            )
            let message = try SNMPMessageParser.parse(data)
            XCTAssertEqual(message.version, version)
            XCTAssertEqual(message.community, "public")
            XCTAssertEqual(message.pduType, 0xA1)
            XCTAssertEqual(message.requestID, 42)
            XCTAssertEqual(message.varbinds.count, 1)
            XCTAssertEqual(message.varbinds[0].oid, "1.3.6.1.2.1.43.11.1.1.6")
            if case .null = message.varbinds[0].value {
                // Expected GETNEXT null value.
            } else {
                XCTFail("GETNEXT varbind should have a null value")
            }
        }
    }

    func testNoResponseAndTruncatedPacketsAtParserLayer() throws {
        XCTAssertThrowsError(try SNMPMessageParser.parse(Data()))
        XCTAssertNil(SNMPMessageParser.parseOrNil(Data()))

        let valid = SNMPFakes.response(varbinds: [
            ("1.3.6.1.2.1.43.11.1.1.6.1", .octetString(Data("Black Ink".utf8)))
        ])
        XCTAssertNotNil(SNMPMessageParser.parseOrNil(valid))
        XCTAssertNil(SNMPMessageParser.parseOrNil(Data(valid.dropLast(3))))
        XCTAssertNil(SNMPMessageParser.parseOrNil(Data([0x30, 0x82])))
        XCTAssertNil(SNMPMessageParser.parseOrNil(Data([0x30, 0x03, 0x02, 0x01, 0x00])))
    }
}
