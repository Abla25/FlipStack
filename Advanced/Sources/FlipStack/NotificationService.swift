import Foundation
import UserNotifications
import FlipStackCore

/// Owns the interactive "flip the stack" notification and routes its actions
/// back into the app. If notifications are unavailable (for example when the
/// executable is run outside a signed app bundle), the popover still opens.
@MainActor
final class NotificationService: NSObject, DuplexNotifying {
    static let categoryIdentifier = "FLIPSTACK_FLIP"
    static let continueAction = "FLIPSTACK_CONTINUE"
    static let cancelAction = "FLIPSTACK_CANCEL"

    var onOpen: (() -> Void)?
    var onContinue: (() -> Void)?
    var onCancel: (() -> Void)?

    private var center: UNUserNotificationCenter?
    private var authorizationRequested = false
    private var authorizationGranted = false
    private var pendingFlipIdentifier: String?

    override init() {
        super.init()
        // `UNUserNotificationCenter.current()` is only meaningful for a real
        // app bundle. SwiftPM run/debug builds gracefully fall back to the
        // popover.
        if Bundle.main.bundleIdentifier != nil {
            let center = UNUserNotificationCenter.current()
            self.center = center
            center.delegate = self
            registerCategory(on: center)
        }
    }

    private func registerCategory(on center: UNUserNotificationCenter) {
        let continueAction = UNNotificationAction(
            identifier: Self.continueAction,
            title: L("Continue"),
            options: [.foreground]
        )
        let cancelAction = UNNotificationAction(
            identifier: Self.cancelAction,
            title: L("Cancel"),
            options: [.destructive]
        )
        let category = UNNotificationCategory(
            identifier: Self.categoryIdentifier,
            actions: [continueAction, cancelAction],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        center.setNotificationCategories([category])
    }

    func handle(_ event: DuplexNotificationEvent) {
        switch event {
        case .flipRequired(let prompt):
            // The popover is where the signature flip animation lives.
            onOpen?()
            ensureAuthorization { [weak self] in
                self?.postFlipNotification(prompt)
            }
        case .completed(_, let sheetCount):
            removeFlipNotification()
            guard authorizationGranted else { return }
            post(
                title: L("Printing complete"),
                body: String(format: L("FlipStack finished all %lld sheets."), sheetCount),
                identifier: "flipstack-complete-\(UUID().uuidString)",
                category: nil
            )
        case .failed(_, let failure):
            removeFlipNotification()
            guard authorizationGranted else { return }
            // Notification banners can be visible on a locked screen. Keep the
            // detail in the in-app surface rather than leaking queue or job text.
            post(
                title: failure.title,
                body: L("Open FlipStack for details."),
                identifier: "flipstack-failure-\(UUID().uuidString)",
                category: nil
            )
        case .canceled:
            removeFlipNotification()
        }
    }

    func clearFlipNotification() {
        removeFlipNotification()
    }

    func languageDidChange() {
        guard let center else { return }
        registerCategory(on: center)
    }

    private func ensureAuthorization(_ completion: @escaping () -> Void) {
        guard let center else { return }
        if authorizationGranted {
            completion()
            return
        }
        guard !authorizationRequested else { return }
        authorizationRequested = true
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            Task { @MainActor in
                guard let self else { return }
                self.authorizationGranted = granted
                if granted {
                    completion()
                }
            }
        }
    }

    private func postFlipNotification(_ prompt: FlipPrompt) {
        guard let center, authorizationGranted else { return }
        let content = UNMutableNotificationContent()
        content.title = prompt.title
        content.subtitle = "\(FlipFormat.sheets(prompt.sheetCount)) · FlipStack"
        content.body = prompt.message
        content.sound = .default
        content.categoryIdentifier = Self.categoryIdentifier

        let identifier = "flipstack-flip-\(UUID().uuidString)"
        pendingFlipIdentifier = identifier
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        )
        center.add(request)
    }

    private func post(title: String, body: String, identifier: String, category: String?) {
        guard let center, authorizationGranted else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let category { content.categoryIdentifier = category }
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        )
        center.add(request)
    }

    private func removeFlipNotification() {
        guard let center else { return }
        if let pendingFlipIdentifier {
            center.removeDeliveredNotifications(withIdentifiers: [pendingFlipIdentifier])
            center.removePendingNotificationRequests(withIdentifiers: [pendingFlipIdentifier])
        }
        pendingFlipIdentifier = nil
    }
}

extension NotificationService: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let action = response.actionIdentifier
        Task { @MainActor [weak self] in
            guard let self else {
                completionHandler()
                return
            }
            switch action {
            case Self.continueAction:
                self.onOpen?()
                self.onContinue?()
            case Self.cancelAction:
                self.onOpen?()
                self.onCancel?()
            case UNNotificationDefaultActionIdentifier:
                self.onOpen?()
            case UNNotificationDismissActionIdentifier:
                break
            default:
                break
            }
            self.removeFlipNotification()
            completionHandler()
        }
    }
}
