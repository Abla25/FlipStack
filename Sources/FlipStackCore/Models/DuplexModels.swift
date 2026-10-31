import Foundation

/// How the physical stack is handled between the two passes.
public enum FlipAxis: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Like turning a book page: rotate the block around its long (vertical) edge.
    case longEdge
    /// Like a calendar: rotate the block around its short (horizontal) edge.
    case shortEdge

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .longEdge: return L("Long edge")
        case .shortEdge: return L("Short edge")
        }
    }

    public var shortLabel: String {
        switch self {
        case .longEdge: return L("Book")
        case .shortEdge: return L("Calendar")
        }
    }

    public var detail: String {
        switch self {
        case .longEdge:
            return L("For portrait documents and books. Turn the stack like a page, along the long edge.")
        case .shortEdge:
            return L("For landscape pages and calendars. Turn the stack along the short edge.")
        }
    }

    public var flipInstruction: String {
        switch self {
        case .longEdge:
            return L("Flip the stack over its long edge, like turning a book page.")
        case .shortEdge:
            return L("Flip the stack over its short edge, like turning a calendar page.")
        }
    }

    /// The CUPS `Duplex` value associated with the chosen axis.
    public var cupsDuplexValue: String {
        switch self {
        case .longEdge: return "NoTumble"
        case .shortEdge: return "Tumble"
        }
    }

    public var symbolName: String {
        switch self {
        case .longEdge: return "book.closed"
        case .shortEdge: return "calendar"
        }
    }
}

public enum FlipMode: String, Codable, Sendable, Equatable {
    /// The tray ejects face-up, so the printed block must be turned over.
    case flipBlock
    /// The tray already ejects face-down; only reinsert, never reorder.
    case reinsertOnly
}

public struct PrinterPreferences: Hashable, Codable, Sendable {
    public var flipAxis: FlipAxis
    public var ejectsFaceDown: Bool
    public var hasConfiguredFlip: Bool

    public init(
        flipAxis: FlipAxis = .longEdge,
        ejectsFaceDown: Bool = false,
        hasConfiguredFlip: Bool = false
    ) {
        self.flipAxis = flipAxis
        self.ejectsFaceDown = ejectsFaceDown
        self.hasConfiguredFlip = hasConfiguredFlip
    }

    public static let unconfigured = PrinterPreferences()

    public var flipMode: FlipMode {
        ejectsFaceDown ? .reinsertOnly : .flipBlock
    }
}

public enum PrintMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case singleSided
    case manualDuplex
    case booklet

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .singleSided: return L("Single")
        case .manualDuplex: return L("Duplex")
        case .booklet: return L("Booklet")
        }
    }

    public var longLabel: String {
        switch self {
        case .singleSided: return L("Single-sided")
        case .manualDuplex: return L("Manual duplex")
        case .booklet: return L("Booklet")
        }
    }

    public var usesFlipSetup: Bool {
        self != .singleSided
    }

    public var isTwoPass: Bool {
        self == .manualDuplex || self == .booklet
    }
}

public enum DuplexPass: String, Codable, Sendable, Equatable {
    case fronts
    case backs

    public var label: String {
        switch self {
        case .fronts: return L("Fronts")
        case .backs: return L("Backs")
        }
    }
}

/// A source PDF for one pass. Standard duplex uses the same file with
/// `page-set=odd` and `page-set=even`; booklets use two page-sequenced PDFs
/// printed with `number-up=2`.
public struct PrintSource: Hashable, Codable, Sendable {
    public var fileURL: URL
    public var pageSet: PageSet
    /// Physical sheets produced by this pass, used for progress and hints.
    public var pageCount: Int
    public var pageRanges: [PageRange]
    public var numberUp: Int
    public var orientation: PrintOrientation

    public init(
        fileURL: URL,
        pageSet: PageSet,
        pageCount: Int,
        pageRanges: [PageRange] = [],
        numberUp: Int = 1,
        orientation: PrintOrientation = .portrait
    ) {
        self.fileURL = fileURL
        self.pageSet = pageSet
        self.pageCount = pageCount
        self.pageRanges = pageRanges
        self.numberUp = numberUp
        self.orientation = orientation
    }
}

public struct DuplexDocument: Hashable, Codable, Sendable {
    public var title: String
    public var sourcePageCount: Int
    public var sheetCount: Int
    public var firstPass: PrintSource
    public var secondPass: PrintSource
    public var isBooklet: Bool
    public var hasOddPageCount: Bool
    public var isSingleSided: Bool

