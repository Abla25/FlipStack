import AppKit
import Combine
import FlipStackCore
import SwiftUI

private final class FlipPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class MenuBarController: NSObject {
    private let model: AppModel
    private let orchestrator: DuplexOrchestrator
    private let statusItem: NSStatusItem
    private let panel: FlipPanel
    private let effectView = NSVisualEffectView()
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var cancellables = Set<AnyCancellable>()
    private var isVisible = false
    private var hostingView: NSHostingView<RootView>!
    private var lastAnnouncedPhase: String?
    private var lastCalibrationStage: FlipCalibration.Stage?
    var allowsAutomaticPresentation = true

    init(model: AppModel, orchestrator: DuplexOrchestrator) {
        self.model = model
        self.orchestrator = orchestrator
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.panel = FlipPanel(
            contentRect: NSRect(x: 0, y: 0, width: FlipMetrics.panelWidth, height: FlipMetrics.panelHeight),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()
        configureStatusItem()
        configurePanel()
        observeFlow()
    }

    // MARK: Status item

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.image = Self.makeIcon(waiting: false)
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.toolTip = "FlipStack"
        button.setAccessibilityLabel("FlipStack print manager")
        button.setAccessibilityHelp("Opens the FlipStack popover.")
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp {
            showContextMenu()
            return
        }
        toggle()
    }

    private func showContextMenu() {
        guard let button = statusItem.button else { return }
        let menu = NSMenu()
        let open = NSMenuItem(title: "Open FlipStack", action: #selector(openFromMenu), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit FlipStack", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: button.bounds.minY - 4),
            in: button
        )
    }

