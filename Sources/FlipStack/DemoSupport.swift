import AppKit
import FlipStackCore
import Foundation
import SwiftUI

/// Local-only demo and screenshot support. It exercises the real app views and
/// state machine with an in-memory spooler, so the README can show every
/// designed state without sending anything to a physical printer.
@MainActor
final class DemoSession {
    enum Scenario: String {
        case empty
        case ready
        case flip
        case printing
        case error
        case queue
        case ink
        case completed
        case range
        case single
        case singlePrinting
        case booklet
        case completedSingle
        case bookletPrinting
        case rangePrinting
        case preview
        case bookletPreview
        case quality
        case firstPrintSetup
        case firstPrintPending
        case calibrationSetup
        case calibrationPrinting
        case calibrationQuestions
        case calibrationAnswered
        case calibrationApplied
    }

    let scenario: Scenario
    let spooler: DemoSpooler
    let ppdProvider: DemoPPDProvider
    let statusProvider: DemoStatusProvider
    let documentURL: URL

    init?(arguments: [String]) {
        guard let index = arguments.firstIndex(of: "--demo"), index + 1 < arguments.count,
              let scenario = Scenario(rawValue: arguments[index + 1]) else {
            return nil
        }
        self.scenario = scenario
        self.spooler = DemoSpooler(scenario: scenario)
        self.ppdProvider = DemoPPDProvider()
        self.statusProvider = DemoStatusProvider(lowInk: scenario == .ink)
        do {
            self.documentURL = try DemoPDF.make(
                pageCount: (scenario == .ready || scenario == .range || scenario == .booklet || scenario == .completed || scenario == .completedSingle || scenario == .rangePrinting || scenario == .preview || scenario == .bookletPreview) ? 8 : 5
            )
        } catch {
            NSLog("FlipStack demo document failed: \(error)")
            return nil
        }
    }

    nonisolated static func demoPreferences(for scenario: Scenario) -> PrinterPreferences {
        if scenario == .firstPrintSetup
            || scenario == .firstPrintPending
            || scenario == .calibrationApplied {
            return .unconfigured
        }
        return PrinterPreferences(flipAxis: .longEdge, ejectsFaceDown: false, hasConfiguredFlip: true)
    }

    nonisolated static func demoPrinterID() -> String {
        "flipstack-demo-l1800"
    }

