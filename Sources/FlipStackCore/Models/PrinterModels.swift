import Foundation

/// The coarse state of a CUPS queue, normalised from `lpstat`/IPP.
public enum PrinterState: String, Codable, Sendable, CaseIterable {
    case idle
    case processing
    case stopped
    case unknown

    public var label: String {
        switch self {
        case .idle: return "Ready"
        case .processing: return "Printing"
        case .stopped: return "Stopped"
        case .unknown: return "Unknown"
        }
    }

    public var canAcceptJobs: Bool {
        self != .stopped
    }
}

/// A CUPS print queue. `id` is the queue name used by `lp -d`.
public struct Printer: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var name: String
    public var model: String?
    public var location: String?
    public var deviceURI: String?
    public var state: PrinterState
    public var stateReasons: [String]
    public var isDefault: Bool
    public var acceptsJobs: Bool
    public var ppdPath: String?

    public init(
        id: String,
        name: String,
        model: String? = nil,
        location: String? = nil,
        deviceURI: String? = nil,
        state: PrinterState = .unknown,
        stateReasons: [String] = [],
        isDefault: Bool = false,
        acceptsJobs: Bool = true,
        ppdPath: String? = nil
    ) {
        self.id = id
        self.name = name
        self.model = model
        self.location = location
        self.deviceURI = deviceURI
        self.state = state
        self.stateReasons = stateReasons
        self.isDefault = isDefault
        self.acceptsJobs = acceptsJobs
        self.ppdPath = ppdPath
    }

    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? id : trimmed
    }

    public var modelName: String? {
        guard let model, !model.isEmpty else { return nil }
        return model
    }

    public var actionableReasons: [String] {
        stateReasons.compactMap(PrinterReason.humanReadable)
    }

    public var hasError: Bool {
        state == .stopped
            || !acceptsJobs
            || stateReasons.contains(where: { reason in
                // `offline-report` is emitted by some CUPS drivers (including
                // the Epson L1800 USB backend) even while the queue is idle and
                // accepts new jobs. Treat it as a warning, not a blocker.
                PrinterReason.isError(reason) && reason != "offline-report"
            })
    }

    public var isOffline: Bool {
        stateReasons.contains("offline-report")
    }
}

/// Maps IPP/CUPS state-reason keywords to short English labels.
public enum PrinterReason {
    private static let labels: [String: String] = [
        "media-empty-error": "Out of paper",
        "media-empty-warning": "Paper low",
        "media-jam-error": "Paper jam",
        "media-needed-error": "Paper needed",
        "marker-supply-empty-error": "Ink empty",
        "marker-supply-low-warning": "Ink low",
        "marker-waste-full-warning": "Waste ink tank full",
        "marker-waste-almost-full-warning": "Waste ink tank nearly full",
        "cover-open-error": "Cover open",
        "door-open-error": "Cover open",
        "interlock-open-error": "Cover open",
        "input-tray-missing-error": "Input tray missing",
        "output-tray-missing-error": "Output tray missing",
        "offline-report": "Printer offline",
        "paused": "Paused",
        "shutdown": "Printer is shutting down",
        "connecting-to-device": "Connecting to printer",
        "timed-out": "Printer not responding",
        "stopped-partly": "Stopped by the system",
        "cups-waiting-for-job-completed": "Finishing the previous job",
        "job-printing": "Printing",
        "job-processing": "Processing",
        "none": ""
    ]

    public static func humanReadable(_ reason: String) -> String? {
        if reason.isEmpty || reason == "none" { return nil }
        if let value = labels[reason] {
            return value.isEmpty ? nil : value
        }
        var text = reason
            .replacingOccurrences(of: "-error", with: "")
            .replacingOccurrences(of: "-warning", with: "")
            .replacingOccurrences(of: "-report", with: "")
            .replacingOccurrences(of: "-", with: " ")
        text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    public static func isError(_ reason: String) -> Bool {
        reason.hasSuffix("-error") || reason == "stopped-partly" || reason == "offline-report"
    }

    public static func isWarning(_ reason: String) -> Bool {
        reason.hasSuffix("-warning")
    }

    public static func isSupplyReason(_ reason: String) -> Bool {
        reason.hasPrefix("marker-")
    }
}

public enum SupplyKind: String, Codable, Sendable, CaseIterable {
    case ink
    case toner
    case drum
    case waste
    case maintenance
    case other