    @objc private func openFromMenu() {
        present()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: Panel

    private func configurePanel() {
        panel.level = .popUpMenu
        panel.title = "FlipStack"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isMovable = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.setContentSize(NSSize(width: FlipMetrics.panelWidth, height: FlipMetrics.panelHeight))

        let container = NSView(frame: NSRect(x: 0, y: 0, width: FlipMetrics.panelWidth, height: FlipMetrics.panelHeight))
        container.wantsLayer = true
        container.layer?.shadowColor = NSColor.black.cgColor
        container.layer?.shadowOpacity = 0.28
        container.layer?.shadowRadius = 28
        container.layer?.shadowOffset = CGSize(width: 0, height: -10)

        effectView.frame = container.bounds
        effectView.autoresizingMask = [.width, .height]
        effectView.material = .popover
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = FlipMetrics.panelRadius
        effectView.layer?.masksToBounds = true
        effectView.layer?.borderWidth = 0.5
        effectView.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor
        container.addSubview(effectView)

        let root = RootView(model: model, orchestrator: orchestrator)
        hostingView = NSHostingView(rootView: root)
        hostingView.setAccessibilityLabel("FlipStack print manager")
        // The popover owns its own frame. Without this, a tall document/options
        // tree can feed its ideal height back into the panel and make the
        // window thousands of points tall after a real PDF is loaded.
        hostingView.sizingOptions = []
        hostingView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        hostingView.setContentHuggingPriority(.defaultLow, for: .vertical)
        hostingView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hostingView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        effectView.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: effectView.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: effectView.bottomAnchor)
        ])

        panel.contentView = container
    }

    // MARK: Presentation

    /// The popover owns a deliberate 388 x 680 frame. Clamp it to the space
    /// below the menu bar and above the Dock; short screens scroll internally.
    private func panelTargetSize(buttonFrame: NSRect, visible: NSRect) -> NSSize {
        let availableHeight = max(420, buttonFrame.minY - visible.minY - 16)
        return NSSize(
            width: min(FlipMetrics.panelWidth, visible.width - 16),
            height: min(FlipMetrics.panelHeight, availableHeight)
        )
    }

    private func enforcePanelSize(_ target: NSSize) {
        if abs(panel.frame.width - target.width) > 0.5
            || abs(panel.frame.height - target.height) > 0.5 {
            panel.setContentSize(target)
        }
    }

    func toggle() {
        isVisible ? close() : present()
    }

    func present() {
        guard let button = statusItem.button, let buttonWindow = button.window else { return }
        let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = buttonWindow.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let targetSize = panelTargetSize(buttonFrame: buttonFrame, visible: visible)
        enforcePanelSize(targetSize)

        if isVisible {
            panel.makeKey()
            DispatchQueue.main.async { [weak self] in
                self?.enforcePanelSize(targetSize)
            }
            return
        }

        let size = panel.frame.size
        var x = buttonFrame.midX - size.width / 2
        x = max(visible.minX + 8, min(x, visible.maxX - size.width - 8))
        var y = buttonFrame.minY - size.height - 6
        if y < visible.minY + 8 { y = visible.minY + 8 }
        panel.setFrameOrigin(NSPoint(x: x, y: y))

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKey()

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if reduceMotion {
            panel.alphaValue = 1
        } else {
            effectView.layer?.anchorPoint = CGPoint(x: 0.5, y: 1)
            effectView.layer?.position = CGPoint(
                x: effectView.bounds.midX,
                y: effectView.bounds.maxY
            )
            let spring = CASpringAnimation(keyPath: "transform.scale")
            spring.fromValue = 0.965
            spring.toValue = 1.0
            spring.mass = 0.7
            spring.stiffness = 260
            spring.damping = 24
            spring.initialVelocity = 0
            spring.duration = spring.settlingDuration
            effectView.layer?.add(spring, forKey: "flipstack.present")
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = 0.14
            effectView.layer?.add(fade, forKey: "flipstack.fade")
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
        }

        isVisible = true
        installMonitors()
        // SwiftUI may publish a new ideal size during the next layout pass.
        // Re-assert the popover frame once after that pass.
        DispatchQueue.main.async { [weak self] in
            self?.enforcePanelSize(targetSize)
        }
        Task {
            await model.refreshStatus()
            await model.refreshQueue()
        }
    }

    func close() {
        guard isVisible else { return }
        isVisible = false
        model.isShowingQueue = false
        removeMonitors()
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if reduceMotion {
            panel.orderOut(nil)
            panel.alphaValue = 0
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.11
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                panel.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                self?.panel.orderOut(nil)
            }
        }
    }

    /// Renders the SwiftUI root into a PNG for README screenshots and local
    /// visual QA. The real panel uses system glass; this renders the content on
    /// a neutral paper backdrop so the image is legible everywhere.
    @discardableResult
    func renderScreenshot(
        to url: URL,
        colorScheme: ColorScheme = .light,
        largeText: Bool = false,
        height: CGFloat = FlipMetrics.panelHeight
    ) -> Bool {
        let content = ZStack {
            (colorScheme == .dark
                ? Color(red: 0.11, green: 0.10, blue: 0.09)
                : Color(red: 0.965, green: 0.945, blue: 0.918))
            RootView(model: model, orchestrator: orchestrator)
                .environment(\.colorScheme, colorScheme)
                .environment(\.dynamicTypeSize, largeText ? .accessibility2 : .large)
        }
        .frame(width: FlipMetrics.panelWidth, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
        }

        let host = NSHostingView(rootView: content)
        host.frame = NSRect(x: 0, y: 0, width: FlipMetrics.panelWidth, height: height)
        host.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return false }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
            return true
        } catch {
            NSLog("FlipStack render failed: \(error)")
            return false
        }
    }

    private func installMonitors() {
        removeMonitors()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 {
                self.close()
                return nil
            }
            return event
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
    }

    private func removeMonitors() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
            self.resignObserver = nil
        }
    }

    // MARK: Flow observation

    private func observeFlow() {
        orchestrator.$phase
            .receive(on: RunLoop.main)
            .sink { [weak self] phase in
                guard let self else { return }
                self.updateIcon(for: phase)
                self.announceIfNeeded(phase)
                switch phase {
                case .preparing, .printing, .awaitingFlip:
                    if self.allowsAutomaticPresentation {
                        self.present()
                    }
                default:
                    break
                }
            }
            .store(in: &cancellables)

        model.$selectedDocument
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] document in
                guard document != nil else { return }
                guard self?.allowsAutomaticPresentation == true else { return }
                self?.present()
            }
            .store(in: &cancellables)

        model.$flipCalibration
            .receive(on: RunLoop.main)
            .sink { [weak self] calibration in
                guard let self else { return }
                guard let button = self.statusItem.button else { return }
                guard let calibration else {
                    self.lastCalibrationStage = nil
                    self.updateIcon(for: self.orchestrator.phase)
                    return
                }
                let stageChanged = self.lastCalibrationStage != calibration.stage
                self.lastCalibrationStage = calibration.stage
                switch calibration.stage {
                case .printing:
                    button.image = Self.makeIcon(waiting: false)
                    button.toolTip = "FlipStack · calibrating"
                    button.setAccessibilityLabel("FlipStack, calibrating the flip")
                case .questions:
                    button.image = Self.makeIcon(waiting: true)
                    button.toolTip = "FlipStack · calibration ready"
                    button.setAccessibilityLabel("FlipStack, calibration ready")
                    if stageChanged, self.allowsAutomaticPresentation {
                        self.present()
                    }
                case .failed:
                    button.image = Self.makeIcon(waiting: false)
                    button.toolTip = "FlipStack · calibration needs attention"
                    button.setAccessibilityLabel("FlipStack, calibration needs attention")
                }
            }
            .store(in: &cancellables)
    }

    private func updateIcon(for phase: DuplexPhase) {
        guard let button = statusItem.button else { return }
        let waiting: Bool
        if case .awaitingFlip = phase {
            waiting = true
        } else {
            waiting = false
        }
        button.image = Self.makeIcon(waiting: waiting)
        switch phase {
        case .printing(_, let job):
            button.toolTip = "FlipStack · \(job.displayState)"
            button.setAccessibilityLabel("FlipStack, printing")
        case .awaitingFlip:
            button.toolTip = "FlipStack · waiting for you to flip the stack"
            button.setAccessibilityLabel("FlipStack, waiting for the stack to be flipped")
        default:
            button.toolTip = "FlipStack"
            button.setAccessibilityLabel("FlipStack print manager")
        }
    }

    /// Announces meaningful state changes once. The job object updates on every
    /// poll, so compare a coarse phase key instead of `DuplexPhase` itself.
    private func announceIfNeeded(_ phase: DuplexPhase) {
        let key: String
        let message: String
        switch phase {
        case .idle:
            key = "idle"
            message = "FlipStack is ready."
        case .preparing:
            key = "preparing"
            message = "Preparing the print job."
        case .printing(.fronts, _):
            key = "printing-fronts"
            message = "Printing fronts."
        case .printing(.backs, _):
            key = "printing-backs"
            message = "Printing backs."
        case .awaitingFlip(let prompt):
            key = "awaiting-flip"
            message = prompt.mode == .reinsertOnly
                ? "Your turn. Reinsert the stack exactly as it is, then continue."
                : "Your turn. Flip the whole stack as one block, then continue."
        case .completed:
            key = "completed"
            message = "Printing complete."
        case .failed(let failure):
            key = "failed-\(failure.title)"
            message = failure.title
        case .cancelled:
            key = "cancelled"
            message = "Printing canceled."
        }
        guard key != lastAnnouncedPhase else { return }
        lastAnnouncedPhase = key
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue
            ]
        )
    }

    // MARK: Icon

    private static func makeIcon(waiting: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let ink = NSColor.black
            ink.setStroke()
            ink.setFill()

            // Back sheet.
            let back = NSBezierPath(
                roundedRect: NSRect(x: 3.5, y: 2.5, width: 9.5, height: 12.5),
                xRadius: 1.6,
                yRadius: 1.6
            )
            back.lineWidth = 1.15
            back.stroke()

            // Front sheet.
            let front = NSBezierPath(
                roundedRect: NSRect(x: 6.5, y: 4.5, width: 8, height: 11),
                xRadius: 1.4,
                yRadius: 1.4
            )
            front.lineWidth = 1.35
            if waiting {
                front.fill()
                if let context = NSGraphicsContext.current?.cgContext {
                    context.saveGState()
                    context.setBlendMode(.clear)
                    context.fill(CGRect(x: 8.2, y: 8.2, width: 4.6, height: 1.0))
                    context.fill(CGRect(x: 8.2, y: 10.1, width: 4.6, height: 1.0))
                    context.fill(CGRect(x: 8.2, y: 12.0, width: 3.2, height: 1.0))
                    context.restoreGState()
                }
                let dot = NSBezierPath(ovalIn: NSRect(x: 13.2, y: 2.8, width: 3.2, height: 3.2))
                dot.fill()
            } else {
                front.stroke()
                let line = NSBezierPath()
                line.lineWidth = 0.9
                line.move(to: NSPoint(x: 8.2, y: 8.3))
                line.line(to: NSPoint(x: 12.8, y: 8.3))
                line.move(to: NSPoint(x: 8.2, y: 10.2))
                line.line(to: NSPoint(x: 12.8, y: 10.2))
                line.move(to: NSPoint(x: 8.2, y: 12.1))
                line.line(to: NSPoint(x: 11.4, y: 12.1))
                line.stroke()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
