import XCTest
@testable import FlipStackCore

final class BookletImpositionPlanTests: XCTestCase {
    private let imposer = BookletImposer()

    func testEightPagesProducesTwoSheetSignature() throws {
        let plan = try imposer.plan(pageCount: 8, signatureSheets: nil)

        XCTAssertEqual(plan.sourcePageCount, 8)
        XCTAssertEqual(plan.paddedPageCount, 8)
        XCTAssertEqual(plan.signatureSheetCount, 2)
        XCTAssertEqual(plan.signatureCount, 1)
        XCTAssertEqual(plan.sheetCount, 2)
        XCTAssertEqual(plan.frontPageSequence, [8, 1, 6, 3])
        XCTAssertEqual(plan.backPageSequence, [2, 7, 4, 5])
        XCTAssertEqual(
            plan.spreads,
            [
                BookletSpread(
                    front: BookletPagePair(left: 8, right: 1),
                    back: BookletPagePair(left: 2, right: 7)
                ),
                BookletSpread(
                    front: BookletPagePair(left: 6, right: 3),
                    back: BookletPagePair(left: 4, right: 5)
                )
            ]
        )
        XCTAssertEqual(plan.signatures, [
            BookletSignature(index: 0, firstPage: 1, lastPage: 8, sheetCount: 2)
        ])
    }

    func testFivePagesPadsToEightAndBlanksAllMissingPages() throws {
        let plan = try imposer.plan(pageCount: 5, signatureSheets: nil)

        XCTAssertEqual(plan.sourcePageCount, 5)
        XCTAssertEqual(plan.paddedPageCount, 8)
        XCTAssertEqual(plan.signatureSheetCount, 2)
        XCTAssertEqual(plan.signatureCount, 1)
        XCTAssertEqual(plan.sheetCount, 2)
        // Pages 6, 7, and 8 are padding for a five-page source.
        XCTAssertEqual(plan.frontPageSequence, [nil, 1, nil, 3])
        XCTAssertEqual(plan.backPageSequence, [2, nil, 4, 5])
        XCTAssertEqual(
            plan.spreads,
            [
                BookletSpread(
                    front: BookletPagePair(left: nil, right: 1),
                    back: BookletPagePair(left: 2, right: nil)
                ),
                BookletSpread(
                    front: BookletPagePair(left: nil, right: 3),
                    back: BookletPagePair(left: 4, right: 5)
                )
            ]
        )
        XCTAssertEqual(plan.signatures, [
            BookletSignature(index: 0, firstPage: 1, lastPage: 8, sheetCount: 2)
        ])
    }

    func testSixPagesPadsToEightAndBlanksOnlyPagesSevenAndEight() throws {
        let plan = try imposer.plan(pageCount: 6, signatureSheets: nil)

        XCTAssertEqual(plan.sourcePageCount, 6)
        XCTAssertEqual(plan.paddedPageCount, 8)
        XCTAssertEqual(plan.signatureSheetCount, 2)
        XCTAssertEqual(plan.frontPageSequence, [nil, 1, 6, 3])
        XCTAssertEqual(plan.backPageSequence, [2, nil, 4, 5])
    }

    func testTwelvePagesWithExplicitTwoSheetSignatures() throws {
        let plan = try imposer.plan(pageCount: 12, signatureSheets: 2)

        XCTAssertEqual(plan.sourcePageCount, 12)
        XCTAssertEqual(plan.paddedPageCount, 12)
        XCTAssertEqual(plan.signatureSheetCount, 2)
        XCTAssertEqual(plan.signatureCount, 2)
        XCTAssertEqual(plan.sheetCount, 3)
        XCTAssertEqual(plan.frontPageSequence, [8, 1, 6, 3, 12, 9])
        XCTAssertEqual(plan.backPageSequence, [2, 7, 4, 5, 10, 11])
        XCTAssertEqual(plan.signatures, [
            BookletSignature(index: 0, firstPage: 1, lastPage: 8, sheetCount: 2),
            BookletSignature(index: 1, firstPage: 9, lastPage: 12, sheetCount: 1)
        ])
        XCTAssertEqual(
            plan.spreads.map(\.front),
            [
                BookletPagePair(left: 8, right: 1),
                BookletPagePair(left: 6, right: 3),
                BookletPagePair(left: 12, right: 9)
            ]
        )
        XCTAssertEqual(
            plan.spreads.map(\.back),
            [
                BookletPagePair(left: 2, right: 7),
                BookletPagePair(left: 4, right: 5),
                BookletPagePair(left: 10, right: 11)
            ]
        )
    }

