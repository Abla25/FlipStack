import XCTest
import Foundation
import PDFKit
import CoreGraphics
import Combine
import FlipStackCore
@testable import FlipStackDemo

/// Independent, adversarial verification of the manual-duplex print flow
/// (fronts → "Continua" → flip → backs → done) using the env-gated fake print
/// engine in `Printing` (FLIPSTACK_FAKE_PRINT / FLIPSTACK_FAKE_HANG).
///
/// Written by the independent verifier (task-14). It does NOT edit production
/// code and never sends a real print job: with FLIPSTACK_FAKE_PRINT=1 `submit`
/// only bumps `Printing.qaSubmissionCount`, and HANG=1 makes the completion
/// probe report "still running" forever, which is exactly the real-world case
/// where the CUPS completion probe is unreliable and the user must press
/// "Continua".
///
/// Every test runs against an isolated `UserDefaults` suite and a fake printer
/// ("QA"), so it can never touch the real settings domain or a real queue.
@MainActor
final class FlowVerificationTests: XCTestCase {
    private var suiteName = ""
    private var model: AppModel!
    private var tempURLs: [URL] = []

    override func setUp() async throws {
        try await super.setUp()
        setenv("FLIPSTACK_FAKE_PRINT", "1", 1)
        setenv("FLIPSTACK_FAKE_HANG", "1", 1)
        setenv("FLIPSTACK_LOG_PATH", "/tmp/flow-verifier-app.log", 1)
        Printing.resetQAFakeCounters()

        suiteName = "FlipStackFlowVerify-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let store = DemoSettingsStore(defaults: defaults, debounce: 0)
        model = AppModel(store: store)
        model.printers = [Printer(id: "QA", name: "QA", state: .idle, isDefault: true)]
        model.printerID = "QA"
        model.duplex = true
        model.duplexEdge = "long"
        model.copies = 1

        let url = try Self.makePDF(pages: 4)
        tempURLs.append(url)
        model.chooseDoc(url)
        let ready = await waitUntil(5.0) { self.model.canPrint }
        XCTAssertTrue(ready, snapshot("setUp: 4-page document never became printable"))
    }

