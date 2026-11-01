import AppKit
import CoreGraphics
import Foundation
import PDFKit
import XCTest
@testable import FlipStackCore

/// `PDFPageScaler` bounds (50/150), clamping, rotation handling, page-count
/// and page-order preservation.
final class PDFPageScalerTests: XCTestCase {
    private var testRoot: URL!

    override func setUpWithError() throws {
        testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("FlipStackPageScalerTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: testRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let testRoot {
            try? FileManager.default.removeItem(at: testRoot)
        }
    }

    // MARK: - Scale bounds and clamping

    func testScaleAtBounds50And150PreservesPageCountBoxAndOrder() throws {
        let source = try makeLabeledPDF(pageCount: 5)
        let expectedBox = CGRect(x: 0, y: 0, width: 400, height: 600)

        for percent in [50, 150] {
            let destination = testRoot.appendingPathComponent("scaled-\(percent).pdf")
            let count = try PDFPageScaler.scale(from: source, to: destination, percent: percent)
            XCTAssertEqual(count, 5)

            let scaled = try XCTUnwrap(PDFDocument(url: destination))
            XCTAssertEqual(scaled.pageCount, 5)
            for index in 0..<scaled.pageCount {
                let page = try XCTUnwrap(scaled.page(at: index))
                XCTAssertEqual(page.bounds(for: .mediaBox), expectedBox)
                XCTAssertEqual(
                    page.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                    "Page \(index + 1)"
                )
            }
        }
    }

    func testScaleFactorIsAppliedToPageContent() throws {
        // One 400x600 page with a centered 100x100 black square.
        let source = try makeBlackSquarePDF()
        let page = try XCTUnwrap(PDFDocument(url: source)?.page(at: 0))

        XCTAssertEqual(Double(darkPixelWidth(of: page)), 100, accuracy: 3)

        let at50 = testRoot.appendingPathComponent("square-50.pdf")
        try PDFPageScaler.scale(from: source, to: at50, percent: 50)
        let page50 = try XCTUnwrap(PDFDocument(url: at50)?.page(at: 0))
        XCTAssertEqual(Double(darkPixelWidth(of: page50)), 50, accuracy: 3)

        let at150 = testRoot.appendingPathComponent("square-150.pdf")
        try PDFPageScaler.scale(from: source, to: at150, percent: 150)
        let page150 = try XCTUnwrap(PDFDocument(url: at150)?.page(at: 0))
        XCTAssertEqual(Double(darkPixelWidth(of: page150)), 150, accuracy: 3)
    }

    /// Out-of-range percentages are clamped to 50/150 instead of throwing:
    /// `ScaleError.invalidScale` is unreachable because the clamp runs
    /// before the guard. Characterized here so a future fix flips the test.
    func testOutOfRangePercentIsClampedNotRejected() throws {
        let source = try makeBlackSquarePDF()

        let at10 = testRoot.appendingPathComponent("square-10.pdf")
        let count10 = try PDFPageScaler.scale(from: source, to: at10, percent: 10)
        XCTAssertEqual(count10, 1)
        let page10 = try XCTUnwrap(PDFDocument(url: at10)?.page(at: 0))
        XCTAssertEqual(Double(darkPixelWidth(of: page10)), 50, accuracy: 3)

        let at500 = testRoot.appendingPathComponent("square-500.pdf")
        let count500 = try PDFPageScaler.scale(from: source, to: at500, percent: 500)
        XCTAssertEqual(count500, 1)
        let page500 = try XCTUnwrap(PDFDocument(url: at500)?.page(at: 0))
        XCTAssertEqual(Double(darkPixelWidth(of: page500)), 150, accuracy: 3)
    }

    func testUnreadableSourceThrows() {
        let missing = testRoot.appendingPathComponent("does-not-exist.pdf")
        let destination = testRoot.appendingPathComponent("out.pdf")
        XCTAssertThrowsError(
            try PDFPageScaler.scale(from: missing, to: destination, percent: 100)
        ) { error in
            XCTAssertEqual(error as? PDFPageScaler.ScaleError, .unreadableDocument)
        }
    }

