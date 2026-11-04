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
        XCTAssertEqual(PrintMath.selectedPageList(total: 5, pages: "custom", spec: "bogus"), [1, 2, 3, 4, 5])
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
    func testTogglePageIncluded() {
        let m = AppModel()
        m.docPages = 10
        XCTAssertEqual(m.includedSet, Set(1...10))
        m.togglePageIncluded(3)
        XCTAssertFalse(m.includedSet.contains(3))
        XCTAssertEqual(m.pagesSel, "custom")
        XCTAssertEqual(m.pageSpec, "1-2,4-10")
        m.togglePageIncluded(3)
        XCTAssertEqual(m.pagesSel, "all")
        XCTAssertEqual(m.pageSpec, "")
    }
    func testParseJobID() {
        XCTAssertEqual(Printing.parseJobID("request id is EPSON_ET_8550_Series-42 (1 file(s))"), 42)
        XCTAssertEqual(Printing.parseJobID("request id is CASA-7 (1 file(s))"), 7)
        XCTAssertNil(Printing.parseJobID("lp: error"))
    }
    func testResolutionChoicesParsing() {
        let out = "*Resolution: 360x360dpi 720x720dpi 1440x720dpi 5760x1440dpi\n*MediaType: Plain Photo Glossy\n"
        let c = Printing.parseResolutionChoices(out)
        XCTAssertEqual(c.map { $0.dpi }, [360, 720, 1440, 5760])
        XCTAssertEqual(c.last?.label, "5760x1440dpi")
    }
    func testPickGrayscalePPDChoices() {
        // Epson ESC/P-R (L1800/ET-8550): ColorModel choices are RGB + Mono — "Gray" is invalid there
        XCTAssertEqual(Printing.pickGrayscale(from: ["RGB", "Mono"]), "Mono")
        // HP: Gray is a real choice
        XCTAssertEqual(Printing.pickGrayscale(from: ["Gray", "Gray16", "DeviceGray", "RGB", "AdobeRGB"]), "Gray")
        XCTAssertEqual(Printing.pickGrayscale(from: []), "Gray")
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
        // dnssd resolved via endpoints map; unadvertised instance → nil (off)
        let eps = ["cfe92100-67c4": (host: "192.168.1.60", port: 631)]
        let d2 = NetworkProbe.target(for: "dnssd://EPSON%20ET-8550%20Series._ipps._tcp.local./?uuid=CFE92100-67C4", endpoints: eps)
        XCTAssertEqual(d2?.host, "192.168.1.60")
        XCTAssertNil(NetworkProbe.target(for: "dnssd://HP%20ENVY._ipp._tcp.local./?uuid=aaaaaaaa", endpoints: eps))
    }
}