    func testTwelvePagesAutoUsesOneSignature() throws {
        let plan = try imposer.plan(pageCount: 12, signatureSheets: nil)

        XCTAssertEqual(plan.paddedPageCount, 12)
        XCTAssertEqual(plan.signatureSheetCount, 3)
        XCTAssertEqual(plan.signatureCount, 1)
        XCTAssertEqual(plan.sheetCount, 3)
        XCTAssertEqual(plan.frontPageSequence, [12, 1, 10, 3, 8, 5])
        XCTAssertEqual(plan.backPageSequence, [2, 11, 4, 9, 6, 7])
        XCTAssertEqual(plan.signatures, [
            BookletSignature(index: 0, firstPage: 1, lastPage: 12, sheetCount: 3)
        ])
    }

    func testFortyPagesAutoUsesFourSheetSignatures() throws {
        let plan = try imposer.plan(pageCount: 40, signatureSheets: nil)

        XCTAssertEqual(plan.sourcePageCount, 40)
        XCTAssertEqual(plan.paddedPageCount, 40)
        XCTAssertEqual(plan.signatureSheetCount, 4)
        XCTAssertEqual(plan.signatureCount, 3)
        XCTAssertEqual(plan.sheetCount, 10)
        XCTAssertEqual(plan.frontPageSequence.count, 20)
        XCTAssertEqual(plan.backPageSequence.count, 20)
        XCTAssertEqual(plan.signatures, [
            BookletSignature(index: 0, firstPage: 1, lastPage: 16, sheetCount: 4),
            BookletSignature(index: 1, firstPage: 17, lastPage: 32, sheetCount: 4),
            BookletSignature(index: 2, firstPage: 33, lastPage: 40, sheetCount: 2)
        ])

        let emittedPages = (plan.frontPageSequence + plan.backPageSequence).compactMap { $0 }
        XCTAssertEqual(emittedPages.count, 40)
        XCTAssertEqual(Set(emittedPages), Set(1...40))
        XCTAssertEqual(emittedPages.sorted(), Array(1...40))
    }

    func testThreePagesUsesOneSheetAndOneBlank() throws {
        let plan = try imposer.plan(pageCount: 3, signatureSheets: nil)

        XCTAssertEqual(plan.sourcePageCount, 3)
        XCTAssertEqual(plan.paddedPageCount, 4)
        XCTAssertEqual(plan.signatureSheetCount, 1)
        XCTAssertEqual(plan.signatureCount, 1)
        XCTAssertEqual(plan.sheetCount, 1)
        XCTAssertEqual(plan.frontPageSequence, [nil, 1])
        XCTAssertEqual(plan.backPageSequence, [2, 3])
        XCTAssertEqual(
            plan.spreads,
            [
                BookletSpread(
                    front: BookletPagePair(left: nil, right: 1),
                    back: BookletPagePair(left: 2, right: 3)
                )
            ]
        )
    }

    func testOneAndTwoPageDocumentsBecomeOneSheet() throws {
        let onePage = try imposer.plan(pageCount: 1, signatureSheets: nil)
        XCTAssertEqual(onePage.frontPageSequence, [nil, 1])
        XCTAssertEqual(onePage.backPageSequence, [nil, nil])
        XCTAssertEqual(onePage.sheetCount, 1)

        let twoPages = try imposer.plan(pageCount: 2, signatureSheets: nil)
        XCTAssertEqual(twoPages.frontPageSequence, [nil, 1])
        XCTAssertEqual(twoPages.backPageSequence, [2, nil])
        XCTAssertEqual(twoPages.sheetCount, 1)
    }

    func testExplicitOneSheetCreatesOneSignaturePerSheet() throws {
        let plan = try imposer.plan(pageCount: 8, signatureSheets: 1)

        XCTAssertEqual(plan.signatureSheetCount, 1)
        XCTAssertEqual(plan.signatureCount, 2)
        XCTAssertEqual(plan.frontPageSequence, [4, 1, 8, 5])
        XCTAssertEqual(plan.backPageSequence, [2, 3, 6, 7])
        XCTAssertEqual(plan.signatures, [
            BookletSignature(index: 0, firstPage: 1, lastPage: 4, sheetCount: 1),
            BookletSignature(index: 1, firstPage: 5, lastPage: 8, sheetCount: 1)
        ])
    }

