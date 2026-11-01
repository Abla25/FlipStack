import CoreGraphics
import XCTest
@testable import FlipStackCore

final class PaperSizeCatalogTests: XCTestCase {
    func testStandardKeywordsResolve() {
        XCTAssertEqual(PaperSizeCatalog.size(forKeyword: "A4"), CGSize(width: 595.28, height: 841.89))
        XCTAssertEqual(PaperSizeCatalog.size(forKeyword: "Letter"), CGSize(width: 612, height: 792))
        XCTAssertEqual(PaperSizeCatalog.size(forKeyword: "Legal"), CGSize(width: 612, height: 1008))
        XCTAssertEqual(PaperSizeCatalog.size(forKeyword: "A5"), CGSize(width: 419.53, height: 595.28))
        XCTAssertEqual(PaperSizeCatalog.size(forKeyword: "Tabloid"), CGSize(width: 792, height: 1224))
    }

    func testVendorPrefixesAndSuffixesAreNormalized() {
        XCTAssertEqual(PaperSizeCatalog.size(forKeyword: "na-letter"), CGSize(width: 612, height: 792))
        XCTAssertEqual(PaperSizeCatalog.size(forKeyword: "iso-a4"), CGSize(width: 595.28, height: 841.89))
        XCTAssertEqual(PaperSizeCatalog.size(forKeyword: "oe_photo-4x6"), CGSize(width: 288, height: 432))
        XCTAssertEqual(PaperSizeCatalog.size(forKeyword: "A4.Borderless"), CGSize(width: 595.28, height: 841.89))
        XCTAssertEqual(PaperSizeCatalog.size(forKeyword: "\"A5\""), CGSize(width: 419.53, height: 595.28))
    }

    func testUnknownKeywordsReturnNil() {
        XCTAssertNil(PaperSizeCatalog.size(forKeyword: "custom-999x999"))
        XCTAssertNil(PaperSizeCatalog.size(forKeyword: ""))
    }

    func testLandscapeKeywordsAreDetected() {
        XCTAssertTrue(PaperSizeCatalog.isLandscapeKeyword("A4.Landscape"))
        XCTAssertTrue(PaperSizeCatalog.isLandscapeKeyword("LetterLandscape"))
        XCTAssertFalse(PaperSizeCatalog.isLandscapeKeyword("A4"))
    }
}
