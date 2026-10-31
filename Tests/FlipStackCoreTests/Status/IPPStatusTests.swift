import Foundation
import XCTest
@testable import FlipStackCore

final class IPPStatusTests: XCTestCase {
    func testIdleResponseParsesFourInkMarkers() throws {
        let attributes = [
            IPPFakes.integer(IPPTag.enumeration, name: "printer-state", value: 3),
            IPPFakes.string(IPPTag.keyword, name: "printer-state-reasons", value: "none"),
            IPPFakes.markerCollection(name: "Black Ink", color: "#000000", level: 80),
            IPPFakes.markerCollection(name: "Cyan Ink", color: "#00FFFF", level: 60),
            IPPFakes.markerCollection(name: "Magenta Ink", color: "#FF00FF", level: 55),
            IPPFakes.markerCollection(name: "Yellow Ink", color: "#FFFF00", level: 72)
        ]
        let data = IPPFakes.response(groups: [(IPPTag.printerAttributes, attributes)])

        let response = try IPPResponseParser.parse(data)
        XCTAssertTrue(response.isSuccess)
        XCTAssertEqual(response.statusCode, 0)
        XCTAssertEqual(response.requestID, 1)

        // Deliberately give the client a stale stopped state so the test
        // proves the IPP state wins on success.
        let printer = Printer(id: "office", name: "Office", state: .stopped)
        let status = IPPStatusMapper.status(from: response, printer: printer)

        XCTAssertEqual(status.printerID, "office")
        XCTAssertEqual(status.state, .idle)
        XCTAssertEqual(status.stateReasons, [])
        XCTAssertEqual(status.origin, .ipp)
        XCTAssertNil(status.note)
        XCTAssertEqual(status.supplies.count, 4)

        let expected: [(String, String, Int)] = [
            ("Black Ink", "Black", 80),
            ("Cyan Ink", "Cyan", 60),
            ("Magenta Ink", "Magenta", 55),
            ("Yellow Ink", "Yellow", 72)
        ]
        for (index, item) in expected.enumerated() {
            let supply = status.supplies[index]
            XCTAssertEqual(supply.name, item.0)
            XCTAssertEqual(supply.colorName, item.1)
            XCTAssertEqual(supply.levelPercent, item.2)
            XCTAssertEqual(supply.kind, .ink)
            XCTAssertFalse(supply.id.isEmpty)
        }
        XCTAssertEqual(Set(status.supplies.map(\.id)).count, 4)

        let repeatStatus = IPPStatusMapper.status(
            from: try IPPResponseParser.parse(data),
            printer: printer
        )
        XCTAssertEqual(status.supplies.map(\.id), repeatStatus.supplies.map(\.id))
    }

    func testStoppedResponseWithMediaAndCoverReasons() throws {
        let attributes = [
            IPPFakes.integer(IPPTag.enumeration, name: "printer-state", value: 5),
            IPPFakes.string(IPPTag.keyword, name: "printer-state-reasons", value: "media-empty-error"),
            IPPFakes.string(IPPTag.keyword, name: "printer-state-reasons", value: "cover-open-error")
        ]
        let response = try IPPResponseParser.parse(
            IPPFakes.response(groups: [(IPPTag.printerAttributes, attributes)])
        )
        let status = IPPStatusMapper.status(
            from: response,
            printer: Printer(id: "office", name: "Office")
        )

        XCTAssertEqual(status.state, .stopped)
        XCTAssertEqual(status.stateReasons, ["media-empty-error", "cover-open-error"])
        XCTAssertTrue(status.supplies.isEmpty)
        XCTAssertEqual(status.origin, .ipp)
        XCTAssertEqual(status.note, "No supply levels reported by IPP")
        XCTAssertEqual(status.actionableReasons, ["Out of paper", "Cover open"])
    }

