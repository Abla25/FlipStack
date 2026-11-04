import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    var panel: ReceiptPanel?
    var hosting: NSHostingView<ReceiptView>?
    var statusItem: NSStatusItem?
    private var globalClickMonitor: Any?
    private var localKeyMonitor: Any?
    private var flags = Flags()
    private let statusMenu = NSMenu()

    struct Flags {
        var capturePath: String?
        var state: String = "empty"
        var openDocument: String?
        var language: String?
        var defaultQuality: String?
        var simulatePrint = false
        var autoFlow = false
        var quitAfter: Double = 0
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        parseFlags()
        model.simulate = flags.simulatePrint
        if let language = flags.language {
            model.settings.language = AppLanguage(rawValue: language.lowercased()) ?? .en
        }
        if let quality = flags.defaultQuality,
           ["draft", "normal", "high"].contains(quality) {
            model.settings.defaultQuality = quality
        }
        model.onNeedsAttention = { [weak self] in
            self?.presentPanel()
        }
        model.refreshPrinters()
        if let doc = flags.openDocument {
            model.chooseDoc(URL(fileURLWithPath: doc))
        }

        setupStatusItem()
        buildPanel()
        applyState(flags.state)
        installEventMonitors()

        if flags.capturePath != nil || flags.quitAfter > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                guard let self else { return }
                self.panel?.orderFrontRegardless()
                self.model.setPanelVisible(true)
                // Document loading is async; open the requested overlay / jump once
                // the PDF is ready, otherwise `chooseDoc`'s reset would close it.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                    guard let self else { return }
                    switch self.flags.state {
                    case "preview": self.model.previewOpen = true
                    case "flip": self.model.jumpToFlip()
                    case "flowdone": self.model.jumpToDone()
                    default: break
                    }
                }
                if self.flags.autoFlow {
                    self.model.simulate = true
                    self.model.startPrint()
                    Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] timer in
                        Task { @MainActor in
                            guard let self else {
                                timer.invalidate()
                                return
                            }
                            if self.model.flowPhase == .flip { self.model.confirmFlip() }
                            if self.model.flowPhase == .done || self.model.flowPhase == .idle {
                                timer.invalidate()
                            }
                        }
                    }
                }
                let delay: Double = self.flags.autoFlow ? 5.0 : 2.6
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self else { return }
                    if let path = self.flags.capturePath { self.capture(to: path) }
                    if self.flags.quitAfter > 0 {
                        self.model.prepareForTermination()
                        NSApp.terminate(nil)
                    }
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        removeEventMonitors()
        model.prepareForTermination()
    }

    // MARK: - Flags (kept for the headless QA harness; bounds-safe)

    private func parseFlags() {
        let args = CommandLine.arguments
        var i = 1
        func nextValue() -> String? {
            guard i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        while i < args.count {
            switch args[i] {
            case "--capture":
                if let value = nextValue() { flags.capturePath = value; i += 2 } else { i += 1 }
            case "--state":
                if let value = nextValue() { flags.state = value; i += 2 } else { i += 1 }
            case "--open-document":
                if let value = nextValue() { flags.openDocument = value; i += 2 } else { i += 1 }
            case "--language":
                if let value = nextValue() { flags.language = value; i += 2 } else { i += 1 }
            case "--default-quality":
                if let value = nextValue() { flags.defaultQuality = value; i += 2 } else { i += 1 }
            case "--simulate-print":
                flags.simulatePrint = true
                i += 1
            case "--auto-flow":
                flags.autoFlow = true
                i += 1
            case "--quit-after":
                if let value = nextValue() { flags.quitAfter = Double(value) ?? 1; i += 2 } else { i += 1 }
            default:
                i += 1
            }
        }
    }

    private func applyState(_ state: String) {
        switch state {
        case "doc":
            if model.docURL == nil { model.chooseDoc(samplePDF()) }
        case "preview":
            if model.docURL == nil { model.chooseDoc(samplePDF()) }
        case "settings":
            model.settingsOpen = true
        case "more":
            model.moreOpen = true
        case "flip":
            if model.docURL == nil { model.chooseDoc(samplePDF()) }
        case "printers":
            model.printersOpen = true
        case "flowdone":
            if model.docURL == nil { model.chooseDoc(samplePDF()) }
        case "select":
            if model.docURL == nil { model.chooseDoc(samplePDF()) }
            model.selectMode = true
            model.togglePageIncluded(2)
            model.togglePageIncluded(4)
        default:
            break
        }
    }

    private func samplePDF() -> URL {
        let path = "/tmp/Sample-Document.pdf"
        if !FileManager.default.fileExists(atPath: path) { makeSamplePDF(at: path) }
        return URL(fileURLWithPath: path)
    }

    private func makeSamplePDF(at path: String) {
        guard let doc = Printing.calibrationPDF() else { return }
        try? FileManager.default.copyItem(at: doc, to: URL(fileURLWithPath: path))
    }

    // MARK: - Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem?.button else { return }
        // The toolbar icon is a monochrome template of the FlipStack receipt
        // logo: macOS tints it white on dark menu bars and black on light ones,
        // so it never looks like a colored sticker in the menu bar. The colored
        // brand logo (menuicon.png / AppIcon.icns) is unchanged everywhere else.
        if let url = Bundle.main.url(forResource: "menuicon-template", withExtension: "png"),
           let template = NSImage(contentsOf: url) {
            template.size = NSSize(width: 18, height: 18)
            template.isTemplate = true
            button.image = template
        } else if let url = Bundle.main.url(forResource: "menuicon", withExtension: "png"),
                  let image = NSImage(contentsOf: url) {
            image.size = NSSize(width: 18, height: 18)
            button.image = image
        } else {
            let fallback = Self.menuBarTemplateImage()
            fallback.isTemplate = true
            button.image = fallback
        }
        button.toolTip = T("app.tooltip")
        button.setAccessibilityLabel(T("app.tooltip"))
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        statusMenu.removeAllItems()
        let open = NSMenuItem(title: T("menu.open"), action: #selector(menuOpen), keyEquivalent: "")
        open.target = self
        let settings = NSMenuItem(title: T("menu.settings"), action: #selector(menuSettings), keyEquivalent: "")
        settings.target = self
        let quit = NSMenuItem(title: T("menu.quit"), action: #selector(menuQuit), keyEquivalent: "q")
        quit.target = self
        statusMenu.addItem(open)
        statusMenu.addItem(settings)
        statusMenu.addItem(.separator())
        statusMenu.addItem(quit)
    }

    /// Fallback for unbundled dev runs: the monochrome, template version of the
    /// receipt + flip-arrow motif (same shape as the shipped toolbar asset).
    static func menuBarTemplateImage() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()
        let page = NSBezierPath(roundedRect: NSRect(x: 4.4, y: 4.2, width: 8.0, height: 10.2),
                                xRadius: 1.4, yRadius: 1.4)
        page.lineWidth = 1.3
        NSColor.black.withAlphaComponent(0.95).setStroke()
        page.stroke()
        NSColor.black.withAlphaComponent(0.8).setStroke()
        for y in [11.3, 9.7] as [CGFloat] {
            let line = NSBezierPath()
            line.move(to: NSPoint(x: 6.2, y: y))
            line.line(to: NSPoint(x: 10.6, y: y))
            line.lineWidth = 1.1
            line.lineCapStyle = .round
            line.stroke()
        }
        let arc = NSBezierPath()
        arc.appendArc(withCenter: NSPoint(x: 11.9, y: 6.6), radius: 2.5,
                      startAngle: 35, endAngle: 300, clockwise: false)
        arc.lineWidth = 1.35
        arc.lineCapStyle = .round
        NSColor.black.withAlphaComponent(0.95).setStroke()
        arc.stroke()
        let head = NSBezierPath()
        head.move(to: NSPoint(x: 13.2, y: 8.9))
        head.line(to: NSPoint(x: 11.9, y: 9.4))
        head.line(to: NSPoint(x: 12.1, y: 7.9))
        head.close()
        NSColor.black.withAlphaComponent(0.95).setFill()
        head.fill()
        image.unlockFocus()
        return image
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            statusItem?.menu = statusMenu
            sender.performClick(nil)
            statusItem?.menu = nil
        } else {
            togglePanel()
        }
    }

    @objc private func menuOpen() {
        showPanel()
    }

    @objc private func menuSettings() {
        model.settingsOpen = true
        showPanel()
    }

    @objc private func menuQuit() {
        model.prepareForTermination()
        NSApp.terminate(nil)
    }

    // MARK: - Panel

    private func buildPanel() {
        let panel = ReceiptPanel.make()
        // The receipt aesthetic is intentionally light; pin it so Dark Mode
        // cannot turn overlay text white-on-white.
        panel.appearance = NSAppearance(named: .aqua)
        let view = ReceiptView(model: model)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: ReceiptPanel.panelWidth, height: ReceiptPanel.panelHeight)
        panel.contentView = host
        panel.applyReceiptMask()
        self.panel = panel
        self.hosting = host
    }

    @objc func togglePanel() {
        guard let panel else { return }
        if panel.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    private func hidePanel() {
        panel?.orderOut(nil)
        model.setPanelVisible(false)
    }

    func showPanel() {
        guard let panel, let item = statusItem, let button = item.button else { return }
        let buttonWindowFrame = button.window?.convertToScreen(button.bounds)
        let screen = button.window?.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var x = (buttonWindowFrame?.midX ?? visible.midX) - ReceiptPanel.panelWidth / 2
        x = max(visible.minX + 8, min(x, visible.maxX - ReceiptPanel.panelWidth - 8))
        var y = (buttonWindowFrame?.minY ?? visible.maxY) - ReceiptPanel.panelHeight - 6
        y = max(visible.minY + 8, min(y, visible.maxY - ReceiptPanel.panelHeight - 8))
        panel.setFrame(NSRect(x: x, y: y, width: ReceiptPanel.panelWidth, height: ReceiptPanel.panelHeight),
                       display: true)
        panel.orderFrontRegardless()
        model.setPanelVisible(true)
    }

    /// Presents the panel when the flow needs the user (flip prompt / done)
    /// even if the panel was closed meanwhile.
    func presentPanel() {
        showPanel()
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Dismissal

    private func installEventMonitors() {
        removeEventMonitors()
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.panel?.isVisible == true else { return }
                self.hidePanel()
            }
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 { // Escape
                if self.dismissTopOverlay() { return nil }
            }
            return event
        }
    }

    private func removeEventMonitors() {
        if let monitor = globalClickMonitor {
            NSEvent.removeMonitor(monitor)
            globalClickMonitor = nil
        }
        if let monitor = localKeyMonitor {
            NSEvent.removeMonitor(monitor)
            localKeyMonitor = nil
        }
    }

    /// Closes the topmost overlay; returns false when nothing was open.
    @discardableResult
    private func dismissTopOverlay() -> Bool {
        if model.popover != nil {
            model.popover = nil
            return true
        }
        if model.printersOpen {
            model.printersOpen = false
            return true
        }
        if model.calibOpen {
            model.calibOpen = false
            return true
        }
        if model.previewOpen {
            model.previewOpen = false
            return true
        }
        if model.settingsOpen {
            model.settingsOpen = false
            return true
        }
        return false
    }

    // MARK: - Headless capture

    func capture(to path: String) {
        guard let view = hosting else { return }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
        print("CAPTURED \(path)")
    }
}

extension AppModel {
    /// Deterministic state jumps for automated UI capture.
    func jumpToFlip() {
        flowPhase = .flip
        flowProgress = 1
        flowLabel = ""
    }

    func jumpToDone() {
        flowPhase = .done
        flowProgress = 1
        flowLabel = ""
        lastPrint = "\(L10n.sheets(sheets)) · \(L10n.pages(selectedPages)) → \(printerName)"
    }
}
