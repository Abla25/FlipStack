import AppKit
import FlipStackCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var model: AppModel?
    private var orchestrator: DuplexOrchestrator?
    private var menuBar: MenuBarController?
    private var studioWindow: StudioWindowController?
    private var notificationService: NotificationService?
    private var pendingDocumentURL: URL?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let arguments = ProcessInfo.processInfo.arguments
        let demo = DemoSession(arguments: arguments)

        let spooler: any PrintSpooling
        let ppdProvider: any PPDProviding
        let statusProvider: any PrinterStatusProviding
        let preferencesStore: PreferencesStore

        if let demo {
            let suiteName = "app.flipstack.demo"
            let defaults = UserDefaults(suiteName: suiteName) ?? .standard
            defaults.removePersistentDomain(forName: suiteName)
            preferencesStore = PreferencesStore(defaults: defaults)
            if demo.scenario != .noPrinter {
                preferencesStore.lastPrinterID = DemoSession.demoPrinterID()
                preferencesStore.save(
                    DemoSession.demoPreferences(for: demo.scenario),
                    for: DemoSession.demoPrinterID()
                )
            }
            spooler = demo.spooler
            ppdProvider = demo.ppdProvider
            statusProvider = demo.statusProvider
        } else {
            preferencesStore = PreferencesStore()
            spooler = CUPSClient()
            ppdProvider = PPDLoader()
            statusProvider = IPPStatusClient()
        }

        let bookletImposer = BookletImposer()
        let notifications = NotificationService()
        let orchestrator = DuplexOrchestrator(spooler: spooler, notifier: notifications)
        let model = AppModel(
            spooler: spooler,
            ppdProvider: ppdProvider,
            statusProvider: statusProvider,
            bookletImposer: bookletImposer,
            preferencesStore: preferencesStore,
            orchestrator: orchestrator,
            printerDiscovery: demo == nil ? CUPSDeviceDiscovery() : DemoPrinterDiscovery()
        )
        let menuBar = MenuBarController(model: model, orchestrator: orchestrator)
        menuBar.allowsAutomaticPresentation = Self.argumentValue("--capture-panel", in: arguments) == nil
        let studioWindow = StudioWindowController(model: model, orchestrator: orchestrator)
        menuBar.mainWindowIsVisible = { [weak studioWindow] in
            studioWindow?.window?.isVisible == true
        }

        notifications.onOpen = { [weak menuBar] in
            menuBar?.present()
        }
        notifications.onContinue = { [weak model] in
            model?.confirmFlip()
        }
        notifications.onCancel = { [weak model] in
            model?.cancelFlow()
        }

        self.notificationService = notifications
        self.orchestrator = orchestrator
        self.model = model
        self.menuBar = menuBar
        self.studioWindow = studioWindow

        if let rawLanguage = Self.argumentValue("--language", in: arguments),
           let language = AppLanguage(rawValue: rawLanguage) {
            model.language = language
        }

        configureMainMenu(model: model)
        NotificationCenter.default.addObserver(
            forName: .flipStackConfirmHandled,
            object: nil,
            queue: .main
        ) { [weak notifications] _ in
            Task { @MainActor in notifications?.clearFlipNotification() }
        }
        NotificationCenter.default.addObserver(
            forName: .flipStackLanguageChanged,
            object: nil,
            queue: .main
        ) { [weak self, weak model] _ in
            Task { @MainActor in
                guard let self, let model else { return }
                self.configureMainMenu(model: model)
                self.menuBar?.refreshLocalizedChrome()
                self.notificationService?.languageDidChange()
            }
        }
        NotificationCenter.default.addObserver(
            forName: .flipStackOpenStudioWindow,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.openStudioWindow() }
        }
        model.start()

        if let pendingDocumentURL {
            self.pendingDocumentURL = nil
            Task { await model.acceptDocument(url: pendingDocumentURL) }
        }

        let capturePath = Self.argumentValue("--capture-panel", in: arguments)

        if let demo {
            Task { [weak self, weak menuBar] in
                await demo.prepareAndWait(model: model)
                if arguments.contains("--show-settings") {
                    model.openSettings()
                }
                if let capturePath {
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    let url = URL(fileURLWithPath: capturePath)
                    let scheme: ColorScheme = arguments.contains("--dark") ? .dark : .light
                    let customHeight: CGFloat? = Self.argumentValue("--panel-height", in: arguments).flatMap { Double($0) }.map { CGFloat($0) }
                    let ok = menuBar?.renderScreenshot(
                        to: url,
                        colorScheme: scheme,
                        largeText: arguments.contains("--large-text"),
                        height: customHeight ?? FlipMetrics.panelHeight
                    ) ?? false
                    NSLog("%@", "FlipStack demo screenshot \(ok ? "written" : "failed")")
                    NSApp.terminate(nil)
                } else if arguments.contains("--capture-studio"),
                          let path = Self.argumentValue("--capture-studio", in: arguments) {
                    self?.openStudioWindow()
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    _ = self?.studioWindow?.renderScreenshot(to: URL(fileURLWithPath: path))
                    NSLog("%@", "FlipStack studio screenshot written")
                    NSApp.terminate(nil)
                } else if arguments.contains("--open-studio") {
                    self?.openStudioWindow()
                } else {
                    menuBar?.present()
                }
                _ = self
            }
            return
        }

        // Useful for local UI review. It is not advertised in the app UI and
        // does not alter normal launch behavior.
        if let documentPath = Self.argumentValue("--open-document", in: arguments) {
            Task { await model.acceptDocument(url: URL(fileURLWithPath: documentPath)) }
        }

        if arguments.contains("--show-flip-setup") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak model] in
                model?.openFlipAxisSetup()
            }
        }

        if arguments.contains("--show-settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak model] in
                model?.openSettings()
            }
        }

        if arguments.contains("--show-preview") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak model] in
                model?.togglePreview()
            }
        }

        if arguments.contains("--open-panel") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak menuBar] in
                menuBar?.present()
            }
        }

        if arguments.contains("--open-studio") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                self?.openStudioWindow()
            }
        }

        if let capturePath {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak menuBar] in
                menuBar?.present()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                    let url = URL(fileURLWithPath: capturePath)
                    let scheme: ColorScheme = arguments.contains("--dark") ? .dark : .light
                    let customHeight: CGFloat? = Self.argumentValue("--panel-height", in: arguments).flatMap { Double($0) }.map { CGFloat($0) }
                    let ok = menuBar?.renderScreenshot(
                        to: url,
                        colorScheme: scheme,
                        largeText: arguments.contains("--large-text"),
                        height: customHeight ?? FlipMetrics.panelHeight
                    ) ?? false
                    NSLog("%@", "FlipStack screenshot \(ok ? "written" : "failed")")
                    NSApp.terminate(nil)
                }
            }
        }
    }

    private static func argumentValue(_ name: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }

    private func configureMainMenu(model: AppModel) {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem(title: "FlipStack", action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: "FlipStack")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)
        let settingsItem = NSMenuItem(
            title: L("Settings…"),
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: L("Quit FlipStack"),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        let fileItem = NSMenuItem(title: L("File"), action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: L("File"))
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        let openItem = NSMenuItem(
            title: L("Open PDF…"),
            action: #selector(openDocument),
            keyEquivalent: "o"
        )
        openItem.target = self
        fileMenu.addItem(openItem)

        let printItem = NSMenuItem(
            title: L("Print"),
            action: #selector(printDocument),
            keyEquivalent: "p"
        )
        printItem.target = self
        fileMenu.addItem(printItem)

        let editItem = NSMenuItem(title: L("Edit"), action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: L("Edit"))
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        editMenu.addItem(withTitle: L("Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: L("Redo"), action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: L("Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: L("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: L("Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: L("Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let viewItem = NSMenuItem(title: L("View"), action: nil, keyEquivalent: "")
        let viewMenu = NSMenu(title: L("View"))
        viewItem.submenu = viewMenu
        mainMenu.addItem(viewItem)
        let openWindowItem = NSMenuItem(
            title: L("Open FlipStack Window"),
            action: #selector(openStudioWindow),
            keyEquivalent: "n"
        )
        openWindowItem.target = self
        viewMenu.addItem(openWindowItem)
        viewMenu.addItem(.separator())
        let refreshItem = NSMenuItem(
            title: L("Refresh Printers"),
            action: #selector(refreshPrinters),
            keyEquivalent: "r"
        )
        refreshItem.target = self
        viewMenu.addItem(refreshItem)

        let windowItem = NSMenuItem(title: L("Window"), action: nil, keyEquivalent: "")
        let windowMenu = NSMenu(title: L("Window"))
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)
        windowMenu.addItem(withTitle: L("Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: L("Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    @objc private func openDocument() {
        model?.chooseDocument()
    }

    @objc private func printDocument() {
        model?.requestPrint()
    }

    @objc func openStudioWindow() {
        menuBar?.close()
        studioWindow?.show()
    }

    @objc func openSettingsFromMenu() {
        openSettings()
    }

    @objc private func openSettings() {
        model?.openSettings()
        if studioWindow?.window?.isVisible != true {
            menuBar?.present()
        }
    }

    @objc private func refreshPrinters() {
        Task { await model?.refreshAll() }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: { $0.pathExtension.lowercased() == "pdf" }) else { return }
        if let model {
            Task { await model.acceptDocument(url: url) }
        } else {
            pendingDocumentURL = url
        }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if flag {
            return true
        }
        if let studioWindow {
            studioWindow.show()
        } else {
            menuBar?.present()
        }
        return true
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let model else { return true }
        switch menuItem.action {
        case #selector(printDocument):
            return model.canPrint
        case #selector(openDocument):
            return !model.isPreparingPrint
                && !model.orchestrator.phase.isActive
                && !model.isShowingSettings
                && model.flipAxisSetup == nil
                && model.flipCalibration == nil
        case #selector(openStudioWindow):
            return studioWindow != nil
        case #selector(openSettings):
            return model.orchestrator.phase.isIdle
                && !model.isPreparingPrint
                && !model.isMaintenanceBusy
                && model.flipCalibration == nil
                && model.flipAxisSetup == nil
        case #selector(refreshPrinters):
            return !model.isLoadingPrinters
                && model.flipCalibration == nil
                && !model.orchestrator.phase.isActive
        default:
            return true
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        orchestrator?.cancel()
        model?.cancelFlipCalibration()
        model?.clearOpenPanelState()
        model?.cleanUpTemporaryFiles()
    }
}