    /// Waits until the view that the screenshot is meant to document is on
    /// screen, then lets layout and the final animation settle.
    func prepareAndWait(model: AppModel, timeout: TimeInterval = 20) async {
        let printerDeadline = Date().addingTimeInterval(10)
        while model.selectedPrinter == nil && Date() < printerDeadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard let printer = model.selectedPrinter ?? model.printers.first else { return }

        let ppdDeadline = Date().addingTimeInterval(4)
        while model.isLoadingPPD && Date() < ppdDeadline {
            try? await Task.sleep(nanoseconds: 80_000_000)
        }

        switch scenario {
        case .empty:
            break
        case .range:
            await model.acceptDocument(url: documentURL)
            model.pageSelectionMode = .range
            model.pageRangeText = "2-4, 7"
        case .single:
            await model.acceptDocument(url: documentURL)
            model.mode = .singleSided
        case .preview:
            await model.acceptDocument(url: documentURL)
            model.togglePreview()
            await waitForPreview(model: model, timeout: timeout)
        case .bookletPreview:
            await model.acceptDocument(url: documentURL)
            model.mode = .booklet
            model.togglePreview()
            await waitForPreview(model: model, timeout: timeout)
        case .quality:
            await model.acceptDocument(url: documentURL)
            model.applyQualityPreset(.photo)
            model.forceLandscape = true
            model.fitToPage = true
        case .firstPrintPending:
            await model.acceptDocument(url: documentURL)
            model.mode = .manualDuplex
        case .firstPrintSetup:
            await model.acceptDocument(url: documentURL)
            model.mode = .manualDuplex
            model.requestPrint()
        case .calibrationSetup:
            await model.acceptDocument(url: documentURL)
            model.openFlipAxisSetup()
        case .calibrationPrinting:
            await model.acceptDocument(url: documentURL)
            model.openFlipAxisSetup()
            model.startFlipCalibration()
            await waitForCalibration(model: model) { calibration in
                if case .printing = calibration.stage { return true }
                if case .failed = calibration.stage { return true }
                return false
            }
        case .calibrationQuestions:
            await model.acceptDocument(url: documentURL)
            model.openFlipAxisSetup()
            model.startFlipCalibration()
            await waitForCalibration(model: model) { calibration in
                if case .questions = calibration.stage { return true }
                if case .failed = calibration.stage { return true }
                return false
            }
        case .calibrationAnswered:
            await model.acceptDocument(url: documentURL)
            model.openFlipAxisSetup()
            model.startFlipCalibration()
            await waitForCalibration(model: model) { calibration in
                if case .questions = calibration.stage { return true }
                if case .failed = calibration.stage { return true }
                return false
            }
            model.setFlipCalibrationAxis(.longEdge)
            model.setFlipCalibrationEjectsFaceDown(false)
        case .calibrationApplied:
            await model.acceptDocument(url: documentURL)
            model.mode = .manualDuplex
            model.requestPrint()
            model.startFlipCalibration()
            await waitForCalibration(model: model) { calibration in
                if case .questions = calibration.stage { return true }
                if case .failed = calibration.stage { return true }
                return false
            }
            if model.flipCalibration != nil {
                model.setFlipCalibrationAxis(.shortEdge)
                model.setFlipCalibrationEjectsFaceDown(true)
                model.applyFlipCalibration()
                await waitForPhase(model: model, matches: { phase in
                    if case .printing(.fronts, _) = phase { return true }
                    if case .failed = phase { return true }
                    return false
                }, timeout: timeout)
            }
        case .booklet:
            await model.acceptDocument(url: documentURL)
            model.mode = .booklet
        case .bookletPrinting:
            await model.acceptDocument(url: documentURL)
            model.mode = .booklet
            beginPrintFlow(model: model, printer: printer)
            await waitForPhase(model: model, matches: { phase in
                if case .printing(.fronts, _) = phase { return true }
                if case .failed = phase { return true }
                return false
            }, timeout: timeout)
        case .rangePrinting:
            await model.acceptDocument(url: documentURL)
            model.pageSelectionMode = .range
            model.pageRangeText = "2-4, 7"
            beginPrintFlow(model: model, printer: printer)
            await waitForPhase(model: model, matches: { phase in
                if case .printing(.fronts, _) = phase { return true }
                if case .failed = phase { return true }
                return false
            }, timeout: timeout)
        case .completedSingle:
            await model.acceptDocument(url: documentURL)
            model.mode = .singleSided
            beginPrintFlow(model: model, printer: printer)
            await waitForPhase(model: model, matches: { phase in
                if case .completed = phase { return true }
                return false
            }, timeout: timeout)
        case .ready, .ink, .queue, .completed:
            await model.acceptDocument(url: documentURL)
            if scenario == .queue {
                model.isShowingQueue = true
                await model.refreshQueue()
            }
            if scenario == .completed {
                beginPrintFlow(model: model, printer: printer)
                await waitForPhase(model: model, matches: { phase in
                    if case .awaitingFlip = phase { return true }
                    if case .completed = phase { return true }
                    return false
                }, timeout: timeout)
                if case .awaitingFlip = model.orchestrator.phase {
                    model.confirmFlip()
                    await waitForPhase(model: model, matches: { phase in
                        if case .completed = phase { return true }
                        return false
                    }, timeout: timeout)
                }
            }
        case .singlePrinting:
            await model.acceptDocument(url: documentURL)
            model.mode = .singleSided
            beginPrintFlow(model: model, printer: printer)
            await waitForPhase(model: model, matches: { phase in
                if case .printing(.fronts, _) = phase { return true }
                return false
            }, timeout: timeout)
        case .flip, .printing, .error:
            await model.acceptDocument(url: documentURL)
            beginPrintFlow(model: model, printer: printer)
            await waitForPhase(model: model, matches: { phase in
                switch self.scenario {
                case .flip:
                    if case .awaitingFlip = phase { return true }
                case .printing:
                    if case .printing(.fronts, _) = phase { return true }
                case .error:
                    if case .failed = phase { return true }
                default:
                    break
                }
                return false
            }, timeout: timeout)
        }

        try? await Task.sleep(nanoseconds: 750_000_000)

        if scenario == .queue {
            model.isShowingQueue = true
            await model.refreshQueue()
        }
    }

