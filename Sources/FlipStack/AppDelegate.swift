import AppKit
import FlipStackCore
import SwiftUI

/// FlipStack minimal — a menu-bar app focused exclusively on guided manual
/// duplex printing. The feature-rich implementation lives in Advanced/.
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

        let preferencesStore = PreferencesStore()
        let spooler = CUPSClient()
        let ppdProvider = PPDLoader()
        let statusProvider = IPPStatusClient()

        let notifications = NotificationService()
        let orchestrator = DuplexOrchestrator(spooler: spooler, notifier: notifications)
        let model = AppModel(
            spooler: spooler,
            ppdProvider: ppdProvider,
            statusProvider: statusProvider,
            preferencesStore: preferencesStore,
            orchestrator: orchestrator,
            printerDiscovery: CUPSDeviceDiscovery()
        )
        let menuBar = MenuBarController(model: model, orchestrator: orchestrator)
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

        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let documentPath = Self.argumentValue("--open-document", in: arguments) {
            Task { await model.acceptDocument(url: URL(fileURLWithPath: documentPath)) }
        }
        if let capturePath = Self.argumentValue("--capture-panel", in: arguments) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                let url = URL(fileURLWithPath: capturePath)
                _ = menuBar.renderScreenshot(to: url, height: FlipMetrics.panelHeight)
                NSApp.terminate(nil)
            }
        } else if arguments.contains("--open-panel") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                menuBar.present()
            }
        }
        #endif
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

        let openItem = NSMenuItem(
            title: L("Open File…"),
            action: #selector(openDocument),
            keyEquivalent: "o"
        )
        openItem.target = self
        appMenu.addItem(openItem)

        let printItem = NSMenuItem(
            title: L("Print Fronts…"),
            action: #selector(printDocument),
            keyEquivalent: "p"
        )
        printItem.target = self
        appMenu.addItem(printItem)

        appMenu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: L("Settings…"),
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        appMenu.addItem(settingsItem)

        let windowItem = NSMenuItem(
            title: L("Open FlipStack Window…"),
            action: #selector(openStudioWindow),
            keyEquivalent: "w"
        )
        windowItem.target = self
        appMenu.addItem(windowItem)

        let refreshItem = NSMenuItem(
            title: L("Refresh Printers"),
            action: #selector(refreshPrinters),
            keyEquivalent: "r"
        )
        refreshItem.target = self
        appMenu.addItem(refreshItem)

        appMenu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: L("Quit FlipStack"),
            action: #selector(NSApplication.terminate),
            keyEquivalent: "q"
        )
        appMenu.addItem(quitItem)

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
        guard let url = urls.first(where: { DocumentIngest.isAccepted($0) }) else { return }
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