    public init(
        title: String,
        sourcePageCount: Int,
        sheetCount: Int,
        firstPass: PrintSource,
        secondPass: PrintSource,
        isBooklet: Bool = false,
        hasOddPageCount: Bool = false,
        isSingleSided: Bool = false
    ) {
        self.title = title
        self.sourcePageCount = sourcePageCount
        self.sheetCount = sheetCount
        self.firstPass = firstPass
        self.secondPass = secondPass
        self.isBooklet = isBooklet
        self.hasOddPageCount = hasOddPageCount
        self.isSingleSided = isSingleSided
    }

    public var hasBackSides: Bool {
        secondPass.pageCount > 0
    }

    public var hasBlankFinalBack: Bool {
        !isBooklet && !isSingleSided && hasOddPageCount
    }

    public static func singleSided(
        fileURL: URL,
        pageCount: Int,
        title: String,
        pageRanges: [PageRange] = [],
        orientation: PrintOrientation = .portrait,
        numberUp: Int = 1
    ) throws -> DuplexDocument {
        guard pageCount > 0 else {
            throw DuplexDocumentError.emptyDocument
        }
        return DuplexDocument(
            title: title,
            sourcePageCount: pageCount,
            sheetCount: pageCount,
            firstPass: PrintSource(
                fileURL: fileURL,
                pageSet: .all,
                pageCount: pageCount,
                pageRanges: pageRanges,
                numberUp: numberUp,
                orientation: orientation
            ),
            secondPass: PrintSource(
                fileURL: fileURL,
                pageSet: .all,
                pageCount: 0,
                pageRanges: pageRanges,
                numberUp: numberUp,
                orientation: orientation
            ),
            isBooklet: false,
            hasOddPageCount: false,
            isSingleSided: true
        )
    }

    public static func manualDuplex(
        fileURL: URL,
        pageCount: Int,
        title: String,
        pageRanges: [PageRange] = []
    ) throws -> DuplexDocument {
        guard pageCount > 0 else {
            throw DuplexDocumentError.emptyDocument
        }
        let sheets = Int(ceil(Double(pageCount) / 2.0))
        let frontCount = (pageCount + 1) / 2
        let backCount = pageCount / 2
        return DuplexDocument(
            title: title,
            sourcePageCount: pageCount,
            sheetCount: sheets,
            firstPass: PrintSource(
                fileURL: fileURL,
                pageSet: .odd,
                pageCount: frontCount,
                pageRanges: pageRanges
            ),
            secondPass: PrintSource(
                fileURL: fileURL,
                pageSet: .even,
                pageCount: backCount,
                pageRanges: pageRanges
            ),
            isBooklet: false,
            hasOddPageCount: pageCount % 2 == 1
        )
    }
}

public enum DuplexDocumentError: LocalizedError, Equatable, Sendable {
    case emptyDocument
    case unreadableDocument(String)
    case invalidPageCount(Int)

    public var errorDescription: String? {
        switch self {
        case .emptyDocument:
            return "The document has no printable pages."
        case .unreadableDocument(let name):
            return "“\(name)” is not a readable PDF."
        case .invalidPageCount(let count):
            return "The document page count (\(count)) is invalid."
        }
    }
}

public struct DuplexConfiguration: Hashable, Sendable {
    public var printerID: String
    public var printerName: String
    public var flipAxis: FlipAxis
    public var ejectsFaceDown: Bool
    /// PPD-derived values such as `ColorModel`, `PageSize`, `MediaType`.
    public var driverOptions: [String: String]
    public var copies: Int
    public var pollInterval: TimeInterval
    public var jobStuckTimeout: TimeInterval
    public var printerErrorGracePeriod: TimeInterval
    /// When the queue has hardware duplex, FlipStack still uses the guided
    /// two-pass workflow, but each pass must be forced to one side so the
    /// driver does not turn pages on its own.
    public var forceOneSidedPasses: Bool
    /// Ask CUPS to scale each page to the selected media size.
    public var fitToPage: Bool
    /// Exact CUPS scaling percentage when `fitToPage` is false.
    public var scalePercent: Int

    public init(
        printerID: String,
        printerName: String,
        flipAxis: FlipAxis,
        ejectsFaceDown: Bool,
        driverOptions: [String: String] = [:],
        copies: Int = 1,
        pollInterval: TimeInterval = 0.75,
        jobStuckTimeout: TimeInterval = 600,
        printerErrorGracePeriod: TimeInterval = 8,
        forceOneSidedPasses: Bool = false,
        fitToPage: Bool = false,
        scalePercent: Int = 100
    ) {
        self.printerID = printerID
        self.printerName = printerName
        self.flipAxis = flipAxis
        self.ejectsFaceDown = ejectsFaceDown
        self.driverOptions = driverOptions
        self.copies = copies
        self.pollInterval = pollInterval
        self.jobStuckTimeout = jobStuckTimeout
        self.printerErrorGracePeriod = printerErrorGracePeriod
        self.forceOneSidedPasses = forceOneSidedPasses
        self.fitToPage = fitToPage
        self.scalePercent = min(max(scalePercent, 50), 150)
    }

