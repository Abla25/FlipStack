import Foundation
import AppKit
import PDFKit
import FlipStackCore

// MARK: - App model

enum FlowPhase: Equatable { case idle, printing, flip, done }

enum PopoverKind: Equatable {
    case paper, color, quality, copies, duplexEdge, pages, orientation, scale, media, tray, resOverride, inkSave
}

/// The single source of truth for the receipt UI.
///
/// v1.0.2 changes:
/// - `settings` is `@Published`, so settings taps repaint immediately;
/// - app defaults + per-printer last-used options are persisted
///   (`DemoSettingsStore`, `FlipStack.demo.*` keys) and restored at launch;
/// - the print flow is a cancellable state machine with a generation token, so
///   cancel/retry/document changes can never be overridden by stale completions;
/// - documents are validated/converted with `FlipStackCore.DocumentIngest`
///   (DOCX/RTF/text really work), and page selection resets per document;
/// - photos/oversized pages are scaled to fit the chosen media instead of being
///   clipped (`PrintMath.effectiveScale`);
/// - every user-visible string goes through `T(...)` (EN + IT).
@MainActor
final class AppModel: ObservableObject {
    // MARK: Document
    @Published var docURL: URL?
    @Published var docName = ""
    @Published var docPages = 0
    @Published var docSizeMB = 0.0
    @Published var documentTag = "PDF"
    @Published var previewDoc: PDFDocument?     // cached so we don't re-parse per render
    @Published var isPreparingDoc = false
    var isPhoto: Bool { docURL.map { PrintMath.isPhoto($0.lastPathComponent) } ?? false }
    private var printableURL: URL?              // what actually goes to `lp` (PDF)
    private var ingestedTempDirectory: URL?     // owned temp dir for converted files
    private var docLoadGeneration = 0

    // MARK: Printers — real CUPS queues from FlipStackCore
    @Published var printers: [Printer] = []
    @Published var printerID = ""
    @Published var supplies: [SupplyLevel] = []          // real levels (IPP/SNMP via core)
    @Published var printerState: PrinterState = .unknown
    @Published var queuedJobs = 0
    @Published var statusOrigin: StatusOrigin = .unavailable
    @Published var printerStates: [String: PrinterStatus] = [:]   // live status for ALL queues
    @Published var probeOffline: Set<String> = []                 // network printers that fail TCP probe
    @Published var printersLoading = false
    var printer: Printer? { printers.first(where: { $0.id == printerID }) }
    var printerName: String { printer?.name ?? printerID }

    // MARK: Options (persisted per printer)
    @Published var duplex = true { didSet { optionsChanged() } }
    @Published var duplexEdge = "long" { didSet { optionsChanged() } }
    @Published var paper = "A4" { didSet { optionsChanged() } }
    @Published var colorMode = "Color" { didSet { optionsChanged() } }
    @Published var quality = "high" { didSet { optionsChanged() } }
    @Published var pagesSel = "all"
    @Published var pageSpec = ""
    @Published var orientation = "auto" { didSet { optionsChanged() } }
    @Published var scale = 100 { didSet { optionsChanged() } }
    @Published var media = "Plain" { didSet { optionsChanged() } }
    @Published var tray = "auto" { didSet { optionsChanged() } }
    @Published var copies = 1
    @Published var resOverride = "off" { didSet { optionsChanged() } }
    @Published var inkSave = false { didSet { optionsChanged() } }

    // MARK: App settings (persisted; @Published so the Settings page repaints)
    @Published var settings: DemoAppSettings {
        didSet {
            guard !isRestoringSettings else { return }
            L10n.current = settings.language
            store.saveAppSettings(settings)
            if settings.defaultQuality != oldValue.defaultQuality {
                quality = settings.defaultQuality
            }
        }
    }

    // MARK: UI state
    @Published var moreOpen = false
    @Published var popover: PopoverKind?
    @Published var customPagesDraft = ""          // kept for the pages popover compatibility
    @Published var previewOpen = false
    @Published var previewPage = 1
    @Published var previewZoom: CGFloat = 1.0
    @Published var selectMode = false              // filmstrip tap = include/exclude pages
    @Published var settingsOpen = false
    @Published var printersOpen = false
    @Published var calibOpen = false
    @Published var toast: String?
    @Published var flowPhase: FlowPhase = .idle
    @Published var flowProgress: Double = 0
    @Published var flowLabel = ""
    @Published var lastPrint: String?
    @Published var flowCopyIndex = 1
    @Published var flowCopiesTotal = 1
    /// Live hint shown while the fronts are printing / ready ("checking…", "ready…").
    @Published var flowStatusHint = ""
    /// Localized printer problem shown instead of advancing (paper out, jam…).
    @Published var flowError: String?