    override func tearDown() async throws {
        model?.cancelFlow()
        try? await Task.sleep(nanoseconds: 150_000_000)
        for url in tempURLs { try? FileManager.default.removeItem(at: url) }
        tempURLs.removeAll()
        if !suiteName.isEmpty {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
        unsetenv("FLIPSTACK_FAKE_PRINT")
        unsetenv("FLIPSTACK_FAKE_HANG")
        unsetenv("FLIPSTACK_LOG_PATH")
        Printing.resetQAFakeCounters()
        try await super.tearDown()
    }

    // MARK: - 1. The reported bug: fronts → Continua must reach .flip, then backs → .done

    func test01_manualContinueAfterFronts_reachesFlip_printsBacks_done() async throws {
        model.startPrint()
        // Planned pass candidates for a 4-page document: fronts 1,3 · backs 2,4.
        XCTAssertEqual(intArray("flowFronts") ?? [], [1, 3], "front pass candidates")
        XCTAssertEqual(intArray("flowBacks") ?? [], [2, 4], "back pass candidates")

        await assertEventually(3.0, "fronts were never spooled / no Continua offered") { self.model.flowCanContinue }
        XCTAssertEqual(model.flowPhase, .printing)
        XCTAssertEqual(Printing.qaSubmissionCount, 1, "fronts submitted exactly once")

        // THE user action: press Continua on the fronts.
        model.continueAfterFronts()
        XCTAssertFalse(model.flowCanContinue, "Continua must be consumed once pressed")
        let reachedFlip = await waitUntil(3.0) { self.model.flowPhase == .flip }
        XCTAssertTrue(reachedFlip, snapshot("BUG: Continua did not advance to .flip"))
        XCTAssertNotEqual(model.flowPhase, .printing, "dead-end: still printing after Continua")
        XCTAssertEqual(model.flowProgress, 1)

        // Reinsert + confirm: the backs must be submitted.
        model.confirmFlip()
        await assertEventually(3.0, "backs were never spooled after confirmFlip") { self.model.flowCanContinue }
        XCTAssertEqual(model.flowPhase, .printing)
        XCTAssertEqual(Printing.qaSubmissionCount, 2, "backs submitted after confirmFlip")

        model.continueAfterFronts()
        await assertEventually(5.0, "backs Continua did not finish the flow") { self.model.flowPhase == .done }
        XCTAssertEqual(Printing.qaSubmissionCount, 2, "exactly fronts+backs, no duplicate")
        XCTAssertEqual(model.flowProgress, 1)
        XCTAssertNotNil(model.lastPrint)
        XCTAssertFalse(model.isPrinting)
    }

    // MARK: - 2. Manual-only contract: no auto-advance even when CUPS reports completion

    /// v1.0.5 contract (Lead decision): the manual-duplex flow is **manual-only**.
    /// CUPS job history cannot reliably distinguish cancelled from completed
    /// jobs, so completion detection is gone: after the fronts are spooled the
    /// flow waits for the user's Continua, even when the completion probe would
    /// report success (HANG=0 here). Verify it does NOT auto-advance and that the
    /// two manual presses still take it to `.done`.
    func test02_manualOnly_neverAutoAdvances_evenWhenProbeReportsCompletion() async throws {
        setenv("FLIPSTACK_FAKE_HANG", "0", 1)
        model.startPrint()
        await assertEventually(3.0, "fronts: no Continua offer") { self.model.flowCanContinue }
        XCTAssertEqual(Printing.qaSubmissionCount, 1)

        // Even with a (fake) probe that would report completion, no auto-advance.
        try? await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(model.flowPhase, .printing, "manual-only: must NOT auto-advance to .flip")
        XCTAssertTrue(model.flowCanContinue, "manual-only: Continua must still be offered")
        XCTAssertEqual(Printing.qaSubmissionCount, 1, "manual-only: backs must not be submitted without Continua")

        model.continueAfterFronts()
        await assertEventually(3.0, "manual-only: Continua did not reach .flip") { self.model.flowPhase == .flip }
        model.confirmFlip()
        await assertEventually(3.0, "manual-only: no backs Continua after confirmFlip") { self.model.flowCanContinue }
        XCTAssertEqual(Printing.qaSubmissionCount, 2)

        // The backs pass is also manual-only.
        try? await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(model.flowPhase, .printing, "manual-only: flow must NOT finish backs on its own")
        XCTAssertTrue(model.flowCanContinue)
        model.continueAfterFronts()
        await assertEventually(5.0, "manual-only: backs Continua did not finish") { self.model.flowPhase == .done }
        XCTAssertEqual(Printing.qaSubmissionCount, 2)
        XCTAssertEqual(model.flowProgress, 1)
    }

    // MARK: - 3. Double Continue / Continue while already in .flip

    func test03_continueTwice_andContinueDuringFlip_isSafe() async throws {
        model.startPrint()
        await assertEventually(3.0, "no fronts Continua") { self.model.flowCanContinue }
        model.continueAfterFronts()
        await assertEventually(3.0, "no flip") { self.model.flowPhase == .flip }
        XCTAssertEqual(Printing.qaSubmissionCount, 1)

        // A stale second tap while the flip prompt is showing must not skip or
        // corrupt the flip step.
        model.continueAfterFronts()
        XCTAssertEqual(model.flowPhase, .flip, "stale Continua must not leave .flip")
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(model.flowPhase, .flip)
        XCTAssertEqual(Printing.qaSubmissionCount, 1, "stale Continua must not submit anything")

        model.confirmFlip()
        await assertEventually(3.0, "no backs Continua") { self.model.flowCanContinue }
        XCTAssertEqual(Printing.qaSubmissionCount, 2)

        // Double-tap Continua on the backs: first advances to done, second is a no-op.
        model.continueAfterFronts()
        model.continueAfterFronts()
        await assertEventually(5.0, "backs double-tap did not finish") { self.model.flowPhase == .done }
        XCTAssertEqual(Printing.qaSubmissionCount, 2, "double tap must not duplicate the backs")
    }

    // MARK: - 4. Continua pressed the instant the button appears (first render tick)

    /// Deterministic version of "user taps Continua the moment the button shows
    /// up": the Combine sink observes the offer and schedules the tap on the next
    /// MainActor turn (the earliest a real click can arrive, after the published
    /// value is stored and the view can render). Historically a continuation-based
    /// implementation lost a tap in this window and sat on "Printing…" forever
    /// (reproduced on the v1.0.4 baseline, see /tmp/fv-verifier baseline notes);
    /// the current manual-only flag+loop implementation must honour it.
    func test04_continueOnFirstRenderTick_isHonored() async throws {
        var pressed = false
        let sink = model.$flowCanContinue.dropFirst().sink { value in
            guard value, !pressed else { return }
            pressed = true
            // Next main-actor turn: `@Published` emits in willSet, so the tap is
            // scheduled after `flowCanContinue` is actually stored/visible.
            Task { @MainActor [weak self] in
                self?.model.continueAfterFronts()
            }
        }
        defer { sink.cancel() }

        model.startPrint()
        let reachedFlip = await waitUntil(3.0) { self.model.flowPhase == .flip }
        XCTAssertTrue(pressed, "sink did not observe the Continua offer")
        XCTAssertTrue(reachedFlip, snapshot("BUG: Continua pressed on first render was lost (stuck in .printing)"))
        XCTAssertNotEqual(model.flowPhase, .printing)
        XCTAssertEqual(Printing.qaSubmissionCount, 1)

        model.confirmFlip()
        await assertEventually(3.0, "no backs after early Continua") { self.model.flowCanContinue }
        model.continueAfterFronts()
        await assertEventually(5.0, "early-Continua flow did not finish") { self.model.flowPhase == .done }
        XCTAssertEqual(Printing.qaSubmissionCount, 2)
    }

    // MARK: - 5. Continua pressed while the pass is still being spooled

    func test05_continueBeforeSpool_isNotLost_flowStillCompletes() async throws {
        model.startPrint()
        // The button is not visible yet in the real UI; a stale "Continua" tap
        // must never corrupt the flow: the pass must still offer/accept one.
        model.continueAfterFronts()
        await assertEventually(4.0, "early stale Continua broke the Continua offer") { self.model.flowCanContinue }
        XCTAssertEqual(Printing.qaSubmissionCount, 1)
        model.continueAfterFronts()
        await assertEventually(3.0, "flow stuck after early + real Continua") { self.model.flowPhase == .flip }
        XCTAssertNotEqual(model.flowPhase, .printing)
    }

    // MARK: - 6. Cancel during the fronts, then a stale Continua

    func test06_cancelDuringFronts_thenStaleContinue_neverPrintsBacks() async throws {
        model.startPrint()
        await assertEventually(3.0, "no fronts Continua") { self.model.flowCanContinue }
        model.cancelFlow()
        XCTAssertEqual(model.flowPhase, .idle)
        XCTAssertFalse(model.flowCanContinue)
        XCTAssertEqual(Printing.qaSubmissionCount, 1)

        // The user's finger may still land on the (now gone) button.
        model.continueAfterFronts()
        try? await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(model.flowPhase, .idle, "cancel must not be overridden by a stale Continua")
        XCTAssertEqual(Printing.qaSubmissionCount, 1, "no backs after cancel during fronts")
        XCTAssertFalse(model.flowCanContinue)
    }

    // MARK: - 7. Cancel during the backs, then a stale Continua

    func test07_cancelDuringBacks_thenStaleContinue_neverFinishes() async throws {
        model.startPrint()
        await assertEventually(3.0, "no fronts Continua") { self.model.flowCanContinue }
        model.continueAfterFronts()
        await assertEventually(3.0, "no flip") { self.model.flowPhase == .flip }
        model.confirmFlip()
        await assertEventually(3.0, "no backs Continua") { self.model.flowCanContinue }
        XCTAssertEqual(Printing.qaSubmissionCount, 2)

        model.cancelFlow()
        XCTAssertEqual(model.flowPhase, .idle)
        XCTAssertEqual(Printing.qaSubmissionCount, 2, "cancel must not submit another pass")

        model.continueAfterFronts()
        try? await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(model.flowPhase, .idle)
        XCTAssertEqual(Printing.qaSubmissionCount, 2, "stale Continua after cancel must not submit")
        XCTAssertFalse(model.flowCanContinue)

        // The model must still be usable after a cancel.
        XCTAssertTrue(model.canPrint, "cancel left the model unable to print again")
        model.startPrint()
        await assertEventually(3.0, "restart after cancel did not reach the Continua offer") { self.model.flowCanContinue }
        XCTAssertEqual(Printing.qaSubmissionCount, 3)
    }

    // MARK: - 8. copies=2 with manual duplex → 4 passes total

    func test08_copiesTwo_duplex_submitsFourPasses() async throws {
        model.copies = 2
        model.startPrint()
        XCTAssertEqual(model.flowCopiesTotal, 2)

        var seenCounts: [Int] = []
        var lastCount = -1
        var guardCounter = 0
        while model.flowPhase != .done && guardCounter < 600 {
            let count = Printing.qaSubmissionCount
            if count != lastCount {
                if count > 0 { seenCounts.append(count) }
                lastCount = count
            }
            if model.flowPhase == .flip {
                model.confirmFlip()
            } else if model.flowCanContinue {
                model.continueAfterFronts()
            } else if model.flowPhase == .idle {
                break
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
            guardCounter += 1
        }

        XCTAssertEqual(model.flowPhase, .done, snapshot("copies=2 flow never finished"))
        XCTAssertEqual(Printing.qaSubmissionCount, 4, "2 copies × (fronts+backs) = 4 submitted passes")
        XCTAssertEqual(seenCounts, [1, 2, 3, 4], "passes must be submitted sequentially, one at a time")
        XCTAssertEqual(model.flowProgress, 1)
    }

    // MARK: - 9. Odd page count (3 pages → fronts 1,3 · backs 2)

    func test09_oddPageCount_threePages_twoPasses() async throws {
        try await useDocument(pages: 3)
        model.startPrint()
        XCTAssertEqual(intArray("flowFronts") ?? [], [1, 3])
        XCTAssertEqual(intArray("flowBacks") ?? [], [2])

        await assertEventually(3.0, "3-page: no fronts Continua") { self.model.flowCanContinue }
        model.continueAfterFronts()
        await assertEventually(3.0, "3-page: no flip") { self.model.flowPhase == .flip }
        XCTAssertNotEqual(model.flowPhase, .printing)
        model.confirmFlip()
        await assertEventually(3.0, "3-page: no backs Continua") { self.model.flowCanContinue }
        XCTAssertEqual(Printing.qaSubmissionCount, 2)
        model.continueAfterFronts()
        await assertEventually(5.0, "3-page flow did not finish") { self.model.flowPhase == .done }
    }

    // MARK: - 10. Short-edge manual duplex

    func test10_shortEdge_duplex_twoPassesAndOrientationDiffers() async throws {
        // Pure math: the edge changes the backs rotation, not the page split.
        let longBacks = PrintMath.backsOrientationRequested(fronts: 3, shortEdge: false)
        let shortBacks = PrintMath.backsOrientationRequested(fronts: 3, shortEdge: true)
        XCTAssertNotEqual(longBacks, shortBacks, "short edge must rotate the back pass differently")
        XCTAssertEqual(shortBacks, 5)

        model.duplexEdge = "short"
        model.startPrint()
        XCTAssertEqual(intArray("flowFronts") ?? [], [1, 3])
        XCTAssertEqual(intArray("flowBacks") ?? [], [2, 4])

        await assertEventually(3.0, "short-edge: no fronts Continua") { self.model.flowCanContinue }
        model.continueAfterFronts()
        await assertEventually(3.0, "short-edge: no flip") { self.model.flowPhase == .flip }
        XCTAssertNotEqual(model.flowPhase, .printing)
        XCTAssertEqual(model.duplexEdge, "short")
        model.confirmFlip()
        await assertEventually(3.0, "short-edge: no backs Continua") { self.model.flowCanContinue }
        XCTAssertEqual(Printing.qaSubmissionCount, 2)
        model.continueAfterFronts()
        await assertEventually(5.0, "short-edge flow did not finish") { self.model.flowPhase == .done }
    }

    // MARK: - 11. Document swap mid-flow must cancel safely (no backs)

    func test11_documentSwapMidFlow_cancelsSafely_noBacks() async throws {
        model.startPrint()
        await assertEventually(3.0, "no fronts Continua") { self.model.flowCanContinue }
        XCTAssertEqual(Printing.qaSubmissionCount, 1)

        try await useDocument(pages: 2)   // chooseDoc() must cancel the in-flight flow

        XCTAssertEqual(model.flowPhase, .idle, "swapping the document must cancel the flow")
        XCTAssertEqual(Printing.qaSubmissionCount, 1, "swapping the document must not submit backs")
        XCTAssertEqual(model.docPages, 2)
        XCTAssertTrue(model.canPrint)

        // A stale Continua from the old document must not print the new one.
        model.continueAfterFronts()
        try? await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(model.flowPhase, .idle)
        XCTAssertEqual(Printing.qaSubmissionCount, 1, "stale Continua after document swap printed something")
    }

    // MARK: - 12. Remove document mid-flow must cancel safely (no backs)

    func test12_removeDocumentMidFlow_cancelsSafely_noBacks() async throws {
        model.startPrint()
        await assertEventually(3.0, "no fronts Continua") { self.model.flowCanContinue }
        XCTAssertEqual(Printing.qaSubmissionCount, 1)

        model.removeDoc()
        XCTAssertEqual(model.flowPhase, .idle)
        XCTAssertFalse(model.canPrint)
        XCTAssertNil(model.docURL)
        XCTAssertEqual(Printing.qaSubmissionCount, 1)

        model.continueAfterFronts()
        try? await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(model.flowPhase, .idle)
        XCTAssertEqual(Printing.qaSubmissionCount, 1, "stale Continua after removeDoc printed something")
        XCTAssertEqual(model.flowPhase, .idle)
    }

    // MARK: - 13. Backs-only dead-end check: with a hanging probe the flow may only
    // advance through Continua, and it must never sit in .printing after a press.

    func test13_hangingProbe_noPathLeavesPrintingAfterContinue() async throws {
        model.startPrint()
        await assertEventually(3.0, "no fronts Continua") { self.model.flowCanContinue }

        // While HANG=1 and nobody presses, the flow is allowed to wait...
        try? await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(model.flowPhase, .printing, "hanging probe must keep waiting for the user, not fail")
        XCTAssertTrue(model.flowCanContinue, "Continua must stay available while waiting")

        // ...but after a press it MUST leave .printing.
        model.continueAfterFronts()
        await assertEventually(3.0, "dead-end: still .printing 3s after pressing Continua") { self.model.flowPhase != .printing }
        XCTAssertEqual(model.flowPhase, .flip)

        model.confirmFlip()
        await assertEventually(3.0, "no backs Continua") { self.model.flowCanContinue }
        model.continueAfterFronts()
        await assertEventually(5.0, "dead-end: backs Continua did not finish") { self.model.flowPhase == .done }
        XCTAssertEqual(Printing.qaSubmissionCount, 2)
    }

    // MARK: - Helpers

    /// Replaces the current document, waiting for the async ingest to finish.
    private func useDocument(pages: Int) async throws {
        let url = try Self.makePDF(pages: pages)
        tempURLs.append(url)
        model.chooseDoc(url)
        let ready = await waitUntil(5.0) { self.model.docPages == pages && self.model.canPrint }
        XCTAssertTrue(ready, snapshot("document with \(pages) pages never became printable"))
    }

    private func waitUntil(_ timeout: TimeInterval,
                           poll: UInt64 = 40_000_000,
                           _ condition: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: poll)
        }
        return condition()
    }

