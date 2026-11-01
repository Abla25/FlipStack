import Foundation
import FlipStackCore

enum PageOrientationChoice: String, CaseIterable, Identifiable, Codable, Sendable {
    case automatic
    case portrait
    case landscape

    var id: String { rawValue }

    var label: String {
        switch self {
        case .automatic: return L("Match PDF")
        case .portrait: return L("Portrait")
        case .landscape: return L("Landscape")
        }
    }
}

struct PrintLayoutPreferences: Codable, Equatable, Sendable {
    var pageOrientation: PageOrientationChoice
    var fitToPage: Bool
    var scalePercent: Int

    static let standard = PrintLayoutPreferences(
        pageOrientation: .automatic,
        fitToPage: true,
        scalePercent: 100
    )

    init(
        pageOrientation: PageOrientationChoice,
        fitToPage: Bool,
        scalePercent: Int = 100
    ) {
        self.pageOrientation = pageOrientation
        self.fitToPage = fitToPage
        self.scalePercent = min(max(scalePercent, 50), 150)
    }

    private enum CodingKeys: String, CodingKey {
        case pageOrientation
        case forceLandscape
        case fitToPage
        case scalePercent
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if let raw = try values.decodeIfPresent(String.self, forKey: .pageOrientation),
           let saved = PageOrientationChoice(rawValue: raw) {
            pageOrientation = saved
        } else {
            // Migrate layouts saved before the three-way orientation choice.
            pageOrientation = try values.decodeIfPresent(Bool.self, forKey: .forceLandscape) == true
                ? .landscape
                : .automatic
        }
        fitToPage = try values.decodeIfPresent(Bool.self, forKey: .fitToPage) ?? true
        scalePercent = min(
            max(try values.decodeIfPresent(Int.self, forKey: .scalePercent) ?? 100, 50),
            150
        )
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(pageOrientation.rawValue, forKey: .pageOrientation)
        try values.encode(fitToPage, forKey: .fitToPage)
        try values.encode(scalePercent, forKey: .scalePercent)
    }
}

protocol PreferencesStoring: AnyObject {
    var lastPrinterID: String? { get set }
    var lastPrintMode: PrintMode? { get set }
    func load(for printerID: String) -> PrinterPreferences
    func save(_ preferences: PrinterPreferences, for printerID: String)
    func loadOptionChoices(for printerID: String) -> [String: String]
    func saveOptionChoices(_ choices: [String: String], for printerID: String)
    func loadLayout(for printerID: String) -> PrintLayoutPreferences
    func saveLayout(_ layout: PrintLayoutPreferences, for printerID: String)
}

final class PreferencesStore: PreferencesStoring {
    private let defaults: UserDefaults
    private let preferencesKey = "FlipStack.printerPreferences.v1"
    private let optionsKey = "FlipStack.printerOptions.v1"
    private let layoutKey = "FlipStack.printLayout.v1"
    private let lastPrinterKey = "FlipStack.lastPrinterID"
    private let lastModeKey = "FlipStack.lastPrintMode.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var lastPrinterID: String? {
        get { defaults.string(forKey: lastPrinterKey) }
        set { defaults.set(newValue, forKey: lastPrinterKey) }
    }

    var lastPrintMode: PrintMode? {
        get {
            guard let raw = defaults.string(forKey: lastModeKey) else { return nil }
            return PrintMode(rawValue: raw)
        }
        set {
            if let newValue {
                defaults.set(newValue.rawValue, forKey: lastModeKey)
            } else {
                defaults.removeObject(forKey: lastModeKey)
            }
        }
    }

    func load(for printerID: String) -> PrinterPreferences {
        guard
            let all = defaults.dictionary(forKey: preferencesKey) as? [String: Data],
            let data = all[printerID],
            let decoded = try? JSONDecoder().decode(PrinterPreferences.self, from: data)
        else {
            return .unconfigured
        }
        return decoded
    }

    func save(_ preferences: PrinterPreferences, for printerID: String) {
        var all = (defaults.dictionary(forKey: preferencesKey) as? [String: Data]) ?? [:]
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        all[printerID] = data
        defaults.set(all, forKey: preferencesKey)
    }

    func loadOptionChoices(for printerID: String) -> [String: String] {
        guard
            let all = defaults.dictionary(forKey: optionsKey) as? [String: Data],
            let data = all[printerID],
            let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        else {
            return [:]
        }
        return decoded
    }

    func saveOptionChoices(_ choices: [String: String], for printerID: String) {
        var all = (defaults.dictionary(forKey: optionsKey) as? [String: Data]) ?? [:]
        guard let data = try? JSONEncoder().encode(choices) else { return }
        all[printerID] = data
        defaults.set(all, forKey: optionsKey)
    }

    func loadLayout(for printerID: String) -> PrintLayoutPreferences {
        guard
            let all = defaults.dictionary(forKey: layoutKey) as? [String: Data],
            let data = all[printerID],
            let decoded = try? JSONDecoder().decode(PrintLayoutPreferences.self, from: data)
        else {
            return .standard
        }
        return decoded
    }

    func saveLayout(_ layout: PrintLayoutPreferences, for printerID: String) {
        var all = (defaults.dictionary(forKey: layoutKey) as? [String: Data]) ?? [:]
        guard let data = try? JSONEncoder().encode(layout) else { return }
        all[printerID] = data
        defaults.set(all, forKey: layoutKey)
    }




}
