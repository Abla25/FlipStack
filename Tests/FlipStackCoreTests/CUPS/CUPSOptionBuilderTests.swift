import XCTest
@testable import FlipStackCore

final class CUPSOptionBuilderTests: XCTestCase {
    private let fileURL = URL(fileURLWithPath: "/tmp/FlipStack Test Document.pdf")

    private func request(
        pageSet: PageSet = .all,
        ranges: [PageRange] = [],
        copies: Int = 1,
        numberUp: Int = 1,
        orientation: PrintOrientation = .portrait,
        driverOptions: [String: String] = [:]
    ) -> PrintRequest {
        PrintRequest(
            fileURL: fileURL,
            printerID: "EPSON_L1800_Series",
            title: "FlipStack Test",
            pageSet: pageSet,
            pageRanges: ranges,
            copies: copies,
            numberUp: numberUp,
            orientation: orientation,
            driverOptions: driverOptions
        )
    }

    private func pairStrings(_ request: PrintRequest) -> [String] {
        CUPSOptionBuilder.optionPairs(for: request).map { "\($0.0)=\($0.1)" }
    }

    func testOddPageSetAndRangesAreExact() {
        let value = request(
            pageSet: .odd,
            ranges: [PageRange(1, 3)!, PageRange(5, 5)!]
        )
        XCTAssertEqual(pairStrings(value), [
            "page-set=odd",
            "page-ranges=1-3,5",
            "number-up=1",
            "orientation-requested=3",
            "scaling=100"
        ])
        XCTAssertEqual(CUPSOptionBuilder.arguments(for: value), [
            "-d", "EPSON_L1800_Series",
            "-t", "FlipStack Test",
            "-n", "1",
            "-o", "page-set=odd",
            "-o", "page-ranges=1-3,5",
            "-o", "number-up=1",
            "-o", "orientation-requested=3",
            "-o", "scaling=100",
            fileURL.path
        ])
    }

    func testEvenPageSetPreservesRangeOrderAndNeverReverses() {
        let value = request(
            pageSet: .even,
            ranges: [PageRange(2, 4)!, PageRange(8, 8)!]
        )
        let pairs = pairStrings(value)
        XCTAssertEqual(pairs, [
            "page-set=even",
            "page-ranges=2-4,8",
            "number-up=1",
            "orientation-requested=3",
            "scaling=100"
        ])
        let joined = pairs.joined(separator: " ")
        XCTAssertFalse(joined.contains("output-order"))
        XCTAssertFalse(joined.contains("reverse"))
        XCTAssertFalse(CUPSOptionBuilder.arguments(for: value).joined(separator: " ").contains("reverse"))
    }

    func testNumberUpAndOrientation() {
        let value = request(
            numberUp: 2,
            orientation: .reverseLandscape
        )
        XCTAssertEqual(pairStrings(value), [
            "page-set=all",
            "number-up=2",
            "orientation-requested=5",
            "scaling=100"
        ])
    }

    func testFitToPageIsAnExplicitCupsOption() {
        var value = request()
        value.fitToPage = true
        XCTAssertEqual(pairStrings(value), [
            "page-set=all",
            "number-up=1",
            "orientation-requested=3",
            "fit-to-page=true"
        ])
        XCTAssertTrue(
            CUPSOptionBuilder.arguments(for: value).contains("fit-to-page=true")
        )
    }

    func testScaleIsExplicitWhenFitIsOff() {
        var value = request()
        value.scalePercent = 90
        XCTAssertEqual(pairStrings(value), [
            "page-set=all",
            "number-up=1",
            "orientation-requested=3",
            "scaling=90"
        ])
    }

    func testAllOrientationValues() {
        XCTAssertEqual(CUPSOptionBuilder.optionPairs(for: request(orientation: .landscape)).first { $0.0 == "orientation-requested" }?.1, "4")
        XCTAssertEqual(CUPSOptionBuilder.optionPairs(for: request(orientation: .reverseLandscape)).first { $0.0 == "orientation-requested" }?.1, "5")
        XCTAssertEqual(CUPSOptionBuilder.optionPairs(for: request(orientation: .reversePortrait)).first { $0.0 == "orientation-requested" }?.1, "6")
        XCTAssertEqual(CUPSOptionBuilder.optionPairs(for: request(orientation: .portrait)).first { $0.0 == "orientation-requested" }?.1, "3")
    }

