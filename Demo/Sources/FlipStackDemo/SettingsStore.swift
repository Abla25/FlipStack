import Foundation

// MARK: - Defaults keyspace

/// UserDefaults keys for the receipt app.
///
/// Deliberately namespaced under `FlipStack.demo.*`: the production bundle
/// identifier (`app.flipstack.FlipStack`) is shared with the older root app,
/// whose defaults domain already contains `FlipStack.printerPreferences.v1`,
/// `FlipStack.language`, … — those must never be reused or reinterpreted here.
private enum DemoStoreKey {
    static let schemaVersion = "FlipStack.demo.schemaVersion"
    static let appSettings = "FlipStack.demo.settings.v1"
    static let printerOptions = "FlipStack.demo.printerOptions.v1"
    static let lastPrinterID = "FlipStack.demo.lastPrinterID"
}

private enum DemoStoreSchema {
    /// Bump when the persisted shape changes in a way that needs migration.
    static let current = 1
    /// Per-printer records for queues we have not seen for this long are pruned.
    static let orphanRetention: TimeInterval = 90 * 24 * 60 * 60
    /// Hard cap on retained per-printer records (most recently used win).
    static let maxPrinterRecords = 40
}

// MARK: - App-level defaults (the Settings page)

/// App-wide defaults, one set per user (not per printer): the values the
/// Settings page edits and the fallbacks used when a printer has no saved
/// record of its own.
struct DemoAppSettings: Codable, Equatable {
    static let allowedQualities = ["draft", "normal", "high"]
    static let fallbackQuality = "high"

    var schemaVersion: Int = 1
    var language: AppLanguage = .en
    var defaultQuality: String = "high"

    static let standard = DemoAppSettings()

    /// Clamp persisted values to the supported set. Decoding is deliberately
    /// permissive; unknown strings that still decoded are normalised here.
    func validated() -> DemoAppSettings {
        var value = self
        value.schemaVersion = DemoStoreSchema.current
        if !DemoAppSettings.allowedQualities.contains(value.defaultQuality) {
            value.defaultQuality = DemoAppSettings.fallbackQuality
        }
        return value
    }
}

// MARK: - Per-printer last-used options

/// Last-used print options for one CUPS queue. Every option is restored when
/// that printer is selected again; missing/invalid records fall back to
/// `defaults(appDefaultQuality:)`.
struct DemoPrinterOptions: Codable, Equatable {
    static let allowedQualities = DemoAppSettings.allowedQualities
    static let allowedDuplexEdges = ["long", "short"]
    static let allowedPapers = ["A4", "A3", "Letter", "Photo 4×6"]
    static let allowedColorModes = ["Color", "B&W"]
    static let allowedOrientations = ["auto", "portrait", "landscape"]
    static let allowedMedia = ["Plain", "Glossy", "Photo", "Recycled"]
    static let allowedTrays = ["auto", "tray1", "tray2"]
    static let allowedResOverrides = ["off", "180", "366", "600"]
    static let minScale = 50
    static let maxScale = 150

    var schemaVersion: Int = 1
    var duplex: Bool
    var duplexEdge: String
    var paper: String
    var colorMode: String
    var quality: String
    var orientation: String
    var scale: Int
    var media: String
    var tray: String
    var resOverride: String
    var inkSave: Bool
    var lastUsedAt: Date

    /// First-launch values for a printer that has no record yet. They must stay
    /// in sync with `AppModel`'s hardcoded defaults (duplex on, A4, colour,
    /// auto orientation, 100 %, plain media, auto tray, no resolution override,
    /// ink save off) except `quality`, which comes from the app default.
    static func defaults(appDefaultQuality: String) -> DemoPrinterOptions {
        let quality = DemoAppSettings.allowedQualities.contains(appDefaultQuality)
            ? appDefaultQuality
            : DemoAppSettings.fallbackQuality
        return DemoPrinterOptions(
            duplex: true,
            duplexEdge: "long",
            paper: "A4",
            colorMode: "Color",
            quality: quality,
            orientation: "auto",
            scale: 100,
            media: "Plain",
            tray: "auto",
            resOverride: "off",
            inkSave: false,
            lastUsedAt: Date()
        )
    }

