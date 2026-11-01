import CoreGraphics
import XCTest
@testable import FlipStackCore

/// Additional keyword spellings, landscape detection, and nil cases for
/// `PaperSizeCatalog`.
final class PaperSizeCatalogKeywordTests: XCTestCase {
    func testPhotoAndEnvelopeSpellingsResolve() {
        XCTAssertEqual(
            PaperSizeCatalog.size(forKeyword: "oe_photo-5x7"),
            CGSize(width: 360, height: 504)
        )
        XCTAssertEqual(
            PaperSizeCatalog.size(forKeyword: "OE_PHOTO-5X7"),
            CGSize(width: 360, height: 504)
        )
        XCTAssertEqual(
            PaperSizeCatalog.size(forKeyword: "photo-5x7"),
            CGSize(width: 360, height: 504)
        )
        XCTAssertEqual(
            PaperSizeCatalog.size(forKeyword: "envC5"),
            CGSize(width: 459, height: 649)
        )
        XCTAssertEqual(
            PaperSizeCatalog.size(forKeyword: "ENVC5"),
            CGSize(width: 459, height: 649)
        )
        XCTAssertEqual(
            PaperSizeCatalog.size(forKeyword: "envdl"),
            CGSize(width: 312, height: 624)
        )
        XCTAssertEqual(
            PaperSizeCatalog.size(forKeyword: "EnvMonarch"),
            CGSize(width: 279, height: 540)
        )
        XCTAssertEqual(
            PaperSizeCatalog.size(forKeyword: "env10"),
            CGSize(width: 297, height: 684)
        )
        XCTAssertEqual(
            PaperSizeCatalog.size(forKeyword: "Envelope10"),
            CGSize(width: 297, height: 684)
        )
    }

    func testQuotedKeywordsAreUnwrappedBeforeLookup() {
        XCTAssertEqual(
            PaperSizeCatalog.size(forKeyword: "\"oe_photo-5x7\""),
            CGSize(width: 360, height: 504)
        )
        XCTAssertEqual(
            PaperSizeCatalog.size(forKeyword: "\"A4\""),
            CGSize(width: 595.28, height: 841.89)
        )
        XCTAssertEqual(
            PaperSizeCatalog.size(forKeyword: "\"na-letter\""),
            CGSize(width: 612, height: 792)
        )
        XCTAssertEqual(
            PaperSizeCatalog.size(forKeyword: "  \"iso-a5\"  "),
            CGSize(width: 419.53, height: 595.28)
        )
    }

    func testFullBleedAndSuffixVariantsResolveToBaseSize() {
        XCTAssertEqual(
            PaperSizeCatalog.size(forKeyword: "A4.FullBleed"),
            CGSize(width: 595.28, height: 841.89)
        )
        XCTAssertEqual(
            PaperSizeCatalog.size(forKeyword: "a4.fullbleed"),
            CGSize(width: 595.28, height: 841.89)
        )
        XCTAssertEqual(
            PaperSizeCatalog.size(forKeyword: "Letter.Borderless"),
            CGSize(width: 612, height: 792)
        )
        XCTAssertEqual(
            PaperSizeCatalog.size(forKeyword: "oe_photo-5x7.FullBleed"),
            CGSize(width: 360, height: 504)
        )
        XCTAssertEqual(
            PaperSizeCatalog.size(forKeyword: "na-letter.landscape"),
            CGSize(width: 612, height: 792)
        )
    }

    func testLandscapeKeywordsAreDetected() {
        XCTAssertTrue(PaperSizeCatalog.isLandscapeKeyword("A4.Landscape"))
        XCTAssertTrue(PaperSizeCatalog.isLandscapeKeyword("LANDSCAPE"))
        XCTAssertTrue(PaperSizeCatalog.isLandscapeKeyword("oe_photo-5x7.landscape"))
        XCTAssertTrue(PaperSizeCatalog.isLandscapeKeyword("  Letter.Landscape  "))
        XCTAssertTrue(PaperSizeCatalog.isLandscapeKeyword("na-letter-landscape"))

        XCTAssertFalse(PaperSizeCatalog.isLandscapeKeyword("A4"))
        XCTAssertFalse(PaperSizeCatalog.isLandscapeKeyword("A4.FullBleed"))
        XCTAssertFalse(PaperSizeCatalog.isLandscapeKeyword("letter"))
        XCTAssertFalse(PaperSizeCatalog.isLandscapeKeyword(""))
        XCTAssertFalse(PaperSizeCatalog.isLandscapeKeyword("   "))
        XCTAssertFalse(PaperSizeCatalog.isLandscapeKeyword("portrait"))
    }

    func testUnknownAndDegenerateKeywordsReturnNil() {
        XCTAssertNil(PaperSizeCatalog.size(forKeyword: ""))
        XCTAssertNil(PaperSizeCatalog.size(forKeyword: "   "))
        XCTAssertNil(PaperSizeCatalog.size(forKeyword: "unknown-size"))
        XCTAssertNil(PaperSizeCatalog.size(forKeyword: "custom-999x999"))
        XCTAssertNil(PaperSizeCatalog.size(forKeyword: "envC5x"))
        // A bare prefix normalizes to the empty key.
        XCTAssertNil(PaperSizeCatalog.size(forKeyword: "na-"))
        XCTAssertNil(PaperSizeCatalog.size(forKeyword: "photo-"))
        // Only the quotes, nothing else.
        XCTAssertNil(PaperSizeCatalog.size(forKeyword: "\"\""))
    }
}
