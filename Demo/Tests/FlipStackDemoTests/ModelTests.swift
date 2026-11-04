import XCTest
@testable import FlipStackDemo

final class PrintMathTests: XCTestCase {
    func testSelectedPages() {
        XCTAssertEqual(PrintMath.selectedPages(total: 24, pages: "all"), 24)
        XCTAssertEqual(PrintMath.selectedPages(total: 24, pages: "odd"), 12)
        XCTAssertEqual(PrintMath.selectedPages(total: 24, pages: "even"), 12)
        XCTAssertEqual(PrintMath.selectedPages(total: 25, pages: "odd"), 13)
        XCTAssertEqual(PrintMath.selectedPages(total: 25, pages: "even"), 12)
    }

    func testSheetsDuplexMath() {
        XCTAssertEqual(PrintMath.sheets(pages: 24, duplex: true, copies: 1), 12)
        XCTAssertEqual(PrintMath.sheets(pages: 24, duplex: false, copies: 1), 24)
        XCTAssertEqual(PrintMath.sheets(pages: 25, duplex: true, copies: 1), 13)
        XCTAssertEqual(PrintMath.sheets(pages: 24, duplex: true, copies: 2), 24)
        XCTAssertEqual(PrintMath.totalSheets(pages: 3, copies: 3, duplex: true), 6)
    }

    func testDpiOverrideWins() {
        XCTAssertEqual(PrintMath.dpi(quality: "high", resOverride: "off"), 600)
        XCTAssertEqual(PrintMath.dpi(quality: "draft", resOverride: "off"), 180)
        XCTAssertEqual(PrintMath.dpi(quality: "normal", resOverride: "off"), 366)
        XCTAssertEqual(PrintMath.dpi(quality: "high", resOverride: "180"), 180)
    }

    func testPageRanges() {
        XCTAssertEqual(PrintMath.pageRange(pages: 6, side: "odd"), "1,3,5")
        XCTAssertEqual(PrintMath.pageRange(pages: 6, side: "even"), "2,4,6")
        XCTAssertEqual(PrintMath.pageRange(pages: 5, side: "even"), "2,4")
        XCTAssertEqual(PrintMath.pageRange(pages: 1, side: "odd"), "1")
        XCTAssertEqual(PrintMath.pageRange(pages: 1, side: "even"), "")
    }

    func testQualityLevel() {
        XCTAssertEqual(PrintMath.qualityLevel("draft"), 3)
        XCTAssertEqual(PrintMath.qualityLevel("normal"), 4)
        XCTAssertEqual(PrintMath.qualityLevel("high"), 5)
    }

    func testIsPhoto() {
        XCTAssertTrue(PrintMath.isPhoto("holiday.HEIC"))
        XCTAssertTrue(PrintMath.isPhoto("a.jpg"))
        XCTAssertFalse(PrintMath.isPhoto("doc.pdf"))
        XCTAssertFalse(PrintMath.isPhoto("notes.docx"))
    }

    func testParsePageSpec() {
        XCTAssertEqual(PrintMath.parsePageSpec("1-5, 8, 12-14", total: 24), [1, 2, 3, 4, 5, 8, 12, 13, 14])
        XCTAssertEqual(PrintMath.parsePageSpec("3,3,1-2", total: 10), [1, 2, 3])
        XCTAssertEqual(PrintMath.parsePageSpec("20-99", total: 24), [20, 21, 22, 23, 24])
        XCTAssertEqual(PrintMath.parsePageSpec("abc,,", total: 24), [])
        XCTAssertEqual(PrintMath.parsePageSpec("", total: 24), [])
        XCTAssertEqual(PrintMath.parsePageSpec(" 4 , 6 ", total: 8), [4, 6])
    }

    /// Regression for the v1.0.1 crash: `for i in a...min(b, total)` trapped
    /// with "Range requires lowerBound <= upperBound" when the range start was
    /// past the end of the document (e.g. "5-9" on a 3-page file).
    func testParsePageSpecNeverTraps() {
        XCTAssertEqual(PrintMath.parsePageSpec("5-9", total: 3), [])
        XCTAssertEqual(PrintMath.parsePageSpec("1-9", total: 0), [])
        XCTAssertEqual(PrintMath.parsePageSpec("999", total: 10), [])
        XCTAssertEqual(PrintMath.parsePageSpec("0-2", total: 10), [])
        XCTAssertEqual(PrintMath.parsePageSpec("9-5", total: 10), [])
        XCTAssertEqual(PrintMath.parsePageSpec("-", total: 10), [])
        XCTAssertEqual(PrintMath.parsePageSpec("1-", total: 10), [])
        XCTAssertEqual(PrintMath.parsePageSpec("1-3,99", total: 5), [1, 2, 3])
    }