    /// Called when the flow needs the user (flip prompt / done) so the app can
    /// present the panel even if the user closed it.
    var onNeedsAttention: (() -> Void)?

    var simulate = false

    // MARK: Private state
    private let store: DemoSettingsStore
    private var isRestoringOptions = false
    private var isRestoringSettings = false
    private var statusTimer: Timer?
    private var isPolling = false
    private var progressTimer: Timer?
    private var toastID = 0
    private var flowGeneration = 0
    private var flowTask: Task<Void, Never>?
    private var flowPrinterID = ""
    private var flowJobID: Int?
    private var flowFronts: [Int] = []
    private var flowBacks: [Int] = []
    private var flipContinuation: CheckedContinuation<Bool, Never>?
    private var flowCurrentSide = "fronts"
    private var flowRetrySide: String?
    private var statusMonitorTask: Task<Void, Never>?

    // MARK: - Init / persistence

    init(store: DemoSettingsStore = DemoSettingsStore()) {
        self.store = store
        let loaded = store.loadAppSettings()
        self.settings = loaded
        self.quality = loaded.defaultQuality
        L10n.current = loaded.language
    }

    deinit {
        statusTimer?.invalidate()
        progressTimer?.invalidate()
    }

    private var currentOptions: DemoPrinterOptions {
        DemoPrinterOptions(
            duplex: duplex,
            duplexEdge: duplexEdge,
            paper: paper,
            colorMode: colorMode,
            quality: quality,
            orientation: orientation,
            scale: scale,
            media: media,
            tray: tray,
            resOverride: resOverride,
            inkSave: inkSave,
            lastUsedAt: Date()
        )
    }

    private func optionsChanged() {
        guard !isRestoringOptions, !printerID.isEmpty else { return }
        store.saveOptions(currentOptions, for: printerID)
    }

    private func applyOptions(_ options: DemoPrinterOptions) {
        isRestoringOptions = true
        duplex = options.duplex
        duplexEdge = options.duplexEdge
        paper = options.paper
        colorMode = options.colorMode
        quality = options.quality
        orientation = options.orientation
        scale = options.scale
        media = options.media
        tray = options.tray
        resOverride = options.resOverride
        inkSave = options.inkSave
        isRestoringOptions = false
    }

    /// Writes pending settings to disk (called from the terminate hook).
    func prepareForTermination() {
        cancelFlow()
        store.flush()
        stopStatusTimer()
        progressTimer?.invalidate()
        progressTimer = nil
    }

    /// Stops polling while the panel is hidden; refreshes when shown again.
    func setPanelVisible(_ visible: Bool) {
        if visible {
            if printers.isEmpty { refreshPrinters() }
            startStatusTimer()
            Task {
                await pollStatus()
                await pollAllPrinters()
            }
        } else {
            stopStatusTimer()
        }
    }

    // MARK: Derived print math
    var selectedPageList: [Int] { PrintMath.selectedPageList(total: docPages, pages: pagesSel, spec: pageSpec) }
    var selectedPages: Int { selectedPageList.count }
    var sheets: Int { PrintMath.sheets(pages: selectedPages, duplex: duplex, copies: copies) }
    var dpi: Int { PrintMath.dpi(quality: quality, resOverride: resOverride) }
    var isPrinting: Bool { flowPhase == .printing || flowPhase == .flip }

    /// Everything that must be true before PRINT is allowed to start.
    var canPrint: Bool {
        flowPhase == .idle && !isPrinting && !isPreparingDoc
            && docURL != nil && printableURL != nil
            && !printerID.isEmpty && printer != nil
            && !selectedPageList.isEmpty
    }

    /// Media box of the first page; used for auto orientation and fit scaling.
    private var printPageSize: PrintMath.Size? {
        guard let pdf = previewDoc, let page = pdf.page(at: 0) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        return PrintMath.Size(width: Double(bounds.width), height: Double(bounds.height))
    }

    // MARK: - Printers & live status