    func testAutoPolicySwitchesAfterSixSheets() throws {
        let sixSheets = try imposer.plan(pageCount: 24, signatureSheets: nil)
        XCTAssertEqual(sixSheets.signatureCount, 1)
        XCTAssertEqual(sixSheets.signatureSheetCount, 6)

        let sevenSheets = try imposer.plan(pageCount: 25, signatureSheets: nil)
        XCTAssertEqual(sevenSheets.paddedPageCount, 28)
        XCTAssertEqual(sevenSheets.signatureCount, 2)
        XCTAssertEqual(sevenSheets.signatureSheetCount, 4)
        XCTAssertEqual(sevenSheets.signatures, [
            BookletSignature(index: 0, firstPage: 1, lastPage: 16, sheetCount: 4),
            BookletSignature(index: 1, firstPage: 17, lastPage: 28, sheetCount: 3)
        ])
    }

    func testExplicitSignatureLargerThanDocumentReportsActualSize() throws {
        let plan = try imposer.plan(pageCount: 8, signatureSheets: 10)

        XCTAssertEqual(plan.signatureSheetCount, 2)
        XCTAssertEqual(plan.signatureCount, 1)
        XCTAssertEqual(plan.sheetCount, 2)
    }

    func testPlanIsDeterministic() throws {
        let first = try imposer.plan(pageCount: 37, signatureSheets: nil)
        let second = try imposer.plan(pageCount: 37, signatureSheets: nil)
        XCTAssertEqual(first, second)
    }

    func testEverySourcePageAppearsOnceForManyPageCounts() throws {
        for pageCount in 1...60 {
            for requestedSheets in [nil, 1, 2, 3, 4, 7] as [Int?] {
                let plan = try imposer.plan(
                    pageCount: pageCount,
                    signatureSheets: requestedSheets
                )

                XCTAssertEqual(plan.paddedPageCount % 4, 0)
                XCTAssertEqual(plan.paddedPageCount, (pageCount + 3) / 4 * 4)
                XCTAssertEqual(plan.sheetCount, plan.paddedPageCount / 4)
                XCTAssertEqual(plan.frontPageSequence.count, plan.sheetCount * 2)
                XCTAssertEqual(plan.backPageSequence.count, plan.sheetCount * 2)
                XCTAssertEqual(plan.spreads.count, plan.sheetCount)
                XCTAssertEqual(plan.signatures.count, plan.signatureCount)
                XCTAssertGreaterThan(plan.signatureCount, 0)

                let emittedPages = (plan.frontPageSequence + plan.backPageSequence)
                let sourcePages = emittedPages.compactMap { $0 }
                XCTAssertEqual(sourcePages.count, pageCount)
                XCTAssertEqual(Set(sourcePages), Set(1...pageCount))
                XCTAssertEqual(Set(sourcePages).count, sourcePages.count)
                XCTAssertEqual(emittedPages.count - sourcePages.count, plan.paddedPageCount - pageCount)

                var expectedFirstPage = 1
                for signature in plan.signatures {
                    XCTAssertEqual(signature.firstPage, expectedFirstPage)
                    XCTAssertEqual((signature.lastPage - signature.firstPage + 1) % 4, 0)
                    XCTAssertEqual(
                        signature.sheetCount,
                        (signature.lastPage - signature.firstPage + 1) / 4
                    )
                    if let requestedSheets {
                        XCTAssertLessThanOrEqual(signature.sheetCount, requestedSheets)
                    }
                    expectedFirstPage = signature.lastPage + 1
                }
                XCTAssertEqual(expectedFirstPage, plan.paddedPageCount + 1)
            }
        }
    }

    func testInvalidPageAndSignatureCountsThrow() {
        XCTAssertThrowsError(try imposer.plan(pageCount: 0, signatureSheets: nil)) { error in
            XCTAssertEqual(error as? BookletError, .emptyDocument)
        }
        XCTAssertThrowsError(try imposer.plan(pageCount: 8, signatureSheets: 0)) { error in
            XCTAssertEqual(error as? BookletError, .invalidSignatureSheetCount(0))
        }
        XCTAssertThrowsError(try imposer.plan(pageCount: 8, signatureSheets: -2)) { error in
            XCTAssertEqual(error as? BookletError, .invalidSignatureSheetCount(-2))
        }
    }
}
