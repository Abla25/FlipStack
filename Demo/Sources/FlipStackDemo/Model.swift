import Foundation
import AppKit
import PDFKit
import FlipStackCore

// MARK: - Pure print math (unit-tested)
enum PrintMath {
    static func selectedPages(total: Int, pages: String) -> Int {
        switch pages {
        case "odd": return (total + 1) / 2
        case "even": return total / 2
        default: return total
        }
    }
    static func sheets(pages: Int, duplex: Bool, copies: Int) -> Int {
        let s = duplex ? (pages + 1) / 2 : pages
        return s * copies
    }
    static func dpi(quality: String, resOverride: String) -> Int {
        if let v = Int(resOverride), v > 0 { return v }
        switch quality {
        case "draft": return 180
        case "normal": return 366
        default: return 600
        }
    }
    static func qualityLevel(forDPI dpi: Int) -> Int {
        dpi <= 180 ? 3 : dpi <= 366 ? 4 : 5
    }
    static func qualityLevel(_ q: String) -> Int {
        switch q { case "draft": return 3; case "normal": return 4; default: return 5 }
    }
    static func pageRange(pages: Int, side: String) -> String {
        var nums: [Int] = []
        var i = side == "odd" ? 1 : 2
        while i <= pages { nums.append(i); i += 2 }
        return compressRange(nums)
    }
    /// Compress sorted page numbers into "1-3,5,7-9" form.
    static func compressRange(_ pages: [Int]) -> String {
        let sorted = Array(Set(pages)).sorted()
        guard !sorted.isEmpty else { return "" }
        var parts: [String] = []
        var start = sorted[0], prev = sorted[0]
        for p in sorted.dropFirst() {
            if p == prev + 1 { prev = p; continue }
            parts.append(start == prev ? "\(start)" : "\(start)-\(prev)")
            start = p; prev = p
        }
        parts.append(start == prev ? "\(start)" : "\(start)-\(prev)")
        return parts.joined(separator: ",")
    }
    /// Parse a user page spec like "1-5, 8, 12-14" against a total page count.
    static func parsePageSpec(_ spec: String, total: Int) -> [Int] {
        var result = Set<Int>()
        for part in spec.split(separator: ",") {
            let p = part.trimmingCharacters(in: .whitespaces)
            if let dash = p.firstIndex(of: "-") {
                let a = Int(p[..<dash].trimmingCharacters(in: .whitespaces)) ?? 0
                let b = Int(p[p.index(after: dash)...].trimmingCharacters(in: .whitespaces)) ?? 0
                if a > 0, b >= a { for i in a...min(b, total) { result.insert(i) } }
            } else if let n = Int(p), n >= 1 {
                result.insert(min(n, total))
            }
        }
        return result.sorted()
    }
    /// The actual pages to print, given the mode ("all"/"odd"/"even"/"custom") and spec.
    static func selectedPageList(total: Int, pages: String, spec: String) -> [Int] {
        switch pages {
        case "odd": return stride(from: 1, through: total, by: 2).map { $0 }
        case "even": return stride(from: 2, through: total, by: 2).map { $0 }
        case "custom":
            let list = parsePageSpec(spec, total: total)
            return list.isEmpty ? Array(1...max(total, 1)) : list
        default: return total > 0 ? Array(1...total) : []
        }
    }
    /// Scale factor so a page fits inside a fixed sheet (zoom=1.0 → fit).
    static func fitScale(sheetW: Double, sheetH: Double, pageW: Double, pageH: Double) -> Double {
        guard pageW > 0, pageH > 0 else { return 1 }
        return min(sheetW / pageW, sheetH / pageH)
    }
    static func isPhoto(_ name: String) -> Bool {
        let exts = ["jpg", "jpeg", "heic", "heif", "png", "tiff", "tif", "bmp", "gif", "webp"]
        return exts.contains((name as NSString).pathExtension.lowercased())
    }
}

// MARK: - App model
enum FlowPhase: Equatable { case idle, printing, flip, done }

enum PopoverKind: Equatable {
    case paper, color, quality, copies, duplexEdge, pages, orientation, scale, media, tray, resOverride, inkSave
}

