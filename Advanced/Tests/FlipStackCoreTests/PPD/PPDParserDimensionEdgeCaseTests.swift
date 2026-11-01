import CoreGraphics
import Foundation
import XCTest
@testable import FlipStackCore

/// `*PaperDimension` / `*ImageableArea` parsing edge cases: whitespace,
/// tabs, garbage values, duplicate keys, mixed-case keywords, plus a sweep
/// over every fixture PPD in Tests/FlipStackCoreTests/Fixtures/PPDs.
final class PPDParserDimensionEdgeCaseTests: XCTestCase {
    private let parser = PPDParser()

    func testExtraWhitespaceAndTabsAroundHeaderAndColonAreTolerated() {
        let contents = """
        *PPD-Adobe: "4.3"
        *PaperDimension   A4 :   "595.28    841.89"
        *PaperDimension\tLetter:\t"612 792"
        *\tPaperDimension Legal: "612    1008"
        *ImageableArea   4x6:    "12 12   276  420"
        *\tImageableArea\tA5:\t"18  12 401.53 583.28"
        *End
        """
        let document = parser.parse(contents: contents)

        XCTAssertEqual(document.paperDimensions["a4"], CGSize(width: 595.28, height: 841.89))
        XCTAssertEqual(document.paperDimensions["letter"], CGSize(width: 612, height: 792))
        XCTAssertEqual(document.paperDimensions["legal"], CGSize(width: 612, height: 1008))
        XCTAssertEqual(
            document.imageableAreas["4x6"],
            CGRect(x: 12, y: 12, width: 264, height: 408)
        )
        XCTAssertEqual(
            document.imageableAreas["a5"],
            CGRect(x: 18, y: 12, width: 383.53, height: 571.28)
        )
        XCTAssertEqual(document.paperSize(for: "A4"), CGSize(width: 595.28, height: 841.89))
        XCTAssertEqual(document.imageableArea(for: "Letter"), nil)
    }

    func testGarbageDimensionAndAreaValuesAreRejected() {
        let contents = """
        *PPD-Adobe: "4.3"
        *PaperDimension Good: "288 432"
        *PaperDimension NoNumbers: "not numbers"
        *PaperDimension OneNumber: "612"
        *PaperDimension ThreeNumbers: "1 2 3"
        *PaperDimension Negative: "-10 800"
        *PaperDimension ZeroWidth: "0 800"
        *PaperDimension ZeroHeight: "800 0"
        *ImageableArea GoodArea: "18 12 577.28 829.89"
        *ImageableArea TooFew: "1 2 3"
        *ImageableArea TooMany: "1 2 3 4 5"
        *ImageableArea Inverted: "100 100 50 200"
        *ImageableArea Empty: "0 0 0 0"
        *ImageableArea NegativeOrigin: "-5 -5 590 836"
        *End
        """
        let document = parser.parse(contents: contents)

        XCTAssertEqual(document.paperDimensions, ["good": CGSize(width: 288, height: 432)])
        XCTAssertEqual(
            document.imageableAreas["goodarea"],
            CGRect(x: 18, y: 12, width: 559.28, height: 817.89)
        )
        // A negative origin is legal as long as right > left and top > bottom.
        XCTAssertEqual(
            document.imageableAreas["negativeorigin"],
            CGRect(x: -5, y: -5, width: 595, height: 841)
        )
        XCTAssertEqual(document.imageableAreas.count, 2)
    }

    func testDuplicateKeysLastWinsAndKeywordTokensAreCaseInsensitive() {
        let contents = """
        *PPD-Adobe: "4.3"
        *PaperDimension A4: "595.28 841.89"
        *PaperDimension a4: "600 800"
        *PAPERDIMENSION Legal: "612 1008"
        *paperDimension letter: "612 792"
        *ImageableArea A4: "0 0 595.28 841.89"
        *ImageableArea A4: "1 1 594 840"
        *IMAGEABLEAREA Letter: "0 0 612 792"
        *End
        """
        let document = parser.parse(contents: contents)

        XCTAssertEqual(document.paperDimensions, [
            "a4": CGSize(width: 600, height: 800),
            "legal": CGSize(width: 612, height: 1008),
            "letter": CGSize(width: 612, height: 792)
        ])
        XCTAssertEqual(
            document.imageableAreas,
            [
                "a4": CGRect(x: 1, y: 1, width: 593, height: 839),
                "letter": CGRect(x: 0, y: 0, width: 612, height: 792)
            ]
        )
        // Stored dimensions stay reachable through their own keyword.
        XCTAssertEqual(document.paperSize(for: "A4"), CGSize(width: 600, height: 800))
        XCTAssertEqual(document.imageableArea(for: "a4"), CGRect(x: 1, y: 1, width: 593, height: 839))
    }

    func testEveryFixturePPDParsesWithNonEmptyPositivePaperDimensions() throws {
        let directory = CUPSFixtureLocator.ppdDirectory
        let files = try FileManager.default
            .contentsOfDirectory(atPath: directory.path)
            .filter { $0.lowercased().hasSuffix(".ppd") }
            .sorted()
        XCTAssertGreaterThanOrEqual(files.count, 2, "expected the bundled fixture PPDs")

        for name in files {
            let document = try parser.parse(url: directory.appendingPathComponent(name))
            XCTAssertFalse(
                document.paperDimensions.isEmpty,
                "\(name) parsed with no *PaperDimension entries"
            )
            for (keyword, size) in document.paperDimensions {
                XCTAssertGreaterThan(size.width, 0, "\(name) \(keyword) width")
                XCTAssertGreaterThan(size.height, 0, "\(name) \(keyword) height")
                XCTAssertNotNil(
                    document.paperSize(for: keyword),
                    "\(name) stored dimension \(keyword) is not reachable via paperSize(for:)"
                )
            }
        }
    }

    // MARK: - Characterized source quirks (reported, not fixed here)

    /// A tab *between the numbers* of a PaperDimension/ImageableArea value is
    /// silently dropped: the value splitter only treats ASCII space as a
    /// separator, so `"595.28\t841.89"` never parses. Tabs around the header
    /// and colon are fine (see the whitespace test above).
    func testTabSeparatedNumbersInsideValuesAreParsed() {
        let document = parser.parse(contents: """
        *PPD-Adobe: "4.3"
        *PaperDimension A4: "595.28\t841.89"
        *ImageableArea A4: "0\t0\t595.28\t841.89"
        *End
        """)
        XCTAssertEqual(document.paperDimensions["a4"], CGSize(width: 595.28, height: 841.89))
        XCTAssertEqual(
            document.imageableAreas["a4"],
            CGRect(x: 0, y: 0, width: 595.28, height: 841.89)
        )
    }

    /// A quoted PaperDimension keyword is stored without quotes, so
    /// `paperSize(for: "Custom10x15")` finds the PPD's own dimension.
    func testQuotedPaperDimensionKeywordIsStoredWithoutQuotes() {
        let document = parser.parse(contents: """
        *PPD-Adobe: "4.3"
        *PaperDimension "Custom10x15": "720 1080"
        *End
        """)
        XCTAssertEqual(
            document.paperDimensions["custom10x15"],
            CGSize(width: 720, height: 1080)
        )
        XCTAssertEqual(
            document.paperSize(for: "Custom10x15"),
            CGSize(width: 720, height: 1080)
        )
    }
}