    func testDriverOptionsAreSortedIncludingDuplexAndPPDOptions() {
        let value = request(driverOptions: [
            "PageSize": "A4",
            "Duplex": "NoTumble",
            "ColorModel": "Grayscale",
            "MediaType": "PLAIN"
        ])
        XCTAssertEqual(pairStrings(value), [
            "page-set=all",
            "number-up=1",
            "orientation-requested=3",
            "scaling=100",
            "ColorModel=Grayscale",
            "Duplex=NoTumble",
            "MediaType=PLAIN",
            "PageSize=A4"
        ])
    }

    func testDuplexTumble() {
        let value = request(driverOptions: ["Duplex": "Tumble"])
        XCTAssertEqual(pairStrings(value), [
            "page-set=all",
            "number-up=1",
            "orientation-requested=3",
            "scaling=100",
            "Duplex=Tumble"
        ])
    }

    func testCopiesAreAlwaysExplicit() {
        let single = request(copies: 1)
        XCTAssertEqual(Array(CUPSOptionBuilder.arguments(for: single).prefix(6)), [
            "-d", "EPSON_L1800_Series",
            "-t", "FlipStack Test",
            "-n", "1"
        ])

        let multiple = request(copies: 3)
        let arguments = CUPSOptionBuilder.arguments(for: multiple)
        XCTAssertEqual(Array(arguments.prefix(6)), [
            "-d", "EPSON_L1800_Series",
            "-t", "FlipStack Test",
            "-n", "3"
        ])
        XCTAssertEqual(arguments.last, fileURL.path)
    }

    func testFullOrderingWithEveryOption() {
        let value = request(
            pageSet: .odd,
            ranges: [PageRange(1, 3)!],
            copies: 2,
            numberUp: 2,
            orientation: .landscape,
            driverOptions: ["Duplex": "NoTumble", "ColorModel": "Color", "PageSize": "A4"]
        )
        XCTAssertEqual(CUPSOptionBuilder.arguments(for: value), [
            "-d", "EPSON_L1800_Series",
            "-t", "FlipStack Test",
            "-n", "2",
            "-o", "page-set=odd",
            "-o", "page-ranges=1-3",
            "-o", "number-up=2",
            "-o", "orientation-requested=4",
            "-o", "scaling=100",
            "-o", "ColorModel=Color",
            "-o", "Duplex=NoTumble",
            "-o", "PageSize=A4",
            fileURL.path
        ])
    }

    func testExplicitPageReversalOptionsAreSuppressed() {
        let value = request(driverOptions: [
            "output-order": "reverse",
            "PageSize": "A4"
        ])
        XCTAssertEqual(pairStrings(value), [
            "page-set=all",
            "number-up=1",
            "orientation-requested=3",
            "scaling=100",
            "PageSize=A4"
        ])
        XCTAssertFalse(CUPSOptionBuilder.arguments(for: value).joined().contains("output-order"))
    }

    func testReservedLayoutOptionsCannotComeFromDriverOptions() {
        let value = request(driverOptions: [
            "page-set": "even",
            "page-ranges": "9-1",
            "number-up": "4",
            "orientation-requested": "5",
            "PageSize": "A4"
        ])
        XCTAssertEqual(pairStrings(value), [
            "page-set=all",
            "number-up=1",
            "orientation-requested=3",
            "scaling=100",
            "PageSize=A4"
        ])
    }

    func testFileWithSpacesIsASingleArgumentAndNotQuoted() {
        let arguments = CUPSOptionBuilder.arguments(for: request())
        XCTAssertEqual(arguments.last, fileURL.path)
        XCTAssertFalse(arguments.last!.hasPrefix("\""))
    }
}