    /// Asserts that `condition` becomes true within `timeout`; on failure the
    /// message contains the complete flow state (phase, submissions, generation,
    /// page lists, pending continuations) so the report is actionable.
    private func assertEventually(_ timeout: TimeInterval,
                                  _ context: String,
                                  poll: UInt64 = 40_000_000,
                                  file: StaticString = #filePath,
                                  line: UInt = #line,
                                  _ condition: @escaping () -> Bool) async {
        let ok = await waitUntil(timeout, poll: poll, condition)
        XCTAssertTrue(ok, snapshot(context), file: file, line: line)
    }

    /// Reads a private stored property (Mirror works for `private var` on classes
    /// and keeps this file independent of production internals).
    private func raw(_ name: String) -> String {
        guard let child = Mirror(reflecting: model!).children.first(where: { $0.label == name }) else {
            return "<missing \(name)>"
        }
        return String(describing: child.value)
    }

    private func intArray(_ name: String) -> [Int]? {
        Mirror(reflecting: model!).children.first { $0.label == name }?.value as? [Int]
    }

    /// Full flow state dump embedded in every failing assertion.
    private func snapshot(_ context: String) -> String {
        return """
        \(context)
          flowPhase=\(model.flowPhase) flowCanContinue=\(model.flowCanContinue) \
        flowProgress=\(model.flowProgress) flowLabel=\(String(reflecting: model.flowLabel)) \
        copy=\(model.flowCopyIndex)/\(model.flowCopiesTotal)
          qaSubmissionCount=\(Printing.qaSubmissionCount) \
        flowGeneration=\(raw("flowGeneration")) flowJobID=\(raw("flowJobID"))
          flowFronts=\(raw("flowFronts")) flowBacks=\(raw("flowBacks"))
          manualContinueRequested=\(raw("manualContinueRequested")) \
        flipContinuation=\(raw("flipContinuation")) manualContinueContinuation=\(raw("manualContinueContinuation"))
          docPages=\(model.docPages) canPrint=\(model.canPrint) docURL=\(model.docURL?.lastPathComponent ?? "nil") \
        duplex=\(model.duplex) edge=\(model.duplexEdge) copies=\(model.copies)
        """
    }

    private static func makePDF(pages: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("flipstack-flowverify-\(UUID().uuidString).pdf")
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            throw NSError(domain: "FlowVerificationTests", code: 1)
        }
        for page in 0..<max(pages, 1) {
            context.beginPage(mediaBox: &box)
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(box)
            context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 40, y: 700, width: 300, height: 3))
            context.fill(CGRect(x: 40, y: 680, width: 200 + CGFloat(page), height: 3))
            context.endPage()
        }
        context.closePDF()
        try (data as Data).write(to: url)
        return url
    }
}