    func testProcessingResponseWithLegacyMarkerArrays() throws {
        let attributes: [Data] = [
            IPPFakes.integer(IPPTag.enumeration, name: "printer-state", value: 4),
            IPPFakes.string(IPPTag.keyword, name: "printer-state-reasons", value: "job-printing"),
            IPPFakes.string(name: "marker-names", value: "Black Ink"),
            IPPFakes.string(name: "marker-names", value: "Cyan Ink"),
            IPPFakes.string(IPPTag.keyword, name: "marker-colors", value: "#000000"),
            IPPFakes.string(IPPTag.keyword, name: "marker-colors", value: "cyan"),
            IPPFakes.integer(name: "marker-levels", value: 50),
            IPPFakes.integer(name: "marker-levels", value: 40),
            IPPFakes.integer(name: "marker-high-levels", value: 200),
            IPPFakes.integer(name: "marker-high-levels", value: 100),
            IPPFakes.string(IPPTag.keyword, name: "marker-types", value: "ink"),
            IPPFakes.string(IPPTag.keyword, name: "marker-types", value: "ink")
        ]
        let response = try IPPResponseParser.parse(
            IPPFakes.response(groups: [(IPPTag.printerAttributes, attributes)])
        )
        let status = IPPStatusMapper.status(
            from: response,
            printer: Printer(id: "office", name: "Office")
        )

        XCTAssertEqual(status.state, .processing)
        XCTAssertEqual(status.stateReasons, ["job-printing"])
        XCTAssertEqual(status.origin, .ipp)
        XCTAssertNil(status.note)
        XCTAssertEqual(status.supplies.count, 2)
        XCTAssertEqual(status.supplies[0].name, "Black Ink")
        XCTAssertEqual(status.supplies[0].colorName, "Black")
        XCTAssertEqual(status.supplies[0].levelPercent, 25)
        XCTAssertEqual(status.supplies[1].colorName, "Cyan")
        XCTAssertEqual(status.supplies[1].levelPercent, 40)
    }

    func testModernCollectionWithCapacityAndKinds() throws {
        let attributes = [
            IPPFakes.integer(IPPTag.enumeration, name: "printer-state", value: 3),
            IPPFakes.markerCollection(
                name: "Black Toner",
                color: "#000000",
                type: "toner",
                level: 450,
                high: 500,
                low: 20
            ),
            IPPFakes.markerCollection(
                name: "Waste Ink Tank",
                color: "#808080",
                type: "wasteInk",
                level: 90,
                high: 100
            )
        ]
        let response = try IPPResponseParser.parse(
            IPPFakes.response(groups: [(IPPTag.printerAttributes, attributes)])
        )
        let status = IPPStatusMapper.status(
            from: response,
            printer: Printer(id: "office", name: "Office")
        )

        XCTAssertEqual(status.supplies.count, 2)
        XCTAssertEqual(status.supplies[0].kind, .toner)
        XCTAssertEqual(status.supplies[0].colorName, "Black")
        XCTAssertEqual(status.supplies[0].levelPercent, 90)
        XCTAssertEqual(status.supplies[1].kind, .waste)
        XCTAssertEqual(status.supplies[1].levelPercent, 90)
    }

    func testOutOfBandAndUnknownTagsAreSkipped() throws {
        let attributes = [
            IPPFakes.integer(IPPTag.enumeration, name: "printer-state", value: 3),
            IPPFakes.attribute(tag: IPPTag.noValue, name: "printer-alerts", value: Data()),
            IPPFakes.attribute(
                tag: 0x7F,
                name: "vendor-unknown",
                value: Data([0xDE, 0xAD, 0xBE, 0xEF])
            ),
            IPPFakes.attribute(
                tag: IPPTag.octetString,
                name: "vendor-binary",
                value: Data([0xFF, 0xFE, 0x00])
            )
        ]
        let response = try IPPResponseParser.parse(
            IPPFakes.response(groups: [(IPPTag.printerAttributes, attributes)])
        )

        if case .outOfBand(let tag)? = response.firstValue(named: "printer-alerts") {
            XCTAssertEqual(tag, IPPTag.noValue)
        } else {
            XCTFail("Expected an out-of-band printer-alerts value")
        }
        if case .raw(let tag, let data)? = response.firstValue(named: "vendor-unknown") {
            XCTAssertEqual(tag, 0x7F)
            XCTAssertEqual(data, Data([0xDE, 0xAD, 0xBE, 0xEF]))
        } else {
            XCTFail("Expected an unknown tag to be preserved as raw data")
        }

        let status = IPPStatusMapper.status(
            from: response,
            printer: Printer(id: "office", name: "Office")
        )
        XCTAssertEqual(status.state, .idle)
    }