    private func beginPrintFlow(model: AppModel, printer: Printer) {
        if model.preferences.hasConfiguredFlip == false {
            model.completeFlipAxisSetup(flipAxis: .longEdge, ejectsFaceDown: false)
        } else {
            model.requestPrint()
        }
    }

    private func waitForPhase(
        model: AppModel,
        matches: (DuplexPhase) -> Bool,
        timeout: TimeInterval
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if matches(model.orchestrator.phase) { return }
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
    }

    private func waitForPreview(model: AppModel, timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if model.isShowingPreview || !model.isPreparingPreview { return }
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
    }

    private func waitForCalibration(
        model: AppModel,
        timeout: TimeInterval = 20,
        matches: (FlipCalibration) -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let calibration = model.flipCalibration, matches(calibration) { return }
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
    }
}

// MARK: - Demo spooler

actor DemoSpooler: PrintSpooling {
    private let scenario: DemoSession.Scenario
    private var jobs: [Int: PrintJob] = [:]
    private var polls: [Int: Int] = [:]
    private var activeIDs: [Int] = []
    private var nextID = 480
    private let printer: Printer

    init(scenario: DemoSession.Scenario) {
        self.scenario = scenario
        let printer = Printer(
            id: DemoSession.demoPrinterID(),
            name: "EPSON L1800 Series",
            model: "EPSON L1800 Series",
            location: "Studio desk",
            deviceURI: "usb://EPSON/L1800%20Series",
            state: .idle,
            stateReasons: [],
            isDefault: true,
            acceptsJobs: true
        )
        self.printer = printer

        if scenario == .queue {
            jobs[470] = PrintJob(
                id: 470,
                printerID: printer.id,
                title: "Annual report.pdf",
                state: .completed,
                impressionsCompleted: 12,
                impressionsTotal: 12,
                owner: NSUserName()
            )
            jobs[471] = PrintJob(
                id: 471,
                printerID: printer.id,
                title: "Invoice batch.pdf",
                state: .pending,
                impressionsCompleted: 0,
                impressionsTotal: 4,
                owner: NSUserName(),
                documentCount: 1
            )
            jobs[472] = PrintJob(
                id: 472,
                printerID: printer.id,
                title: "Field Notes — fronts",
                state: .processing,
                impressionsCompleted: 2,
                impressionsTotal: 5,
                owner: NSUserName(),
                documentCount: 1
            )
            activeIDs = [471, 472]
        }
    }

    func listPrinters() async throws -> [Printer] {
        [printer]
    }

    func printer(id: String) async throws -> Printer {
        guard id == printer.id else { throw CUPSCommandError.printerNotFound(id) }
        return printer
    }

    func submit(_ request: PrintRequest) async throws -> PrintJob {
        let id = nextID
        nextID += 1
        let isCalibration = request.title == "FlipStack calibration sheet"
        let total = isCalibration ? 1 : max(1, (request.pageSet == .all ? 5 : 3))
        var job = PrintJob(
            id: id,
            printerID: request.printerID,
            title: request.title,
            state: .processing,
            impressionsCompleted: 0,
            impressionsTotal: total,
            owner: NSUserName(),
            documentCount: 1
        )
        if scenario == .printing {
            job.impressionsCompleted = 1
        }
        jobs[id] = job
        polls[id] = 0
        activeIDs.append(id)
        return job
    }

    func job(id: Int, printerID: String) async throws -> PrintJob? {
        guard var job = jobs[id] else { return nil }
        polls[id, default: 0] += 1
        let count = polls[id, default: 0]

        switch scenario {
        case .calibrationQuestions, .calibrationAnswered, .calibrationApplied:
            if count >= 2 {
                job.state = .completed
                job.impressionsCompleted = job.impressionsTotal
                activeIDs.removeAll { $0 == id }
            } else {
                job.state = .processing
                job.impressionsCompleted = 0
            }
        case .printing, .bookletPrinting, .rangePrinting, .calibrationPrinting:
            job.state = .processing
            job.impressionsCompleted = min(job.impressionsTotal ?? 1, 1 + count / 3)
        case .flip, .completed, .completedSingle:
            if count >= 2 {
                job.state = .completed
                job.impressionsCompleted = job.impressionsTotal
                activeIDs.removeAll { $0 == id }
            } else {
                job.state = .processing
                job.impressionsCompleted = min(job.impressionsTotal ?? 1, 1)
            }
        case .error:
            if count >= 3 {
                job.state = .aborted
                job.stateReasons = ["media-jam-error"]
                activeIDs.removeAll { $0 == id }
            } else {
                job.state = .processing
            }
        default:
            break
        }

        jobs[id] = job
        return job
    }

    func activeJobs(printerID: String) async throws -> [PrintJob] {
        jobs.values
            .filter { $0.isActive }
            .sorted { $0.id < $1.id }
    }

    func recentJobs(printerID: String, limit: Int) async throws -> [PrintJob] {
        Array(
            jobs.values
                .filter { !$0.isActive }
                .sorted { $0.id > $1.id }
                .prefix(limit)
        )
    }

    func cancel(jobID: Int, printerID: String) async throws {
        guard var job = jobs[jobID] else { return }
        job.state = .canceled
        jobs[jobID] = job
        activeIDs.removeAll { $0 == jobID }
    }
}

