import AppKit
import Combine
import FlipStackCore
import PDFKit
import UniformTypeIdentifiers

enum PrinterHealth: Equatable {
    case unknown
    case ready
    case preparing
    case printing
    case waiting
    case offline
    case attention

    var label: String {
        switch self {
        case .unknown: return "Unknown"
        case .ready: return "Ready"
        case .preparing: return "Preparing"
        case .printing: return "Printing"
        case .waiting: return "Your turn"
        case .offline: return "Offline"
        case .attention: return "Needs attention"
        }
    }
}

struct SelectedDocument: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let name: String
    let pageCount: Int
    let isLandscape: Bool

    var title: String {
        let base = (name as NSString).deletingPathExtension
        return base.isEmpty ? name : base
    }

    var formattedPageCount: String {
        pageCount == 1 ? "1 page" : "\(pageCount) pages"
    }
}

enum PageSelectionMode: String, CaseIterable, Identifiable {
    case all
    case range

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "All"
        case .range: return "Pages"
        }
    }
}

struct PageSelectionInfo: Equatable {
    var mode: PageSelectionMode
    var ranges: [PageRange]
    var pageCount: Int
    var totalPages: Int
    var isValid: Bool
    var message: String?

    var isAll: Bool {
        guard isValid else { return false }
        if mode == .all { return true }
        return pageCount == totalPages
            && ranges.first?.lowerBound == 1
            && ranges.last?.upperBound == totalPages
    }

    var summary: String {
        guard isValid else { return "Check the page range" }
        if isAll {
            return totalPages == 1 ? "All 1 page" : "All \(totalPages) pages"
        }
        return pageCount == 1 ? "1 of \(totalPages) pages" : "\(pageCount) of \(totalPages) pages"
    }
}

struct FlipAxisSetup: Equatable {
    var autoStartsPrint: Bool
}

struct FlipCalibration: Equatable {
    enum Stage: Equatable {
        case printing
        case questions
        case failed(String)
    }

    var id = UUID()
    var stage: Stage
    var autoStartsPrint: Bool
    var printerID: String
    var axis: FlipAxis
    var recommendedAxis: FlipAxis
    var ejectsFaceDown: Bool
    var jobID: Int?
    var hasConfirmedTray: Bool = false
    var hasConfirmedAxis: Bool = false

    var isAnswered: Bool {
        hasConfirmedTray && hasConfirmedAxis
    }
}

struct AppBanner: Identifiable, Equatable {
    enum Kind: String, Equatable {
        case info
        case success
        case warning
        case error
    }

    let id = UUID()
    var kind: Kind
    var title: String
    var message: String?
}

@MainActor
final class AppModel: ObservableObject {
    // MARK: Printers and status

    @Published private(set) var printers: [Printer] = []
    @Published private(set) var selectedPrinter: Printer?
    @Published private(set) var status: PrinterStatus?
    @Published private(set) var ppd: PPDDocument?
    @Published private(set) var isLoadingPrinters = true
    @Published private(set) var isLoadingPPD = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var ppdNote: String?
    @Published private(set) var discoveredDevices: [DiscoveredPrinter] = []
    @Published private(set) var isDiscoveringPrinters = false
    @Published private(set) var discoveryNote: String?

    private var isRefreshingStatus = false
    private var isRefreshingQueue = false
    private var localJobIDs = Set<Int>()
    private var localJobTitles: [Int: String] = [:]

    // MARK: Document and options

    @Published private(set) var selectedDocument: SelectedDocument?
    @Published var mode: PrintMode = .manualDuplex {
        didSet {
            guard oldValue != mode else { return }
            if mode.isTwoPass {
                copies = 1
            }
            preferencesStore.lastPrintMode = mode
            closePreview()
            recomputeBookletPlan()
        }
    }
    @Published var pageSelectionMode: PageSelectionMode = .all {
        didSet {
            guard oldValue != pageSelectionMode else { return }
            if pageSelectionMode == .range,
               pageRangeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let document = selectedDocument {
                pageRangeText = "1-\(document.pageCount)"
            }
            closePreview()
            recomputeBookletPlan()
        }
    }
    @Published var pageRangeText: String = "" {
        didSet {
            guard oldValue != pageRangeText else { return }
            closePreview()
            recomputeBookletPlan()
        }
    }
    @Published private(set) var activePrintMode: PrintMode = .manualDuplex
    @Published private(set) var selectedQualityPreset: PrintQualityPreset?
    @Published var forceLandscape = false {
        didSet {
            guard oldValue != forceLandscape else { return }
            saveLayout()
        }
    }
    @Published var fitToPage = true {
        didSet {
            guard oldValue != fitToPage else { return }
            saveLayout()
        }
    }
    @Published var scalePercent = 100 {
        didSet {
            let clamped = min(max(scalePercent, 50), 150)
            if clamped != scalePercent {
                scalePercent = clamped
                return
            }
            guard oldValue != scalePercent else { return }
            saveLayout()
        }
    }

    var effectiveScale: CGFloat {
        fitToPage ? 1 : CGFloat(scalePercent) / 100
    }

    func setScalePercent(_ value: Int) {
        let clamped = min(max(value, 50), 150)
        if fitToPage {
            fitToPage = false
        }
        scalePercent = clamped
    }
    @Published private(set) var optionSelection: [String: String] = [:]
    @Published private(set) var preferences: PrinterPreferences = .unconfigured
    @Published var bookletSignatureSheets: Int = 0 {
        didSet {
            guard oldValue != bookletSignatureSheets else { return }
            closePreview()
            recomputeBookletPlan()
        }
    }
    @Published private(set) var bookletPlan: BookletPlan?
    @Published var copies: Int = 1

    // MARK: Print preview

    @Published private(set) var previewURL: URL?
    @Published private(set) var previewBacksURL: URL?
    @Published private(set) var isShowingPreview = false
    @Published private(set) var isPreparingPreview = false
    @Published var previewShowsBacks = false
    private var previewDirectory: URL?
    private var previewGeneration = 0

    // MARK: Flow and surfaces

    @Published var flipAxisSetup: FlipAxisSetup?
    @Published private(set) var flipCalibration: FlipCalibration?
    @Published var isShowingQueue = false {
        didSet {
            guard oldValue != isShowingQueue else { return }
            if isShowingQueue {
                closePreview()
            }
            updateQueuePolling()
        }
    }
    @Published var banner: AppBanner?
    @Published private(set) var isPreparingPrint = false
    @Published private(set) var queue: [PrintJob] = []
    @Published private(set) var queueError: String?
    @Published private(set) var isMaintenanceBusy = false

    let orchestrator: DuplexOrchestrator

    private let spooler: PrintSpooling
    private let ppdProvider: PPDProviding
    private let statusProvider: PrinterStatusProviding
    private let bookletImposer: any BookletImposing
    private let preferencesStore: PreferencesStore
    private let printerDiscovery: any PrinterDiscovering

    private var bookletDocuments: BookletDocuments?
    private var selectionWorkingDirectory: URL?
    private var presetResolver: PrintPresetResolver?
    private var monitorTask: Task<Void, Never>?
    private var queueMonitorTask: Task<Void, Never>?
    private var preparationTask: Task<Void, Never>?
    private var calibrationTask: Task<Void, Never>?
    private var preparationGeneration = 0
    private var lastDiscoveryAt: Date?
    private var hasStarted = false
    private var cancellables = Set<AnyCancellable>()