    func testTruncatedResponsesFailGracefully() {
        let valid = IPPFakes.response(
            groups: [(IPPTag.printerAttributes, [
                IPPFakes.integer(IPPTag.enumeration, name: "printer-state", value: 3),
                IPPFakes.markerCollection(name: "Black Ink", color: "#000000", level: 80)
            ])]
        )
        let truncated = valid.dropLast(6)

        XCTAssertThrowsError(try IPPResponseParser.parse(Data(truncated)))
        XCTAssertNil(IPPResponseParser.parseOrNil(Data(truncated)))
        XCTAssertThrowsError(try IPPResponseParser.parse(Data([2, 0, 0, 0])))
        XCTAssertNil(IPPResponseParser.parseOrNil(Data()))
    }

    func testIPPErrorResponseMapsToUnavailableAndPreservesState() throws {
        let response = try IPPResponseParser.parse(
            IPPFakes.response(statusCode: 0x0406, groups: [])
        )
        XCTAssertFalse(response.isSuccess)
        XCTAssertEqual(response.statusNote?.contains("not found"), true)

        let printer = Printer(
            id: "office",
            name: "Office",
            state: .processing,
            stateReasons: ["paused"]
        )
        let unavailable = IPPStatusMapper.status(from: response, printer: printer)
        XCTAssertEqual(unavailable.state, .processing)
        XCTAssertEqual(unavailable.stateReasons, ["paused"])
        XCTAssertEqual(unavailable.origin, .unavailable)
        XCTAssertTrue(unavailable.note?.contains("not found") == true)

        let fallbackSupply = SupplyLevel(
            name: "Black Toner",
            kind: .toner,
            colorName: "Black",
            levelPercent: 42
        )
        let snmp = IPPStatusMapper.status(
            from: response,
            printer: printer,
            snmpSupplies: [fallbackSupply]
        )
        XCTAssertEqual(snmp.state, .processing)
        XCTAssertEqual(snmp.origin, .snmp)
        XCTAssertEqual(snmp.supplies, [fallbackSupply])
        XCTAssertTrue(snmp.note?.contains("SNMP") == true)
    }

    func testSuccessWithoutMarkersAndWithSNMPSuppliesUsesSNMPOrigin() throws {
        let response = try IPPResponseParser.parse(
            IPPFakes.response(groups: [(IPPTag.printerAttributes, [
                IPPFakes.integer(IPPTag.enumeration, name: "printer-state", value: 3)
            ])])
        )
        let supply = SupplyLevel(name: "Cyan Ink", kind: .ink, colorName: "Cyan", levelPercent: 55)
        let status = IPPStatusMapper.status(
            from: response,
            printer: Printer(id: "office", name: "Office"),
            snmpSupplies: [supply]
        )

        XCTAssertEqual(status.state, .idle)
        XCTAssertEqual(status.origin, .snmp)
        XCTAssertEqual(status.supplies, [supply])
        XCTAssertEqual(status.note, "Supply levels read from SNMP.")
    }

    func testRequestBytesContainOperationAndAttributes() {
        let request = IPPRequest(
            printerURI: "http://localhost:631/printers/Office%20Printer",
            requestID: 0x0102_0304
        )
        let data = request.encoded()

        XCTAssertEqual(Array(data.prefix(10)), [
            0x02, 0x00,
            0x00, 0x0B,
            0x01, 0x02, 0x03, 0x04,
            IPPTag.operationAttributes,
            IPPTag.charset
        ])
        XCTAssertEqual(data.last, IPPTag.endOfAttributes)
        XCTAssertTrue(containsAttribute(data, tag: IPPTag.charset, name: "attributes-charset", value: "utf-8"))
        XCTAssertTrue(containsAttribute(data, tag: IPPTag.naturalLanguage, name: "attributes-natural-language", value: "en"))
        XCTAssertTrue(containsAttribute(
            data,
            tag: IPPTag.uri,
            name: "printer-uri",
            value: "http://localhost:631/printers/Office%20Printer"
        ))
        for attribute in IPPRequest.defaultRequestedAttributes {
            XCTAssertTrue(
                containsAttribute(data, tag: IPPTag.keyword, name: "requested-attributes", value: attribute),
                "Missing requested attribute \(attribute)"
            )
        }
        XCTAssertEqual(
            occurrences(of: Data("requested-attributes".utf8), in: data),
            IPPRequest.defaultRequestedAttributes.count
        )
        XCTAssertEqual(request.operationID, 0x000B)
    }

