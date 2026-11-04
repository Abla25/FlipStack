import XCTest
@testable import FlipStackDemo

/// Tests for `DemoSettingsStore` (pure Foundation, injected UserDefaults suite).
///
/// Every test uses a unique suite and clears it in setUp/tearDown so the real
/// user defaults domain is never read or written.
final class SettingsStoreTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    private let settingsKey = "FlipStack.demo.settings.v1"
    private let printerOptionsKey = "FlipStack.demo.printerOptions.v1"
    private let lastPrinterKey = "FlipStack.demo.lastPrinterID"
    private let schemaKey = "FlipStack.demo.schemaVersion"

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "FlipStackDemoTests.SettingsStore.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults?.removePersistentDomain(forName: suiteName)
        defaults = nil
        try super.tearDownWithError()
    }

    // MARK: Helpers

    private func makeStore(debounce: TimeInterval = 0) -> DemoSettingsStore {
        DemoSettingsStore(defaults: defaults, debounce: debounce)
    }

    private func options(
        duplex: Bool = true,
        duplexEdge: String = "long",
        paper: String = "A4",
        colorMode: String = "Color",
        quality: String = "high",
        orientation: String = "auto",
        scale: Int = 100,
        media: String = "Plain",
        tray: String = "auto",
        resOverride: String = "off",
        inkSave: Bool = false,
        lastUsedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> DemoPrinterOptions {
        DemoPrinterOptions(
            duplex: duplex,
            duplexEdge: duplexEdge,
            paper: paper,
            colorMode: colorMode,
            quality: quality,
            orientation: orientation,
            scale: scale,
            media: media,
            tray: tray,
            resOverride: resOverride,
            inkSave: inkSave,
            lastUsedAt: lastUsedAt
        )
    }

    /// Write a raw per-printer record (bypasses `saveOptions`) so load-side
    /// validation/corruption paths can be exercised.
    private func writeRawPrinterRecord(_ data: Data, for id: String) {
        var all = (defaults.dictionary(forKey: printerOptionsKey) as? [String: Data]) ?? [:]
        all[id] = data
        defaults.set(all, forKey: printerOptionsKey)
    }

    private func rawPrinterRecords() -> [String: Data] {
        (defaults.dictionary(forKey: printerOptionsKey) as? [String: Data]) ?? [:]
    }

    // MARK: First launch

    func testFirstLaunchAppSettingsDefaults() {
        let store = makeStore()
        let settings = store.loadAppSettings()

        XCTAssertEqual(settings, .standard)
        XCTAssertEqual(settings.language, .en)
        XCTAssertEqual(settings.defaultQuality, "high")
        XCTAssertEqual(settings.schemaVersion, 1)
        XCTAssertNil(store.lastPrinterID)

        // Reading must never create keys (no write-on-first-launch).
        XCTAssertNil(defaults.object(forKey: settingsKey))
        XCTAssertNil(defaults.object(forKey: schemaKey))
        XCTAssertNil(defaults.object(forKey: lastPrinterKey))
    }

    func testFirstLaunchPrinterOptionsDefaults() {
        let store = makeStore()
        let loaded = store.loadOptions(for: "printer-1", appDefaultQuality: "draft")

        XCTAssertEqual(loaded.duplex, true)
        XCTAssertEqual(loaded.duplexEdge, "long")
        XCTAssertEqual(loaded.paper, "A4")
        XCTAssertEqual(loaded.colorMode, "Color")
        XCTAssertEqual(loaded.quality, "draft", "first launch quality must follow the app default")
        XCTAssertEqual(loaded.orientation, "auto")
        XCTAssertEqual(loaded.scale, 100)
        XCTAssertEqual(loaded.media, "Plain")
        XCTAssertEqual(loaded.tray, "auto")
        XCTAssertEqual(loaded.resOverride, "off")
        XCTAssertEqual(loaded.inkSave, false)
        XCTAssertEqual(loaded.schemaVersion, 1)
        XCTAssertNil(defaults.object(forKey: printerOptionsKey), "load must not create a record")
    }

    func testOptionsDefaultsClampInvalidAppDefaultQuality() {
        let loaded = DemoPrinterOptions.defaults(appDefaultQuality: "ultra")
        XCTAssertEqual(loaded.quality, "high")
        XCTAssertEqual(loaded.schemaVersion, 1)
    }

    // MARK: App settings round-trip / validation

    func testAppSettingsRoundTrip() throws {
        let store = makeStore()
        var settings = DemoAppSettings.standard
        settings.language = .it
        settings.defaultQuality = "draft"
        store.saveAppSettings(settings)
        store.flush()

        let raw = try XCTUnwrap(defaults.data(forKey: settingsKey))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
        XCTAssertEqual(object["language"] as? String, "it")
        XCTAssertEqual(object["defaultQuality"] as? String, "draft")
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        XCTAssertEqual(defaults.object(forKey: schemaKey) as? Int, 1)

        let reloaded = makeStore().loadAppSettings()
        XCTAssertEqual(reloaded, settings.validated())
    }

    func testInvalidDefaultQualityClampedOnLoad() {
        let store = makeStore()
        var settings = DemoAppSettings.standard
        settings.defaultQuality = "ultra"
        store.saveAppSettings(settings)
        store.flush()

        XCTAssertEqual(store.loadAppSettings().defaultQuality, "high")
    }

    func testCorruptAppSettingsFallbackAndRawDataKept() {
        let garbage = Data("not json".utf8)
        defaults.set(garbage, forKey: settingsKey)

        let store = makeStore()
        XCTAssertEqual(store.loadAppSettings(), .standard)
        XCTAssertEqual(defaults.data(forKey: settingsKey), garbage, "load must not overwrite corrupt data")
    }

    func testUnknownLanguageRawValueFallsBackToStandard() throws {
        // "xx" is not a valid AppLanguage raw value: the whole blob is unreadable.
        let json = #"{"schemaVersion":1,"language":"xx","defaultQuality":"draft"}"#
        defaults.set(try XCTUnwrap(json.data(using: .utf8)), forKey: settingsKey)
        XCTAssertEqual(makeStore().loadAppSettings(), .standard)
    }

    func testFutureSchemaBlobFallsBackToStandard() throws {
        var future = DemoAppSettings.standard
        future.schemaVersion = 2
        future.defaultQuality = "draft"
        let data = try JSONEncoder().encode(future)
        defaults.set(data, forKey: settingsKey)

        let store = makeStore()
        XCTAssertEqual(store.loadAppSettings(), .standard)
        XCTAssertEqual(defaults.data(forKey: settingsKey), data, "future data must be left untouched")
    }

    func testFutureGlobalSchemaFallsBackForEverything() throws {
        var future = DemoAppSettings.standard
        future.schemaVersion = 2
        defaults.set(try JSONEncoder().encode(future), forKey: settingsKey)
        let optionData = try JSONEncoder().encode(options(paper: "A3"))
        writeRawPrinterRecord(optionData, for: "printer-1")
        defaults.set(2, forKey: schemaKey) // e.g. written by a newer build

        let store = makeStore()
        XCTAssertEqual(store.loadAppSettings(), .standard)
        // Options also fall back because the global schema is unknown.
        let loaded = store.loadOptions(for: "printer-1", appDefaultQuality: "normal")
        XCTAssertEqual(loaded.paper, "A4")
        XCTAssertEqual(loaded.quality, "normal")
    }

    // MARK: Per-printer isolation

    func testPerPrinterOptionsAreIsolated() {
        let store = makeStore()
        store.saveOptions(options(duplex: false, duplexEdge: "short", paper: "A3", quality: "draft"), for: "printer-1")
        store.saveOptions(options(duplex: true, colorMode: "B&W", quality: "normal"), for: "printer-2")
        store.flush()

        let one = store.loadOptions(for: "printer-1", appDefaultQuality: "high")
        XCTAssertEqual(one.duplex, false)
        XCTAssertEqual(one.duplexEdge, "short")
        XCTAssertEqual(one.paper, "A3")
        XCTAssertEqual(one.quality, "draft")
        XCTAssertEqual(one.colorMode, "Color", "printer-2 values must not leak into printer-1")
        XCTAssertEqual(rawPrinterRecords().count, 2)

        let two = store.loadOptions(for: "printer-2", appDefaultQuality: "high")
        XCTAssertEqual(two.duplex, true)
        XCTAssertEqual(two.colorMode, "B&W")
        XCTAssertEqual(two.quality, "normal")
        XCTAssertEqual(two.paper, "A4")
        XCTAssertEqual(two.duplexEdge, "long")
    }

    func testPerPrinterRoundTripPreservesAllFields() throws {
        let store = makeStore()
        let original = options(
            duplex: false,
            duplexEdge: "short",
            paper: "Photo 4×6",
            colorMode: "B&W",
            quality: "normal",
            orientation: "landscape",
            scale: 125,
            media: "Glossy",
            tray: "tray2",
            resOverride: "366",
            inkSave: true,
            lastUsedAt: Date(timeIntervalSince1970: 1_700_123_456)
        )
        store.saveOptions(original, for: "queue-1")
        store.flush()

        XCTAssertEqual(store.loadOptions(for: "queue-1", appDefaultQuality: "draft"), original)
    }

    func testQualityOverrideBeatsAppDefaultOnLoad() {
        let store = makeStore()
        store.saveOptions(options(quality: "normal"), for: "p")
        store.flush()
        XCTAssertEqual(store.loadOptions(for: "p", appDefaultQuality: "draft").quality, "normal")
    }

    // MARK: Validation / clamping

    func testInvalidPersistedOptionsAreClamped() throws {
        let invalid = options(
            duplexEdge: "diagonal",
            paper: "Legal",
            colorMode: "Sepia",
            quality: "ultra",
            orientation: "sideways",
            scale: 999,
            media: "Vellum",
            tray: "manual",
            resOverride: "1200"
        )
        writeRawPrinterRecord(try JSONEncoder().encode(invalid), for: "p")

        let loaded = makeStore().loadOptions(for: "p", appDefaultQuality: "draft")
        XCTAssertEqual(loaded.duplex, true)
        XCTAssertEqual(loaded.duplexEdge, "long")
        XCTAssertEqual(loaded.paper, "A4")
        XCTAssertEqual(loaded.colorMode, "Color")
        XCTAssertEqual(loaded.quality, "draft", "invalid quality falls back to the app default")
        XCTAssertEqual(loaded.orientation, "auto")
        XCTAssertEqual(loaded.scale, 150)
        XCTAssertEqual(loaded.media, "Plain")
        XCTAssertEqual(loaded.tray, "auto")
        XCTAssertEqual(loaded.resOverride, "off")
        XCTAssertEqual(loaded.schemaVersion, 1)
    }

    func testScaleIsClampedToLowerBoundToo() throws {
        let invalid = options(scale: 10)
        writeRawPrinterRecord(try JSONEncoder().encode(invalid), for: "p")
        XCTAssertEqual(makeStore().loadOptions(for: "p", appDefaultQuality: "high").scale, 50)
    }

    func testInvalidOptionsAreValidatedOnSaveToo() {
        let store = makeStore()
        store.saveOptions(options(paper: "Legal", quality: "ultra", scale: 999), for: "p")
        store.flush()

        let loaded = store.loadOptions(for: "p", appDefaultQuality: "normal")
        XCTAssertEqual(loaded.quality, "high", "invalid quality normalises to the fallback quality on save")
        XCTAssertEqual(loaded.scale, 150)
        XCTAssertEqual(loaded.paper, "A4")
    }

    // MARK: Corrupt / future per-printer data

    func testCorruptPrinterOptionsFallBackToDefaults() {
        writeRawPrinterRecord(Data("garbage".utf8), for: "p")
        let loaded = makeStore().loadOptions(for: "p", appDefaultQuality: "draft")
        XCTAssertEqual(loaded.quality, "draft")
        XCTAssertEqual(loaded.paper, "A4")
        XCTAssertEqual(loaded.duplex, true)
    }

    func testFuturePerPrinterSchemaFallsBackToDefaults() throws {
        var future = options(paper: "A3", quality: "draft")
        future.schemaVersion = 2
        writeRawPrinterRecord(try JSONEncoder().encode(future), for: "p")

        let loaded = makeStore().loadOptions(for: "p", appDefaultQuality: "normal")
        XCTAssertEqual(loaded.paper, "A4", "record from a future schema is ignored")
        XCTAssertEqual(loaded.quality, "normal")
    }

    // MARK: lastPrinterID

    func testLastPrinterIDIsImmediateAndClears() {
        let store = makeStore(debounce: 10)
        XCTAssertNil(store.lastPrinterID)

        store.lastPrinterID = "EPSON_L1800_Series"
        XCTAssertEqual(defaults.string(forKey: lastPrinterKey), "EPSON_L1800_Series", "must be written immediately")
        XCTAssertEqual(store.lastPrinterID, "EPSON_L1800_Series")
        XCTAssertNil(defaults.object(forKey: schemaKey), "immediate id write must not stamp the schema")

        store.lastPrinterID = "   "
        XCTAssertNil(store.lastPrinterID)
        XCTAssertNil(defaults.string(forKey: lastPrinterKey))

        store.lastPrinterID = "CASA"
        store.lastPrinterID = nil
        XCTAssertNil(store.lastPrinterID)
    }

    // MARK: Empty printer ids

    func testEmptyPrinterIDIsIgnored() {
        let store = makeStore()
        store.saveOptions(options(), for: "")
        store.saveOptions(options(), for: "   ")
        store.flush()

        XCTAssertNil(defaults.object(forKey: printerOptionsKey), "no record may be created for an empty queue id")
        let loaded = store.loadOptions(for: "", appDefaultQuality: "normal")
        XCTAssertEqual(loaded.quality, "normal")
    }

    func testPrinterIDsAreTrimmed() {
        let store = makeStore()
        store.saveOptions(options(paper: "A3"), for: "  EPSON_L1800_Series  ")
        store.flush()

        XCTAssertEqual(rawPrinterRecords().keys.first, "EPSON_L1800_Series")
        XCTAssertEqual(store.loadOptions(for: "EPSON_L1800_Series", appDefaultQuality: "high").paper, "A3")
    }

    // MARK: Debounce / flush

    func testDebounceDefersWritesUntilFlush() {
        let store = makeStore(debounce: 10)
        var settings = DemoAppSettings.standard
        settings.language = .it
        store.saveAppSettings(settings)
        store.saveOptions(options(paper: "A3"), for: "p")

        XCTAssertNil(defaults.object(forKey: settingsKey))
        XCTAssertNil(defaults.object(forKey: printerOptionsKey))

        store.flush()

        XCTAssertNotNil(defaults.data(forKey: settingsKey))
        XCTAssertEqual(store.loadAppSettings().language, .it)
        XCTAssertEqual(store.loadOptions(for: "p", appDefaultQuality: "high").paper, "A3")
        XCTAssertEqual(defaults.object(forKey: schemaKey) as? Int, 1)
    }

    func testDebounceCoalescesLatestValuePerKey() {
        let store = makeStore(debounce: 10)
        var first = DemoAppSettings.standard
        first.defaultQuality = "draft"
        var second = DemoAppSettings.standard
        second.defaultQuality = "normal"

        store.saveAppSettings(first)
        store.saveAppSettings(second)
        store.saveOptions(options(paper: "A3"), for: "p")
        store.saveOptions(options(paper: "Photo 4×6"), for: "p")
        store.saveOptions(options(paper: "Letter"), for: "other")
        store.flush()

        XCTAssertEqual(store.loadAppSettings().defaultQuality, "normal", "latest app settings win")
        XCTAssertEqual(store.loadOptions(for: "p", appDefaultQuality: "high").paper, "Photo 4×6", "latest options win per printer")
        XCTAssertEqual(store.loadOptions(for: "other", appDefaultQuality: "high").paper, "Letter", "different printers survive one flush")
        XCTAssertEqual(rawPrinterRecords().count, 2)
    }

    func testDebounceTimerWritesWithoutExplicitFlush() {
        let store = makeStore(debounce: 0.05)
        var settings = DemoAppSettings.standard
        settings.defaultQuality = "draft"
        store.saveAppSettings(settings)

        let written = expectation(description: "debounced write lands on the main queue")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { written.fulfill() }
        wait(for: [written], timeout: 2)

        XCTAssertEqual(store.loadAppSettings().defaultQuality, "draft")
    }

    func testZeroDebounceWritesSynchronously() {
        let store = makeStore(debounce: 0)
        store.saveOptions(options(paper: "A3"), for: "p")
        XCTAssertNotNil(defaults.object(forKey: printerOptionsKey), "debounce 0 must write immediately")
    }

    func testReadYourWritesBeforeFlush() {
        let store = makeStore(debounce: 10)
        var settings = DemoAppSettings.standard
        settings.language = .it
        store.saveAppSettings(settings)
        store.saveOptions(options(paper: "A3"), for: "p")

        // Simulates Model.refreshPrinters() re-reading state while a debounced
        // save is still pending: it must not revert the user's latest change.
        XCTAssertEqual(store.loadAppSettings().language, .it)
        XCTAssertEqual(store.loadOptions(for: "p", appDefaultQuality: "high").paper, "A3")

        store.flush()
        XCTAssertEqual(store.loadAppSettings().language, .it)
        XCTAssertEqual(store.loadOptions(for: "p", appDefaultQuality: "high").paper, "A3")
    }

    func testReadYourWritesDoesNotLeakAcrossPrinters() {
        let store = makeStore(debounce: 10)
        store.saveOptions(options(paper: "A3"), for: "p1")
        XCTAssertEqual(store.loadOptions(for: "p2", appDefaultQuality: "high").paper, "A4")
        XCTAssertEqual(store.loadOptions(for: "p1", appDefaultQuality: "high").paper, "A3")
    }

    // MARK: Prune

    func testPruneDropsOldOrphansAndCorruptRecords() throws {
        let now = Date()
        let knownOld = options(lastUsedAt: now.addingTimeInterval(-200 * 86_400))
        let unknownOld = options(lastUsedAt: now.addingTimeInterval(-120 * 86_400))
        let unknownRecent = options(lastUsedAt: now.addingTimeInterval(-1 * 86_400))

        var all: [String: Data] = [:]
        all["knownOld"] = try JSONEncoder().encode(knownOld)
        all["unknownOld"] = try JSONEncoder().encode(unknownOld)
        all["unknownRecent"] = try JSONEncoder().encode(unknownRecent)
        all["corrupt"] = Data("not json".utf8)
        defaults.set(all, forKey: printerOptionsKey)

        makeStore().prunePrinterOptions(known: ["knownOld"])

        let ids = Set(rawPrinterRecords().keys)
        XCTAssertEqual(ids, ["knownOld", "unknownRecent"])
    }

    func testPruneCapsAtFortyKeepingNewest() throws {
        let now = Date()
        var all: [String: Data] = [:]
        for index in 0..<45 {
            let record = options(lastUsedAt: now.addingTimeInterval(-Double(index) * 60))
            all["p\(index)"] = try JSONEncoder().encode(record)
        }
        defaults.set(all, forKey: printerOptionsKey)

        makeStore().prunePrinterOptions(known: Set(all.keys))

        let records = rawPrinterRecords()
        XCTAssertEqual(records.count, 40)
        for index in 0..<40 {
            XCTAssertNotNil(records["p\(index)"], "newest 40 records must be kept")
        }
        for index in 40..<45 {
            XCTAssertNil(records["p\(index)"], "oldest records must be dropped")
        }
    }

    func testPruneFlushesPendingWritesFirst() {
        let store = makeStore(debounce: 10)
        store.saveOptions(options(paper: "A3", lastUsedAt: Date()), for: "known")
        store.prunePrinterOptions(known: ["known"])

        XCTAssertEqual(store.loadOptions(for: "known", appDefaultQuality: "high").paper, "A3")
        XCTAssertEqual(rawPrinterRecords().count, 1)
    }

    // MARK: Standard contract values

    func testStandardSettingsContract() {
        let settings = DemoAppSettings.standard
        XCTAssertEqual(settings.language, .en)
        XCTAssertEqual(settings.defaultQuality, "high")
        XCTAssertEqual(settings.schemaVersion, 1)
        XCTAssertEqual(DemoAppSettings.allowedQualities, ["draft", "normal", "high"])
    }

    func testEmptyStoreLoadsAreSideEffectFree() {
        let store = makeStore()
        _ = store.loadAppSettings()
        _ = store.loadOptions(for: "p", appDefaultQuality: "draft")
        store.flush() // nothing pending → must not write anything

        XCTAssertNil(defaults.object(forKey: settingsKey))
        XCTAssertNil(defaults.object(forKey: printerOptionsKey))
        XCTAssertNil(defaults.object(forKey: lastPrinterKey))
        XCTAssertNil(defaults.object(forKey: schemaKey))
    }
}
