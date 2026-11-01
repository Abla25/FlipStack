import Foundation

/// The in-app language override. English is the source language; the app
/// bundle carries Italian, Spanish, and French `.lproj` resources.
public enum AppLanguage: String, CaseIterable, Codable, Sendable, Identifiable {
    case english = "en"
    case italian = "it"
    case spanish = "es"
    case french = "fr"

    public static let defaultsKey = "FlipStack.language"

    public var id: String { rawValue }

    public var locale: Locale {
        Locale(identifier: rawValue)
    }

    /// Native language name, deliberately not translated.
    public var displayName: String {
        switch self {
        case .english: return "English"
        case .italian: return "Italiano"
        case .spanish: return "Español"
        case .french: return "Français"
        }
    }

    public var shortCode: String {
        rawValue.uppercased()
    }

    public static var stored: AppLanguage {
        if let raw = UserDefaults.standard.string(forKey: defaultsKey),
           let saved = AppLanguage(rawValue: raw) {
            return saved
        }
        let preferred = Locale.preferredLanguages.first?.prefix(2).lowercased() ?? "en"
        return AppLanguage(rawValue: String(preferred)) ?? .english
    }

    /// Used by AppKit and by model-layer labels that are not SwiftUI
    /// `LocalizedStringKey`s. Reading the current language on every lookup
    /// keeps values correct after an in-app language switch.
    public static var current: AppLanguage = stored

    public func localized(_ key: String) -> String {
        guard self != .english else { return key }
        guard let path = Bundle.main.path(forResource: rawValue, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            return key
        }
        return bundle.localizedString(forKey: key, value: key, table: "Localizable")
    }
}

@inline(__always)
public func L(_ key: String) -> String {
    AppLanguage.current.localized(key)
}