    func refreshPrinters() {
        guard !printersLoading else { return }
        printersLoading = true
        Task {
            let list = (try? await CUPSClient().listPrinters()) ?? []
            self.printers = list
            self.printersLoading = false
            self.store.prunePrinterOptions(known: Set(list.map(\.id)))
            let stored = self.store.lastPrinterID
            let target: String?
            if let stored, list.contains(where: { $0.id == stored }) {
                target = stored
            } else if list.contains(where: { $0.id == self.printerID }) {
                target = self.printerID
            } else {
                target = list.first(where: { $0.isDefault })?.id ?? list.first?.id
            }
            if let target {
                if target != self.printerID { self.printerID = target }
                self.applyOptions(self.store.loadOptions(for: target, appDefaultQuality: self.settings.defaultQuality))
                if self.store.lastPrinterID == nil { self.store.lastPrinterID = target }
            }
            await self.pollStatus()
            await self.pollAllPrinters()
            self.startStatusTimer()
        }
    }

    func pollStatus() async {
        guard let p = printer else { return }
        let st = await IPPStatusClient().status(for: p)
        supplies = st.supplies
        printerState = st.state
        queuedJobs = st.queuedJobCount ?? 0
        statusOrigin = st.origin
        printerStates[st.printerID] = st
    }

    /// Poll every queue so the picker can show real offline/online state.
    /// Wireless (dnssd/socket) queues are ALSO power-probed directly: CUPS
    /// answers for them even when the printer is off, so TCP reachability is
    /// the ground truth for "online".
    func pollAllPrinters() async {
        let endpoints = await NetworkProbe.bonjourEndpoints(timeout: 2.5)
        let canJudge = !endpoints.isEmpty   // if Bonjour sees nothing, fall back to CUPS
        let list = printers
        var states: [String: PrinterStatus] = [:]
        var offlineSet: Set<String> = []
        await withTaskGroup(of: (String, PrinterStatus?, Bool).self) { group in
            for p in list {
                group.addTask {
                    let st = await IPPStatusClient().status(for: p)
                    var offline = false
                    if canJudge,
                       let uri = p.deviceURI,
                       NetworkProbe.parseDnssd(uri)?.uuid != nil || uri.hasPrefix("socket://") {
                        if let target = NetworkProbe.target(for: uri, endpoints: endpoints) {
                            var reachable = await NetworkProbe.canReachAsync(host: target.host, port: target.port)
                            if !reachable { reachable = await NetworkProbe.canReachAsync(host: target.host, port: 9100) }
                            if !reachable { reachable = await NetworkProbe.canReachAsync(host: target.host, port: 631) }
                            offline = !reachable
                        } else {
                            offline = true
                        }
                    }
                    return (p.id, st, offline)
                }
            }
            for await (id, st, off) in group {
                if let st { states[id] = st }
                if off { offlineSet.insert(id) }
            }
        }
        // publish only on change so the UI does not re-render needlessly
        if states != printerStates { printerStates = states }
        if offlineSet != probeOffline { probeOffline = offlineSet }
    }

    func isOffline(_ id: String) -> Bool {
        if probeOffline.contains(id) { return true }
        let reasons = printerStates[id]?.stateReasons
            ?? printers.first(where: { $0.id == id })?.stateReasons
            ?? []
        return reasons.contains { reason in
            let lower = reason.lowercased()
            return lower.contains("offline") || lower.contains("connecting") || lower.contains("unreachable")
        }
    }

    /// 0 = fine, 1 = attention (unknown reasons), 2 = offline
    func statusSeverity(_ id: String) -> Int {
        if isOffline(id) { return 2 }
        let reasons = printerStates[id]?.stateReasons
            ?? printers.first(where: { $0.id == id })?.stateReasons
            ?? []
        let known: Set<String> = ["none", "offline-report"]
        let unknown = reasons.filter { !known.contains($0.lowercased()) && !$0.lowercased().contains("offline") }
        return unknown.isEmpty ? 0 : 1
    }

    func statusLabel(_ id: String) -> String {
        switch statusSeverity(id) {
        case 2: return T("status.offline")
        case 1: return T("status.checkPrinter")
        default:
            let state = printerStates[id]?.state ?? printers.first(where: { $0.id == id })?.state
            switch state {
            case .idle: return T("status.ready")
            case .processing: return T("status.printing")
            case .stopped: return T("status.stopped")
            case .unknown, .none: return T("status.unknown")
            }
        }
    }