    public var flipMode: FlipMode {
        ejectsFaceDown ? .reinsertOnly : .flipBlock
    }

    public var driverOptionsWithDuplex: [String: String] {
        var values = driverOptions
        if forceOneSidedPasses {
            // Keep each manual pass genuinely single-sided on a queue whose
            // PPD defaults to hardware duplex.
            values["sides"] = "one-sided"
        } else {
            // The axis is persisted per printer and sent on both passes. Some
            // simplex drivers ignore it; it costs nothing and keeps the intent
            // explicit in the queue.
            values["Duplex"] = flipAxis.cupsDuplexValue
        }
        return values
    }
}

public enum DuplexCopy {
    public static var flipMessage: String { L("Flip the WHOLE stack over as one block — do NOT reorder or reverse the pages — reinsert it, then press Continue.") }
    public static var reinsertMessage: String { L("Reinsert the stack exactly as it is — do NOT reorder or reverse the pages — then press Continue.") }
    public static var noReversal: String { L("No page reversal is used. The physical flip puts the sheets back in the right order.") }
}

public struct FlipPrompt: Equatable, Sendable {
    public var printerName: String
    public var sheetCount: Int
    public var flipAxis: FlipAxis
    public var mode: FlipMode
    public var hasOddPageCount: Bool
    public var title: String
    public var message: String
    public var detail: String
    public var footnote: String?

    public init(
        printerName: String,
        sheetCount: Int,
        flipAxis: FlipAxis,
        mode: FlipMode,
        hasOddPageCount: Bool,
        title: String,
        message: String,
        detail: String,
        footnote: String? = nil
    ) {
        self.printerName = printerName
        self.sheetCount = sheetCount
        self.flipAxis = flipAxis
        self.mode = mode
        self.hasOddPageCount = hasOddPageCount
        self.title = title
        self.message = message
        self.detail = detail
        self.footnote = footnote
    }

    public static func make(
        printerName: String,
        sheetCount: Int,
        flipAxis: FlipAxis,
        mode: FlipMode,
        hasOddPageCount: Bool
    ) -> FlipPrompt {
        switch mode {
        case .flipBlock:
            return FlipPrompt(
                printerName: printerName,
                sheetCount: sheetCount,
                flipAxis: flipAxis,
                mode: mode,
                hasOddPageCount: hasOddPageCount,
                title: L("Flip the stack"),
                message: DuplexCopy.flipMessage,
                detail: flipAxis.flipInstruction,
                footnote: hasOddPageCount
                    ? L("The document has an odd page count, so the last sheet’s back stays blank.")
                    : nil
            )
        case .reinsertOnly:
            return FlipPrompt(
                printerName: printerName,
                sheetCount: sheetCount,
                flipAxis: flipAxis,
                mode: mode,
                hasOddPageCount: hasOddPageCount,
                title: L("Reinsert the stack"),
                message: DuplexCopy.reinsertMessage,
                detail: L("Your output tray ejects face-down, so the stack is already in the right order."),
                footnote: hasOddPageCount
                    ? L("The document has an odd page count, so the last sheet’s back stays blank.")
                    : nil
            )
        }
    }

    public var notificationBody: String { message }
}

public struct DuplexResult: Equatable, Sendable {
    public var printerName: String
    public var sourcePageCount: Int
    public var sheetCount: Int
    public var isBooklet: Bool
    public var hadBlankFinalBack: Bool
    public var elapsed: TimeInterval
    public var isSingleSided: Bool

    public init(
        printerName: String,
        sourcePageCount: Int,
        sheetCount: Int,
        isBooklet: Bool,
        hadBlankFinalBack: Bool,
        elapsed: TimeInterval,
        isSingleSided: Bool = false
    ) {
        self.printerName = printerName
        self.sourcePageCount = sourcePageCount
        self.sheetCount = sheetCount
        self.isBooklet = isBooklet
        self.hadBlankFinalBack = hadBlankFinalBack
        self.elapsed = elapsed
        self.isSingleSided = isSingleSided
    }
}

