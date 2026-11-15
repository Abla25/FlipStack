import XCTest
import PDFKit
import FlipStackCore
@testable import FlipStackDemo

/// End-to-end tests of the manual-duplex state machine using the env-gated
/// fake print engine in `Printing` (FLIPSTACK_FAKE_PRINT / FLIPSTACK_FAKE_HANG).
/// They reproduce the real flow without sending a physical print job.
@MainActor
final class FlowTests: XCTestCase {
    private var suiteName = ""
    private var model: AppModel!

    override func setUp() async throws {
        try await super.setUp()
        setenv("FLIPSTACK_FAKE_PRINT", "1", 1)
        setenv("FLIPSTACK_FAKE_HANG", "1", 1)
        Printing.resetQAFakeCounters()
        suiteName = "FlipStackFlowTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        model = AppModel(store: DemoSettingsStore(defaults: defaults, debounce: 0))
        model.printers = [Printer(id: "QA_QUEUE", name: "QA Queue", state: .idle, isDefault: true)]
        model.printerID = "QA_QUEUE"
        model.duplex = true
        model.copies = 1
        let url = try Self.makePDF(pages: 4)
        model.chooseDoc(url)
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

    /// Reproduces the reported bug: after the fronts, pressing "Continua" must
    /// show the flip step, and confirming it must send the backs.
    func testManualContinueAfterFrontsAdvancesToFlipThenPrintsBacks() async throws {
        model.startPrint()
        try await waitUntil(3.0) { self.model.flowCanContinue }
        XCTAssertEqual(model.flowPhase, .printing)
        XCTAssertEqual(Printing.qaSubmissionCount, 1, "fronts submitted once")

        model.continueAfterFronts()
        try await waitUntil(3.0) { self.model.flowPhase == .flip }

        model.confirmFlip()
        try await waitUntil(3.0) { self.model.flowCanContinue }
        model.continueAfterFronts()
        try await waitUntil(5.0) { self.model.flowPhase == .done }

        XCTAssertEqual(Printing.qaSubmissionCount, 2, "fronts + backs submitted")
        XCTAssertEqual(model.flowProgress, 1)
    }

    /// Manual-only contract: even if CUPS would report completion, the flow
    /// must NOT advance without the user's explicit Continue.
    func testNoAutoAdvanceWithoutUserConfirmation() async throws {
        setenv("FLIPSTACK_FAKE_HANG", "0", 1)
        model.startPrint()
        try await waitUntil(3.0) { self.model.flowCanContinue }
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(model.flowPhase, .printing, "must wait for the user")
        model.continueAfterFronts()
        try await waitUntil(3.0) { self.model.flowPhase == .flip }
        model.confirmFlip()
        try await waitUntil(3.0) { self.model.flowCanContinue }
        model.continueAfterFronts()
        try await waitUntil(5.0) { self.model.flowPhase == .done }
        XCTAssertEqual(Printing.qaSubmissionCount, 2)
    }

    /// Cancel during the fronts must not run the backs and must reset the flow.
    func testCancelDuringFrontsStopsFlow() async throws {
        model.startPrint()
        try await waitUntil(3.0) { self.model.flowCanContinue }
        model.cancelFlow()
        try await waitUntil(2.0) { self.model.flowPhase == .idle }
        XCTAssertEqual(Printing.qaSubmissionCount, 1)
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

    private static func makePDF(pages: Int) throws -> URL {
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
        guard output.write(to: url) else {
            throw NSError(domain: "FlowTests", code: 3)
        }
        return url
    }
}
