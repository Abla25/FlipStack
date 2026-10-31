import AppKit
import FlipStackCore
import SwiftUI

extension Notification.Name {
    static let flipStackOpenStudioWindow = Notification.Name("FlipStack.openStudioWindow")
}

private final class FirstResponderSink: NSView {
    override var acceptsFirstResponder: Bool { true }
}

/// The optional full-size FlipStack surface. The menu-bar panel remains the
/// quick path; this window is the same model and the same print flow, with a
/// normal title bar, resizing, and a Dock presence while it is open.
@MainActor
final class StudioWindowController: NSWindowController, NSWindowDelegate {
    private let model: AppModel
    private let orchestrator: DuplexOrchestrator
    private let firstResponderSink = FirstResponderSink(frame: .zero)

    init(model: AppModel, orchestrator: DuplexOrchestrator) {
        self.model = model
        self.orchestrator = orchestrator

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "FlipStack"
        window.subtitle = model.selectedPrinter?.displayName ?? "Print Studio"
        window.titlebarAppearsTransparent = false
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 440, height: 560)
        window.setFrameAutosaveName("FlipStackStudioWindow")
        window.center()

        super.init(window: window)

        window.delegate = self
        let container = NSView()
        window.contentView = container
        let root = StudioWindowView(model: model, orchestrator: orchestrator)
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = []
        hosting.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hosting)
        firstResponderSink.translatesAutoresizingMaskIntoConstraints = true
        firstResponderSink.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
        container.addSubview(firstResponderSink)
        window.initialFirstResponder = firstResponderSink
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: container.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        // A fresh window can be opened from a menu-bar-only app; switch only
        // while the normal window is visible.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refreshSubtitle),
            name: NSWindow.didBecomeKeyNotification,
            object: window
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        guard let window else { return }
        NSApp.setActivationPolicy(.regular)
        window.subtitle = model.selectedPrinter?.displayName ?? "Print Studio"
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Do not let AppKit focus the scale field just because it is the first
        // editable control. Typing at launch should not disable Fit.
        window.makeFirstResponder(firstResponderSink)
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self else { return }
            window?.makeFirstResponder(self.firstResponderSink)
        }
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    @objc private func refreshSubtitle() {
        window?.subtitle = model.selectedPrinter?.displayName ?? "Print Studio"
        window?.makeFirstResponder(firstResponderSink)
    }

    /// Local UI QA hook. It renders the real content view, including the
    /// window canvas, without relying on screen-recording permission.
    @discardableResult
    func renderScreenshot(to url: URL, size: NSSize = NSSize(width: 600, height: 820)) -> Bool {
        guard let window, let content = window.contentView else { return false }
        window.setContentSize(size)
        content.layoutSubtreeIfNeeded()
        content.displayIfNeeded()
        guard let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return false }
        content.cacheDisplay(in: content.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            NSLog("FlipStack window render failed: \(error)")
            return false
        }
    }
}

@MainActor
private struct StudioWindowView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var orchestrator: DuplexOrchestrator

    var body: some View {
        ZStack {
            // A normal window loses the popover's system glass. Give it the
            // same warm paper canvas instead of default window grey.
            Color(nsColor: .windowBackgroundColor)
            LinearGradient(
                colors: [
                    FlipColor.paper.opacity(0.72),
                    FlipColor.paper.opacity(0.28)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            RootView(model: model, orchestrator: orchestrator)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 440, minHeight: 560)
        .tint(FlipColor.coral)
    }
}
