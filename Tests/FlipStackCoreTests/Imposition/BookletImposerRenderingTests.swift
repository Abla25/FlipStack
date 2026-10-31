import AppKit
import CoreGraphics
import CoreText
import Foundation
import PDFKit
import XCTest
@testable import FlipStackCore

final class BookletImpositionRenderingTests: XCTestCase {
    private var testRoot: URL!

    override func setUpWithError() throws {
        testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("FlipStackImpositionTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: testRoot,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }

    override func tearDownWithError() throws {
        if let testRoot {
            try? FileManager.default.removeItem(at: testRoot)
        }
    }

    func testTwelvePageMultiSignatureRendering() throws {
        let sourceURL = try makeLabeledPDF(pageCount: 12)
        let imposer = BookletImposer()
        let plan = try imposer.plan(pageCount: 12, signatureSheets: 2)
        let documents = try imposer.makeDocuments(from: sourceURL, plan: plan)
        defer { imposer.cleanUp(documents) }

        XCTAssertEqual(documents.plan, plan)
        XCTAssertEqual(documents.workingDirectory.deletingLastPathComponent().lastPathComponent, "FlipStack")
        XCTAssertNotNil(UUID(uuidString: documents.workingDirectory.lastPathComponent))
        XCTAssertTrue(FileManager.default.fileExists(atPath: documents.frontsURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: documents.backsURL.path))
        XCTAssertGreaterThan(fileSize(at: documents.frontsURL), 0)
        XCTAssertGreaterThan(fileSize(at: documents.backsURL), 0)

        let directoryAttributes = try FileManager.default.attributesOfItem(
            atPath: documents.workingDirectory.path
        )
        XCTAssertEqual(
            ((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o777,
            0o700
        )
        for file in [documents.frontsURL, documents.backsURL] {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            XCTAssertEqual(
                ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o777,
                0o600
            )
        }

        // The imposed files must be self-contained rather than depending on
        // the source PDF remaining at its original URL.
        try FileManager.default.removeItem(at: sourceURL)

        let fronts = try pageTexts(at: documents.frontsURL)
        let backs = try pageTexts(at: documents.backsURL)
        XCTAssertEqual(fronts.count, plan.frontPageSequence.count)
        XCTAssertEqual(backs.count, plan.backPageSequence.count)
        XCTAssertEqual(fronts, ["Page 8", "Page 1", "Page 6", "Page 3", "Page 12", "Page 9"])
        XCTAssertEqual(backs, ["Page 2", "Page 7", "Page 4", "Page 5", "Page 10", "Page 11"])

        let renderedPages = (fronts + backs).compactMap { Int($0.replacingOccurrences(of: "Page ", with: "")) }
        XCTAssertEqual(renderedPages.sorted(), Array(1...12))
    }

    func testRenderingUsesRealBlankPagesInSequence() throws {
        let sourceURL = try makeLabeledPDF(pageCount: 5)
        let imposer = BookletImposer()
        let plan = try imposer.plan(pageCount: 5, signatureSheets: nil)
        let documents = try imposer.makeDocuments(from: sourceURL, plan: plan)
        defer { imposer.cleanUp(documents) }

        let fronts = try pageTexts(at: documents.frontsURL)
        let backs = try pageTexts(at: documents.backsURL)
        XCTAssertEqual(fronts, ["", "Page 1", "", "Page 3"])
        XCTAssertEqual(backs, ["Page 2", "", "Page 4", "Page 5"])
        XCTAssertEqual(fronts.count, plan.frontPageSequence.count)
        XCTAssertEqual(backs.count, plan.backPageSequence.count)

        let sourceDocument = try XCTUnwrap(PDFDocument(url: sourceURL))
        let sourceBounds = try XCTUnwrap(sourceDocument.page(at: 0)).bounds(for: .mediaBox)
        let frontsDocument = try XCTUnwrap(PDFDocument(url: documents.frontsURL))
        let backsDocument = try XCTUnwrap(PDFDocument(url: documents.backsURL))

        let blankFrontPage = try XCTUnwrap(frontsDocument.page(at: 0))
        XCTAssertNil(blankFrontPage.string)
        XCTAssertEqual(blankFrontPage.bounds(for: .mediaBox), sourceBounds)
        XCTAssertEqual(blankFrontPage.bounds(for: .cropBox), sourceBounds)

        let blankBackPage = try XCTUnwrap(backsDocument.page(at: 1))
        XCTAssertNil(blankBackPage.string)
        XCTAssertEqual(blankBackPage.bounds(for: .mediaBox), sourceBounds)
    }

    func testRenderingPreservesRotationAndBlankPageAppearance() throws {
        let sourceURL = try makeLabeledPDF(
            pageCount: 5,
            pageSize: CGSize(width: 320, height: 480),
            firstPageRotation: 90
        )
        let imposer = BookletImposer()
        let plan = try imposer.plan(pageCount: 5, signatureSheets: nil)
        let documents = try imposer.makeDocuments(from: sourceURL, plan: plan)
        defer { imposer.cleanUp(documents) }

        let source = try XCTUnwrap(PDFDocument(url: sourceURL))
        let firstSourcePage = try XCTUnwrap(source.page(at: 0))
        let fronts = try XCTUnwrap(PDFDocument(url: documents.frontsURL))
        let blank = try XCTUnwrap(fronts.page(at: 0))
        let rotated = try XCTUnwrap(fronts.page(at: 1))

        XCTAssertEqual(blank.bounds(for: .mediaBox), firstSourcePage.bounds(for: .mediaBox))
        XCTAssertEqual(blank.rotation, 90)
        XCTAssertEqual(rotated.bounds(for: .mediaBox), firstSourcePage.bounds(for: .mediaBox))
        XCTAssertEqual(rotated.rotation, 90)
        XCTAssertEqual(rotated.string?.trimmingCharacters(in: .whitespacesAndNewlines), "Page 1")
    }

    func testCleanUpRemovesOnlyTheWorkingDirectory() throws {
        let sourceURL = try makeLabeledPDF(pageCount: 4)
        let imposer = BookletImposer()
        let plan = try imposer.plan(pageCount: 4, signatureSheets: nil)
        let documents = try imposer.makeDocuments(from: sourceURL, plan: plan)

        let base = documents.workingDirectory.deletingLastPathComponent()
        let sibling = base.appendingPathComponent("keep-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sibling,
            withIntermediateDirectories: true,
            attributes: nil
        )
        let marker = sibling.appendingPathComponent("marker.txt")
        try Data("keep".utf8).write(to: marker)
        defer { try? FileManager.default.removeItem(at: sibling) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: documents.workingDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))

        imposer.cleanUp(documents)

        XCTAssertFalse(FileManager.default.fileExists(atPath: documents.workingDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sibling.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))

        // Cleaning up twice is safe.
        imposer.cleanUp(documents)
        XCTAssertFalse(FileManager.default.fileExists(atPath: documents.workingDirectory.path))
    }

    func testMissingSourceThrowsUnreadableDocument() throws {
        let imposer = BookletImposer()
        let plan = try imposer.plan(pageCount: 8, signatureSheets: nil)
        let missingURL = testRoot.appendingPathComponent("missing.pdf")

        XCTAssertThrowsError(try imposer.makeDocuments(from: missingURL, plan: plan)) { error in
            XCTAssertEqual(error as? BookletError, .unreadableDocument("missing.pdf"))
        }
    }

    // MARK: - Helpers

    private func makeLabeledPDF(
        pageCount: Int,
        pageSize: CGSize = CGSize(width: 400, height: 600),
        firstPageRotation: Int = 0
    ) throws -> URL {
        let url = testRoot.appendingPathComponent("source-\(UUID().uuidString).pdf")
        var defaultMediaBox = CGRect(origin: .zero, size: pageSize)
        guard let context = CGContext(url as CFURL, mediaBox: &defaultMediaBox, nil) else {
            throw TestFailure.cannotCreatePDF
        }

        for pageNumber in 1...pageCount {
            var mediaBox = CGRect(origin: .zero, size: pageSize)
            let boxData = Data(
                bytes: &mediaBox,
                count: MemoryLayout<CGRect>.size
            )
            context.beginPDFPage(
                [kCGPDFContextMediaBox as String: boxData] as CFDictionary
            )

            let text = NSAttributedString(
                string: "Page \(pageNumber)",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 24),
                    .foregroundColor: NSColor.black
                ]
            )
            let line = CTLineCreateWithAttributedString(text)
            context.saveGState()
            context.textMatrix = .identity
            context.translateBy(x: 40, y: pageSize.height - 100)
            CTLineDraw(line, context)
            context.restoreGState()
            context.endPDFPage()
        }
        context.closePDF()

        guard firstPageRotation != 0 else { return url }
        let document = try XCTUnwrap(PDFDocument(url: url))
        let firstPage = try XCTUnwrap(document.page(at: 0))
        firstPage.rotation = firstPageRotation
        let rotatedURL = testRoot.appendingPathComponent("rotated-\(UUID().uuidString).pdf")
        guard document.write(to: rotatedURL) else {
            throw TestFailure.cannotCreatePDF
        }
        return rotatedURL
    }

    private func pageTexts(at url: URL) throws -> [String] {
        let document = try XCTUnwrap(PDFDocument(url: url), "Could not open \(url.path)")
        return (0..<document.pageCount).map { index in
            document.page(at: index)?.string?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
    }

    private func fileSize(at url: URL) -> Int {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return values?.fileSize ?? 0
    }

    private enum TestFailure: Error {
        case cannotCreatePDF
    }
}
