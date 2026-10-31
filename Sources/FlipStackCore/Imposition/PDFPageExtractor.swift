import Foundation
import PDFKit

/// Turns a page-range selection into a contiguous PDF, in ascending page order.
/// This lets the manual-duplex flow treat "pages 4–9" as a normal six-page
/// document, so odd/even passes still pair the correct physical sheets.
public enum PDFPageExtractor {
    public enum ExtractError: LocalizedError, Equatable, Sendable {
        case emptySelection
        case unreadableDocument
        case pageOutOfRange(Int)
        case cannotWrite(String)

        public var errorDescription: String? {
            switch self {
            case .emptySelection:
                return "No pages were selected."
            case .unreadableDocument:
                return "The PDF could not be opened."
            case .pageOutOfRange(let page):
                return "Page \(page) is outside this document."
            case .cannotWrite(let message):
                return "The selected pages could not be prepared: \(message)"
            }
        }
    }

    /// Normalizes ranges into ascending, unique, one-based page numbers,
    /// clamped to the document. Throws if the result is empty or out of range.
    public static func pageNumbers(
        for ranges: [PageRange],
        pageCount: Int
    ) throws -> [Int] {
        guard pageCount > 0 else { throw ExtractError.unreadableDocument }
        var pages = Set<Int>()
        for range in ranges {
            guard range.lowerBound >= 1, range.upperBound <= pageCount else {
                throw ExtractError.pageOutOfRange(range.upperBound)
            }
            pages.formUnion(range.lowerBound...range.upperBound)
        }
        guard !pages.isEmpty else { throw ExtractError.emptySelection }
        return pages.sorted()
    }

    /// Copies the requested pages, in the given order, into a new PDF.
    /// Returns the page count of the written file.
    @discardableResult
    public static func extract(
        from sourceURL: URL,
        pageNumbers: [Int],
        to destinationURL: URL
    ) throws -> Int {
        guard let source = PDFDocument(url: sourceURL), source.pageCount > 0 else {
            throw ExtractError.unreadableDocument
        }
        var seen = Set<Int>()
        var unique: [Int] = []
        for page in pageNumbers where seen.insert(page).inserted {
            unique.append(page)
        }
        guard !unique.isEmpty else { throw ExtractError.emptySelection }

        let output = PDFDocument()
        for pageNumber in unique {
            guard pageNumber >= 1, pageNumber <= source.pageCount else {
                throw ExtractError.pageOutOfRange(pageNumber)
            }
            guard let page = source.page(at: pageNumber - 1),
                  let copy = page.copy() as? PDFPage else {
                throw ExtractError.cannotWrite("Page \(pageNumber) is not available.")
            }
            output.insert(copy, at: output.pageCount)
        }

        guard output.pageCount == unique.count else {
            throw ExtractError.cannotWrite("Unexpected page count after extraction.")
        }
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard output.write(to: destinationURL) else {
            throw ExtractError.cannotWrite("Could not write the selected pages.")
        }
        return output.pageCount
    }
}
