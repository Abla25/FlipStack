import CoreGraphics
import Foundation
import PDFKit

/// Builds nested booklet plans and writes the two PDFs used for a duplex
/// booklet pass.
///
/// The type has no mutable shared state; every operation uses local
/// `PDFDocument` instances. It is safe to create one and use it from a
/// background task.
public struct BookletImposer: BookletImposing {
    /// All working directories live under this folder in the system
    /// temporary directory.
    private static let workingFolderName = "FlipStack"
    /// A document with at most this many padded sheets is imposed as one
    /// signature so short booklets do not need separate folding.
    private static let singleSignatureSheetLimit = 6
    /// Longer documents are split into signatures of this many sheets. The
    /// final signature may be smaller, but always holds at least one sheet.
    private static let automaticSignatureSheets = 4

    public init() {}

    // MARK: - Planning

    /// Builds a nested booklet plan.
    ///
    /// Signature indices are zero-based. `signatureSheetCount` is the largest
    /// signature size actually used, so a requested size larger than the
    /// document reports the number of available sheets instead of implying
    /// blank signatures.
    public func plan(pageCount: Int, signatureSheets: Int?) throws -> BookletPlan {
        guard pageCount > 0 else {
            throw BookletError.emptyDocument
        }
        if let signatureSheets, signatureSheets < 1 {
            throw BookletError.invalidSignatureSheetCount(signatureSheets)
        }

        let paddedPageCount = Self.paddedPageCount(for: pageCount)
        let paddedSheetCount = paddedPageCount / 4

        // An explicit size larger than the document does not add padding. It
        // is equivalent to using one signature for all of the sheets. The
        // plan reports the size actually used so labels stay accurate.
        let sheetsPerSignature: Int
        if let signatureSheets {
            sheetsPerSignature = min(signatureSheets, paddedSheetCount)
        } else if paddedSheetCount <= Self.singleSignatureSheetLimit {
            sheetsPerSignature = paddedSheetCount
        } else {
            sheetsPerSignature = Self.automaticSignatureSheets
        }
        let pagesPerSignature = sheetsPerSignature * 4

        var spreads: [BookletSpread] = []
        var signatures: [BookletSignature] = []
        var frontPageSequence: [Int?] = []
        var backPageSequence: [Int?] = []

        var firstPage = 1
        var signatureIndex = 0
        while firstPage <= paddedPageCount {
            let remainingPages = paddedPageCount - firstPage + 1
            let signaturePageCount = min(remainingPages, pagesPerSignature)
            let lastPage = firstPage + signaturePageCount - 1
            let offset = firstPage - 1
            let sheetCount = signaturePageCount / 4

            signatures.append(
                BookletSignature(
                    index: signatureIndex,
                    firstPage: firstPage,
                    lastPage: lastPage,
                    sheetCount: sheetCount
                )
            )

            for sheet in 0..<sheetCount {
                // Nested booklet order. The first page number in a signature
                // is the outside front-left position, and the last page is
                // the outside front-right position.
                let front = BookletPagePair(
                    left: Self.sourcePage(
                        offset + signaturePageCount - 2 * sheet,
                        sourcePageCount: pageCount
                    ),
                    right: Self.sourcePage(
                        offset + 1 + 2 * sheet,
                        sourcePageCount: pageCount
                    )
                )
                let back = BookletPagePair(
                    left: Self.sourcePage(
                        offset + 2 + 2 * sheet,
                        sourcePageCount: pageCount
                    ),
                    right: Self.sourcePage(
                        offset + signaturePageCount - 1 - 2 * sheet,
                        sourcePageCount: pageCount
                    )
                )

                spreads.append(BookletSpread(front: front, back: back))
                frontPageSequence.append(front.left)
                frontPageSequence.append(front.right)
                backPageSequence.append(back.left)
                backPageSequence.append(back.right)
            }

            firstPage = lastPage + 1
            signatureIndex += 1
        }

        return BookletPlan(
            sourcePageCount: pageCount,
            paddedPageCount: paddedPageCount,
            signatureSheetCount: sheetsPerSignature,
            signatureCount: signatures.count,
            spreads: spreads,
            signatures: signatures,
            frontPageSequence: frontPageSequence,
            backPageSequence: backPageSequence
        )
    }