struct DemoSettings {
    var lang = "EN"
    var defQuality = "high"
}

final class AppModel: ObservableObject {
    // document
    @Published var docURL: URL?
    @Published var docName = ""
    @Published var docPages = 0
    @Published var docSizeMB = 0.0
    @Published var previewDoc: PDFDocument?   // cached so we don't re-parse per render
    var isPhoto: Bool { docURL.map { PrintMath.isPhoto($0.lastPathComponent) } ?? false }

    // printers — real CUPS queues from FlipStackCore
    @Published var printers: [Printer] = []
    @Published var printerID = ""
    @Published var supplies: [SupplyLevel] = []          // real levels (IPP/SNMP via core)
    @Published var printerState: PrinterState = .unknown
    @Published var queuedJobs = 0
    @Published var statusOrigin: StatusOrigin = .unavailable
    @Published var printerStates: [String: PrinterStatus] = [:]   // live status for ALL queues
    @Published var probeOffline: Set<String> = []                // network printers that fail TCP probe (power off)
    var printer: Printer? { printers.first(where: { $0.id == printerID }) }
    var printerName: String { printer?.name ?? printerID }

    // options
    @Published var duplex = true
    @Published var duplexEdge = "long"
    @Published var paper = "A4"
    @Published var colorMode = "Color"
    @Published var quality = "high"
    @Published var pagesSel = "all"
    @Published var pageSpec = ""
    @Published var orientation = "auto"
    @Published var scale = 100
    @Published var media = "Plain"
    @Published var tray = "auto"
    @Published var copies = 1
    @Published var resOverride = "off"
    @Published var inkSave = false

    // ui state
    @Published var moreOpen = false
    @Published var popover: PopoverKind?
    @Published var customPagesDraft = ""
    @Published var previewOpen = false
    @Published var previewPage = 1
    @Published var previewZoom: CGFloat = 1.0
    @Published var selectMode = false                    // filmstrip tap = include/exclude pages
    @Published var settingsOpen = false
    @Published var printersOpen = false
    @Published var calibOpen = false
    @Published var toast: String?
    @Published var flowPhase: FlowPhase = .idle
    @Published var flowProgress: Double = 0
    @Published var flowLabel = ""
    @Published var lastPrint: String?

    var settings = DemoSettings()
    var simulate = false
    private var flowTimer: Timer?
    private var statusTimer: Timer?
    private var flowSide = "all"

    // derived
    var selectedPageList: [Int] { PrintMath.selectedPageList(total: docPages, pages: pagesSel, spec: pageSpec) }
    var selectedPages: Int { selectedPageList.count }
    var sheets: Int { PrintMath.sheets(pages: selectedPages, duplex: duplex, copies: copies) }
    var dpi: Int { PrintMath.dpi(quality: quality, resOverride: resOverride) }

