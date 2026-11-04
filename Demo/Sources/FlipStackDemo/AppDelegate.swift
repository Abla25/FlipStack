import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    var panel: ReceiptPanel?
    var hosting: NSHostingView<ReceiptView>?
    var statusItem: NSStatusItem?
    private var flags = Flags()

    struct Flags {
        var capturePath: String?
        var state: String = "empty"
        var openDocument: String?
        var simulatePrint = false
        var autoFlow = false
        var quitAfter: Double = 0
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        parseFlags()
        model.simulate = flags.simulatePrint
        model.refreshPrinters()
        if let doc = flags.openDocument { model.chooseDoc(URL(fileURLWithPath: doc)) }

        setupStatusItem()
        buildPanel()
        applyState(flags.state)

        if flags.capturePath != nil || flags.quitAfter > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                self?.panel?.orderFrontRegardless()
                if self?.flags.autoFlow == true {
                    self?.model.simulate = true
                    self?.model.startPrint()
                    Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { t in
                        if self?.model.flowPhase == .flip { self?.model.confirmFlip() }
                        if self?.model.flowPhase == .done || self?.model.flowPhase == .idle { t.invalidate() }
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + (self?.flags.autoFlow == true ? 5.0 : 2.6)) { [weak self] in
                    if let path = self?.flags.capturePath { self?.capture(to: path) }
                    if self?.flags.quitAfter ?? 0 > 0 { NSApp.terminate(nil) }
                }
            }
        }
    }

    private func parseFlags() {
        let args = CommandLine.arguments
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--capture": flags.capturePath = args[i + 1]; i += 2
            case "--state": flags.state = args[i + 1]; i += 2
            case "--open-document": flags.openDocument = args[i + 1]; i += 2
            case "--simulate-print": flags.simulatePrint = true; i += 1
            case "--auto-flow": flags.autoFlow = true; i += 1
            case "--quit-after": flags.quitAfter = Double(args[i + 1]) ?? 1; i += 2
            default: i += 1
            }
        }
    }

    private func applyState(_ state: String) {
        switch state {
        case "doc": if model.docURL == nil { model.chooseDoc(samplePDF()) }
        case "preview": model.previewOpen = true
        case "settings": model.settingsOpen = true
        case "more": model.moreOpen = true
        case "flip": if model.docURL == nil { model.chooseDoc(samplePDF()) }; model.jumpToFlip()
        case "printers": model.printersOpen = true
        case "flowdone": if model.docURL == nil { model.chooseDoc(samplePDF()) }; model.jumpToDone()
        case "select":
            if model.docURL == nil { model.chooseDoc(samplePDF()) }
            model.selectMode = true
            model.togglePageIncluded(2)
            model.togglePageIncluded(4)
        default: break
        }
    }

    private func samplePDF() -> URL {
        let p = "/tmp/Sample-Document.pdf"
        if !FileManager.default.fileExists(atPath: p) { makeSamplePDF(at: p) }
        return URL(fileURLWithPath: p)
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let btn = statusItem?.button {
            if let url = Bundle.main.url(forResource: "menuicon", withExtension: "png"),
               let img = NSImage(contentsOf: url) {
                img.size = NSSize(width: 18, height: 18)
                btn.image = img
            } else {
                btn.image = Self.logoImage()
            }
            btn.target = self
            btn.action = #selector(togglePanel)
        }
    }

    static func logoImage() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let img = NSImage(size: size)
        img.lockFocus()
        let rect = NSRect(origin: .zero, size: size)
        NSColor(red: 235 / 255, green: 79 / 255, blue: 49 / 255, alpha: 1).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
        NSColor.white.setFill()
        NSBezierPath(roundedRect: NSRect(x: 4, y: 9.4, width: 7.5, height: 3.6), xRadius: 1.8, yRadius: 1.8).fill()
        NSColor.white.withAlphaComponent(0.65).setFill()
        NSBezierPath(roundedRect: NSRect(x: 4, y: 5.2, width: 9, height: 3.6), xRadius: 1.8, yRadius: 1.8).fill()
        img.unlockFocus()
        return img
    }

    private func buildPanel() {
        let panel = ReceiptPanel.make()
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
        if panel.isVisible { panel.orderOut(nil) } else { showPanel() }
    }

    func showPanel() {
        guard let panel, let item = statusItem, let btn = item.button else { return }
        let btnFrame = btn.window?.convertToScreen(btn.bounds) ?? .zero
        let x = btnFrame.midX - ReceiptPanel.panelWidth / 2
        let y = btnFrame.minY - ReceiptPanel.panelHeight - 6
        panel.setFrame(NSRect(x: x, y: y, width: ReceiptPanel.panelWidth, height: ReceiptPanel.panelHeight), display: true)
        panel.orderFrontRegardless()
    }

    func capture(to path: String) {
        guard let view = hosting else { return }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
        print("CAPTURED \(path)")
    }

    private func makeSamplePDF(at path: String) {
        guard let doc = Printing.calibrationPDF() else { return }
        try? FileManager.default.copyItem(at: doc, to: URL(fileURLWithPath: path))
    }
}

extension AppModel {
    /// Deterministic state jumps for automated UI capture.
    func jumpToFlip() { flowPhase = .flip; flowProgress = 1 }
    func jumpToDone() { flowPhase = .done; flowProgress = 1; lastPrint = "\(sheets) sheets → \(printerName)" }
}