    func testEndpointURLUsesCUPSHostEnvironmentAndPercentEncoding() {
        XCTAssertEqual(
            IPPStatusClient.endpointURL(
                queue: "My Printer/Test",
                cupsHost: nil,
                environment: [:]
            ).absoluteString,
            "http://localhost:631/printers/My%20Printer%2FTest"
        )
        XCTAssertEqual(
            IPPStatusClient.endpointURL(
                queue: "Office",
                cupsHost: nil,
                environment: ["CUPS_SERVER": "print.local:8631"]
            ).absoluteString,
            "http://print.local:8631/printers/Office"
        )
        XCTAssertEqual(
            IPPStatusClient.endpointURL(
                queue: "Office",
                cupsHost: nil,
                environment: ["CUPS_SERVER": "https://cups.example.com"]
            ).absoluteString,
            "https://cups.example.com/printers/Office"
        )
        XCTAssertEqual(
            IPPStatusClient.endpointURL(
                queue: "Office",
                cupsHost: "http://192.168.1.5:631",
                environment: ["CUPS_SERVER": "ignored:631"]
            ).absoluteString,
            "http://192.168.1.5:631/printers/Office"
        )
        XCTAssertEqual(
            IPPStatusClient.endpointURL(
                queue: "Office",
                cupsHost: nil,
                environment: ["CUPS_SERVER": "ipp://print.local:631"]
            ).absoluteString,
            "http://print.local:631/printers/Office"
        )
    }

    func testClientInitializationVariants() {
        _ = IPPStatusClient()
        _ = IPPStatusClient(cupsHost: nil)
        _ = IPPStatusClient(
            cupsHost: "http://localhost:631",
            snmpEnabled: false,
            timeout: 0.5
        )
    }

    func testPrinterURIUsesIPPSchemeForIPPRequest() {
        let http = URL(string: "http://localhost:631/printers/Office%20Printer")!
        XCTAssertEqual(
            IPPStatusClient.ippPrinterURI(for: http),
            "ipp://localhost:631/printers/Office%20Printer"
        )

        let https = URL(string: "https://print.local:631/printers/Office")!
        XCTAssertEqual(
            IPPStatusClient.ippPrinterURI(for: https),
            "ipps://print.local:631/printers/Office"
        )
    }

    func testSNMPHostExtraction() {
        XCTAssertEqual(
            IPPStatusClient.snmpHost(from: "socket://192.168.1.50:9100"),
            "192.168.1.50"
        )
        XCTAssertEqual(
            IPPStatusClient.snmpHost(from: "ipp://printer.local/ipp/print"),
            "printer.local"
        )
        XCTAssertEqual(
            IPPStatusClient.snmpHost(from: "ipps://printer.local/ipp/print"),
            "printer.local"
        )
        XCTAssertEqual(
            IPPStatusClient.snmpHost(from: "lpd://printer.local/queue"),
            "printer.local"
        )
        XCTAssertNil(IPPStatusClient.snmpHost(from: "usb://HP/LaserJet"))
        XCTAssertNil(IPPStatusClient.snmpHost(from: "socket://localhost:9100"))
        XCTAssertNil(IPPStatusClient.snmpHost(from: nil))
    }

    func testStateMappingAndReasonNormalization() {
        XCTAssertEqual(IPPStatusMapper.state(from: [.enumeration(3)]), .idle)
        XCTAssertEqual(IPPStatusMapper.state(from: [.enumeration(4)]), .processing)
        XCTAssertEqual(IPPStatusMapper.state(from: [.enumeration(5)]), .stopped)
        XCTAssertEqual(IPPStatusMapper.state(from: [.integer(99)]), nil)
        XCTAssertEqual(IPPStatusMapper.state(from: [.string("4")]), .processing)

        XCTAssertEqual(
            IPPStatusMapper.reasons(
                from: [.string("none"), .string("media-empty-error,cover-open-error")],
                fallback: ["paused"]
            ),
            ["media-empty-error", "cover-open-error"]
        )
        XCTAssertEqual(
            IPPStatusMapper.reasons(from: [], fallback: ["paused"]),
            ["paused"]
        )
        XCTAssertEqual(
            IPPStatusMapper.reasons(from: [.string("none")], fallback: ["paused"]),
            []
        )
    }