    public var label: String {
        switch self {
        case .ink: return "Ink"
        case .toner: return "Toner"
        case .drum: return "Drum"
        case .waste: return "Waste"
        case .maintenance: return "Maintenance"
        case .other: return "Supply"
        }
    }
}

public struct SupplyLevel: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var name: String
    public var kind: SupplyKind
    public var colorName: String?
    /// 0...100 when known; `nil` when the device did not report a usable level.
    public var levelPercent: Int?
    public var isEstimated: Bool

    public init(
        id: String = UUID().uuidString,
        name: String,
        kind: SupplyKind = .ink,
        colorName: String? = nil,
        levelPercent: Int? = nil,
        isEstimated: Bool = false
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.colorName = colorName
        self.levelPercent = levelPercent
        self.isEstimated = isEstimated
    }

    /// Marker descriptions from drivers are often abbreviations (`MB`, `PK`,
    /// `LC`). Prefer a readable color name when one is available.
    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let shortNames = [
            "mb": "Matte Black",
            "pk": "Photo Black",
            "lc": "Light Cyan",
            "lm": "Light Magenta",
            "lk": "Light Black",
            "pc": "Photo Cyan",
            "pm": "Photo Magenta",
            "vm": "Vivid Magenta",
            "vlm": "Vivid Light Magenta",
            "vlc": "Vivid Light Cyan"
        ]
        if let friendly = shortNames[trimmed.lowercased()] {
            return friendly
        }
        let color = colorName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            return color.isEmpty ? kind.label : color
        }
        if trimmed.count <= 3, color.count > trimmed.count {
            return color
        }
        return trimmed
    }

    public var isLow: Bool {
        guard let levelPercent else { return false }
        return levelPercent <= 12
    }

    public var isCritical: Bool {
        guard let levelPercent else { return false }
        return levelPercent <= 4
    }

    public var fraction: Double? {
        guard let levelPercent else { return nil }
        return min(max(Double(levelPercent) / 100.0, 0), 1)
    }
}

public enum StatusOrigin: String, Codable, Sendable {
    case ipp
    case snmp
    case lpstat
    case unavailable
}

public struct PrinterStatus: Hashable, Codable, Sendable {
    public var printerID: String
    public var state: PrinterState
    public var stateReasons: [String]
    public var supplies: [SupplyLevel]
    public var origin: StatusOrigin
    public var fetchedAt: Date
    public var note: String?
    public var acceptsJobs: Bool?
    public var queuedJobCount: Int?
    public var stateMessage: String?

    public init(
        printerID: String,
        state: PrinterState,
        stateReasons: [String] = [],
        supplies: [SupplyLevel] = [],
        origin: StatusOrigin = .unavailable,
        fetchedAt: Date = Date(),
        note: String? = nil,
        acceptsJobs: Bool? = nil,
        queuedJobCount: Int? = nil,
        stateMessage: String? = nil
    ) {
        self.printerID = printerID
        self.state = state
        self.stateReasons = stateReasons
        self.supplies = supplies
        self.origin = origin
        self.fetchedAt = fetchedAt
        self.note = note
        self.acceptsJobs = acceptsJobs
        self.queuedJobCount = queuedJobCount
        self.stateMessage = stateMessage
    }

    public static func unknown(for printer: Printer) -> PrinterStatus {
        PrinterStatus(
            printerID: printer.id,
            state: printer.state,
            stateReasons: printer.stateReasons,
            origin: .unavailable,
            note: "Live status is not available right now."
        )
    }

    public var actionableReasons: [String] {
        stateReasons.compactMap(PrinterReason.humanReadable)
    }

    public var isLowOnSupply: Bool {
        supplies.contains(where: \.isLow)
    }

    public var hasSupplyData: Bool {
        !supplies.isEmpty
    }
}
