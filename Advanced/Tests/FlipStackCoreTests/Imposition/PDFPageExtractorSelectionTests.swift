import AppKit
import Foundation
import PDFKit
import XCTest
@testable import FlipStackCore

/// `PDFPageExtractor` selection edge cases: single page, reversed order
/// input, duplicates, and out-of-range handling.
final class PDFPageExtractorSelectionTests: XCTestCase {
    private var testRoot: URL!

    override func setUpWithError() throws {
        testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("FlipStackPageSelectionEdgeTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: testRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let testRoot {
            try? FileManager.default.removeItem(at: testRoot)
        }
    }

    func testSinglePageExtraction() throws {
        let source = try makeLabeledPDF(pageCount: 6)
        let output = testRoot.appendingPathComponent("single.pdf")

        let count = try PDFPageExtractor.extract(from: source, pageNumbers: [3], to: output)
        XCTAssertEqual(count, 1)

        let selected = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(selected.pageCount, 1)
        XCTAssertEqual(
            selected.page(at: 0)?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
            "Page 3"
        )
    }

    func testReversedOrderInputIsCopiedInGivenOrder() throws {
        let source = try makeLabeledPDF(pageCount: 6)
        let output = testRoot.appendingPathComponent("reversed.pdf")

        let count = try PDFPageExtractor.extract(
            from: source,
            pageNumbers: [6, 4, 2],
            to: output
        )
        XCTAssertEqual(count, 3)

        let selected = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(
            (0..<selected.pageCount).map {
                selected.page(at: $0)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            },
            ["Page 6", "Page 4", "Page 2"]
        )
    }

    func testDuplicatePageNumbersCollapseToOneCopy() throws {
        let source = try makeLabeledPDF(pageCount: 6)

        let onlyDuplicates = testRoot.appendingPathComponent("dupes.pdf")
        let count = try PDFPageExtractor.extract(
            from: source,
            pageNumbers: [2, 2, 2],
            to: onlyDuplicates
        )
        XCTAssertEqual(count, 1)
        let selected = try XCTUnwrap(PDFDocument(url: onlyDuplicates))
        XCTAssertEqual(selected.pageCount, 1)
        XCTAssertEqual(
            selected.page(at: 0)?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
            "Page 2"
        )

        let mixed = testRoot.appendingPathComponent("mixed-dupes.pdf")
        let mixedCount = try PDFPageExtractor.extract(
            from: source,
            pageNumbers: [5, 1, 5, 1],
            to: mixed
        )
        XCTAssertEqual(mixedCount, 2)
        let mixedDoc = try XCTUnwrap(PDFDocument(url: mixed))
        XCTAssertEqual(
            (0..<mixedDoc.pageCount).map {
                mixedDoc.page(at: $0)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            },
            ["Page 5", "Page 1"]
        )
    }

    func testPageNumbersDeduplicatesAcrossOverlappingRanges() throws {
        let ranges = [
            try XCTUnwrap(PageRange(1, 3)),
            try XCTUnwrap(PageRange(3, 5)),
            try XCTUnwrap(PageRange(2, 2))
        ]
        XCTAssertEqual(
            try PDFPageExtractor.pageNumbers(for: ranges, pageCount: 8),
            [1, 2, 3, 4, 5]
        )
    }

    func testOutOfRangeSelectionThrows() throws {
        let source = try makeLabeledPDF(pageCount: 6)
        let output = testRoot.appendingPathComponent("out-of-range.pdf")

        XCTAssertThrowsError(
            try PDFPageExtractor.extract(from: source, pageNumbers: [7], to: output)
        ) { error in
            XCTAssertEqual(error as? PDFPageExtractor.ExtractError, .pageOutOfRange(7))
        }

        XCTAssertThrowsError(
            try PDFPageExtractor.extract(from: source, pageNumbers: [0], to: output)
        ) { error in
            XCTAssertEqual(error as? PDFPageExtractor.ExtractError, .pageOutOfRange(0))
        }

        XCTAssertThrowsError(
            try PDFPageExtractor.pageNumbers(
                for: [try XCTUnwrap(PageRange(1, 7))],
                pageCount: 6
            )
        ) { error in
            XCTAssertEqual(error as? PDFPageExtractor.ExtractError, .pageOutOfRange(7))
        }
    }

    func testEmptyInputThrows() throws {
        let source = try makeLabeledPDF(pageCount: 6)
        let output = testRoot.appendingPathComponent("empty.pdf")

        XCTAssertThrowsError(
            try PDFPageExtractor.extract(from: source, pageNumbers: [], to: output)
        ) { error in
            XCTAssertEqual(error as? PDFPageExtractor.ExtractError, .emptySelection)
        }

        XCTAssertThrowsError(
            try PDFPageExtractor.pageNumbers(for: [], pageCount: 6)
        ) { error in
            XCTAssertEqual(error as? PDFPageExtractor.ExtractError, .emptySelection)
        }

        XCTAssertThrowsError(
            try PDFPageExtractor.pageNumbers(
                for: [try XCTUnwrap(PageRange(1, 1))],
                pageCount: 0
            )
        ) { error in
            XCTAssertEqual(error as? PDFPageExtractor.ExtractError, .unreadableDocument)
        }
    }

    private func makeLabeledPDF(pageCount: Int) throws -> URL {
        let url = testRoot.appendingPathComponent("source-\(UUID().uuidString).pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 400, height: 600)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw NSError(domain: "PDFPageExtractorSelectionTests", code: 1)
        }
        for page in 1...pageCount {
            context.beginPDFPage(nil)
            context.setFillColor(NSColor.white.cgColor)
            context.fill(mediaBox)
            let graphics = NSGraphicsContext(cgContext: context, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 28, weight: .bold),
                .foregroundColor: NSColor.black
            ]
            ("Page \(page)" as NSString).draw(
                at: CGPoint(x: 60, y: 300),
                withAttributes: attributes
            )
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }
}