    func pickPrinter(_ id: String) {
        guard id != printerID else {
            printersOpen = false
            return
        }
        cancelFlow()
        printerID = id
        store.lastPrinterID = id
        applyOptions(store.loadOptions(for: id, appDefaultQuality: settings.defaultQuality))
        printersOpen = false
        showToast("\(T("toast.printer")): \(printerName)")
        Task { await pollStatus() }
    }

    private func startStatusTimer() {
        stopStatusTimer()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isPolling else { return }
                self.isPolling = true
                await self.pollStatus()
                await self.pollAllPrinters()
                self.isPolling = false
            }
        }
    }

    private func stopStatusTimer() {
        statusTimer?.invalidate()
        statusTimer = nil
    }

    // MARK: - Page inclusion (preview filmstrip)
    var includedSet: Set<Int> {
        switch pagesSel {
        case "custom": return Set(PrintMath.parsePageSpec(pageSpec, total: max(docPages, 1)))
        case "odd": return Set(PrintMath.selectedPageList(total: docPages, pages: "odd", spec: ""))
        case "even": return Set(PrintMath.selectedPageList(total: docPages, pages: "even", spec: ""))
        default: return docPages > 0 ? Set(1...docPages) : []
        }
    }

    func togglePageIncluded(_ p: Int) {
        var s = includedSet
        if s.contains(p) { s.remove(p) } else { s.insert(p) }
        if s.count == docPages && docPages > 0 {
            pagesSel = "all"
            pageSpec = ""
        } else {
            pagesSel = "custom"
            pageSpec = PrintMath.compressRange(Array(s).sorted())
        }
        previewPage = min(max(p, 1), max(docPages, 1))
    }

    /// Applies a contiguous range from the pages popover steppers.
    func applyPageRange(from: Int, to: Int) {
        guard docPages > 0 else { return }
        let lo = max(1, min(from, docPages))
        let hi = max(lo, min(to, docPages))
        pagesSel = "custom"
        pageSpec = PrintMath.compressRange(Array(lo...hi))
        previewPage = lo
    }

    // MARK: - Documents

    func chooseDoc(_ url: URL) {
        cancelFlow()
        docLoadGeneration += 1
        let generation = docLoadGeneration
        isPreparingDoc = true
        Task {
            let kind = DocumentIngest.kind(of: url)
            guard kind != .unsupported else {
                self.isPreparingDoc = false
                self.showToast(T("toast.unsupportedFile"))
                return
            }
            let outcome: Result<(URL, PDFDocument, Int64), Error>
            do {
                let pdfURL: URL
                if kind == .pdf {
                    pdfURL = url
                } else {
                    pdfURL = try DocumentIngest.makePDF(from: [url])
                }
                guard let pdf = PDFDocument(url: pdfURL), pdf.pageCount > 0 else {
                    throw DocumentIngest.IngestError.unreadable
                }
                let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
                let bytes = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
                outcome = .success((pdfURL, pdf, bytes))
            } catch {
                outcome = .failure(error)
            }
            guard generation == self.docLoadGeneration else {
                if case .success(let value) = outcome, value.0 != url {
                    try? FileManager.default.removeItem(at: value.0.deletingLastPathComponent())
                }
                return
            }
            switch outcome {
            case .success(let (pdfURL, pdf, bytes)):
                self.cleanupIngestedTemp()
                if pdfURL != url { self.ingestedTempDirectory = pdfURL.deletingLastPathComponent() }
                self.docURL = url
                self.docName = url.lastPathComponent
                self.previewDoc = pdf
                self.docPages = pdf.pageCount
                self.docSizeMB = Double(bytes) / 1_048_576
                self.printableURL = pdfURL
                self.documentTag = DocumentIngest.formatTag(for: kind)
                self.pagesSel = "all"
                self.pageSpec = ""
                self.customPagesDraft = ""
                self.previewPage = 1
                self.selectMode = false
                self.previewOpen = false
                self.previewZoom = 1
                self.isPreparingDoc = false
            case .failure(let error):
                self.isPreparingDoc = false
                let message = (error as? LocalizedError)?.errorDescription
                    ?? T("toast.conversionFailed")
                self.showToast(message)
            }
        }
    }

    func removeDoc() {
        cancelFlow()
        docLoadGeneration += 1
        cleanupIngestedTemp()
        docURL = nil
        docName = ""
        docPages = 0
        docSizeMB = 0
        previewDoc = nil
        printableURL = nil
        ingestReset()
        documentTag = "PDF"
        pagesSel = "all"
        pageSpec = ""
        previewPage = 1
    }

    private func ingestReset() {
        previewPage = 1
        selectMode = false
        previewOpen = false
    }

    private func cleanupIngestedTemp() {
        if let directory = ingestedTempDirectory {
            try? FileManager.default.removeItem(at: directory)
        }
        ingestedTempDirectory = nil
    }

    // MARK: - Toasts

    func showToast(_ message: String) {
        toastID += 1
        let id = toastID
        toast = message
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            guard let self, self.toastID == id else { return }
            self.toast = nil
        }
    }

    // MARK: - Print flow

    func startPrint() {
        guard flowPhase == .idle else { return }
        guard docURL != nil, printableURL != nil else {
            showToast(T("toast.noDocument"))
            return
        }
        guard !printerID.isEmpty, printer != nil else {
            showToast(T("toast.noPrinter"))
            return
        }
        let pages = selectedPageList
        guard !pages.isEmpty else {
            showToast(T("toast.noPages"))
            return
        }
        if isOffline(printerID) {
            showToast(T("toast.offlineWarning"))
        }
        let plan = PrintMath.frontsAndBacks(pages)
        flowFronts = plan.fronts
        flowBacks = duplex ? plan.backs : []
        flowCopiesTotal = max(copies, 1)
        flowCopyIndex = 1
        flowPrinterID = printerID
        flowJobID = nil
        flowError = nil
        flowStatusHint = ""
        flowRetrySide = nil
        flowGeneration += 1
        let generation = flowGeneration
        flowPhase = .printing
        flowProgress = 0
        flowLabel = duplex ? T("flow.printingFronts") : T("flow.printing")
        FlowLog.write("flow started: \(pages.count) pages, duplex=\(duplex), copies=\(copies), printer=\(printerID), backOrder=\(settings.duplexBackOrder)")
        let simulate = self.simulate
        flowTask?.cancel()
        flowTask = Task {
            if simulate {
                await self.runSimulatedFlow(generation: generation)
            } else {
                await self.runRealFlow(generation: generation)
            }
        }
    }

    private func isFlowCurrent(_ generation: Int) -> Bool {
        generation == flowGeneration
            && !Task.isCancelled
            && (flowPhase == .printing || flowPhase == .flip)
    }

    private func runRealFlow(generation: Int) async {
        let copiesTotal = max(flowCopiesTotal, 1)
        for copy in 1...copiesTotal {
            guard isFlowCurrent(generation) else { return }
            flowCopyIndex = copy
            flowPhase = .printing
            flowProgress = 0
            flowLabel = T("flow.printingFronts")
            flowStatusHint = ""
            guard await performPass(pages: flowFronts, side: "fronts", generation: generation) else { return }

            if duplex && !flowBacks.isEmpty {
                // ONE user action: wait for the sheets, flip the stack and press
                // Reinserted — that immediately starts the backs pass.
                flowPhase = .flip
                flowProgress = 1
                flowLabel = ""
                flowStatusHint = T("flow.frontsChecking")
                FlowLog.write("fronts submitted → flip prompt (single tap starts the backs)")
                onNeedsAttention?()
                startFrontsStatusMonitor(generation: generation)
                let confirmed = await waitForFlipConfirmation(generation: generation)
                stopStatusMonitor()
                guard confirmed, isFlowCurrent(generation), flowError == nil else { return }

                flowPhase = .printing
                flowProgress = 0
                flowLabel = T("flow.printingBacks")
                flowStatusHint = ""
                let backsFile = backsPDFIfNeeded(fronts: flowFronts, backs: flowBacks)
                guard await performPass(pages: flowBacks, side: "backs", fileOverride: backsFile, generation: generation) else { return }
                guard await waitForBacksCompletion(generation: generation) else { return }
            }
        }
        finishFlow(generation: generation)
    }

    /// One print pass. Returns as soon as the pass is spooled — manual duplex is
    /// driven by the user, never by a timeout.
    private func performPass(pages: [Int], side: String, fileOverride: URL? = nil, generation: Int) async -> Bool {
        guard isFlowCurrent(generation) else { return false }
        if let issue = currentPrinterIssue() {
            flowError = issue
            flowRetrySide = side
            FlowLog.write("pass \(side): blocked by printer issue: \(issue)")
            return false
        }
        guard let file = fileOverride ?? printableURL else {
            showToast(T("toast.noDocument"))
            return false
        }
        let isBacks = side == "backs"
        let frontsOrientation = PrintMath.orientationRequested(orientation: orientation, pageSize: printPageSize)
        let passOrientation = isBacks
            ? PrintMath.backsOrientationRequested(fronts: frontsOrientation, shortEdge: duplexEdge == "short")
            : frontsOrientation
        let passScale = PrintMath.effectiveScale(paper: paper, pageSize: printPageSize, userScale: scale)
        let passColor = colorMode == "Color" && !inkSave
        let printer = flowPrinterID
        let title = "FlipStack \(side) \(Int(Date().timeIntervalSince1970))"
        let range = fileOverride == nil ? PrintMath.compressRange(pages) : ""
        let paperName = paper
        let mediaName = media
        let trayName = tray
        let targetDPI = dpi

        let result = await Task.detached(priority: .userInitiated) {
            Printing.submit(
                file: file,
                printer: printer,
                pageRange: range.isEmpty ? nil : range,
                paper: paperName,
                orientationRequested: passOrientation,
                scale: passScale,
                color: passColor,
                copies: 1,
                media: mediaName,
                tray: trayName,
                title: title,
                targetDPI: targetDPI
            )
        }.value

        guard isFlowCurrent(generation) else {
            if let jobID = result.jobID {
                Task { await Printing.cancel(jobID: jobID, printer: printer) }
            }
            return false
        }
        guard result.succeeded else {
            flowError = result.message.isEmpty ? T("error.printFailed") : result.message
            flowRetrySide = side
            FlowLog.write("pass \(side) failed: \(result.message)")
            return false
        }
        flowJobID = result.jobID
        flowCurrentSide = side
        flowProgress = 1
        FlowLog.write("pass \(side): submitted job=\(result.jobID.map(String.init) ?? "nil")")
        return true
    }

    // MARK: Printer problems

    private func currentPrinterIssue() -> String? {
        // QA fake engine: never let the real queue state block a simulated job
        // (unless the test explicitly asks to exercise the error path).
        if Printing.qaFakePrintEnabled && !Printing.qaAllowPrinterIssues { return nil }
        guard let status = printerStates[printerID] else { return nil }
        let reasons = status.stateReasons.map { $0.lowercased() }
        if reasons.contains(where: { $0.contains("media-empty") || $0.contains("media-needed") }) {
            return T("error.paperOut")
        }
        if reasons.contains(where: { $0.contains("jam") }) {
            return T("error.paperJam")
        }
        if reasons.contains(where: { $0.contains("cover-open") || $0.contains("door-open") || $0.contains("interlock") }) {
            return T("error.coverOpen")
        }
        if reasons.contains(where: { $0.contains("marker-supply-empty") }) {
            return T("error.inkEmpty")
        }
        // Offline/paused are not blockers: the queue often resumes by itself and
        // stale status would otherwise prevent a legitimate print.
        return nil
    }

    private func localizedIssue(from jobReason: String) -> String {
        let lower = jobReason.lowercased()
        if lower.contains("cancel") || lower.contains("abort") { return T("error.canceled") }
        return T("error.printFailed")
    }

    /// Live status for the flip screen: refreshes the printer state and turns a
    /// CUPS terminal state into a hint or a clear error. It never advances the
    /// flow — the user's single confirmation is authoritative.
    private func startFrontsStatusMonitor(generation: Int) {
        stopStatusMonitor()
        statusMonitorTask = Task { [weak self] in
            guard let self else { return }
            while self.isFlowCurrent(generation), self.flowPhase == .flip {
                await self.pollStatus()
                if let issue = self.currentPrinterIssue() {
                    self.flowError = issue
                    self.flowRetrySide = "fronts"
                    self.flowStatusHint = ""
                    break
                }
                if let jobID = self.flowJobID,
                   let outcome = await Printing.jobOutcome(jobID, printer: self.flowPrinterID) {
                    switch outcome {
                    case .completed:
                        self.flowStatusHint = T("flow.frontsReady")
                    case .failed(let reason):
                        self.flowError = self.localizedIssue(from: reason)
                        self.flowRetrySide = "fronts"
                        self.flowStatusHint = ""
                        break
                    default:
                        break
                    }
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func stopStatusMonitor() {
        statusMonitorTask?.cancel()
        statusMonitorTask = nil
    }

    /// After the backs are spooled: wait for completion/errors, but never require
    /// another user press. Falls back to "sent" after 60 s if detection fails.
    private func waitForBacksCompletion(generation: Int) async -> Bool {
        let deadline = Date().addingTimeInterval(60)
        while isFlowCurrent(generation) {
            await pollStatus()
            if let issue = currentPrinterIssue() {
                flowError = issue
                flowRetrySide = "backs"
                FlowLog.write("backs: printer issue: \(issue)")
                return false
            }
            if let jobID = flowJobID,
               let outcome = await Printing.jobOutcome(jobID, printer: flowPrinterID) {
                switch outcome {
                case .completed:
                    flowProgress = 1
                    FlowLog.write("backs completed")
                    return true
                case .failed(let reason):
                    flowError = localizedIssue(from: reason)
                    flowRetrySide = "backs"
                    FlowLog.write("backs failed: \(reason)")
                    return false
                default:
                    break
                }
            }
            if Date() >= deadline {
                flowProgress = 1
                FlowLog.write("backs: completion not reported after 60s — assuming sent")
                return true
            }
            try? await Task.sleep(nanoseconds: 700_000_000)
        }
        return false
    }

    // MARK: Odd-page / back-order planning

    /// For "alternate" output order the backs must be printed explicitly in
    /// reverse sheet order, with a blank page for the unpaired last side of an
    /// odd selection. Returns nil for the standard mode (CUPS page-ranges).
    private func backsPDFIfNeeded(fronts: [Int], backs: [Int]) -> URL? {
        guard settings.duplexBackOrder == "alternate", !backs.isEmpty else { return nil }
        let sequence = PrintMath.backsSequence(fronts: fronts, backs: backs, alternate: true)
        guard !sequence.isEmpty else { return nil }
        return makeBacksPDF(sequence: sequence)
    }

    private func makeBacksPDF(sequence: [Int?]) -> URL? {
        guard let sourceURL = printableURL,
              let source = PDFDocument(url: sourceURL),
              let sourceData = source.dataRepresentation() else { return nil }
        let output = PDFDocument()
        for entry in sequence {
            if let pageNumber = entry,
               pageNumber >= 1, pageNumber <= source.pageCount {
                guard let copy = PDFDocument(data: sourceData),
                      let page = copy.page(at: pageNumber - 1) else { continue }
                output.insert(page, at: output.pageCount)
            } else if let blank = makeBlankPage() {
                output.insert(blank, at: output.pageCount)
            }
        }
        guard output.pageCount > 0 else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("flipstack-backs-\(UUID().uuidString).pdf")
        guard output.write(to: url) else { return nil }
        FlowLog.write("backs PDF built: \(sequence.map { $0.map(String.init) ?? "blank" }.joined(separator: ","))")
        return url
    }

    private func makeBlankPage() -> PDFPage? {
        let size = printPageSize.map { CGSize(width: $0.width, height: $0.height) }
            ?? CGSize(width: 595, height: 842)
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: size)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(box)
        context.endPage()
        context.closePDF()
        guard let document = PDFDocument(data: data as Data) else { return nil }
        return document.page(at: 0)
    }

    private func waitForFlipConfirmation(generation: Int) async -> Bool {
        await withCheckedContinuation { continuation in
            if !isFlowCurrent(generation) {
                continuation.resume(returning: false)
                return
            }
            flipContinuation = continuation
        }
    }

    /// Single user confirmation for the manual fallback: the fronts are out and
    /// the stack has been flipped; the backs pass starts immediately.
    func confirmFlip() {
        if flowPhase == .flip {
            let continuation = flipContinuation
            flipContinuation = nil
            FlowLog.write("user confirmed flip — starting backs")
            continuation?.resume(returning: true)
        } else if flowPhase == .done {
            flowPhase = .idle
            flowProgress = 0
            flowLabel = ""
        }
    }

    func cancelFlow() {
        flowGeneration += 1
        flowTask?.cancel()
        flowTask = nil
        if let continuation = flipContinuation {
            flipContinuation = nil
            continuation.resume(returning: false)
        }
        stopStatusMonitor()
        let job = flowJobID
        let printer = flowPrinterID
        flowJobID = nil
        if job != nil || !printer.isEmpty {
            Task { await Printing.cancel(jobID: job, printer: printer) }
        }
        flowPhase = .idle
        flowProgress = 0
        flowLabel = ""
        flowCopyIndex = 1
        flowStatusHint = ""
        flowError = nil
        flowRetrySide = nil
    }

    /// Retry after a printer error. Backs errors resubmit only the backs (never
    /// reprinting already-printed fronts); fronts errors restart the job.
    func retryAfterError() {
        guard flowError != nil else { return }
        let side = flowRetrySide ?? "fronts"
        flowError = nil
        flowStatusHint = ""
        flowProgress = 0
        flowGeneration += 1
        let generation = flowGeneration
        flowTask?.cancel()
        if side == "backs" {
            flowPhase = .printing
            flowLabel = T("flow.printingBacks")
            let backsFile = backsPDFIfNeeded(fronts: flowFronts, backs: flowBacks)
            flowTask = Task { [weak self] in
                guard let self else { return }
                if await self.performPass(pages: self.flowBacks, side: "backs", fileOverride: backsFile, generation: generation) {
                    if await self.waitForBacksCompletion(generation: generation) {
                        self.finishFlow(generation: generation)
                    }
                }
            }
        } else {
            // Restart the fronts pass from scratch (the fronts failed).
            flowPhase = .printing
            flowProgress = 0
            flowLabel = T("flow.printingFronts")
            flowTask = Task { [weak self] in
                await self?.runRealFlow(generation: generation)
            }
        }
    }

    private func finishFlow(generation: Int) {
        guard generation == flowGeneration, !Task.isCancelled else { return }
        flowPhase = .done
        flowProgress = 1
        flowLabel = ""
        flowJobID = nil
        flowStatusHint = ""
        flowError = nil
        let sheetText = L10n.sheets(sheets)
        let pageText = L10n.pages(selectedPages)
        let time = Date().formatted(date: .omitted, time: .shortened)
        lastPrint = "\(sheetText) · \(pageText) → \(printerName) · \(time)"
        showToast(T("toast.printed"))
        onNeedsAttention?()
    }

    private func runSimulatedFlow(generation: Int) async {
        let copiesTotal = max(flowCopiesTotal, 1)
        for copy in 1...copiesTotal {
            guard isFlowCurrent(generation) else { return }
            flowCopyIndex = copy
            guard await simulatePass(label: T("flow.printingFronts"), generation: generation) else { return }
            if duplex && !flowBacks.isEmpty {
                flowPhase = .flip
                flowProgress = 1
                flowLabel = ""
                flowStatusHint = T("flow.frontsReady")
                onNeedsAttention?()
                let confirmed = await waitForFlipConfirmation(generation: generation)
                guard confirmed, isFlowCurrent(generation) else { return }
                flowPhase = .printing
                flowProgress = 0
                guard await simulatePass(label: T("flow.printingBacks"), generation: generation) else { return }
            }
        }
        finishFlow(generation: generation)
    }

    private func simulatePass(label: String, generation: Int) async -> Bool {
        flowLabel = label
        for step in 1...12 {
            guard isFlowCurrent(generation) else { return false }
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard isFlowCurrent(generation) else { return false }
            flowProgress = min(0.95, Double(step) / 12.0)
        }
        flowProgress = 1
        return isFlowCurrent(generation)
    }

    // MARK: - Calibration

    func printCalibration() {
        guard !printerID.isEmpty, printer != nil else {
            showToast(T("toast.noPrinter"))
            return
        }
        guard let pdf = Printing.calibrationPDF() else {
            showToast(T("toast.printFailed"))
            return
        }
        let printer = printerID
        showToast(T("toast.calibrationSent"))
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Printing.submit(
                    file: pdf,
                    printer: printer,
                    pageRange: nil,
                    paper: "A4",
                    orientationRequested: 3,
                    scale: 100,
                    color: false,
                    copies: 1,
                    media: "Plain",
                    tray: "auto",
                    title: "FlipStack — calibration",
                    targetDPI: 600
                )
            }.value
            if !result.succeeded {
                self.showToast(result.message.isEmpty ? T("toast.printFailed") : result.message)
            }
        }
    }
}