    private static func paddedPageCount(for pageCount: Int) -> Int {
        let remainder = pageCount % 4
        return remainder == 0 ? pageCount : pageCount + (4 - remainder)
    }

    private static func sourcePage(_ paddedPage: Int, sourcePageCount: Int) -> Int? {
        guard paddedPage >= 1, paddedPage <= sourcePageCount else { return nil }
        return paddedPage
    }

    // MARK: - Rendering

    public func makeDocuments(from sourceURL: URL, plan: BookletPlan) throws -> BookletDocuments {
        let fileName = sourceURL.lastPathComponent
        guard let source = PDFDocument(url: sourceURL),
              !source.isLocked,
              source.pageCount > 0,
              let firstSourcePage = source.page(at: 0)
        else {
            throw BookletError.unreadableDocument(fileName)
        }

        let fileManager = FileManager.default
        let workingDirectory = fileManager.temporaryDirectory
            .appendingPathComponent(Self.workingFolderName, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        do {
            try fileManager.createDirectory(
                at: workingDirectory,
                withIntermediateDirectories: true,
                attributes: nil
            )
            try? fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: workingDirectory.path
            )
        } catch {
            throw BookletError.cannotCreateWorkingDirectory(error.localizedDescription)
        }

        do {
            let frontsURL = workingDirectory.appendingPathComponent("fronts.pdf")
            let backsURL = workingDirectory.appendingPathComponent("backs.pdf")
            let fallbackAppearance = PageAppearance(
                bounds: firstSourcePage.bounds(for: .mediaBox),
                rotation: firstSourcePage.rotation
            )

            // PDFKit is an Objective-C framework. Keeping the document
            // creation inside an autorelease pool releases temporary page
            // objects promptly for large documents.
            try autoreleasepool {
                try write(
                    sequence: plan.frontPageSequence,
                    from: source,
                    fallbackAppearance: fallbackAppearance,
                    to: frontsURL
                )
                try write(
                    sequence: plan.backPageSequence,
                    from: source,
                    fallbackAppearance: fallbackAppearance,
                    to: backsURL
                )
            }

            return BookletDocuments(
                frontsURL: frontsURL,
                backsURL: backsURL,
                plan: plan,
                workingDirectory: workingDirectory
            )
        } catch {
            // Do not leave a half-written directory behind when either pass
            // fails.
            try? fileManager.removeItem(at: workingDirectory)
            throw error
        }
    }

    public func cleanUp(_ documents: BookletDocuments) {
        // Only the directory owned by this documents value is removed. A
        // missing directory is not an error.
        try? FileManager.default.removeItem(at: documents.workingDirectory)
    }

    private func write(
        sequence: [Int?],
        from source: PDFDocument,
        fallbackAppearance: PageAppearance,
        to url: URL
    ) throws {
        let output = PDFDocument()
        var lastAppearance = fallbackAppearance

        for entry in sequence {
            if let pageNumber = entry {
                guard pageNumber >= 1,
                      pageNumber <= source.pageCount,
                      let sourcePage = source.page(at: pageNumber - 1),
                      let copiedPage = sourcePage.copy() as? PDFPage
                else {
                    throw BookletError.cannotWrite(
                        "Page \(pageNumber) is not available in the source PDF."
                    )
                }
                output.insert(copiedPage, at: output.pageCount)
                lastAppearance = PageAppearance(
                    bounds: sourcePage.bounds(for: .mediaBox),
                    rotation: sourcePage.rotation
                )
            } else {
                let blankPage = PDFPage()
                blankPage.setBounds(lastAppearance.bounds, for: .mediaBox)
                blankPage.setBounds(lastAppearance.bounds, for: .cropBox)
                blankPage.rotation = lastAppearance.rotation
                output.insert(blankPage, at: output.pageCount)
            }
        }

        guard output.pageCount == sequence.count else {
            throw BookletError.cannotWrite(
                "The imposed PDF was expected to have \(sequence.count) pages."
            )
        }
        guard output.write(to: url) else {
            throw BookletError.cannotWrite("Could not write \(url.lastPathComponent).")
        }
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }
}

/// The size and rotation of the page used for the most recent source page.
/// Blank pages copy this so every output page has the expected sheet size.
private struct PageAppearance {
    var bounds: CGRect
    var rotation: Int
}