public enum DuplexPhase: Equatable, Sendable {
    case idle
    case preparing
    case printing(pass: DuplexPass, job: PrintJob)
    case awaitingFlip(FlipPrompt)
    case completed(DuplexResult)
    case failed(DuplexFailure)
    case cancelled(DuplexPass?)

    public var isIdle: Bool {
        if case .idle = self { return true }
        return false
    }

    public var isActive: Bool {
        switch self {
        case .preparing, .printing, .awaitingFlip: return true
        default: return false
        }
    }

    public var activePass: DuplexPass? {
        switch self {
        case .printing(let pass, _): return pass
        case .cancelled(let pass): return pass
        default: return nil
        }
    }

    public var job: PrintJob? {
        if case .printing(_, let job) = self { return job }
        return nil
    }

    public var prompt: FlipPrompt? {
        if case .awaitingFlip(let prompt) = self { return prompt }
        return nil
    }
}

public enum DuplexFailure: Error, Equatable, Sendable {
    case invalidDocument(String)
    case printerUnavailable(String)
    case printerStopped(pass: DuplexPass, reasons: [String])
    case submitFailed(pass: DuplexPass, message: String)
    case jobFailed(pass: DuplexPass, state: JobState, reasons: [String])
    case jobStuck(pass: DuplexPass, seconds: TimeInterval)
    case monitorFailed(pass: DuplexPass, message: String)
    case cancelled(pass: DuplexPass)

    public var pass: DuplexPass? {
        switch self {
        case .printerStopped(let pass, _),
             .submitFailed(let pass, _),
             .jobFailed(let pass, _, _),
             .jobStuck(let pass, _),
             .monitorFailed(let pass, _),
             .cancelled(let pass):
            return pass
        case .invalidDocument, .printerUnavailable:
            return nil
        }
    }

    public var title: String {
        switch self {
        case .invalidDocument: return L("Cannot print this document")
        case .printerUnavailable: return L("Printer unavailable")
        case .printerStopped: return L("The printer stopped")
        case .submitFailed: return L("Could not start printing")
        case .jobFailed: return L("Printing did not finish")
        case .jobStuck: return L("The job is stuck")
        case .monitorFailed: return L("Lost contact with the printer")
        case .cancelled: return L("Printing canceled")
        }
    }

    public var message: String {
        switch self {
        case .invalidDocument(let message):
            return message
        case .printerUnavailable(let message):
            return message
        case .printerStopped(_, let reasons):
            let detail = reasons.compactMap(PrinterReason.humanReadable).joined(separator: ", ")
            return detail.isEmpty ? L("The queue is stopped mid-job.") : detail
        case .submitFailed(_, let message):
            return message
        case .jobFailed(_, let state, let reasons):
            let detail = reasons.compactMap(PrinterReason.humanReadable).joined(separator: ", ")
            if !detail.isEmpty { return detail }
            return state == .canceled ? L("The print job was canceled.") : "The print job ended in \(state.label.lowercased()) state."
        case .jobStuck(_, let seconds):
            return String(format: L("No progress was reported for %lld seconds. Check the printer, then try again."), Int(seconds))
        case .monitorFailed(_, let message):
            return message
        case .cancelled:
            return L("The job was canceled.")
        }
    }

    public var canRetryBacks: Bool {
        switch self {
        case .printerStopped(let pass, _), .submitFailed(let pass, _):
            // These fail before the backs job exists, so the stack is still
            // intact and a second-pass retry cannot double-print a sheet.
            // Job/stuck/monitor failures may have printed some backs; restart.
            return pass == .backs
        default:
            return false
        }
    }
}

public extension DuplexFailure {
    /// A short recovery suggestion used by the popover's error surface.
    var recoverySuggestion: String {
        switch self {
        case .invalidDocument:
            return "Choose another PDF."
        case .printerUnavailable:
            return "Check that the printer is connected and the queue is enabled."
        case .printerStopped:
            return "Clear the error on the printer, then retry the backs or start over."
        case .submitFailed:
            return "Check the queue, then start the job again."
        case .jobFailed:
            return "Remove the sheets, then start over to keep the order correct."
        case .jobStuck:
            return "Cancel the job in the queue, then start over."
        case .monitorFailed:
            return "Reopen FlipStack and check the queue."
        case .cancelled:
            return "Nothing else will be printed."
        }
    }
}

public enum DuplexNotificationEvent: Equatable, Sendable {
    case flipRequired(FlipPrompt)
    case completed(printerName: String, sheetCount: Int)
    case failed(printerName: String, failure: DuplexFailure)
    case canceled
}

@MainActor
public protocol DuplexNotifying: AnyObject {
    func handle(_ event: DuplexNotificationEvent)
}
