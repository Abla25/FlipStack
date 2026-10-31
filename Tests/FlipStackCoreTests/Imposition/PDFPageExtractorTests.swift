import AppKit
import Foundation
import PDFKit
import XCTest
@testable import FlipStackCore

final class PDFPageExtractorTests: XCTestCase {
    private var testRoot: URL!

    override func setUpWithError() throws {
        testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("FlipStackPageSelectionTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: testRoot,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let testRoot {
            try? FileManager.default.removeItem(at: testRoot)
        }
    }

    func testPageNumbersNormalizesAndSorts() throws {
        let ranges = [try XCTUnwrap(PageRange(3, 5)), try XCTUnwrap(PageRange(1, 2)), try XCTUnwrap(PageRange(5, 6))]
        XCTAssertEqual(
            try PDFPageExtractor.pageNumbers(for: ranges, pageCount: 8),
            [1, 2, 3, 4, 5, 6]
        )
    }

    func testPageRangeListAcceptsTypographicDashes() {
        XCTAssertEqual(
            PageRange.list(from: "1–2, 4—5").map(\.cupsValue),
            ["1-2", "4-5"]
        )
    }

    func testPageNumbersRejectOutOfRange() throws {
        let ranges = [try XCTUnwrap(PageRange(1, 9))]
        XCTAssertThrowsError(
            try PDFPageExtractor.pageNumbers(for: ranges, pageCount: 8)
        ) { error in
            XCTAssertEqual(error as? PDFPageExtractor.ExtractError, .pageOutOfRange(9))
        }
    }

    func testExtractionKeepsExactPageOrderAndCount() throws {
        let source = try makeLabeledPDF(pageCount: 6)
        let output = testRoot.appendingPathComponent("selected.pdf")

        let count = try PDFPageExtractor.extract(
            from: source,
            pageNumbers: [4, 2, 5, 2],
            to: output
        )
        XCTAssertEqual(count, 3)

        let selected = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(selected.pageCount, 3)
        XCTAssertEqual(
            (0..<selected.pageCount).map {
                selected.page(at: $0)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            },
            ["Page 4", "Page 2", "Page 5"]
        )
    }

    func testEmptySelectionThrows() {
        XCTAssertThrowsError(
            try PDFPageExtractor.pageNumbers(for: [], pageCount: 4)
        ) { error in
            XCTAssertEqual(error as? PDFPageExtractor.ExtractError, .emptySelection)
        }
    }

    private func makeLabeledPDF(pageCount: Int) throws -> URL {
        let url = testRoot.appendingPathComponent("source-\(UUID().uuidString).pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 400, height: 600)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw NSError(domain: "PDFPageExtractorTests", code: 1)
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