    func testCompressRange() {
        XCTAssertEqual(PrintMath.compressRange([1, 2, 3, 5, 7, 8, 9]), "1-3,5,7-9")
        XCTAssertEqual(PrintMath.compressRange([]), "")
        XCTAssertEqual(PrintMath.compressRange([4]), "4")
    }

    func testSelectedPageList() {
        XCTAssertEqual(PrintMath.selectedPageList(total: 6, pages: "all", spec: ""), [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(PrintMath.selectedPageList(total: 6, pages: "odd", spec: ""), [1, 3, 5])
        XCTAssertEqual(PrintMath.selectedPageList(total: 6, pages: "even", spec: ""), [2, 4, 6])
        XCTAssertEqual(PrintMath.selectedPageList(total: 24, pages: "custom", spec: "2-4, 10"), [2, 3, 4, 10])
        // v1.0.2: an invalid custom spec selects NOTHING (it used to print all).
        XCTAssertEqual(PrintMath.selectedPageList(total: 5, pages: "custom", spec: "bogus"), [])
        XCTAssertEqual(PrintMath.selectedPageList(total: 0, pages: "all", spec: ""), [])
    }

    func testFrontsAndBacks() {
        XCTAssertEqual(PrintMath.frontsAndBacks([1, 2, 3, 4, 5, 6]).fronts, [1, 3, 5])
        XCTAssertEqual(PrintMath.frontsAndBacks([1, 2, 3, 4, 5, 6]).backs, [2, 4, 6])
        XCTAssertEqual(PrintMath.frontsAndBacks([1, 2, 3]).fronts, [1, 3])
        XCTAssertEqual(PrintMath.frontsAndBacks([1, 2, 3]).backs, [2])
        XCTAssertEqual(PrintMath.frontsAndBacks([]).fronts, [])
        XCTAssertEqual(PrintMath.frontsAndBacks([]).backs, [])
    }

    func testQualityLevelForDPI() {
        XCTAssertEqual(PrintMath.qualityLevel(forDPI: 180), 3)
        XCTAssertEqual(PrintMath.qualityLevel(forDPI: 366), 4)
        XCTAssertEqual(PrintMath.qualityLevel(forDPI: 600), 5)
        XCTAssertEqual(PrintMath.qualityLevel(forDPI: 300), 4)
    }

    func testFitScale() {
        XCTAssertEqual(PrintMath.fitScale(sheetW: 200, sheetH: 283, pageW: 595, pageH: 842), 200.0 / 595.0, accuracy: 0.0001)
        XCTAssertEqual(PrintMath.fitScale(sheetW: 100, sheetH: 100, pageW: 50, pageH: 200), 0.5, accuracy: 0.0001)
        XCTAssertEqual(PrintMath.fitScale(sheetW: 100, sheetH: 100, pageW: 0, pageH: 0), 1.0)
    }

    func testPaperMediaAndSizes() {
        XCTAssertEqual(PrintMath.paperMediaName("A4"), "iso_a4_210x297mm")
        XCTAssertEqual(PrintMath.paperMediaName("A3"), "iso_a3_297x420mm")
        XCTAssertEqual(PrintMath.paperMediaName("Letter"), "na_letter_8.5x11in")
        XCTAssertEqual(PrintMath.paperMediaName("Photo 4×6"), "na_index-4x6_4x6in")
        XCTAssertEqual(PrintMath.paperMediaName("unknown"), "iso_a4_210x297mm")
        XCTAssertEqual(PrintMath.paperSizePoints("A4"), PrintMath.Size(width: 595, height: 842))
        XCTAssertEqual(PrintMath.paperSizePoints("A3").width, 842)
    }

    func testEffectiveScaleFitsOversizedAndPhotos() {
        let a4 = PrintMath.Size(width: 595, height: 842)
        // A4 page on A4 paper keeps the user's scale.
        XCTAssertEqual(PrintMath.effectiveScale(paper: "A4", pageSize: a4, userScale: 100), 100)
        XCTAssertEqual(PrintMath.effectiveScale(paper: "A4", pageSize: a4, userScale: 50), 50)
        // An A3 PDF on A4 paper is scaled down to fit (was clipped before).
        let a3 = PrintMath.Size(width: 842, height: 1191)
        XCTAssertEqual(PrintMath.effectiveScale(paper: "A4", pageSize: a3, userScale: 100), 70)
        // A 12 MP photo (4032×3024 pt page) fits the A4 sheet.
        let photo = PrintMath.Size(width: 4032, height: 3024)
        XCTAssertEqual(PrintMath.effectiveScale(paper: "A4", pageSize: photo, userScale: 100), 14)
        // Unknown page size: keep the requested scale.
        XCTAssertEqual(PrintMath.effectiveScale(paper: "A4", pageSize: nil, userScale: 85), 85)
    }

    func testOrientationHelpers() {
        XCTAssertEqual(PrintMath.detectedOrientation(pageSize: .init(width: 842, height: 595)), "landscape")
        XCTAssertEqual(PrintMath.detectedOrientation(pageSize: .init(width: 595, height: 842)), "portrait")
        XCTAssertEqual(PrintMath.orientationRequested(orientation: "auto", pageSize: .init(width: 595, height: 842)), 3)
        XCTAssertEqual(PrintMath.orientationRequested(orientation: "auto", pageSize: .init(width: 842, height: 595)), 4)
        XCTAssertEqual(PrintMath.orientationRequested(orientation: "portrait", pageSize: nil), 3)
        XCTAssertEqual(PrintMath.orientationRequested(orientation: "landscape", pageSize: nil), 4)
        XCTAssertNil(PrintMath.orientationRequested(orientation: "auto", pageSize: nil))
        XCTAssertEqual(PrintMath.backsOrientationRequested(fronts: 3, shortEdge: true), 5)
        XCTAssertEqual(PrintMath.backsOrientationRequested(fronts: 4, shortEdge: true), 6)
        XCTAssertEqual(PrintMath.backsOrientationRequested(fronts: 3, shortEdge: false), 3)
    }

    func testParseDnssd() {
        let parsed = NetworkProbe.parseDnssd("dnssd://EPSON%20ET-8550%20Series._ipps._tcp.local./?uuid=CFE92100-67C4")
        XCTAssertEqual(parsed?.instance, "EPSON ET-8550 Series")
        XCTAssertEqual(parsed?.type, "_ipps._tcp")
        XCTAssertEqual(parsed?.domain, "local")
        XCTAssertEqual(parsed?.uuid, "cfe92100-67c4")
        XCTAssertNil(NetworkProbe.parseDnssd("usb://EPSON/L1800?serial=123"))
        let s = NetworkProbe.target(for: "socket://192.168.1.50:9100", endpoints: [:])
        XCTAssertEqual(s?.host, "192.168.1.50")
        XCTAssertEqual(s?.port, 9100)
        XCTAssertNil(NetworkProbe.target(for: "usb://EPSON/L1800?serial=1", endpoints: [:]))
        let eps = ["cfe92100-67c4": (host: "192.168.1.60", port: 631)]
        let d2 = NetworkProbe.target(for: "dnssd://EPSON%20ET-8550%20Series._ipps._tcp.local./?uuid=CFE92100-67C4", endpoints: eps)
        XCTAssertEqual(d2?.host, "192.168.1.60")
        XCTAssertNil(NetworkProbe.target(for: "dnssd://HP%20ENVY._ipp._tcp.local./?uuid=aaaaaaaa", endpoints: eps))
    }
}

@MainActor
final class AppModelTests: XCTestCase {
    private func makeIsolatedModel() -> (AppModel, String) {
        let suiteName = "FlipStackTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let model = AppModel(store: DemoSettingsStore(defaults: defaults, debounce: 0))
        return (model, suiteName)
    }

    func testTogglePageIncluded() {
        let (model, suiteName) = makeIsolatedModel()
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        model.docPages = 10
        XCTAssertEqual(model.includedSet, Set(1...10))
        model.togglePageIncluded(3)
        XCTAssertFalse(model.includedSet.contains(3))
        XCTAssertEqual(model.pagesSel, "custom")
        XCTAssertEqual(model.pageSpec, "1-2,4-10")
        model.togglePageIncluded(3)
        XCTAssertEqual(model.pagesSel, "all")
        XCTAssertEqual(model.pageSpec, "")
    }

    func testModelLoadsPersistedDefaultsAndLanguageAtLaunch() {
        let (_, suiteName) = makeIsolatedModel()
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        let defaults = UserDefaults(suiteName: suiteName)!
        let store = DemoSettingsStore(defaults: defaults, debounce: 0)
        var settings = store.loadAppSettings()
        settings.defaultQuality = "normal"
        settings.language = .it
        store.saveAppSettings(settings)
        store.flush()
        defer { L10n.current = .en }

        let model = AppModel(store: DemoSettingsStore(defaults: defaults, debounce: 0))
        XCTAssertEqual(model.settings.defaultQuality, "normal")
        XCTAssertEqual(model.quality, "normal")
        XCTAssertEqual(model.settings.language, .it)
        XCTAssertEqual(L10n.current, .it)
    }

    func testCanPrintRequiresDocumentAndPrinterAndPages() {
        let (model, suiteName) = makeIsolatedModel()
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        XCTAssertFalse(model.canPrint)
        model.docURL = URL(fileURLWithPath: "/tmp/x.pdf")
        model.docPages = 4
        XCTAssertFalse(model.canPrint) // no printable URL / printer yet
    }
}