    init(
        spooler: PrintSpooling,
        ppdProvider: PPDProviding,
        statusProvider: PrinterStatusProviding,
        bookletImposer: any BookletImposing,
        preferencesStore: PreferencesStore,
        orchestrator: DuplexOrchestrator,
        printerDiscovery: any PrinterDiscovering = CUPSDeviceDiscovery()
    ) {
        self.spooler = spooler
        self.ppdProvider = ppdProvider
        self.statusProvider = statusProvider
        self.bookletImposer = bookletImposer
        self.preferencesStore = preferencesStore
        self.orchestrator = orchestrator
        self.printerDiscovery = printerDiscovery
        self.copies = 1
        self.mode = preferencesStore.lastPrintMode ?? .manualDuplex

        orchestrator.$phase
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] phase in
                guard let self else { return }
                if case .printing(let pass, let job) = phase {
                    self.rememberLocalJob(job, pass: pass)
                }
                switch phase {
                case .printing, .awaitingFlip, .completed, .failed, .cancelled:
                    Task {
                        await self.refreshQueue()
                        await self.refreshStatus()
                    }
                case .idle, .preparing:
                    break
                }
            }
            .store(in: &cancellables)
    }

    // MARK: Derived values

    var canPrint: Bool {
        selectedPrinter != nil
            && selectedDocument != nil
            && pageSelectionInfo.isValid
            && pageSelectionInfo.pageCount > 0
            && !isLoadingPPD
            && !isPreparingPrint
            && !isMaintenanceBusy
            && flipCalibration == nil
            && orchestrator.phase.isIdle
    }

    var isCalibrating: Bool { flipCalibration != nil }

    /// The physical sheet shape shown during the flip prompt. Booklet 2-up
    /// sheets are landscape; standard documents follow their first page and
    /// the forced-landscape layout choice.
    var isLandscapeStack: Bool {
        activePrintMode == .booklet
            || forceLandscape
            || (selectedDocument?.isLandscape ?? false)
    }

    var pageSelectionInfo: PageSelectionInfo {
        guard let document = selectedDocument else {
            return PageSelectionInfo(
                mode: pageSelectionMode,
                ranges: [],
                pageCount: 0,
                totalPages: 0,
                isValid: false,
                message: "Choose a PDF first."
            )
        }
        switch pageSelectionMode {
        case .all:
            return PageSelectionInfo(
                mode: .all,
                ranges: [],
                pageCount: document.pageCount,
                totalPages: document.pageCount,
                isValid: document.pageCount > 0,
                message: nil
            )
        case .range:
            let fragments = pageRangeText
                .split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            let raw = PageRange.list(from: pageRangeText)
            guard !raw.isEmpty, raw.count == fragments.count else {
                return PageSelectionInfo(
                    mode: .range,
                    ranges: [],
                    pageCount: 0,
                    totalPages: document.pageCount,
                    isValid: false,
                    message: "Use commas between pages, like 1-4, 7."
                )
            }
            do {
                let pages = try PDFPageExtractor.pageNumbers(
                    for: raw,
                    pageCount: document.pageCount
                )
                return PageSelectionInfo(
                    mode: .range,
                    ranges: Self.mergedRanges(from: pages),
                    pageCount: pages.count,
                    totalPages: document.pageCount,
                    isValid: true,
                    message: nil
                )
            } catch {
                return PageSelectionInfo(
                    mode: .range,
                    ranges: [],
                    pageCount: 0,
                    totalPages: document.pageCount,
                    isValid: false,
                    message: "Pages must be between 1 and \(document.pageCount)."
                )
            }
        }
    }

    private static func mergedRanges(from pages: [Int]) -> [PageRange] {
        guard let first = pages.first else { return [] }
        var ranges: [PageRange] = []
        var start = first
        var previous = first
        for page in pages.dropFirst() {
            if page == previous + 1 {
                previous = page
                continue
            }
            if let range = PageRange(start, previous) {
                ranges.append(range)
            }
            start = page
            previous = page
        }
        if let range = PageRange(start, previous) {
            ranges.append(range)
        }
        return ranges
    }

    var driverOptions: [PPDOption] {
        guard let ppd else { return [] }
        let groupOrder: [PPDOptionGroup] = [.color, .paperSize, .mediaType, .quality]
        return groupOrder.compactMap { group in
            guard let option = ppd.option(in: group), !option.choices.isEmpty else { return nil }
            return option
        }
    }

    var colorModeOption: PPDOption? {
        ppd?.option(in: .color)
    }

    var grayscaleChoice: PPDChoice? {
        colorModeOption?.choices.first { choice in
            let token = "\(choice.keyword) \(choice.displayLabel)".lowercased()
            return token.contains("gray") || token.contains("grey")
                || token.contains("mono") || token.contains("black")
        }
    }

    var colorChoice: PPDChoice? {
        colorModeOption?.choices.first { choice in
            let token = "\(choice.keyword) \(choice.displayLabel)".lowercased()
            return token.contains("rgb") || token.contains("cmyk")
                || token.contains("color") || token.contains("colour")
        }
    }

    var supportsColorModeToggle: Bool {
        colorChoice != nil && grayscaleChoice != nil
    }

    var isGrayscaleSelected: Bool {
        guard let option = colorModeOption,
              let grayscale = grayscaleChoice else { return false }
        return selectedValue(for: option) == grayscale.keyword
    }

    func setGrayscale(_ grayscale: Bool) {
        guard let option = colorModeOption else { return }
        let choice = grayscale ? grayscaleChoice : colorChoice
        guard let choice else { return }
        setValue(choice.keyword, for: option)
    }

    var colorProfileOptions: [PPDOption] {        guard let ppd else { return [] }
        return ppd.options.filter { option in
            guard !option.choices.isEmpty,
                  option.group != .paperSize,
                  option.group != .duplex,
                  option.group != .color else { return false }
            let text = (option.keyword + " " + option.label).lowercased()
            return text.contains("profile") || text.contains("icc")
        }
    }

    var qualityPresets: [PrintQualityPreset] {
        presetResolver?.availablePresets ?? []
    }

    var discoveredPrinters: [DiscoveredPrinter] {
        let queuedURIs = Set(
            printers
                .compactMap(\.deviceURI)
                .map(Self.normalizedDeviceURI)
        )
        return discoveredDevices.filter {
            !queuedURIs.contains(Self.normalizedDeviceURI($0.uri))
        }
    }

    var activeQualityPreset: PrintQualityPreset? {
        selectedQualityPreset ?? presetResolver?.matchingPreset(for: optionSelection)
    }

    var displayStatus: PrinterStatus? {
        status
    }

    var printerState: PrinterState {
        let base = status?.state ?? selectedPrinter?.state ?? .unknown
        if case .failed(let failure) = orchestrator.phase,
           failure.pass != nil {
            return .stopped
        }
        // CUPS can report an idle queue for the first moments after `lp`
        // returns. While our own job is active, show that work is happening.
        if base == .idle,
           case .printing(_, let job) = orchestrator.phase,
           job.isActive {
            return .processing
        }
        return base
    }

    /// A more honest headline than "Ready" for queues whose backend reports
    /// the device offline. FlipStack still lets a job try to wake the printer,
    /// but the header must not pretend the device is reachable.
    var printerHealth: PrinterHealth {
        guard selectedPrinter != nil else { return .unknown }
        if isPreparingPrint {
            return .preparing
        }
        if case .preparing = orchestrator.phase {
            return .preparing
        }
        if case .awaitingFlip = orchestrator.phase {
            return .waiting
        }
        if case .printing(_, let job) = orchestrator.phase, job.isActive {
            if let status,
               status.stateReasons.contains("offline-report"),
               job.state != .processing {
                return .offline
            }
            return .printing
        }
        if case .failed(let failure) = orchestrator.phase, failure.pass != nil {
            return .attention
        }
        guard let status else { return .unknown }
        let state = status.state
        let accepting = status.acceptsJobs ?? selectedPrinter?.acceptsJobs ?? true
        let reasons = status.stateReasons
        if Date().timeIntervalSince(status.fetchedAt) > 120 {
            return .unknown
        }
        if state == .stopped || !accepting {
            return .attention
        }
        if reasons.contains("offline-report") {
            return .offline
        }
        if reasons.contains(where: PrinterReason.isError) {
            return .attention
        }
        if let calibration = flipCalibration {
            switch calibration.stage {
            case .printing:
                return calibration.jobID == nil ? .preparing : .printing
            case .questions:
                return .waiting
            case .failed:
                return .attention
            }
        }
        if state == .processing {
            return .printing
        }
        if status.origin == .unavailable, state == .idle {
            return .unknown
        }
        if state == .unknown {
            return .unknown
        }
        return .ready
    }

    var isWaitingForPrinter: Bool {
        guard case .printing(_, let job) = orchestrator.phase, job.isActive else { return false }
        guard let status else { return false }
        return status.stateReasons.contains("offline-report") && job.state != .processing
    }

    var printerHealthNote: String? {
        switch printerHealth {
        case .offline:
            return "CUPS reports this printer offline. A print job may still wake it."
        case .attention:
            return activeStateReasons.first ?? "The printer queue needs attention."
        case .unknown:
            if status == nil {
                return "Checking live printer status…"
            }
            return "Live printer status is unavailable; queue state is shown from CUPS."
        case .ready, .printing, .preparing, .waiting:
            return nil
        }
    }

    /// Shown when the queue is healthy but the printer does not expose marker
    /// supplies (common on USB-only photo printers such as the L1800).
    var supplyFallbackNote: String? {
        guard selectedPrinter != nil, let status else { return nil }
        if !status.supplies.isEmpty { return nil }
        // The health note already explains an entirely unavailable status;
        // avoid saying the same thing twice in the header.
        if status.origin == .unavailable { return nil }
        return "Supply levels are not reported by this printer."
    }

    var activeStateReasons: [String] {
        let reasons = status?.stateReasons ?? selectedPrinter?.stateReasons ?? []
        let filtered = reasons.filter { reason in
            // The Epson USB backend reports `offline-report` even while the
            // queue is idle and accepting jobs. It is not useful as an alert
            // when the queue is otherwise healthy.
            if reason == "offline-report" && printerState != .stopped {
                return false
            }
            return true
        }
        return filtered.compactMap(PrinterReason.humanReadable)
    }

    var lowSupplies: [SupplyLevel] {
        (status?.supplies ?? []).filter(\.isLow)
    }

    var bookletSignatureLabel: String {
        guard let plan = bookletPlan else { return "Auto" }
        if plan.signatureCount > 1 {
            return "\(plan.signatureSheetCount) sheets × \(plan.signatureCount)"
        }
        return "\(plan.signatureSheetCount) \(plan.signatureSheetCount == 1 ? "sheet" : "sheets")"
    }

    var selectedDocumentLabel: String {
        selectedDocument?.name ?? "No document"
    }

    // MARK: Lifecycle

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        Task {
            await loadPrinters()
            await refreshStatus()
            await refreshQueue()
        }
        Task {
            await refreshDiscovery()
        }
        startMonitoring()
        cleanUpTemporaryFiles()
    }

    /// Remove all local working files owned by FlipStack. Called on launch and
    /// normal termination so a document-derived temporary PDF cannot outlive
    /// the session.
    func cleanUpTemporaryFiles() {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("FlipStack", isDirectory: true)
        try? FileManager.default.removeItem(at: base)
    }

    func refreshAll() async {
        isRefreshing = true
        defer { isRefreshing = false }
        Task { await refreshDiscovery(force: true) }
        if orchestrator.phase.isActive {
            await refreshQueue()
            await refreshStatus()
            return
        }
        await loadPrinters()
        await refreshStatus()
        await refreshQueue()
    }

    func refreshDiscovery(force: Bool = false) async {
        if !force,
           let lastDiscoveryAt,
           Date().timeIntervalSince(lastDiscoveryAt) < 60 {
            return
        }
        guard !isDiscoveringPrinters else { return }
        isDiscoveringPrinters = true
        defer { isDiscoveringPrinters = false }
        do {
            let devices = try await printerDiscovery.discoverDevices()
            guard !Task.isCancelled else { return }
            discoveredDevices = devices
            lastDiscoveryAt = Date()
            discoveryNote = nil
        } catch is CancellationError {
            return
        } catch {
            discoveredDevices = []
            lastDiscoveryAt = Date()
            discoveryNote = error.localizedDescription
        }
    }

    private static func normalizedDeviceURI(_ uri: String) -> String {
        var value = uri.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let query = value.firstIndex(of: "?") {
            value = String(value[..<query])
        }
        while value.hasSuffix("/") {
            value.removeLast()
        }
        return value
    }

    func loadPrinters() async {
        isLoadingPrinters = true
        defer { isLoadingPrinters = false }
        do {
            let list = try await spooler.listPrinters()
            printers = list
            if flipCalibration != nil,
               let selectedPrinter,
               !list.contains(where: { $0.id == selectedPrinter.id }) {
                cancelFlipCalibrationWork()
                flipCalibration = nil
                flipAxisSetup = nil
                banner = AppBanner(
                    kind: .warning,
                    title: "The printer is no longer available",
                    message: "Flip setup was canceled. Reconnect the printer and try again."
                )
                self.selectedPrinter = nil
                ppd = nil
                status = nil
                queue = []
                return
            }
            if let selectedPrinter,
               let refreshed = list.first(where: { $0.id == selectedPrinter.id }) {
                self.selectedPrinter = refreshed
                await reloadDetails(for: refreshed)
            } else if let target = preferredPrinter(in: list) {
                await selectPrinter(target)
            } else {
                self.selectedPrinter = nil
                ppd = nil
                status = nil
                queue = []
            }
        } catch {
            printers = []
            selectedPrinter = nil
            ppd = nil
            status = nil
            banner = AppBanner(
                kind: .error,
                title: "The print system is unavailable",
                message: error.localizedDescription
            )
        }
    }

    private func preferredPrinter(in list: [Printer]) -> Printer? {
        if let lastID = preferencesStore.lastPrinterID,
           let last = list.first(where: { $0.id == lastID }) {
            return last
        }
        if let isDefault = list.first(where: \.isDefault) {
            return isDefault
        }
        return list.first
    }

    func selectPrinter(_ printer: Printer) async {
        guard orchestrator.phase.isIdle,
              !isPreparingPrint,
              flipCalibration == nil,
              flipAxisSetup == nil else { return }
        selectedPrinter = printer
        localJobIDs.removeAll()
        localJobTitles.removeAll()
        preferencesStore.lastPrinterID = printer.id
        preferences = preferencesStore.load(for: printer.id)
        let layout = preferencesStore.loadLayout(for: printer.id)
        forceLandscape = layout.forceLandscape
        fitToPage = layout.fitToPage
        scalePercent = layout.scalePercent
        closePreview()
        optionSelection = [:]
        ppd = nil
        presetResolver = nil
        selectedQualityPreset = nil
        ppdNote = nil
        status = nil
        queue = []
        recomputeBookletPlan()
        await reloadDetails(for: printer)
    }

    private func reloadDetails(for printer: Printer) async {
        let id = printer.id
        await loadPPD(for: printer)
        guard selectedPrinter?.id == id else { return }
        await refreshStatus()
        await refreshQueue()
    }

    // MARK: PPD

    private func loadPPD(for printer: Printer) async {
        isLoadingPPD = true
        ppdNote = nil
        let provider = ppdProvider
        do {
            let parsed = try await Task.detached(priority: .userInitiated) { () throws -> PPDDocument? in
                guard let url = provider.locatePPD(for: printer) else { return nil }
                return try provider.parsePPD(at: url)
            }.value
            guard selectedPrinter?.id == printer.id else { return }
            isLoadingPPD = false
            guard let parsed, !parsed.isEmpty else {
                ppd = nil
                presetResolver = nil
                selectedQualityPreset = nil
                ppdNote = "No driver PPD was found for this queue. Only the system defaults will be used."
                return
            }
            ppd = parsed
            let resolver = PrintPresetResolver(ppd: parsed)
            presetResolver = resolver
            var selection = defaultSelection(for: parsed)
            let savedChoices = preferencesStore.loadOptionChoices(for: printer.id)
            for (keyword, choice) in savedChoices {
                guard let option = parsed.option(keyword: keyword),
                      option.choice(keyword: choice) != nil else { continue }
                selection[keyword] = choice
            }
            if savedChoices.isEmpty {
                let standard = resolver.apply(.standard, to: selection)
                selection = standard.options
                selectedQualityPreset = standard.isComplete
                    ? .standard
                    : resolver.matchingPreset(for: selection)
            } else {
                selectedQualityPreset = resolver.matchingPreset(for: selection)
            }
            optionSelection = selection
        } catch {
            guard selectedPrinter?.id == printer.id else { return }
            isLoadingPPD = false
            ppd = nil
            presetResolver = nil
            selectedQualityPreset = nil
            ppdNote = "The driver description could not be read. Only the system defaults will be used."
            banner = AppBanner(
                kind: .warning,
                title: "Driver options unavailable",
                message: error.localizedDescription
            )
        }
    }

    private func defaultSelection(for document: PPDDocument) -> [String: String] {
        var selection: [String: String] = [:]
        for group in [PPDOptionGroup.color, .paperSize, .mediaType, .quality] {
            if let option = document.option(in: group), let value = option.selectedDefault {
                selection[option.keyword] = value
            }
        }
        for option in profileOptions(in: document) {
            if let value = option.selectedDefault {
                selection[option.keyword] = value
            }
        }
        return selection
    }

    private func profileOptions(in document: PPDDocument) -> [PPDOption] {
        document.options.filter { option in
            guard !option.choices.isEmpty,
                  option.group != .paperSize,
                  option.group != .duplex,
                  option.group != .color else { return false }
            let text = (option.keyword + " " + option.label).lowercased()
            return text.contains("profile") || text.contains("icc")
        }
    }

    func selectedValue(for option: PPDOption) -> String {
        if let value = optionSelection[option.keyword],
           option.choice(keyword: value) != nil {
            return value
        }
        return option.selectedDefault ?? ""
    }

    func setValue(_ value: String, for option: PPDOption) {
        guard option.choice(keyword: value) != nil else { return }
        optionSelection[option.keyword] = value
        selectedQualityPreset = presetResolver?.matchingPreset(for: optionSelection)
        if let id = selectedPrinter?.id {
            preferencesStore.saveOptionChoices(optionSelection, for: id)
        }
    }

    func applyQualityPreset(_ preset: PrintQualityPreset) {
        guard let resolver = presetResolver else { return }
        let result = resolver.apply(preset, to: optionSelection)
        optionSelection = result.options
        selectedQualityPreset = preset
        if let id = selectedPrinter?.id {
            preferencesStore.saveOptionChoices(optionSelection, for: id)
        }
    }

    private var currentDriverOptions: [String: String] {
        guard let ppd else { return [:] }
        var options: [String: String] = [:]
        for group in [PPDOptionGroup.color, .paperSize, .mediaType, .quality] {
            guard let option = ppd.option(in: group) else { continue }
            let value = selectedValue(for: option)
            guard !value.isEmpty, option.choice(keyword: value) != nil else { continue }
            options[option.keyword] = value
        }
        for option in profileOptions(in: ppd) {
            let value = selectedValue(for: option)
            guard !value.isEmpty, option.choice(keyword: value) != nil else { continue }
            options[option.keyword] = value
        }
        return options
    }

    // MARK: Preferences

    func requestPrint() {
        guard canPrint, flipAxisSetup == nil, flipCalibration == nil else { return }
        let needsFlipSetup = mode.usesFlipSetup
            && (mode == .booklet || pageSelectionInfo.pageCount > 1)
        if needsFlipSetup, !preferences.hasConfiguredFlip {
            flipAxisSetup = FlipAxisSetup(autoStartsPrint: true)
            // Match the first-time promise: send one generic calibration sheet
            // immediately, then hold the real document until the answers land.
            startFlipCalibration()
            return
        }
        beginPrint()
    }

    func openFlipAxisSetup() {
        guard flipCalibration == nil else { return }
        flipAxisSetup = FlipAxisSetup(autoStartsPrint: false)
    }

    func completeFlipAxisSetup(flipAxis: FlipAxis, ejectsFaceDown: Bool) {
        guard flipCalibration == nil else { return }
        let autoStart = flipAxisSetup?.autoStartsPrint ?? false
        preferences.flipAxis = flipAxis
        preferences.ejectsFaceDown = ejectsFaceDown
        preferences.hasConfiguredFlip = true
        savePreferences()
        flipAxisSetup = nil
        if autoStart {
            beginPrint()
        }
    }

    func dismissFlipAxisSetup() {
        let hadWaitingDocument = flipAxisSetup?.autoStartsPrint == true
        cancelFlipCalibrationWork()
        flipCalibration = nil
        flipAxisSetup = nil
        if hadWaitingDocument {
            banner = AppBanner(
                kind: .info,
                title: "Flip setup canceled",
                message: "Your PDF was not printed."
            )
        }
    }

    // MARK: Automatic flip calibration

    /// Prints one generic orientation sheet, monitors the real CUPS job, and
    /// only then reveals the confirmation questions. The real document is never
    /// sent until calibration is applied.
    func startFlipCalibration() {
        guard flipCalibration == nil,
              let printer = selectedPrinter,
              orchestrator.phase.isIdle,
              !isPreparingPrint,
              !isMaintenanceBusy else {
            return
        }
        closePreview()
        isShowingQueue = false
        banner = nil
        let autoStart = flipAxisSetup?.autoStartsPrint ?? false
        if flipAxisSetup == nil {
            flipAxisSetup = FlipAxisSetup(autoStartsPrint: false)
        }
        let landscape = forceLandscape || (selectedDocument?.isLandscape ?? false)
        let suggestedAxis: FlipAxis
        if mode == .booklet {
            suggestedAxis = .longEdge
        } else if preferences.hasConfiguredFlip {
            suggestedAxis = preferences.flipAxis
        } else {
            suggestedAxis = landscape ? .shortEdge : .longEdge
        }
        let calibration = FlipCalibration(
            stage: .printing,
            autoStartsPrint: autoStart,
            printerID: printer.id,
            axis: suggestedAxis,
            recommendedAxis: suggestedAxis,
            ejectsFaceDown: preferences.ejectsFaceDown,
            jobID: nil,
            hasConfirmedAxis: mode == .booklet
        )
        flipCalibration = calibration
        calibrationTask?.cancel()
        calibrationTask = Task { [weak self] in
            await self?.runFlipCalibration(
                printer: printer,
                calibrationID: calibration.id
            )
        }
    }

    func retryFlipCalibration() {
        let autoStart = flipCalibration?.autoStartsPrint
            ?? flipAxisSetup?.autoStartsPrint
            ?? false
        cancelFlipCalibrationWork()
        flipCalibration = nil
        if flipAxisSetup == nil {
            flipAxisSetup = FlipAxisSetup(autoStartsPrint: autoStart)
        }
        startFlipCalibration()
    }

    func setFlipCalibrationAxis(_ axis: FlipAxis) {
        guard mode != .booklet,
              var calibration = flipCalibration,
              calibration.stage == .questions else { return }
        calibration.axis = axis
        calibration.hasConfirmedAxis = true
        flipCalibration = calibration
    }

    func setFlipCalibrationEjectsFaceDown(_ value: Bool) {
        guard var calibration = flipCalibration, calibration.stage == .questions else { return }
        calibration.ejectsFaceDown = value
        calibration.hasConfirmedTray = true
        flipCalibration = calibration
    }

    func applyFlipCalibration() {
        guard let calibration = flipCalibration,
              calibration.stage == .questions,
              calibration.isAnswered,
              calibration.printerID == selectedPrinter?.id else { return }
        preferences.flipAxis = mode == .booklet ? .longEdge : calibration.axis
        preferences.ejectsFaceDown = calibration.ejectsFaceDown
        preferences.hasConfiguredFlip = true
        savePreferences()
        let autoStart = calibration.autoStartsPrint
        flipCalibration = nil
        flipAxisSetup = nil
        banner = AppBanner(
            kind: .success,
            title: "Flip setup calibrated",
            message: calibrationSummary(for: calibration)
        )
        if autoStart {
            beginPrint()
        }
    }

    /// Leaves the calibration sheet flow but keeps the manual setup surface
    /// available. The calibration job is cancelled if it is still active.
    func returnToFlipSetup() {
        cancelFlipCalibrationWork()
        flipCalibration = nil
        if flipAxisSetup == nil {
            flipAxisSetup = FlipAxisSetup(autoStartsPrint: false)
        }
    }

    func cancelFlipCalibration() {
        cancelFlipCalibrationWork()
        flipCalibration = nil
    }

    private func cancelFlipCalibrationWork() {
        calibrationTask?.cancel()
        calibrationTask = nil
        guard let calibration = flipCalibration,
              let jobID = calibration.jobID else {
            return
        }
        Task { [weak self, spooler] in
            do {
                try await spooler.cancel(jobID: jobID, printerID: calibration.printerID)
            } catch {
                self?.banner = AppBanner(
                    kind: .warning,
                    title: "Could not cancel the calibration sheet",
                    message: "It may still print. Check the queue before trying again."
                )
            }
        }
    }

    private func calibrationSummary(for calibration: FlipCalibration) -> String {
        "\(calibration.axis.label) · print lands \(calibration.ejectsFaceDown ? "down" : "up")."
    }

    func setEjectsFaceDown(_ value: Bool) {
        preferences.ejectsFaceDown = value
        if !preferences.hasConfiguredFlip {
            preferences.hasConfiguredFlip = true
        }
        savePreferences()
    }

    func setFlipAxis(_ axis: FlipAxis) {
        preferences.flipAxis = axis
        savePreferences()
    }

    private func savePreferences() {
        guard let id = selectedPrinter?.id else { return }
        preferencesStore.save(preferences, for: id)
    }

    private func saveLayout() {
        guard let id = selectedPrinter?.id else { return }
        preferencesStore.saveLayout(
            PrintLayoutPreferences(
                forceLandscape: forceLandscape,
                fitToPage: fitToPage,
                scalePercent: scalePercent
            ),
            for: id
        )
    }

    // MARK: Documents

    func chooseDocument() {
        guard !isPreparingPrint,
              !orchestrator.phase.isActive,
              flipAxisSetup == nil,
              flipCalibration == nil else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose a PDF"
        panel.message = "Pick the document FlipStack should print."
        panel.prompt = "Choose"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.pdf]
        NSApp.activate(ignoringOtherApps: true)
        let response = panel.runModal()
        // AppKit's open panel otherwise persists the last folder as a bookmark
        // in UserDefaults, which can reveal a user's document location.
        clearOpenPanelState()
        guard response == .OK, let url = panel.url else { return }
        Task { await acceptDocument(url: url) }
    }

    func clearOpenPanelState() {
        let defaults = UserDefaults.standard
        for key in [
            "NSOSPLastRootDirectory",
            "NSNavPanelExpandedSizeForOpenMode",
            "NSNavLastRootDirectory",
            "NSNavLastCurrentDirectory"
        ] {
            defaults.removeObject(forKey: key)
        }
    }

    func acceptDocument(url: URL) async {
        guard !isPreparingPrint,
              !orchestrator.phase.isActive,
              flipAxisSetup == nil,
              flipCalibration == nil else { return }
        if !orchestrator.phase.isIdle {
            orchestrator.reset()
            discardWorkingFiles()
        }
        guard let pdf = PDFDocument(url: url) else {
            banner = AppBanner(
                kind: .error,
                title: "That file is not a PDF",
                message: "Choose a PDF document to print."
            )
            return
        }
        guard !pdf.isLocked else {
            banner = AppBanner(
                kind: .error,
                title: "This PDF is locked",
                message: "Remove the password, then choose the file again."
            )
            return
        }
        guard pdf.pageCount > 0 else {
            banner = AppBanner(
                kind: .error,
                title: "This PDF has no pages",
                message: "Choose a document with at least one page."
            )
            return
        }
        let name = url.lastPathComponent
        var isLandscape = false
        if let firstPage = pdf.page(at: 0) {
            let bounds = firstPage.bounds(for: .mediaBox)
            let rotated90 = firstPage.rotation % 180 != 0
            let width = rotated90 ? bounds.height : bounds.width
            let height = rotated90 ? bounds.width : bounds.height
            isLandscape = width > height
        }
        closePreview()
        selectedDocument = SelectedDocument(
            url: url,
            name: name,
            pageCount: pdf.pageCount,
            isLandscape: isLandscape
        )
        pageSelectionMode = .all
        pageRangeText = ""
        banner = nil
        recomputeBookletPlan()
    }

    func clearDocument() {
        guard !orchestrator.phase.isActive,
              flipAxisSetup == nil,
              flipCalibration == nil else { return }
        closePreview()
        discardWorkingFiles()
        selectedDocument = nil
        pageSelectionMode = .all
        pageRangeText = ""
        bookletPlan = nil
    }

    // MARK: Preview

    func togglePreview() {
        if isShowingPreview || isPreparingPreview {
            closePreview()
            return
        }
        isShowingQueue = false
        Task { await preparePreview() }
    }

    func showPreviewBacks(_ showBacks: Bool) {
        guard previewBacksURL != nil else { return }
        previewShowsBacks = showBacks
    }

    private func preparePreview() async {
        guard let document = selectedDocument else { return }
        let selection = pageSelectionInfo
        guard selection.isValid, selection.pageCount > 0 else {
            banner = AppBanner(
                kind: .warning,
                title: "Check the page range",
                message: selection.message ?? "Choose at least one page to preview."
            )
            return
        }
        let mode = self.mode
        let printMode = mode
        let pages = selection.ranges
        let selectionIsAll = selection.isAll
        let signature = bookletSignatureSheets > 0 ? bookletSignatureSheets : nil
        let imposer = bookletImposer

        closePreviewFiles()
        previewGeneration += 1
        let generation = previewGeneration
        isPreparingPreview = true
        isShowingPreview = false
        previewShowsBacks = false
        previewURL = nil
        previewBacksURL = nil

        var temporaryDirectory: URL?
        do {
            var sourceURL = document.url
            var extractedDirectory: URL?
            if !selectionIsAll {
                let pageNumbers = try PDFPageExtractor.pageNumbers(
                    for: pages,
                    pageCount: document.pageCount
                )
                let directory = Self.workingDirectory(prefix: "PreviewSource")
                let destination = directory.appendingPathComponent("selected-pages.pdf")
                try await Task.detached(priority: .userInitiated) {
                    _ = try PDFPageExtractor.extract(
                        from: document.url,
                        pageNumbers: pageNumbers,
                        to: destination
                    )
                }.value
                extractedDirectory = directory
                temporaryDirectory = directory
                sourceURL = destination
            }

            guard generation == previewGeneration,
                  !Task.isCancelled,
                  selectedDocument?.id == document.id,
                  self.mode == printMode else {
                if let temporaryDirectory {
                    try? FileManager.default.removeItem(at: temporaryDirectory)
                }
                isPreparingPreview = false
                return
            }

            if printMode == .booklet {
                let output = try await Task.detached(priority: .userInitiated) {
                    let plan = try imposer.plan(
                        pageCount: selection.pageCount,
                        signatureSheets: signature
                    )
                    return try imposer.makeDocuments(from: sourceURL, plan: plan)
                }.value
                if let extractedDirectory {
                    try? FileManager.default.removeItem(at: extractedDirectory)
                }
                guard generation == previewGeneration,
                      !Task.isCancelled,
                      selectedDocument?.id == document.id,
                      self.mode == printMode else {
                    imposer.cleanUp(output)
                    isPreparingPreview = false
                    return
                }
                previewDirectory = output.workingDirectory
                previewURL = output.frontsURL
                previewBacksURL = output.backsURL
            } else {
                previewDirectory = temporaryDirectory
                previewURL = sourceURL
                previewBacksURL = nil
            }
            guard generation == previewGeneration, !Task.isCancelled else {
                closePreviewFiles()
                isPreparingPreview = false
                return
            }
            isPreparingPreview = false
            isShowingPreview = true
        } catch {
            if let temporaryDirectory {
                try? FileManager.default.removeItem(at: temporaryDirectory)
            }
            guard generation == previewGeneration else { return }
            isPreparingPreview = false
            isShowingPreview = false
            banner = AppBanner(
                kind: .error,
                title: "The preview could not be prepared",
                message: error.localizedDescription
            )
        }
    }

    private func closePreview() {
        previewGeneration += 1
        isPreparingPreview = false
        isShowingPreview = false
        previewShowsBacks = false
        previewURL = nil
        previewBacksURL = nil
        closePreviewFiles()
    }

    private func closePreviewFiles() {
        if let previewDirectory {
            try? FileManager.default.removeItem(at: previewDirectory)
            self.previewDirectory = nil
        }
    }

    private func recomputeBookletPlan() {
        guard mode == .booklet, selectedDocument != nil else {
            bookletPlan = nil
            return
        }
        let selection = pageSelectionInfo
        guard selection.isValid, selection.pageCount > 0 else {
            bookletPlan = nil
            return
        }
        let signature = bookletSignatureSheets > 0 ? bookletSignatureSheets : nil
        bookletPlan = try? bookletImposer.plan(
            pageCount: selection.pageCount,
            signatureSheets: signature
        )
    }

    // MARK: Print flow

    private func beginPrint() {
        guard flipAxisSetup == nil, flipCalibration == nil else { return }
        guard let printer = selectedPrinter, let document = selectedDocument else { return }
        guard !isPreparingPrint, !orchestrator.phase.isActive else { return }
        let selection = pageSelectionInfo
        guard selection.isValid, selection.pageCount > 0 else {
            banner = AppBanner(
                kind: .warning,
                title: "Check the page range",
                message: selection.message ?? "Choose at least one page to print."
            )
            return
        }

        let printMode = mode
        let selectedPageCount = selection.pageCount
        let selectedRanges = selection.ranges
        let source = document
        let signature = bookletSignatureSheets > 0 ? bookletSignatureSheets : nil
        let imposer = bookletImposer
        let requestedScale = scalePercent
        let useFitToPage = fitToPage

        closePreview()
        activePrintMode = printMode
        isPreparingPrint = true
        banner = nil
        preparationGeneration += 1
        let generation = preparationGeneration

        preparationTask = Task { [weak self] in
            guard let self else { return }
            var preparedSelectionDirectory: URL?

            @MainActor func isCurrent() -> Bool {
                !Task.isCancelled && self.preparationGeneration == generation
            }

            @MainActor func finishPreparation() {
                guard self.preparationGeneration == generation else { return }
                self.isPreparingPrint = false
                self.preparationTask = nil
            }

            do {
                var sourceURL = source.url
                if !selection.isAll {
                    let pages = try PDFPageExtractor.pageNumbers(
                        for: selectedRanges,
                        pageCount: source.pageCount
                    )
                    let directory = Self.workingDirectory(prefix: "Pages")
                    let destination = directory.appendingPathComponent("selected-pages.pdf")
                    try await Task.detached(priority: .userInitiated) {
                        _ = try PDFPageExtractor.extract(
                            from: source.url,
                            pageNumbers: pages,
                            to: destination
                        )
                    }.value
                    guard isCurrent() else {
                        try? FileManager.default.removeItem(at: directory)
                        finishPreparation()
                        return
                    }
                    preparedSelectionDirectory = directory
                    sourceURL = destination
                }

                if printMode != .booklet,
                   !useFitToPage,
                   requestedScale != 100 {
                    let directory = preparedSelectionDirectory
                        ?? Self.workingDirectory(prefix: "Scale")
                    preparedSelectionDirectory = directory
                    let destination = directory.appendingPathComponent("scaled-pages.pdf")
                    try await Task.detached(priority: .userInitiated) {
                        _ = try PDFPageScaler.scale(
                            from: sourceURL,
                            to: destination,
                            percent: requestedScale
                        )
                    }.value
                    guard isCurrent() else {
                        try? FileManager.default.removeItem(at: directory)
                        finishPreparation()
                        return
                    }
                    sourceURL = destination
                }

                guard isCurrent(),
                      self.selectedDocument?.id == source.id,
                      self.selectedPrinter?.id == printer.id,
                      self.mode == printMode else {
                    if let preparedSelectionDirectory {
                        try? FileManager.default.removeItem(at: preparedSelectionDirectory)
                    }
                    finishPreparation()
                    return
                }

                self.discardWorkingFiles()
                if let preparedSelectionDirectory {
                    self.selectionWorkingDirectory = preparedSelectionDirectory
                }

                let configuration = self.makeConfiguration(
                    for: printer,
                    flipAxis: printMode == .booklet ? .longEdge : self.preferences.flipAxis
                )
                let orientation: PrintOrientation = self.forceLandscape ? .landscape : .portrait

                switch printMode {
                case .singleSided:
                    let job = try DuplexDocument.singleSided(
                        fileURL: sourceURL,
                        pageCount: selectedPageCount,
                        title: source.title,
                        orientation: orientation
                    )
                    guard isCurrent() else {
                        finishPreparation()
                        return
                    }
                    finishPreparation()
                    self.launch(job, configuration: configuration)

                case .manualDuplex:
                    var job = try DuplexDocument.manualDuplex(
                        fileURL: sourceURL,
                        pageCount: selectedPageCount,
                        title: source.title
                    )
                    job.firstPass.orientation = orientation
                    job.secondPass.orientation = orientation
                    guard isCurrent() else {
                        finishPreparation()
                        return
                    }
                    finishPreparation()
                    self.launch(job, configuration: configuration)

                case .booklet:
                    let output = try await Task.detached(priority: .userInitiated) {
                        let plan = try imposer.plan(
                            pageCount: selectedPageCount,
                            signatureSheets: signature
                        )
                        return try imposer.makeDocuments(from: sourceURL, plan: plan)
                    }.value

                    guard isCurrent(),
                          self.selectedDocument?.id == source.id,
                          self.selectedPrinter?.id == printer.id,
                          self.mode == printMode else {
                        imposer.cleanUp(output)
                        finishPreparation()
                        return
                    }
                    self.bookletDocuments = output
                    self.discardSelectionWorkingDirectory()
                    let imposed = self.makeBookletDocument(output, title: source.title)
                    finishPreparation()
                    self.launch(imposed, configuration: configuration)
                }
            } catch {
                if let preparedSelectionDirectory {
                    if self.selectionWorkingDirectory == preparedSelectionDirectory {
                        self.selectionWorkingDirectory = nil
                    }
                    try? FileManager.default.removeItem(at: preparedSelectionDirectory)
                }
                guard isCurrent() else {
                    finishPreparation()
                    return
                }
                finishPreparation()
                self.banner = AppBanner(
                    kind: .error,
                    title: "The document could not be prepared",
                    message: error.localizedDescription
                )
            }
        }
    }

    private static func workingDirectory(prefix: String) -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FlipStack", isDirectory: true)
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        return directory
    }

    private func makeBookletDocument(_ output: BookletDocuments, title: String) -> DuplexDocument {
        let plan = output.plan
        return DuplexDocument(
            title: "\(title) booklet",
            sourcePageCount: plan.sourcePageCount,
            sheetCount: plan.sheetCount,
            firstPass: PrintSource(
                fileURL: output.frontsURL,
                pageSet: .all,
                pageCount: plan.sheetCount,
                numberUp: 2
            ),
            secondPass: PrintSource(
                fileURL: output.backsURL,
                pageSet: .all,
                pageCount: plan.sheetCount,
                numberUp: 2
            ),
            isBooklet: true,
            hasOddPageCount: false
        )
    }

    private func makeConfiguration(for printer: Printer, flipAxis: FlipAxis) -> DuplexConfiguration {
        DuplexConfiguration(
            printerID: printer.id,
            printerName: printer.displayName,
            flipAxis: flipAxis,
            ejectsFaceDown: preferences.ejectsFaceDown,
            driverOptions: currentDriverOptions,
            copies: activePrintMode == .singleSided ? max(1, copies) : 1,
            // If there is no PPD we cannot prove the queue is simplex. Force
            // each pass to one side rather than risk a driver auto-duplexing
            // the manual pass.
            forceOneSidedPasses: activePrintMode != .singleSided
                && (ppd == nil || ppd?.supportsHardwareDuplex == true),
            fitToPage: activePrintMode != .booklet && fitToPage,
            // Non-booklet documents are scaled into a temporary PDF before
            // submission, so CUPS must not scale them a second time.
            scalePercent: 100
        )
    }

    private func launch(_ document: DuplexDocument, configuration: DuplexConfiguration) {
        let task = orchestrator.start(document: document, configuration: configuration)
        track(task)
    }

    private func track(_ task: Task<Void, Never>) {
        Task { [weak self] in
            await task.value
            guard let self else { return }
            switch self.orchestrator.phase {
            case .completed, .cancelled:
                self.discardWorkingFiles()
            default:
                break
            }
            await self.refreshQueue()
            await self.refreshStatus()
        }
    }

    func confirmFlip() {
        orchestrator.confirmFlip()
    }

    func cancelFlow() {
        if isPreparingPrint {
            preparationGeneration += 1
            preparationTask?.cancel()
            preparationTask = nil
            isPreparingPrint = false
            discardWorkingFiles()
            banner = AppBanner(
                kind: .info,
                title: "Preparation canceled",
                message: "No pages were sent to the printer."
            )
            return
        }
        orchestrator.cancel()
    }

    func startOver() {
        guard !orchestrator.phase.isActive else { return }
        orchestrator.reset()
        discardWorkingFiles()
        beginPrint()
    }

    func retryBacks() {
        if let task = orchestrator.retryBacks() {
            track(task)
        }
    }

    func resetFlow() {
        guard !orchestrator.phase.isActive else { return }
        orchestrator.reset()
        discardWorkingFiles()
    }

    private func discardWorkingFiles() {
        if let documents = bookletDocuments {
            bookletImposer.cleanUp(documents)
            bookletDocuments = nil
        }
        discardSelectionWorkingDirectory()
    }

    private func discardSelectionWorkingDirectory() {
        if let directory = selectionWorkingDirectory {
            try? FileManager.default.removeItem(at: directory)
            selectionWorkingDirectory = nil
        }
    }

    // MARK: Status and queue

    func refreshStatus() async {
        guard let printer = selectedPrinter, !isRefreshingStatus else { return }
        isRefreshingStatus = true
        defer { isRefreshingStatus = false }
        let newStatus = await statusProvider.status(for: printer)
        guard selectedPrinter?.id == printer.id else { return }
        status = newStatus
        if var current = selectedPrinter {
            current.state = newStatus.state
            current.stateReasons = newStatus.stateReasons
            if let acceptsJobs = newStatus.acceptsJobs {
                current.acceptsJobs = acceptsJobs
            }
            selectedPrinter = current
            if let index = printers.firstIndex(where: { $0.id == current.id }) {
                printers[index] = current
            }
        }
    }

    /// The CUPS title is intentionally generic. Keep the friendly local name
    /// in memory for the queue panel, never in the submitted job metadata.
    func jobDisplayTitle(_ job: PrintJob) -> String {
        if let title = localJobTitles[job.id], !title.isEmpty {
            return title
        }
        return job.title.isEmpty ? "Job \(job.id)" : job.title
    }

    private func rememberLocalJob(_ job: PrintJob, pass: DuplexPass) {
        localJobIDs.insert(job.id)
        guard let document = selectedDocument else { return }
        let suffix: String
        switch activePrintMode {
        case .singleSided:
            suffix = ""
        case .manualDuplex:
            suffix = " — \(pass.rawValue)"
        case .booklet:
            suffix = " — booklet \(pass.rawValue)"
        }
        localJobTitles[job.id] = "\(document.title)\(suffix)"
    }

    private func rememberLocalJob(_ job: PrintJob, title: String) {
        localJobIDs.insert(job.id)
        localJobTitles[job.id] = title
    }

    func refreshQueue() async {
        guard let printer = selectedPrinter, !isRefreshingQueue else { return }
        isRefreshingQueue = true
        defer { isRefreshingQueue = false }
        do {
            async let active = spooler.activeJobs(printerID: printer.id)
            async let recent = spooler.recentJobs(printerID: printer.id, limit: 8)
            let (activeJobs, recentJobs) = try await (active, recent)
            guard selectedPrinter?.id == printer.id else { return }
            var byID: [Int: PrintJob] = [:]
            for job in recentJobs { byID[job.id] = job }
            for job in activeJobs { byID[job.id] = job }
            let currentUser = NSUserName()
            queue = byID.values
                .filter { $0.isVisible(to: currentUser, localJobIDs: localJobIDs) }
                .sorted { lhs, rhs in
                    if lhs.isActive != rhs.isActive { return lhs.isActive }
                    if lhs.id != rhs.id { return lhs.id > rhs.id }
                    return lhs.title < rhs.title
                }
            queueError = nil
        } catch {
            queueError = error.localizedDescription
        }
    }

    func cancelQueuedJob(_ job: PrintJob) async {
        guard job.isVisible(to: NSUserName(), localJobIDs: localJobIDs) else { return }
        do {
            try await spooler.cancel(jobID: job.id, printerID: job.printerID)
            await refreshQueue()
        } catch {
            banner = AppBanner(
                kind: .error,
                title: "Could not cancel the job",
                message: error.localizedDescription
            )
        }
    }

    private func startMonitoring() {
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                let active = self?.orchestrator.phase.isActive ?? false
                let interval: UInt64 = active ? 3_000_000_000 : 20_000_000_000
                try? await Task.sleep(nanoseconds: interval)
                guard !Task.isCancelled, let self else { return }
                if self.selectedPrinter != nil {
                    await self.refreshStatus()
                    await self.refreshQueue()
                }
            }
        }
    }

    private func updateQueuePolling() {
        queueMonitorTask?.cancel()
        queueMonitorTask = nil
        guard isShowingQueue else { return }
        queueMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled, let self, self.isShowingQueue else { return }
                await self.refreshQueue()
            }
        }
    }

    // MARK: Automatic flip calibration

    private func runFlipCalibration(printer: Printer, calibrationID: UUID) async {
        guard !Task.isCancelled,
              flipCalibration?.id == calibrationID else { return }
        var sheetURL: URL?
        do {
            let url = try PrintUtilities.makeFlipCalibrationPage()
            sheetURL = url
            var options = currentDriverOptions
            options["sides"] = "one-sided"
            // A calibration sheet must never inherit a stale Duplex value.
            options = options.filter { $0.key.lowercased() != "duplex" }
            let request = PrintRequest(
                fileURL: url,
                printerID: printer.id,
                title: "FlipStack calibration sheet",
                pageSet: .all,
                copies: 1,
                orientation: (forceLandscape || (selectedDocument?.isLandscape ?? false))
                    ? .landscape
                    : .portrait,
                driverOptions: options,
                fitToPage: true
            )
            guard !Task.isCancelled else {
                try? FileManager.default.removeItem(at: url)
                return
            }
            let job = try await spooler.submit(request)
            rememberLocalJob(job, title: "FlipStack calibration sheet")
            // CUPS has consumed the document by the time submit returns.
            try? FileManager.default.removeItem(at: url)
            sheetURL = nil
            guard !Task.isCancelled,
                  var calibration = flipCalibration,
                  calibration.id == calibrationID,
                  selectedPrinter?.id == printer.id else {
                try? await spooler.cancel(jobID: job.id, printerID: printer.id)
                return
            }
            calibration.jobID = job.id
            calibration.stage = .printing
            flipCalibration = calibration
            await refreshQueue()
            await monitorFlipCalibration(
                jobID: job.id,
                printer: printer,
                calibrationID: calibrationID
            )
        } catch {
            if let sheetURL {
                try? FileManager.default.removeItem(at: sheetURL)
            }
            guard !Task.isCancelled else { return }
            failFlipCalibration(
                "The calibration sheet could not be sent to \(printer.displayName).",
                calibrationID: calibrationID
            )
        }
    }

    private func monitorFlipCalibration(
        jobID: Int,
        printer: Printer,
        calibrationID: UUID
    ) async {
        let deadline = Date().addingTimeInterval(10 * 60)
        var lookupErrors = 0
        var missingPolls = 0

        while !Task.isCancelled {
            guard let calibration = flipCalibration,
                  calibration.id == calibrationID,
                  calibration.jobID == jobID,
                  selectedPrinter?.id == printer.id else {
                return
            }

            do {
                guard let job = try await spooler.job(id: jobID, printerID: printer.id) else {
                    guard flipCalibration?.id == calibrationID else { return }
                    missingPolls += 1
                    if missingPolls >= 3 {
                        failFlipCalibration(
                            "The printer no longer reports the calibration job. Check the sheet in the tray, then try again if needed.",
                            calibrationID: calibrationID
                        )
                        return
                    }
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    continue
                }
                guard flipCalibration?.id == calibrationID else { return }
                lookupErrors = 0
                missingPolls = 0
                switch job.state {
                case .completed:
                    guard var current = flipCalibration,
                          current.id == calibrationID else { return }
                    current.stage = .questions
                    current.jobID = nil
                    current.hasConfirmedTray = false
                    current.hasConfirmedAxis = mode == .booklet
                    flipCalibration = current
                    await refreshQueue()
                    await refreshStatus()
                    return
                case .canceled, .aborted, .stopped:
                    failFlipCalibration(
                        "The calibration sheet was \(job.state.label.lowercased()).",
                        calibrationID: calibrationID
                    )
                    return
                default:
                    break
                }
            } catch {
                lookupErrors += 1
                if lookupErrors >= 3 {
                    failFlipCalibration(
                        "FlipStack could not read the calibration job.",
                        calibrationID: calibrationID
                    )
                    return
                }
            }

            if Date() >= deadline {
                try? await spooler.cancel(jobID: jobID, printerID: printer.id)
                failFlipCalibration(
                    "The calibration sheet waited too long. Check the printer, then try again.",
                    calibrationID: calibrationID
                )
                return
            }

            do {
                try await Task.sleep(nanoseconds: 400_000_000)
            } catch {
                return
            }
        }
    }

    private func failFlipCalibration(_ message: String, calibrationID: UUID? = nil) {
        guard var calibration = flipCalibration,
              calibrationID == nil || calibration.id == calibrationID else { return }
        let jobID = calibration.jobID
        let printerID = calibration.printerID
        calibration.stage = .failed(message)
        calibration.jobID = nil
        flipCalibration = calibration
        if let jobID {
            Task { [spooler] in
                try? await spooler.cancel(jobID: jobID, printerID: printerID)
            }
        }
        Task { await refreshQueue() }
    }

    // MARK: Maintenance

    func printTestPage() async {
        await printUtility(title: "FlipStack test page") { printerName in
            try PrintUtilities.makeTestPage(printerName: printerName)
        }
    }

    func printAlignmentPage() async {
        await printUtility(title: "FlipStack head alignment") { printerName in
            try PrintUtilities.makeAlignmentPage(printerName: printerName)
        }
    }

    /// A standalone copy of the generic orientation sheet. Useful after a tray
    /// or output setting changed, without starting the calibration questions.
    func printOrientationSheet() async {
        await printUtility(title: "FlipStack orientation sheet", fitToPage: true) { _ in
            try PrintUtilities.makeFlipCalibrationPage()
        }
    }

    private func printUtility(
        title: String,
        fitToPage: Bool = false,
        makePDF: (String) throws -> URL
    ) async {
        guard let printer = selectedPrinter, !isMaintenanceBusy,
              !isCalibrating,
              orchestrator.phase.isIdle, !isPreparingPrint else { return }
        isMaintenanceBusy = true
        defer { isMaintenanceBusy = false }
        do {
            let url = try makePDF(printer.displayName)
            defer { try? FileManager.default.removeItem(at: url) }
            var options = currentDriverOptions
            options = options.filter { $0.key.lowercased() != "duplex" }
            options["sides"] = "one-sided"
            let request = PrintRequest(
                fileURL: url,
                printerID: printer.id,
                title: title,
                copies: 1,
                driverOptions: options,
                fitToPage: fitToPage
            )
            let job = try await spooler.submit(request)
            rememberLocalJob(job, title: title)
            await refreshQueue()
            banner = AppBanner(
                kind: .success,
                title: "\(title) sent",
                message: "Job \(job.id) is in the queue for \(printer.displayName)."
            )
        } catch {
            banner = AppBanner(
                kind: .error,
                title: "Could not print \(title.lowercased())",
                message: error.localizedDescription
            )
        }
    }

    // MARK: Banner

    func dismissBanner() {
        banner = nil
    }

}