struct DemoPrinterDiscovery: PrinterDiscovering {
    func discoverDevices() async throws -> [DiscoveredPrinter] {
        []
    }
}

struct DemoPPDProvider: PPDProviding {    func locatePPD(for printer: Printer) -> URL? {
        URL(fileURLWithPath: "/Library/Printers/PPDs/Demo/Epson-L1800.ppd")
    }

    func parsePPD(at url: URL) throws -> PPDDocument {
        PPDDocument(
            nickname: "EPSON L1800 Series",
            makeAndModel: "EPSON L1800 Series",
            manufacturer: "Epson",
            options: [
                PPDOption(
                    keyword: "ColorModel",
                    label: "Color Mode",
                    group: .color,
                    choices: [
                        PPDChoice(keyword: "Color", label: "Color"),
                        PPDChoice(keyword: "Grayscale", label: "Grayscale")
                    ],
                    defaultChoice: "Color"
                ),
                PPDOption(
                    keyword: "PageSize",
                    label: "Paper Size",
                    group: .paperSize,
                    choices: [
                        PPDChoice(keyword: "A4", label: "A4"),
                        PPDChoice(keyword: "A5", label: "A5"),
                        PPDChoice(keyword: "Letter", label: "US Letter"),
                        PPDChoice(keyword: "Legal", label: "Legal")
                    ],
                    defaultChoice: "A4"
                ),
                PPDOption(
                    keyword: "MediaType",
                    label: "Media Type",
                    group: .mediaType,
                    choices: [
                        PPDChoice(keyword: "PLAIN", label: "Plain paper"),
                        PPDChoice(keyword: "PHOTO", label: "Photo paper")
                    ],
                    defaultChoice: "PLAIN"
                ),
                PPDOption(
                    keyword: "Resolution",
                    label: "Print Quality",
                    group: .quality,
                    choices: [
                        PPDChoice(keyword: "1440dpi", label: "1440 dpi"),
                        PPDChoice(keyword: "2880dpi", label: "2880 dpi")
                    ],
                    defaultChoice: "1440dpi"
                )
            ],
            supportsHardwareDuplex: false,
            sourcePath: "/Library/Printers/PPDs/Demo/Epson-L1800.ppd"
        )
    }
}

struct DemoStatusProvider: PrinterStatusProviding {
    let lowInk: Bool