    func testSupplyNormalizationSentinelsAndColors() {
        XCTAssertNil(IPPSupplyNormalizer.normalizedPercent(level: -1, capacity: nil))
        XCTAssertNil(IPPSupplyNormalizer.normalizedPercent(level: 101, capacity: nil))
        XCTAssertEqual(IPPSupplyNormalizer.normalizedPercent(level: 80, capacity: 100), 80)
        XCTAssertEqual(IPPSupplyNormalizer.normalizedPercent(level: 50, capacity: 200), 25)
        XCTAssertEqual(IPPSupplyNormalizer.normalizedPercent(level: 450, capacity: 500), 90)
        XCTAssertEqual(IPPSupplyNormalizer.normalizedPercent(level: 80, capacity: 0), 80)
        XCTAssertEqual(IPPSupplyNormalizer.normalizedPercent(level: 120, capacity: 100), 100)

        XCTAssertEqual(IPPSupplyNormalizer.colorName(fromToken: "#000000"), "Black")
        XCTAssertEqual(IPPSupplyNormalizer.colorName(fromToken: "#00FFFF"), "Cyan")
        XCTAssertEqual(IPPSupplyNormalizer.colorName(fromToken: "lightCyan"), "Light Cyan")
        XCTAssertEqual(IPPSupplyNormalizer.colorName(fromToken: "lightMagenta"), "Light Magenta")
        XCTAssertEqual(IPPSupplyNormalizer.colorName(fromToken: "photoBlack"), "Photo Black")
        XCTAssertEqual(IPPSupplyNormalizer.colorName(fromToken: "matteBlack"), "Matte Black")
        XCTAssertEqual(IPPSupplyNormalizer.colorName(fromToken: "Magenta"), "Magenta")
        XCTAssertEqual(IPPSupplyNormalizer.colorName(fromToken: "#123456"), "#123456")
        XCTAssertNil(IPPSupplyNormalizer.colorName(fromToken: "none"))
        XCTAssertEqual(
            IPPSupplyNormalizer.colorName(inText: "Black Ink Cartridge"),
            "Black"
        )

        XCTAssertEqual(
            IPPSupplyNormalizer.kind(typeTokens: ["wasteInk"], name: "Waste Tank", color: nil),
            .waste
        )
        XCTAssertEqual(
            IPPSupplyNormalizer.kind(typeTokens: ["toner"], name: "Black", color: "Black"),
            .toner
        )
        XCTAssertEqual(
            IPPSupplyNormalizer.kind(typeTokens: ["drum"], name: "Drum", color: nil),
            .drum
        )
        XCTAssertEqual(
            IPPSupplyNormalizer.kind(typeTokens: ["fuser"], name: "Fuser", color: nil),
            .maintenance
        )
        XCTAssertEqual(
            IPPSupplyNormalizer.kind(typeTokens: ["mystery"], name: "Module", color: nil),
            .other
        )
    }

    // MARK: - Helpers

    private func containsAttribute(
        _ data: Data,
        tag: UInt8,
        name: String,
        value: String
    ) -> Bool {
        var expected = Data([tag])
        let nameData = Data(name.utf8)
        expected.append(contentsOf: [
            UInt8(truncatingIfNeeded: nameData.count >> 8),
            UInt8(truncatingIfNeeded: nameData.count)
        ])
        expected.append(nameData)
        let valueData = Data(value.utf8)
        expected.append(contentsOf: [
            UInt8(truncatingIfNeeded: valueData.count >> 8),
            UInt8(truncatingIfNeeded: valueData.count)
        ])
        expected.append(valueData)
        return data.range(of: expected) != nil
    }

    private func occurrences(of needle: Data, in haystack: Data) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var searchRange = haystack.startIndex..<haystack.endIndex
        while let found = haystack.range(of: needle, options: [], in: searchRange) {
            count += 1
            searchRange = found.upperBound..<haystack.endIndex
        }
        return count
    }
}
