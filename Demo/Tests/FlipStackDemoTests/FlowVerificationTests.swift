import XCTest
import PDFKit
import FlipStackCore
@testable import FlipStackDemo

/// Independent adversarial coverage of the one-tap manual duplex flow
/// (fake print engine, no paper). Complements FlowTests.
@MainActor
final class FlowVerificationTests: XCTestCase {
    private var suiteName = ""
    private var model: AppModel!

    override func setUp() async throws {
        try await super.setUp()
        setenv("FLIPSTACK_FAKE_PRINT", "1", 1)
        setenv("FLIPSTACK_FAKE_HANG", "0", 1)
        Printing.resetQAFakeCounters()
        suiteName = "FlipStackFlowVerification-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        model = AppModel(store: DemoSettingsStore(defaults: defaults, debounce: 0))
        model.printers = [Printer(id: "QA", name: "QA", state: .idle, isDefault: true)]
        model.printerID = "QA"
        model.printerStates = ["QA": PrinterStatus(printerID: "QA", state: .idle, stateReasons: [])]
        model.duplex = true
        model.copies = 1
        model.chooseDoc(try FlowTests.makePDF(pages: 4))
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

    func testOddPageCountCompletesWithAlternateOrder() async throws {
        model.chooseDoc(try FlowTests.makePDF(pages: 3))
        try await waitUntil(3.0) { self.model.canPrint }
        model.startPrint()
        try await waitUntil(3.0) { self.model.flowPhase == .flip }
        model.confirmFlip()
        try await waitUntil(6.0) { self.model.flowPhase == .done }
        XCTAssertEqual(Printing.qaSubmissionCount, 2)
    }

    func testStandardBackOrderAlsoCompletes() async throws {
        model.settings.duplexBackOrder = "standard"
        model.startPrint()
        try await waitUntil(3.0) { self.model.flowPhase == .flip }
        model.confirmFlip()
        try await waitUntil(6.0) { self.model.flowPhase == .done }
        XCTAssertEqual(Printing.qaSubmissionCount, 2)
    }

    func testRepeatedConfirmAndStaleConfirmAreSafe() async throws {
        model.startPrint()
        try await waitUntil(3.0) { self.model.flowPhase == .flip }
        model.confirmFlip()
        model.confirmFlip() // second tap must be ignored
        try await waitUntil(6.0) { self.model.flowPhase == .done }
        XCTAssertEqual(Printing.qaSubmissionCount, 2)
        model.confirmFlip() // done → idle, no extra submission
        XCTAssertEqual(Printing.qaSubmissionCount, 2)
    }

    func testCancelDuringBacksThenStaleConfirmNeverReachesDone() async throws {
        model.startPrint()
        try await waitUntil(3.0) { self.model.flowPhase == .flip }
        model.confirmFlip()
        // cancel as soon as the backs pass has been submitted
        try await waitUntil(3.0) { Printing.qaSubmissionCount == 2 }
        model.cancelFlow()
        try await waitUntil(2.0) { self.model.flowPhase == .idle }
        model.confirmFlip()
        XCTAssertNotEqual(model.flowPhase, .done)
        XCTAssertEqual(Printing.qaSubmissionCount, 2)
    }

    func testCopiesTwoWithOddPagesFourSubmissions() async throws {
        model.copies = 2
        model.chooseDoc(try FlowTests.makePDF(pages: 3))
        try await waitUntil(3.0) { self.model.canPrint }
        model.startPrint()
        try await waitUntil(3.0) { self.model.flowPhase == .flip }
        model.confirmFlip()
        try await waitUntil(5.0) { self.model.flowPhase == .flip && self.model.flowCopyIndex == 2 }
        model.confirmFlip()
        try await waitUntil(6.0) { self.model.flowPhase == .done }
        XCTAssertEqual(Printing.qaSubmissionCount, 4)
    }

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
        throw NSError(domain: "FlowVerificationTests", code: 1)
    }
}
