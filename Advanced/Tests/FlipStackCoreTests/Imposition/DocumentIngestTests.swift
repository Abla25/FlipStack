import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import XCTest
@testable import FlipStackCore

final class DocumentIngestTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FlipStackIngestTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Helpers

    /// Creates a solid-color image file of the given pixel size and format.
    private func makeImage(
        name: String,
        width: Int,
        height: Int,
        type: UTType = .jpeg,
        color: CGColor = CGColor(red: 0.9, green: 0.3, blue: 0.2, alpha: 1),
        orientation: Int? = nil
    ) throws -> URL {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let cgImage = context.makeImage() else {
            throw NSError(domain: "test", code: 1)
        }
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let cgImage = context.makeImage() else {
            throw NSError(domain: "test", code: 1)
        }
        let url = root.appendingPathComponent(name)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw NSError(domain: "test", code: 2)
        }
        var properties: [String: Any] = [:]
        if let orientation {
            properties[kCGImagePropertyOrientation as String] = orientation
        }
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "test", code: 3)
        }
        return url
    }

    private func writeText(_ name: String, _ content: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Builds a minimal .docx (a zip with the three required parts) using the
    /// system `zip` tool.
    private func makeDocx(name: String, text: String) throws -> URL {
        let staging = root.appendingPathComponent("docx-staging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>
        """
        let rels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>
        """
        let document = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>\(text)</w:t></w:r></w:p></w:body></w:document>
        """
        try contentTypes.write(to: staging.appendingPathComponent("[Content_Types].xml"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: staging.appendingPathComponent("_rels"), withIntermediateDirectories: true)
        try rels.write(to: staging.appendingPathComponent("_rels/.rels"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: staging.appendingPathComponent("word"), withIntermediateDirectories: true)
        try document.write(to: staging.appendingPathComponent("word/document.xml"), atomically: true, encoding: .utf8)

        let url = root.appendingPathComponent(name)
        let zip = URL(fileURLWithPath: "/usr/bin/zip")
        guard FileManager.default.isExecutableFile(atPath: zip.path) else {
            throw XCTSkip("zip tool not available")
        }
        let process = Process()
        process.executableURL = zip
        process.arguments = ["-r", "-X", url.path, "[Content_Types].xml", "_rels", "word"]
        process.currentDirectoryURL = staging
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("could not build docx fixture")
        }
        return url
    }

    // MARK: - Kind classification

    func testKindClassificationByExtensionAndType() throws {
        XCTAssertEqual(DocumentIngest.kind(of: URL(fileURLWithPath: "/tmp/x.pdf")), .pdf)
        XCTAssertEqual(DocumentIngest.kind(of: URL(fileURLWithPath: "/tmp/x.jpg")), .image)
        XCTAssertEqual(DocumentIngest.kind(of: URL(fileURLWithPath: "/tmp/x.JPEG")), .image)
        XCTAssertEqual(DocumentIngest.kind(of: URL(fileURLWithPath: "/tmp/x.heic")), .image)
        XCTAssertEqual(DocumentIngest.kind(of: URL(fileURLWithPath: "/tmp/x.png")), .image)
        XCTAssertEqual(DocumentIngest.kind(of: URL(fileURLWithPath: "/tmp/x.webp")), .image)
        XCTAssertEqual(DocumentIngest.kind(of: URL(fileURLWithPath: "/tmp/x.docx")), .word)
        XCTAssertEqual(DocumentIngest.kind(of: URL(fileURLWithPath: "/tmp/x.doc")), .word)
        XCTAssertEqual(DocumentIngest.kind(of: URL(fileURLWithPath: "/tmp/x.rtf")), .richText)
        XCTAssertEqual(DocumentIngest.kind(of: URL(fileURLWithPath: "/tmp/x.txt")), .plainText)
        XCTAssertEqual(DocumentIngest.kind(of: URL(fileURLWithPath: "/tmp/x.bin")), .unsupported)
        XCTAssertFalse(DocumentIngest.isAccepted(URL(fileURLWithPath: "/tmp/x.exe")))
        XCTAssertTrue(DocumentIngest.isAccepted(URL(fileURLWithPath: "/tmp/x.heic")))
    }

    // MARK: - Images

    func testJPEGIsEmbeddedBitExactAtNativeSize() throws {
        let jpeg = try makeImage(name: "photo.jpg", width: 6, height: 4)
        let original = try Data(contentsOf: jpeg)

        let pdfURL = try DocumentIngest.makePDF(from: [jpeg])
        defer { try? FileManager.default.removeItem(at: pdfURL.deletingLastPathComponent()) }

        let pdfBytes = try Data(contentsOf: pdfURL)
        // The original JPEG stream must appear byte-for-byte in the PDF.
        XCTAssertNotNil(pdfBytes.range(of: original), "JPEG must be embedded bit-exact, not re-encoded")

        let document = try XCTUnwrap(PDFDocument(url: pdfURL))
        XCTAssertEqual(document.pageCount, 1)
        let bounds = document.page(at: 0)!.bounds(for: .mediaBox)
        XCTAssertEqual(bounds.width, 6, accuracy: 0.5)
        XCTAssertEqual(bounds.height, 4, accuracy: 0.5)
    }

    func testEXIFOrientationSwapsPageBox() throws {
        let jpeg = try makeImage(name: "rotated.jpg", width: 6, height: 4, orientation: 6)
        let pdfURL = try DocumentIngest.makePDF(from: [jpeg])
        defer { try? FileManager.default.removeItem(at: pdfURL.deletingLastPathComponent()) }

        let document = try XCTUnwrap(PDFDocument(url: pdfURL))
        let bounds = document.page(at: 0)!.bounds(for: .mediaBox)
        XCTAssertEqual(bounds.width, 4, accuracy: 0.5, "90° EXIF orientation must swap the page box")
        XCTAssertEqual(bounds.height, 6, accuracy: 0.5)
    }

    func testPNGIsStoredLosslessly() throws {
        let png = try makeImage(name: "solid.png", width: 8, height: 8, type: .png)
        let pdfURL = try DocumentIngest.makePDF(from: [png])
        defer { try? FileManager.default.removeItem(at: pdfURL.deletingLastPathComponent()) }

        let document = try XCTUnwrap(PDFDocument(url: pdfURL))
        XCTAssertEqual(document.pageCount, 1)
        let page = try XCTUnwrap(document.page(at: 0))
        let thumb = page.thumbnail(of: NSSize(width: 8, height: 8), for: .mediaBox)
        // Solid coral-ish source: the rendered page must stay close to it.
        let rep = NSBitmapImageRep(data: thumb.tiffRepresentation!)!
        guard let pixel = rep.colorAt(x: 4, y: 4) else {
            return XCTFail("no pixel at center")
        }
        let red = pixel.redComponent * 255
        let green = pixel.greenComponent * 255
        let blue = pixel.blueComponent * 255
        // Color-managed rendering shifts absolute values; the hue must survive.
        XCTAssertEqual(red, 230, accuracy: 45)
        XCTAssertGreaterThan(red, green)
        XCTAssertGreaterThan(green, blue)
    }

    func testMultipleImagesBecomeMultiplePagesInOrder() throws {
        let first = try makeImage(name: "a.jpg", width: 10, height: 5)
        let second = try makeImage(name: "b.png", width: 3, height: 7, type: .png)
        let pdfURL = try DocumentIngest.makePDF(from: [first, second])
        defer { try? FileManager.default.removeItem(at: pdfURL.deletingLastPathComponent()) }

        let document = try XCTUnwrap(PDFDocument(url: pdfURL))
        XCTAssertEqual(document.pageCount, 2)
        XCTAssertEqual(document.page(at: 0)!.bounds(for: .mediaBox).width, 10, accuracy: 0.5)
        XCTAssertEqual(document.page(at: 1)!.bounds(for: .mediaBox).height, 7, accuracy: 0.5)
    }

    // MARK: - Text and Word

    func testPlainTextRendersToPDF() throws {
        let txt = try writeText("notes.txt", "Hello FlipStack plain text line")
        let pdfURL = try DocumentIngest.makePDF(from: [txt])
        defer { try? FileManager.default.removeItem(at: pdfURL.deletingLastPathComponent()) }

        let document = try XCTUnwrap(PDFDocument(url: pdfURL))
        XCTAssertGreaterThanOrEqual(document.pageCount, 1)
        XCTAssertTrue(document.string?.contains("Hello FlipStack plain text line") ?? false)
    }

    func testRTFRendersToPDFKeepingText() throws {
        let rtf = try writeText("doc.rtf", "{\\rtf1\\ansi Hello RTF world}")
        let pdfURL = try DocumentIngest.makePDF(from: [rtf])
        defer { try? FileManager.default.removeItem(at: pdfURL.deletingLastPathComponent()) }

        let document = try XCTUnwrap(PDFDocument(url: pdfURL))
        XCTAssertTrue(document.string?.contains("Hello RTF world") ?? false)
    }

    func testDocxConvertsToPDFWithText() throws {
        let docx = try makeDocx(name: "letter.docx", text: "Hello from Word document")
        XCTAssertEqual(DocumentIngest.kind(of: docx), .word)

        let pdfURL = try DocumentIngest.makePDF(from: [docx])
        defer { try? FileManager.default.removeItem(at: pdfURL.deletingLastPathComponent()) }

        let document = try XCTUnwrap(PDFDocument(url: pdfURL))
        XCTAssertGreaterThanOrEqual(document.pageCount, 1)
        XCTAssertTrue(document.string?.contains("Hello from Word document") ?? false,
                      "docx text must survive conversion, got: \(document.string ?? "nil")")
    }

    func testUnsupportedTypeThrows() throws {
        let bin = try writeText("program.bin", "MZ")
        XCTAssertThrowsError(try DocumentIngest.makePDF(from: [bin])) { error in
            XCTAssertEqual(error as? DocumentIngest.IngestError, .unsupportedType)
        }
    }

    func testMixedPDFAndImageMerge() throws {
        let image = try makeImage(name: "pic.jpg", width: 5, height: 5)
        // A one-page PDF made from a text file via the same pipeline.
        let txt = try writeText("page.txt", "Text page content")
        let textPDF = try DocumentIngest.makePDF(from: [txt])
        defer { try? FileManager.default.removeItem(at: textPDF.deletingLastPathComponent()) }

        let merged = try DocumentIngest.makePDF(from: [textPDF, image])
        defer { try? FileManager.default.removeItem(at: merged.deletingLastPathComponent()) }

        let document = try XCTUnwrap(PDFDocument(url: merged))
        XCTAssertEqual(document.pageCount, 2)
        XCTAssertEqual(document.page(at: 1)!.bounds(for: .mediaBox).width, 5, accuracy: 0.5)
    }
}
