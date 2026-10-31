import AppKit
import CoreGraphics
import Foundation
import PDFKit

/// Applies a true content scale to every page while preserving page count,
/// page order, and page box. CUPS filter support for percentage scaling is not
/// uniform, so the print path scales the PDF itself before submitting it.
public enum PDFPageScaler {
    public enum ScaleError: LocalizedError, Equatable, Sendable {
        case unreadableDocument
        case invalidScale(Int)
        case cannotCreatePDF
        case cannotWrite

        public var errorDescription: String? {
            switch self {
            case .unreadableDocument:
                return "The PDF could not be opened for scaling."
            case .invalidScale(let percent):
                return "The print scale \(percent)% is outside the supported range."
            case .cannotCreatePDF:
                return "The scaled PDF could not be created."
            case .cannotWrite:
                return "The scaled PDF could not be written."
            }
        }
    }

    /// Writes a scaled copy and returns its page count.
    @discardableResult
    public static func scale(
        from sourceURL: URL,
        to destinationURL: URL,
        percent: Int
    ) throws -> Int {
        let clamped = min(max(percent, 50), 150)
        guard clamped > 0 else { throw ScaleError.invalidScale(percent) }
        guard let source = PDFDocument(url: sourceURL), source.pageCount > 0 else {
            throw ScaleError.unreadableDocument
        }

        let data = NSMutableData()
        var initialBox = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: &initialBox, nil) else {
            throw ScaleError.cannotCreatePDF
        }

        let factor = CGFloat(clamped) / 100
        for index in 0..<source.pageCount {
            guard let page = source.page(at: index) else {
                throw ScaleError.unreadableDocument
            }
            var box = page.bounds(for: .mediaBox)
            if page.rotation % 180 != 0 {
                box = CGRect(
                    x: box.minX,
                    y: box.minY,
                    width: box.height,
                    height: box.width
                )
            }
            let boxData = Data(bytes: &box, count: MemoryLayout<CGRect>.size)
            let pageInfo = [
                kCGPDFContextMediaBox as String: boxData
            ] as CFDictionary
            context.beginPDFPage(pageInfo)
            context.saveGState()
            context.setFillColor(NSColor.white.cgColor)
            context.fill(box)
            context.translateBy(x: box.midX, y: box.midY)
            context.scaleBy(x: factor, y: factor)
            context.translateBy(x: -box.midX, y: -box.midY)
            page.draw(with: .mediaBox, to: context)
            context.restoreGState()
            context.endPDFPage()
        }
        context.closePDF()

        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: destinationURL.deletingLastPathComponent().path
        )
        try (data as Data).write(to: destinationURL, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: destinationURL.path
        )
        return source.pageCount
    }
}