    func status(for printer: Printer) async -> PrinterStatus {
        let supplies: [SupplyLevel]
        if lowInk {
            supplies = [
                SupplyLevel(id: "black", name: "Black", kind: .ink, colorName: "black", levelPercent: 7),
                SupplyLevel(id: "cyan", name: "Cyan", kind: .ink, colorName: "cyan", levelPercent: 5),
                SupplyLevel(id: "light-cyan", name: "Light Cyan", kind: .ink, colorName: "lightCyan", levelPercent: 38),
                SupplyLevel(id: "magenta", name: "Magenta", kind: .ink, colorName: "magenta", levelPercent: 44),
                SupplyLevel(id: "light-magenta", name: "Light Magenta", kind: .ink, colorName: "lightMagenta", levelPercent: 56),
                SupplyLevel(id: "yellow", name: "Yellow", kind: .ink, colorName: "yellow", levelPercent: 61)
            ]
        } else {
            supplies = [
                SupplyLevel(id: "black", name: "Black", kind: .ink, colorName: "black", levelPercent: 78),
                SupplyLevel(id: "cyan", name: "Cyan", kind: .ink, colorName: "cyan", levelPercent: 56),
                SupplyLevel(id: "light-cyan", name: "Light Cyan", kind: .ink, colorName: "lightCyan", levelPercent: 43),
                SupplyLevel(id: "magenta", name: "Magenta", kind: .ink, colorName: "magenta", levelPercent: 63),
                SupplyLevel(id: "light-magenta", name: "Light Magenta", kind: .ink, colorName: "lightMagenta", levelPercent: 51),
                SupplyLevel(id: "yellow", name: "Yellow", kind: .ink, colorName: "yellow", levelPercent: 49)
            ]
        }
        return PrinterStatus(
            printerID: printer.id,
            state: .idle,
            stateReasons: [],
            supplies: supplies,
            origin: .ipp,
            fetchedAt: Date(),
            note: nil
        )
    }
}

// MARK: - Sample PDF

enum DemoPDF {
    static func make(pageCount: Int) throws -> URL {
        let size = CGSize(width: 595, height: 842)
        let data = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: size)
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw PrintUtilityError.cannotCreatePDF
        }

        let coral = NSColor(calibratedRed: 0.92, green: 0.28, blue: 0.16, alpha: 1)
        for page in 1...pageCount {
            context.beginPDFPage(nil)
            context.setFillColor(NSColor(calibratedWhite: 0.99, alpha: 1).cgColor)
            context.fill(mediaBox)

            let graphics = NSGraphicsContext(cgContext: context, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics

            coral.setFill()
            NSBezierPath(rect: NSRect(x: 56, y: 770, width: 32, height: 4)).fill()
            draw("Field Notes", at: CGPoint(x: 56, y: 715), size: 32, weight: .bold)
            draw("A quiet study in paper and motion", at: CGPoint(x: 56, y: 690), size: 13, color: .darkGray)
            draw("CHAPTER \(page)", at: CGPoint(x: 56, y: 625), size: 9, color: coral, tracking: 1.2)

            let paragraph = [
                "The sheet does not know which side came first.",
                "It only knows the edge it was turned around.",
                "Keep the block together. Let the stack do the sorting.",
                "A clean flip is one movement, not a shuffle."
            ]
            var y: CGFloat = 585
            for line in paragraph {
                draw(line, at: CGPoint(x: 56, y: y), size: 15, color: NSColor(calibratedWhite: 0.2, alpha: 1))
                y -= 27
            }

            context.setStrokeColor(NSColor(calibratedWhite: 0.82, alpha: 1).cgColor)
            context.setLineWidth(0.6)
            for line in 0..<9 {
                let lineY = 450 - CGFloat(line) * 24
                context.move(to: CGPoint(x: 56, y: lineY))
                context.addLine(to: CGPoint(x: 539, y: lineY))
                context.strokePath()
            }

            draw("FlipStack sample document", at: CGPoint(x: 56, y: 74), size: 9, color: .gray)
            draw("Page \(page) of \(pageCount)", at: CGPoint(x: 470, y: 74), size: 9, color: .gray)
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FlipStackDemo", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        let url = directory.appendingPathComponent("Field-Notes-\(pageCount)-pages.pdf")
        try (data as Data).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
        return url
    }

    private static func draw(
        _ text: String,
        at point: CGPoint,
        size: CGFloat,
        weight: NSFont.Weight = .regular,
        color: NSColor = .black,
        tracking: CGFloat = 0
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
            .kern: tracking,
            .paragraphStyle: paragraph
        ]
        (text as NSString).draw(at: point, withAttributes: attributes)
    }
}
