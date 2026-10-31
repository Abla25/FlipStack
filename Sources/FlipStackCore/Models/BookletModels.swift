import Foundation

/// Two source pages that share one side of a folded sheet. `nil` is a blank.
public struct BookletPagePair: Hashable, Sendable {
    public var left: Int?
    public var right: Int?

    public init(left: Int?, right: Int?) {
        self.left = left
        self.right = right
    }

    public var isBlank: Bool {
        left == nil && right == nil
    }

    public var pageNumbers: [Int] {
        [left, right].compactMap { $0 }
    }
}

public struct BookletSpread: Hashable, Sendable {
    public var front: BookletPagePair
    public var back: BookletPagePair

    public init(front: BookletPagePair, back: BookletPagePair) {
        self.front = front
        self.back = back
    }
}

public struct BookletSignature: Hashable, Sendable {
    public var index: Int
    public var firstPage: Int
    public var lastPage: Int
    public var sheetCount: Int

    public init(index: Int, firstPage: Int, lastPage: Int, sheetCount: Int) {
        self.index = index
        self.firstPage = firstPage
        self.lastPage = lastPage
        self.sheetCount = sheetCount
    }

    public var pageRangeLabel: String {
        firstPage == lastPage ? "Page \(firstPage)" : "Pages \(firstPage)–\(lastPage)"
    }
}

/// A complete, deterministic imposition plan. `frontPageSequence` and
/// `backPageSequence` are flattened source-page numbers, two entries per
/// spread; CUPS `number-up=2` groups each adjacent pair into one sheet side.
public struct BookletPlan: Hashable, Sendable {
    public var sourcePageCount: Int
    public var paddedPageCount: Int
    public var signatureSheetCount: Int
    public var signatureCount: Int
    public var spreads: [BookletSpread]
    public var signatures: [BookletSignature]
    public var frontPageSequence: [Int?]
    public var backPageSequence: [Int?]

    public init(
        sourcePageCount: Int,
        paddedPageCount: Int,
        signatureSheetCount: Int,
        signatureCount: Int,
        spreads: [BookletSpread],
        signatures: [BookletSignature],
        frontPageSequence: [Int?],
        backPageSequence: [Int?]
    ) {
        self.sourcePageCount = sourcePageCount
        self.paddedPageCount = paddedPageCount
        self.signatureSheetCount = signatureSheetCount
        self.signatureCount = signatureCount
        self.spreads = spreads
        self.signatures = signatures
        self.frontPageSequence = frontPageSequence
        self.backPageSequence = backPageSequence
    }

    public var sheetCount: Int {
        spreads.count
    }

    public var paddedSheetCount: Int {
        paddedPageCount / 4
    }

    public var hasBlankPages: Bool {
        paddedPageCount > sourcePageCount
    }

    public var flatSheetOrder: [Int?] {
        frontPageSequence
    }

    public var foldHint: String {
        if signatureCount > 1 {
            return "Fold each of the \(signatureCount) signatures separately, then nest them in order."
        }
        return "Fold the stack in half with the printed pages facing out."
    }

    public var stapleHint: String {
        if signatureCount > 1 {
            return "Staple each signature twice on the fold, then stack the signatures in order."
        }
        return "Staple twice along the fold after folding."
    }
}

public struct BookletDocuments: Sendable {
    public var frontsURL: URL
    public var backsURL: URL
    public var plan: BookletPlan
    public var workingDirectory: URL

    public init(frontsURL: URL, backsURL: URL, plan: BookletPlan, workingDirectory: URL) {
        self.frontsURL = frontsURL
        self.backsURL = backsURL
        self.plan = plan
        self.workingDirectory = workingDirectory
    }
}

public enum BookletError: LocalizedError, Equatable, Sendable {
    case emptyDocument
    case unreadableDocument(String)
    case cannotCreateWorkingDirectory(String)
    case cannotWrite(String)
    case invalidSignatureSheetCount(Int)

    public var errorDescription: String? {
        switch self {
        case .emptyDocument:
            return "The document has no pages to impose."
        case .unreadableDocument(let name):
            return "“\(name)” could not be opened as a PDF."
        case .cannotCreateWorkingDirectory(let message):
            return "Could not create a temporary folder: \(message)"
        case .cannotWrite(let message):
            return "Could not write the imposed PDF: \(message)"
        case .invalidSignatureSheetCount(let count):
            return "A signature must contain at least one sheet (got \(count))."
        }
    }
}

/// Implemented by `BookletImposer`. Kept as a protocol so the app can be
/// previewed and tested with deterministic impositions.
public protocol BookletImposing: Sendable {
    /// `signatureSheets == nil` chooses a sensible signature size.
    func plan(pageCount: Int, signatureSheets: Int?) throws -> BookletPlan
    /// Writes fronts and backs PDFs into a private temporary directory.
    func makeDocuments(from sourceURL: URL, plan: BookletPlan) throws -> BookletDocuments
    /// Removes the working directory created by `makeDocuments`.
    func cleanUp(_ documents: BookletDocuments)
}