    /// Clamp every stored value to the supported set; never traps on bad data.
    /// `appDefaultQuality` is used when `quality` itself is unreadable.
    func validated(appDefaultQuality: String) -> DemoPrinterOptions {
        var value = self
        value.schemaVersion = DemoStoreSchema.current
        let qualityFallback = DemoAppSettings.allowedQualities.contains(appDefaultQuality)
            ? appDefaultQuality
            : DemoAppSettings.fallbackQuality
        value.duplexEdge = DemoPrinterOptions.allowedDuplexEdges.contains(value.duplexEdge) ? value.duplexEdge : "long"
        value.paper = DemoPrinterOptions.allowedPapers.contains(value.paper) ? value.paper : "A4"
        value.colorMode = DemoPrinterOptions.allowedColorModes.contains(value.colorMode) ? value.colorMode : "Color"
        value.quality = DemoPrinterOptions.allowedQualities.contains(value.quality) ? value.quality : qualityFallback
        value.orientation = DemoPrinterOptions.allowedOrientations.contains(value.orientation) ? value.orientation : "auto"
        value.scale = min(max(value.scale, DemoPrinterOptions.minScale), DemoPrinterOptions.maxScale)
        value.media = DemoPrinterOptions.allowedMedia.contains(value.media) ? value.media : "Plain"
        value.tray = DemoPrinterOptions.allowedTrays.contains(value.tray) ? value.tray : "auto"
        value.resOverride = DemoPrinterOptions.allowedResOverrides.contains(value.resOverride) ? value.resOverride : "off"
        return value
    }
}

// MARK: - Store

/// Small synchronous UserDefaults-backed store for the receipt app.
///
/// - Thread: call sites are main-thread (AppModel init / UI actions). The store
///   is **not** thread-safe by itself; keep calls on the main thread.
/// - Writes: `lastPrinterID` is immediate (a single small string); app settings
///   and per-printer options are coalesced and written after `debounce`
///   seconds, using `flush()` (called from the app's terminate hook) as the
///   synchronous "write everything pending now" path. Reads are
///   **read-your-writes**: pending values are returned until they hit disk.
/// - Corruption: unreadable/oversized/foreign JSON never throws; reads fall
///   back to standard defaults and leave the raw data untouched until the next
///   save.
/// - Testability: inject `UserDefaults(suiteName:)`; production passes
///   `UserDefaults.standard`.
final class DemoSettingsStore {
    private let defaults: UserDefaults
    private let debounce: TimeInterval
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    // Coalesced deferred writes: last value per key wins until `flush()`/timer.
    private var pendingAppSettings: DemoAppSettings?
    private var pendingPrinterOptions: [String: DemoPrinterOptions] = [:]
    private var pendingTimer: DispatchWorkItem?

    init(defaults: UserDefaults = .standard, debounce: TimeInterval = 0.4) {
        self.defaults = defaults
        self.debounce = max(0, debounce)
    }

    deinit {
        pendingTimer?.cancel()
    }

    // MARK: App-level settings

    func loadAppSettings() -> DemoAppSettings {
        // Read-your-writes: a change saved less than `debounce` seconds ago is
        // still in memory but not yet on disk; never hand back the stale value.
        if let pendingAppSettings { return pendingAppSettings }
        guard storedSchemaVersion <= DemoStoreSchema.current else { return .standard }
        guard
            let data = defaults.data(forKey: DemoStoreKey.appSettings),
            let decoded = try? decoder.decode(DemoAppSettings.self, from: data),
            decoded.schemaVersion <= DemoStoreSchema.current
        else { return .standard }
        return decoded.validated()
    }

    func saveAppSettings(_ settings: DemoAppSettings) {
        pendingAppSettings = settings.validated()
        scheduleFlush()
    }

    // MARK: Last printer

    /// The last printer the user explicitly selected (never overwritten by an
    /// automatic fallback, so a temporarily powered-off printer can return).
    var lastPrinterID: String? {
        get { defaults.string(forKey: DemoStoreKey.lastPrinterID) }
        set {
            let trimmed = newValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if trimmed.isEmpty {
                defaults.removeObject(forKey: DemoStoreKey.lastPrinterID)
            } else {
                defaults.set(trimmed, forKey: DemoStoreKey.lastPrinterID)
            }
        }
    }

    // MARK: Per-printer last-used options

