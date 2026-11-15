import XCTest
import PDFKit
import FlipStackCore
@testable import FlipStackDemo

/// End-to-end tests of the new manual-duplex flow:
/// fronts are spooled → the flip prompt appears immediately (ONE tap) → backs
/// are submitted → the app completes automatically. The fake print engine
/// (FLIPSTACK_FAKE_PRINT) exercises the real state machine without paper.
@MainActor
final class FlowTests: XCTestCase {
    private var suiteName = ""
    private var model: AppModel!

    override func setUp() async throws {
        try await super.setUp()
        setenv("FLIPSTACK_FAKE_PRINT", "1", 1)
        setenv("FLIPSTACK_FAKE_HANG", "0", 1)
        Printing.resetQAFakeCounters()
        suiteName = "FlipStackFlowTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        model = AppModel(store: DemoSettingsStore(defaults: defaults, debounce: 0))
        model.printers = [Printer(id: "QA_QUEUE", name: "QA Queue", state: .idle, isDefault: true)]
        model.printerID = "QA_QUEUE"
        model.printerStates = ["QA_QUEUE": PrinterStatus(printerID: "QA_QUEUE", state: .idle, stateReasons: [])]
        model.duplex = true
        model.copies = 1
        model.chooseDoc(try Self.makePDF(pages: 4))
        try await waitUntil(3.0) { self.model.canPrint }
    }

    override func tearDown() async throws {
        if !suiteName.isEmpty {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
        unsetenv("FLIPSTACK_FAKE_PRINT")
        unsetenv("FLIPSTACK_FAKE_HANG")
        Printing.resetQAFakeCounters()
        try await super.tearDown()
    }

    /// The reported flow: one tap after the fronts must start the backs and the
    /// app must finish on its own (no second confirmation).
    func testSingleTapAfterFrontsStartsBacksAndFinishes() async throws {
        model.startPrint()
        try await waitUntil(3.0) { self.model.flowPhase == .flip }
        XCTAssertEqual(Printing.qaSubmissionCount, 1, "fronts submitted once")

        model.confirmFlip()
        try await waitUntil(6.0) { self.model.flowPhase == .done }
        XCTAssertEqual(Printing.qaSubmissionCount, 2, "fronts + backs submitted exactly once each")
        XCTAssertEqual(model.flowProgress, 1)
    }

    func testCancelAtFlipStopsWithoutBacks() async throws {
        model.startPrint()
        try await waitUntil(3.0) { self.model.flowPhase == .flip }
        model.cancelFlow()
        try await waitUntil(2.0) { self.model.flowPhase == .idle }
        XCTAssertEqual(Printing.qaSubmissionCount, 1, "backs must not be sent after cancel")
    }

    func testCopiesTwoSubmitsFourPasses() async throws {
        model.copies = 2
        model.startPrint()
        // copy 1
        try await waitUntil(3.0) { self.model.flowPhase == .flip }
        model.confirmFlip()
        // copy 2
        try await waitUntil(5.0) { self.model.flowPhase == .flip && self.model.flowCopyIndex == 2 }
        model.confirmFlip()
        try await waitUntil(6.0) { self.model.flowPhase == .done }
        XCTAssertEqual(Printing.qaSubmissionCount, 4, "two copies × fronts+backs")
    }

    func testDocumentSwapAtFlipCancelsSafely() async throws {
        model.startPrint()
        try await waitUntil(3.0) { self.model.flowPhase == .flip }
        model.chooseDoc(try Self.makePDF(pages: 2))
        try await waitUntil(3.0) { self.model.flowPhase == .idle }
        XCTAssertEqual(Printing.qaSubmissionCount, 1, "no backs after document change")
    }

    /// Paper-out / jam / offline must be surfaced and must not submit the next pass.
    func testPrinterErrorBlocksThePassAndRetryWorksAfterFixing() async throws {
        setenv("FLIPSTACK_QA_PRINTER_ISSUES", "1", 1)
        defer { unsetenv("FLIPSTACK_QA_PRINTER_ISSUES") }
        model.printerStates["QA_QUEUE"] = PrinterStatus(
            printerID: "QA_QUEUE",
            state: .stopped,
            stateReasons: ["media-empty-error"]
        )
        model.startPrint()
        try await waitUntil(3.0) { self.model.flowError != nil }
        XCTAssertEqual(Printing.qaSubmissionCount, 0, "nothing sent while out of paper")

        model.printerStates["QA_QUEUE"] = PrinterStatus(printerID: "QA_QUEUE", state: .idle, stateReasons: [])
        model.retryAfterError()
        try await waitUntil(3.0) { self.model.flowPhase == .flip }
        model.confirmFlip()
        try await waitUntil(6.0) { self.model.flowPhase == .done }
        XCTAssertEqual(Printing.qaSubmissionCount, 2)
    }

    // MARK: - Helpers

    private func waitUntil(
        _ timeout: TimeInterval = 5,
        _ condition: @escaping () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Timed out after \(timeout)s waiting for condition", file: file, line: line)
        throw NSError(domain: "FlowTests", code: 1)
    }

    static func makePDF(pages: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("flipstack-flowtest-\(UUID().uuidString).pdf")
        guard let sourceURL = Printing.calibrationPDF(),
              let sourceDoc = PDFDocument(url: sourceURL),
              let sourceData = sourceDoc.dataRepresentation() else {
            throw NSError(domain: "FlowTests", code: 2)
        }
        let output = PDFDocument()
        for _ in 0..<max(pages, 1) {
            guard let copyDoc = PDFDocument(data: sourceData),
                  let page = copyDoc.page(at: 0) else { continue }
            output.insert(page, at: output.pageCount)
        }
        guard output.write(to: url) else { throw NSError(domain: "FlowTests", code: 3) }
        return url
    }
}

final class BackOrderPlanningTests: XCTestCase {
    func testStandardOrderKeepsDocumentOrder() {
        XCTAssertEqual(PrintMath.backsSequence(fronts: [1, 3], backs: [2, 4], alternate: false), [2, 4])
        XCTAssertEqual(PrintMath.backsSequence(fronts: [1, 3, 5], backs: [2, 4], alternate: false), [2, 4])
    }

    func testAlternateOrderReversesSheetsAndPairsOddLastSideWithBlank() {
        // 4 pages: sheets [1,3] with backs [2,4] → printed 4 then 2.
        XCTAssertEqual(PrintMath.backsSequence(fronts: [1, 3], backs: [2, 4], alternate: true), [4, 2])
        // 5 pages: sheets [1,3,5]; page 2 pairs sheet 1, page 4 sheet 2, the last
        // sheet's back is a blank → printed blank, 4, 2 (blank stays last).
        XCTAssertEqual(PrintMath.backsSequence(fronts: [1, 3, 5], backs: [2, 4], alternate: true), [nil, 4, 2])
        // 3 pages: one back (2) must end on sheet 1; sheet 2's back is blank.
        XCTAssertEqual(PrintMath.backsSequence(fronts: [1, 3], backs: [2], alternate: true), [nil, 2])
    }
}
