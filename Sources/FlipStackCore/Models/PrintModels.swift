import Foundation

public enum PageSet: String, Codable, Sendable, CaseIterable {
    case all
    case odd
    case even

    /// The value passed to CUPS as `-o page-set=...`.
    public var cupsValue: String { rawValue }
}

public struct PageRange: Hashable, Codable, Sendable {
    public let lowerBound: Int
    public let upperBound: Int

    public init?(_ lowerBound: Int, _ upperBound: Int) {
        guard lowerBound > 0, upperBound >= lowerBound else { return nil }
        self.lowerBound = lowerBound
        self.upperBound = upperBound
    }

    private init(uncheckedLower lowerBound: Int, upperBound: Int) {
        self.lowerBound = lowerBound
        self.upperBound = upperBound
    }

    /// Parses `"1-3,7,10-12"`. Invalid fragments are ignored.
    public static func list(from string: String) -> [PageRange] {
        string
            .replacingOccurrences(of: "–", with: "-")
            .replacingOccurrences(of: "—", with: "-")
            .split(separator: ",")
            .compactMap { fragment -> PageRange? in
                let value = fragment.trimmingCharacters(in: .whitespaces)
                if let dash = value.firstIndex(of: "-") {
                    let lower = Int(value[..<dash])
                    let upper = Int(value[value.index(after: dash)...])
                    guard let lower, let upper else { return nil }
                    return PageRange(lower, upper)
                }
                guard let page = Int(value) else { return nil }
                return PageRange(page, page)
            }
    }

    public var cupsValue: String {
        lowerBound == upperBound ? "\(lowerBound)" : "\(lowerBound)-\(upperBound)"
    }
}

public enum PrintOrientation: String, Codable, Sendable, CaseIterable {
    case portrait
    case landscape
    case reverseLandscape
    case reversePortrait

    /// The same page turned 180 degrees, used for the backs of a short-edge
    /// manual flip.
    public var rotated180: PrintOrientation {
        switch self {
        case .portrait: return .reversePortrait
        case .landscape: return .reverseLandscape
        case .reverseLandscape: return .landscape
        case .reversePortrait: return .portrait
        }
    }

    /// IPP `orientation-requested` values.
    public var cupsValue: String {
        switch self {
        case .portrait: return "3"
        case .landscape: return "4"
        case .reverseLandscape: return "5"
        case .reversePortrait: return "6"
        }
    }
}

/// A single `lp` invocation. Driver options are raw PPD keyword/value pairs.
public struct PrintRequest: Hashable, Sendable {
    public var fileURL: URL
    public var printerID: String
    public var title: String
    public var pageSet: PageSet
    public var pageRanges: [PageRange]
    public var copies: Int
    public var numberUp: Int
    public var orientation: PrintOrientation
    public var driverOptions: [String: String]
    public var fitToPage: Bool
    /// 50...150. Ignored by CUPS when `fitToPage` is true.
    public var scalePercent: Int

    public init(
        fileURL: URL,
        printerID: String,
        title: String,
        pageSet: PageSet = .all,
        pageRanges: [PageRange] = [],
        copies: Int = 1,
        numberUp: Int = 1,
        orientation: PrintOrientation = .portrait,
        driverOptions: [String: String] = [:],
        fitToPage: Bool = false,
        scalePercent: Int = 100
    ) {
        self.fileURL = fileURL
        self.printerID = printerID
        self.title = title
        self.pageSet = pageSet
        self.pageRanges = pageRanges
        self.copies = copies
        self.numberUp = numberUp
        self.orientation = orientation
        self.driverOptions = driverOptions
        self.fitToPage = fitToPage
        self.scalePercent = min(max(scalePercent, 50), 150)
    }
}

public enum JobState: String, Codable, Sendable, CaseIterable {
    case pending
    case held
    case processing
    case stopped
    case canceled
    case aborted
    case completed
    case unknown

    public var isTerminal: Bool {
        switch self {
        case .canceled, .aborted, .completed: return true
        default: return false
        }
    }

    public var isFailure: Bool {
        switch self {
        case .canceled, .aborted, .stopped: return true
        default: return false
        }
    }

    public var isActive: Bool {
        switch self {
        case .pending, .held, .processing: return true
        default: return false
        }
    }

    public var label: String {
        switch self {
        case .pending: return L("Waiting")
        case .held: return L("Held")
        case .processing: return L("Printing")
        case .stopped: return L("Stopped")
        case .canceled: return L("Canceled")
        case .aborted: return L("Failed")
        case .completed: return L("Done")
        case .unknown: return L("Unknown")
        }
    }
}

public struct PrintJob: Identifiable, Hashable, Codable, Sendable {
    public var id: Int
    public var printerID: String
    public var title: String
    public var state: JobState
    public var stateReasons: [String]
    public var impressionsCompleted: Int?
    public var impressionsTotal: Int?
    public var createdAt: Date?
    public var owner: String?
    public var documentCount: Int?

    public init(
        id: Int,
        printerID: String,
        title: String,
        state: JobState = .pending,
        stateReasons: [String] = [],
        impressionsCompleted: Int? = nil,
        impressionsTotal: Int? = nil,
        createdAt: Date? = nil,
        owner: String? = nil,
        documentCount: Int? = nil
    ) {
        self.id = id
        self.printerID = printerID
        self.title = title
        self.state = state
        self.stateReasons = stateReasons
        self.impressionsCompleted = impressionsCompleted
        self.impressionsTotal = impressionsTotal
        self.createdAt = createdAt
        self.owner = owner
        self.documentCount = documentCount
    }

    public var isActive: Bool { state.isActive }

    /// A queue row is safe to show when it belongs to the current CUPS user
    /// or when this FlipStack session submitted it. Jobs from other users are
    /// never rendered or offered for cancellation.
    public func isVisible(to user: String, localJobIDs: Set<Int> = []) -> Bool {
        localJobIDs.contains(id) || owner == user
    }

    public var progress: Double? {
        guard let total = impressionsTotal, total > 0 else { return nil }
        let done = impressionsCompleted ?? 0
        return min(max(Double(done) / Double(total), 0), 1)
    }

    public var displayState: String {
        if state == .processing, let progress {
            return String(format: L("Printing %lld%%"), Int(progress * 100))
        }
        return state.label
    }
}

public enum CUPSCommandError: LocalizedError, Equatable, Sendable {
    case toolNotFound(String)
    case commandFailed(tool: String, status: Int32, message: String)
    case invalidOutput(String)
    case printerNotFound(String)
    case jobNotFound(Int)
    case fileNotFound(String)
    case timedOut(tool: String)

    public var errorDescription: String? {
        switch self {
        case .toolNotFound(let tool):
            return String(format: L("The system print tool “%@” was not found."), tool)
        case .commandFailed(let tool, let status, let message):
            let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(tool) exited with status \(status)\(detail.isEmpty ? "." : ": \(detail)")"
        case .invalidOutput(let value):
            return String(format: L("Unexpected output from the print system: %@"), value)
        case .printerNotFound(let printer):
            return String(format: L("Printer “%@” is not available."), printer)
        case .jobNotFound(let id):
            return String(format: L("Print job %lld could not be found."), id)
        case .fileNotFound(let path):
            return String(format: L("The file at %@ does not exist."), path)
        case .timedOut(let tool):
            return String(format: L("%@ did not respond in time."), tool)
        }
    }
}