    // MARK: printers & live status
    func refreshPrinters() {
        Task {
            let list = (try? await CUPSClient().listPrinters()) ?? []
            await MainActor.run {
                self.printers = list
                if self.printerID.isEmpty {
                    self.printerID = list.first(where: { $0.isDefault })?.id ?? list.first?.id ?? ""
                }
                Task { await self.pollStatus() }
                Task { await self.pollAllPrinters() }
                self.statusTimer?.invalidate()
                self.statusTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in
                    Task { await self.pollStatus() }
                    Task { await self.pollAllPrinters() }
                }
            }
        }
    }

    func pollStatus() async {
        guard let p = printer else { return }
        let st = await IPPStatusClient().status(for: p)
        await MainActor.run {
            self.supplies = st.supplies
            self.printerState = st.state
            self.queuedJobs = st.queuedJobCount ?? 0
            self.statusOrigin = st.origin
            self.printerStates[st.printerID] = st
        }
    }

    /// Poll every queue so the picker can show real offline/online state.
    /// Wireless (dnssd/socket) queues are ALSO power-probed directly: CUPS
    /// answers for them even when the printer is off, so TCP reachability is
    /// the ground truth for "online".
    func pollAllPrinters() async {
        // One Bonjour browse resolves every advertised printer to host:port.
        let endpoints = await NetworkProbe.bonjourEndpoints(timeout: 2.5)
        let canJudge = !endpoints.isEmpty   // if Bonjour sees nothing at all, don't judge (fall back to CUPS)
        // Probe all queues in parallel with short deadlines — never block the UI.
        await withTaskGroup(of: (String, PrinterStatus?, Bool).self) { group in
            for p in printers {
                group.addTask {
                    let st = await IPPStatusClient().status(for: p)
                    var offline = false
                    if canJudge, let uri = p.deviceURI, NetworkProbe.parseDnssd(uri)?.uuid != nil || uri.hasPrefix("socket://") {
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
            var states: [String: PrinterStatus] = [:]
            var offlineSet: Set<String> = []
            for await (id, st, off) in group {
                if let st { states[id] = st }
                if off { offlineSet.insert(id) }
            }
            await MainActor.run {
                // publish only on change so the UI does not re-render needlessly
                if states != self.printerStates { self.printerStates = states }
                if offlineSet != self.probeOffline { self.probeOffline = offlineSet }
            }
        }
    }

    func isOffline(_ id: String) -> Bool {
        if probeOffline.contains(id) { return true }
        let reasons = printerStates[id]?.stateReasons ?? printers.first(where: { $0.id == id })?.stateReasons ?? []
        return reasons.contains { $0.contains("offline") || $0.contains("connecting") || $0.contains("unreachable") }
    }
    /// 0 = fine, 1 = attention (unknown reasons), 2 = offline
    func statusSeverity(_ id: String) -> Int {
        if isOffline(id) { return 2 }
        let reasons = printerStates[id]?.stateReasons ?? printers.first(where: { $0.id == id })?.stateReasons ?? []
        let known = ["none", "offline-report"]
        let unknown = reasons.filter { !known.contains($0.lowercased()) && !$0.contains("offline") }
        return unknown.isEmpty ? 0 : 1
    }
    func statusLabel(_ id: String) -> String {
        switch statusSeverity(id) {
        case 2: return "offline"
        case 1: return "check printer"
        default: return printerStates[id]?.state.label.lowercased() ?? printers.first(where: { $0.id == id })?.state.label.lowercased() ?? "unknown"
        }
    }

    func pickPrinter(_ id: String) {
        printerID = id
        printersOpen = false
        Task { await pollStatus() }
        showToast("Printer: \(printerName)")
    }

    // MARK: page inclusion (select pages in the preview filmstrip)
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
        if s.count == docPages && docPages > 0 { pagesSel = "all"; pageSpec = "" }
        else { pagesSel = "custom"; pageSpec = PrintMath.compressRange(Array(s).sorted()) }
        previewPage = min(max(p, 1), max(docPages, 1))
    }

    // MARK: document
    func chooseDoc(_ url: URL) {
        docURL = url
        docName = url.lastPathComponent
        if PrintMath.isPhoto(url.lastPathComponent) {
            docPages = 1
            previewDoc = Printing.photoToPDF(url)
        } else if let pdf = PDFDocument(url: url) {
            docPages = pdf.pageCount
            previewDoc = pdf
        } else {
            docPages = 1
            previewDoc = nil
        }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int64 {
            docSizeMB = Double(size) / 1_048_576
        }
        previewPage = 1
    }

    func removeDoc() {
        cancelFlow()
        docURL = nil; docName = ""; docPages = 0; previewDoc = nil
    }

    func showToast(_ msg: String) {
        toast = msg
        Task { try? await Task.sleep(nanoseconds: 1_600_000_000); if self.toast == msg { self.toast = nil } }
    }

    // MARK: print flow
    func startPrint() {
        guard docURL != nil else { showToast("Drop a document first"); return }
        cancelFlow()
        if duplex {
            let fronts = stride(from: 0, to: selectedPageList.count, by: 2).map { selectedPageList[$0] }
            runPhase(side: "fronts", pages: fronts, label: "Printing…")
        } else {
            runPhase(side: "all", pages: selectedPageList, label: "Printing…")
        }
    }

    private func runPhase(side: String, pages: [Int], label: String) {
        flowSide = side
        flowPhase = .printing
        flowLabel = label
        flowProgress = 0
        guard let url = docURL else { return }
        let range = PrintMath.compressRange(pages)
        if simulate {
            let started = Date()
            flowTimer = Timer.scheduledTimer(withTimeInterval: 0.09, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.flowProgress += 0.12
                    // keep the "Printing…" screen visible at least 1.4s
                    if self.flowProgress >= 1 && Date().timeIntervalSince(started) >= 1.4 {
                        self.flowTimer?.invalidate(); self.flowTimer = nil
                        self.advanceAfter(side: side)
                    } else if self.flowProgress >= 1 {
                        self.flowProgress = 0.98
                    }
                }
            }
        } else {
            let printer = printerID
            let title = side == "backs" ? "FlipStack — backs" : side == "fronts" ? "FlipStack — fronts" : "FlipStack"
            Task {
                let out = Printing.print(file: url, printer: printer, pageRange: range.isEmpty ? nil : range,
                                         targetDPI: dpi, color: colorMode == "Color" && !inkSave,
                                         copies: copies, media: media, paper: paper,
                                         scale: scale, orientation: orientation,
                                         duplexEdge: duplexEdge, title: title)
                await MainActor.run { self.flowProgress = 0.4 }
                // lp exiting only means spooled. Find OUR job by its title, then
                // wait until CUPS reports it completed — only then advance (flip).
                var jobID = Printing.parseJobID(out)
                if jobID == nil {
                    jobID = await Printing.findJob(title: title, printer: printer)
                }
                var ok = !out.contains("error")
                if let jobID {
                    Printing.currentJobID = jobID
                    // animate progress while the printer works
                    let anim = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { _ in
                        Task { @MainActor in
                            if self.flowPhase == .printing && self.flowProgress < 0.95 {
                                self.flowProgress = min(0.95, self.flowProgress + 0.02)
                            }
                        }
                    }
                    ok = await Printing.waitForJob(jobID, printer: printer, timeout: 300)
                    anim.invalidate()
                    await MainActor.run { Printing.currentJobID = nil }
                }
                let okFinal = ok
                await MainActor.run {
                    guard self.flowPhase == .printing else { return } // cancelled meanwhile
                    self.flowProgress = 1
                    if out.contains("error") || !okFinal { self.showToast("Print failed or cancelled"); self.flowPhase = .idle }
                    else { self.advanceAfter(side: side) }
                }
            }
        }
    }

    private func advanceAfter(side: String) {
        if side == "fronts" && duplex {
            let backs = stride(from: 1, to: selectedPageList.count, by: 2).map { selectedPageList[$0] }
            if backs.isEmpty { finishFlow() } else { flowPhase = .flip }
        } else {
            finishFlow()
        }
    }

    func confirmFlip() {
        if flowPhase == .flip {
            let backs = stride(from: 1, to: selectedPageList.count, by: 2).map { selectedPageList[$0] }
            runPhase(side: "backs", pages: backs, label: "Printing…")
        } else if flowPhase == .done {
            flowPhase = .idle
        }
    }

    func finishFlow() {
        flowPhase = .done
        lastPrint = "\(sheets) sheet\(sheets == 1 ? "" : "s") · \(selectedPages) pg → \(printerName) at \(Date().formatted(date: .omitted, time: .shortened))"
        showToast("Printed ✓")
    }

    func cancelFlow() {
        flowTimer?.invalidate(); flowTimer = nil
        Printing.cancelCurrent()
        flowPhase = .idle
        flowProgress = 0
    }

    func retryPhase() {
        guard flowPhase == .printing else { return }
        flowTimer?.invalidate(); flowTimer = nil
        Printing.cancelCurrent()
        let list = selectedPageList
        let pages = flowSide == "backs"
            ? stride(from: 1, to: list.count, by: 2).map { list[$0] }
            : (flowSide == "fronts"
                ? stride(from: 0, to: list.count, by: 2).map { list[$0] }
                : list)
        flowProgress = 0
        runPhase(side: flowSide, pages: pages, label: flowLabel)
    }
}