    func loadOptions(for printerID: String, appDefaultQuality: String) -> DemoPrinterOptions {
        let fallback = DemoPrinterOptions.defaults(appDefaultQuality: appDefaultQuality)
        guard storedSchemaVersion <= DemoStoreSchema.current else { return fallback }
        guard let id = Self.normalizedPrinterID(printerID) else { return fallback }
        // Read-your-writes: coalesced (not yet flushed) saves take precedence.
        if let pending = pendingPrinterOptions[id] { return pending }
        guard
            let all = defaults.dictionary(forKey: DemoStoreKey.printerOptions) as? [String: Data],
            let data = all[id],
            let decoded = try? decoder.decode(DemoPrinterOptions.self, from: data),
            decoded.schemaVersion <= DemoStoreSchema.current
        else { return fallback }
        return decoded.validated(appDefaultQuality: appDefaultQuality)
    }

    /// Persist the last-used options for `printerID`. Empty/blank ids are
    /// ignored (no record is created for "no printer"). The caller supplies
    /// `lastUsedAt` as the snapshot time; the store does not restamp it.
    func saveOptions(_ options: DemoPrinterOptions, for printerID: String) {
        guard let id = Self.normalizedPrinterID(printerID) else { return }
        pendingPrinterOptions[id] = options.validated(appDefaultQuality: DemoAppSettings.fallbackQuality)
        scheduleFlush()
    }

    /// Drop corrupt records and unknown-printer records older than 90 days, then
    /// cap the store at 40 records (most recently used kept). Known printers are
    /// never pruned for age.
    func prunePrinterOptions(known: Set<String>) {
        flush() // always decide on the latest state, not a stale disk snapshot
        guard let all = defaults.dictionary(forKey: DemoStoreKey.printerOptions) as? [String: Data] else { return }
        let cutoff = Date().addingTimeInterval(-DemoStoreSchema.orphanRetention)
        var records: [(id: String, data: Data, lastUsedAt: Date)] = []
        for (id, data) in all {
            guard let decoded = try? decoder.decode(DemoPrinterOptions.self, from: data) else { continue }
            if !known.contains(id), decoded.lastUsedAt < cutoff { continue }
            records.append((id, data, decoded.lastUsedAt))
        }
        let kept = records
            .sorted { $0.lastUsedAt > $1.lastUsedAt }
            .prefix(DemoStoreSchema.maxPrinterRecords)
        var pruned: [String: Data] = [:]
        for record in kept {
            pruned[record.id] = record.data
        }
        defaults.set(pruned, forKey: DemoStoreKey.printerOptions)
    }

    // MARK: Flush / debounce

    /// Write all pending changes synchronously (app terminate hook).
    func flush() {
        pendingTimer?.cancel()
        pendingTimer = nil
        writePending()
    }

    private func scheduleFlush() {
        guard debounce > 0 else {
            writePending()
            return
        }
        pendingTimer?.cancel()
        let timer = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingTimer = nil
            self.writePending()
        }
        pendingTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: timer)
    }

    private func writePending() {
        guard pendingAppSettings != nil || !pendingPrinterOptions.isEmpty else { return }

        if let settings = pendingAppSettings {
            if let data = try? encoder.encode(settings) {
                defaults.set(data, forKey: DemoStoreKey.appSettings)
                pendingAppSettings = nil
            }
        }
        if !pendingPrinterOptions.isEmpty {
            var all = (defaults.dictionary(forKey: DemoStoreKey.printerOptions) as? [String: Data]) ?? [:]
            for (id, options) in pendingPrinterOptions {
                guard let data = try? encoder.encode(options) else { continue }
                all[id] = data
            }
            pendingPrinterOptions.removeAll()
            defaults.set(all, forKey: DemoStoreKey.printerOptions)
        }
        // Version marker is global: written together with the first payload, so
        // a first launch that only reads never creates keys.
        defaults.set(DemoStoreSchema.current, forKey: DemoStoreKey.schemaVersion)
    }

    // MARK: Helpers

    private var storedSchemaVersion: Int {
        defaults.object(forKey: DemoStoreKey.schemaVersion) as? Int ?? 0
    }

    private static func normalizedPrinterID(_ printerID: String) -> String? {
        let trimmed = printerID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