    // MARK: - Rotated pages

    /// Pages rotated 90/270 come out of the scaler with a swapped media box
    /// and `/Rotate` cleared (the output page rotation is 0), even though the
    /// API contract says the page box is preserved. Page count is preserved.
    func testRotatedPagesKeepPageCountButGetSwappedBoxAndClearedRotation() throws {
        let source = try makeRotatedPDF(rotations: [0, 90, 180, 270])
        let destination = testRoot.appendingPathComponent("rotated-scaled.pdf")

        let count = try PDFPageScaler.scale(from: source, to: destination, percent: 100)
        XCTAssertEqual(count, 4)

        let scaled = try XCTUnwrap(PDFDocument(url: destination))
        XCTAssertEqual(scaled.pageCount, 4)

        let expectedBoxes = [
            CGRect(x: 0, y: 0, width: 400, height: 600), // rotation 0
            CGRect(x: 0, y: 0, width: 600, height: 400), // rotation 90: swapped
            CGRect(x: 0, y: 0, width: 400, height: 600), // rotation 180
            CGRect(x: 0, y: 0, width: 600, height: 400)  // rotation 270: swapped
        ]
        for (index, expected) in expectedBoxes.enumerated() {
            let page = try XCTUnwrap(scaled.page(at: index))
            XCTAssertEqual(page.bounds(for: .mediaBox), expected, "page \(index)")
            XCTAssertEqual(page.rotation, 0, "page \(index) lost its /Rotate entry")
        }
    }

    // MARK: - Helpers

    /// Renders the page at 1 px/pt and returns the width of the bounding box
    /// of dark pixels (the black square).
    private func darkPixelWidth(of page: PDFPage) -> Int {
        let box = page.bounds(for: .mediaBox)
        let width = Int(box.width.rounded())
        let height = Int(box.height.rounded())
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let raw = context.data else {
            return -1
        }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        page.draw(with: .mediaBox, to: context)

        let bytes = raw.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var minX = width
        var maxX = -1
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                if bytes[offset] < 128, bytes[offset + 1] < 128, bytes[offset + 2] < 128 {
                    minX = min(minX, x)
                    maxX = max(maxX, x)
                }
            }
        }
        return maxX >= minX ? maxX - minX + 1 : 0
    }

    private func makeLabeledPDF(pageCount: Int) throws -> URL {
        let url = testRoot.appendingPathComponent("labeled-\(UUID().uuidString).pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 400, height: 600)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw NSError(domain: "PDFPageScalerTests", code: 1)
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

    private func makeBlackSquarePDF() throws -> URL {
        let url = testRoot.appendingPathComponent("square-\(UUID().uuidString).pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 400, height: 600)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw NSError(domain: "PDFPageScalerTests", code: 2)
        }
        context.beginPDFPage(nil)
        context.setFillColor(NSColor.white.cgColor)
        context.fill(mediaBox)
        context.setFillColor(NSColor.black.cgColor)
        // Centered 100x100 square: (150, 250) .. (250, 350).
        context.fill(CGRect(x: 150, y: 250, width: 100, height: 100))
        context.endPDFPage()
        context.closePDF()
        return url
    }

    private func makeRotatedPDF(rotations: [Int]) throws -> URL {
        let base = try makeLabeledPDF(pageCount: 1)
        let source = try XCTUnwrap(PDFDocument(url: base))
        let document = PDFDocument()
        for rotation in rotations {
            guard let page = source.page(at: 0)?.copy() as? PDFPage else {
                throw NSError(domain: "PDFPageScalerTests", code: 3)
            }
            page.rotation = rotation
            document.insert(page, at: document.pageCount)
        }
        let url = testRoot.appendingPathComponent("rotated-\(UUID().uuidString).pdf")
        guard document.write(to: url) else {
            throw NSError(domain: "PDFPageScalerTests", code: 4)
        }
        return url
    }
}
