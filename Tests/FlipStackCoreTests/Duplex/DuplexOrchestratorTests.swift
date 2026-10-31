import XCTest
@testable import FlipStackCore

@MainActor
final class DuplexOrchestratorTests: XCTestCase {
    private let sourceURL = URL(fileURLWithPath: "/tmp/FlipStack-Duplex-Test.pdf")

    // MARK: - Standard duplex

    func testLongEdgeSubmitsFrontsThenBacksWithoutReversingPages() async throws {
        let spooler = MockPrintSpooler()
        let notifier = MockDuplexNotifier()
        let orchestrator = DuplexOrchestrator(spooler: spooler, notifier: notifier)

        let ranges = [try XCTUnwrap(PageRange(1, 4))]
        let document = try makeDocument(pageCount: 4, pageRanges: ranges)
        let configuration = makeConfiguration(
            axis: .longEdge,
            driverOptions: ["PageSize": "A4"],
            copies: 2
        )

        let task = orchestrator.start(document: document, configuration: configuration)

        try await waitUntil("the fronts pass should wait for a flip") {
            if case .awaitingFlip = orchestrator.phase { return true }
            return false
        }

        let expectedPrompt = FlipPrompt.make(
            printerName: "Epson L1800",
            sheetCount: 2,
            flipAxis: .longEdge,
            mode: .flipBlock,
            hasOddPageCount: false
        )
        let prompt = try XCTUnwrap(orchestrator.phase.prompt)
        XCTAssertEqual(prompt, expectedPrompt)
        XCTAssertEqual(prompt.message, DuplexCopy.flipMessage)
        XCTAssertEqual(orchestrator.progress, 0.5, accuracy: 0.0001)

        let requestsBeforeConfirm = await spooler.requests
        XCTAssertEqual(requestsBeforeConfirm.count, 1)
        XCTAssertEqual(requestsBeforeConfirm.first?.pageSet, .odd)

        orchestrator.confirmFlip()
        XCTAssertEqual(orchestrator.flipAnimationNonce, 1)
        await waitForTask(task)

        let requests = await spooler.requests
        XCTAssertEqual(requests.count, 2)

        let fronts = requests[0]
        let backs = requests[1]

        XCTAssertEqual(fronts.fileURL, sourceURL)
        XCTAssertEqual(backs.fileURL, sourceURL)
        XCTAssertEqual(fronts.title, "FlipStack fronts")
        XCTAssertEqual(backs.title, "FlipStack backs")
        XCTAssertEqual(fronts.pageSet, .odd)
        XCTAssertEqual(backs.pageSet, .even)
        XCTAssertEqual(fronts.pageRanges, ranges)
        XCTAssertEqual(backs.pageRanges, ranges)
        XCTAssertEqual(fronts.copies, 2)
        XCTAssertEqual(backs.copies, 2)
        XCTAssertEqual(fronts.numberUp, 1)
        XCTAssertEqual(backs.numberUp, 1)
        XCTAssertEqual(fronts.orientation, .portrait)
        XCTAssertEqual(backs.orientation, .portrait)

        for request in requests {
            XCTAssertEqual(request.driverOptions["Duplex"], "NoTumble")
            XCTAssertEqual(request.driverOptions["PageSize"], "A4")
            // There must never be an output-order override or a reversed range.
            XCTAssertFalse(
                request.driverOptions.keys.contains {
                    $0.lowercased().contains("output")
                        || $0.lowercased().contains("reverse")
                }
            )
            XCTAssertFalse(
                request.driverOptions.values.contains {
                    $0.lowercased().contains("reverse")
                }
            )
        }

        guard case .completed(let result) = orchestrator.phase else {
            return XCTFail("Expected completed, got \(orchestrator.phase)")
        }
        XCTAssertEqual(result.printerName, "Epson L1800")
        XCTAssertEqual(result.sourcePageCount, 4)
        XCTAssertEqual(result.sheetCount, 2)
        XCTAssertFalse(result.isBooklet)
        XCTAssertFalse(result.hadBlankFinalBack)
        XCTAssertGreaterThanOrEqual(result.elapsed, 0)
        XCTAssertEqual(orchestrator.progress, 1, accuracy: 0.0001)
        XCTAssertFalse(orchestrator.isRunning)

        XCTAssertEqual(
            notifier.events,
            [
                .flipRequired(expectedPrompt),
                .completed(printerName: "Epson L1800", sheetCount: 2)
            ]
        )
    }

    func testBookletUsesNumberUpTwoAndNoPageSetOnEitherPass() async throws {
        let spooler = MockPrintSpooler()
        let notifier = MockDuplexNotifier()
        let orchestrator = DuplexOrchestrator(spooler: spooler, notifier: notifier)
        let fronts = URL(fileURLWithPath: "/tmp/FlipStack-Booklet-fronts.pdf")
        let backs = URL(fileURLWithPath: "/tmp/FlipStack-Booklet-backs.pdf")
        let document = DuplexDocument(
            title: "Field Notes booklet",
            sourcePageCount: 8,
            sheetCount: 2,
            firstPass: PrintSource(
                fileURL: fronts,
                pageSet: .all,
                pageCount: 2,
                numberUp: 2
            ),
            secondPass: PrintSource(
                fileURL: backs,
                pageSet: .all,
                pageCount: 2,
                numberUp: 2
            ),
            isBooklet: true,
            hasOddPageCount: false
        )

        let task = orchestrator.start(
            document: document,
            configuration: makeConfiguration(axis: .longEdge)
        )
        try await waitUntil("booklet flip prompt") {
            if case .awaitingFlip = orchestrator.phase { return true }
            return false
        }
        let prompt = try XCTUnwrap(orchestrator.phase.prompt)
        XCTAssertEqual(prompt.sheetCount, 2)
        XCTAssertEqual(prompt.mode, .flipBlock)

        orchestrator.confirmFlip()
        await waitForTask(task)

        let requests = await spooler.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].fileURL, fronts)
        XCTAssertEqual(requests[1].fileURL, backs)
        XCTAssertEqual(requests[0].pageSet, .all)
        XCTAssertEqual(requests[1].pageSet, .all)
        XCTAssertEqual(requests[0].numberUp, 2)
        XCTAssertEqual(requests[1].numberUp, 2)
        XCTAssertEqual(requests[0].driverOptions["Duplex"], "NoTumble")
        XCTAssertEqual(requests[1].driverOptions["Duplex"], "NoTumble")

        guard case .completed(let result) = orchestrator.phase else {
            return XCTFail("Expected completed booklet, got \(orchestrator.phase)")
        }
        XCTAssertTrue(result.isBooklet)
        XCTAssertFalse(result.isSingleSided)
    }

    func testSingleSidedSubmitsOnePassWithoutFlipOrDuplexOption() async throws {        let spooler = MockPrintSpooler()
        let notifier = MockDuplexNotifier()
        let orchestrator = DuplexOrchestrator(spooler: spooler, notifier: notifier)
        await spooler.setJobPolicy(.sequence([.processing, .completed]))

        let document = try DuplexDocument.singleSided(
            fileURL: sourceURL,
            pageCount: 3,
            title: "One Sided"
        )
        XCTAssertTrue(document.isSingleSided)
        XCTAssertFalse(document.hasBackSides)
        XCTAssertEqual(document.sheetCount, 3)

        let task = orchestrator.start(
            document: document,
            configuration: makeConfiguration(axis: .shortEdge, driverOptions: ["PageSize": "A4"])
        )
        await waitForTask(task)

        let requests = await spooler.requests
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.pageSet, .all)
        XCTAssertEqual(request.fileURL, sourceURL)
        XCTAssertEqual(request.title, "FlipStack job")
        XCTAssertEqual(request.numberUp, 1)
        XCTAssertEqual(request.driverOptions["PageSize"], "A4")
        XCTAssertEqual(request.driverOptions["sides"], "one-sided")
        XCTAssertNil(request.driverOptions["Duplex"])
        XCTAssertFalse(
            request.driverOptions.keys.contains {
                $0.lowercased().contains("reverse") || $0.lowercased().contains("output")
            }
        )
        XCTAssertEqual(notifier.events.count, 1)
        guard case .completed(let result) = orchestrator.phase else {
            return XCTFail("Expected completed, got \(orchestrator.phase)")
        }
        XCTAssertTrue(result.isSingleSided)
        XCTAssertEqual(result.sheetCount, 3)
        XCTAssertFalse(result.hadBlankFinalBack)
        XCTAssertEqual(orchestrator.flipAnimationNonce, 0)
        XCTAssertEqual(orchestrator.progress, 1, accuracy: 0.0001)
    }

    /// On a queue with hardware duplex, each manual pass must still be
    /// explicitly one-sided so the driver does not turn the page itself.
    func testManualPassesOnHardwareDuplexQueueForceOneSided() async throws {
        let spooler = MockPrintSpooler()
        let orchestrator = DuplexOrchestrator(spooler: spooler)
        let document = try makeDocument(pageCount: 4)
        var configuration = makeConfiguration(axis: .shortEdge)
        configuration.forceOneSidedPasses = true

        let task = orchestrator.start(document: document, configuration: configuration)
        try await waitUntil("flip prompt") {
            if case .awaitingFlip = orchestrator.phase { return true }
            return false
        }
        orchestrator.confirmFlip()
        await waitForTask(task)

        let requests = await spooler.requests
        XCTAssertEqual(requests.count, 2)
        for request in requests {
            XCTAssertEqual(request.driverOptions["sides"], "one-sided")
            XCTAssertNil(request.driverOptions["Duplex"])
        }
    }

    func testShortEdgeUsesTumbleOnBothPasses() async throws {        let spooler = MockPrintSpooler()
        let notifier = MockDuplexNotifier()
        let orchestrator = DuplexOrchestrator(spooler: spooler, notifier: notifier)
        let document = try makeDocument(pageCount: 4)
        let configuration = makeConfiguration(axis: .shortEdge)

        let task = orchestrator.start(document: document, configuration: configuration)
        try await waitUntil("flip prompt") {
            if case .awaitingFlip = orchestrator.phase { return true }
            return false
        }

        let prompt = try XCTUnwrap(orchestrator.phase.prompt)
        XCTAssertEqual(prompt.flipAxis, .shortEdge)
        XCTAssertEqual(prompt.mode, .flipBlock)
        XCTAssertEqual(
            prompt,
            FlipPrompt.make(
                printerName: "Epson L1800",
                sheetCount: 2,
                flipAxis: .shortEdge,
                mode: .flipBlock,
                hasOddPageCount: false
            )
        )

        orchestrator.confirmFlip()
        await waitForTask(task)

        let requests = await spooler.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].driverOptions["Duplex"], "Tumble")
        XCTAssertEqual(requests[1].driverOptions["Duplex"], "Tumble")
        XCTAssertEqual(requests[0].pageSet, .odd)
        XCTAssertEqual(requests[1].pageSet, .even)

        guard case .completed = orchestrator.phase else {
            return XCTFail("Expected completed, got \(orchestrator.phase)")
        }
    }

    func testFaceDownTrayReinsertsWithoutFlippingOrReversing() async throws {
        let spooler = MockPrintSpooler()
        let notifier = MockDuplexNotifier()
        let orchestrator = DuplexOrchestrator(spooler: spooler, notifier: notifier)
        let document = try makeDocument(pageCount: 4)
        let configuration = makeConfiguration(axis: .longEdge, ejectsFaceDown: true)

        let task = orchestrator.start(document: document, configuration: configuration)
        try await waitUntil("reinsert prompt") {
            if case .awaitingFlip = orchestrator.phase { return true }
            return false
        }

        let prompt = try XCTUnwrap(orchestrator.phase.prompt)
        XCTAssertEqual(prompt.mode, .reinsertOnly)
        XCTAssertEqual(prompt.title, "Reinsert the stack")
        XCTAssertEqual(prompt.message, DuplexCopy.reinsertMessage)
        XCTAssertEqual(
            prompt,
            FlipPrompt.make(
                printerName: "Epson L1800",
                sheetCount: 2,
                flipAxis: .longEdge,
                mode: .reinsertOnly,
                hasOddPageCount: false
            )
        )
        XCTAssertNil(prompt.footnote)

        let requestsBeforeConfirm = await spooler.requests
        XCTAssertEqual(requestsBeforeConfirm.count, 1)
        XCTAssertEqual(requestsBeforeConfirm[0].pageSet, .odd)

        orchestrator.confirmFlip()
        await waitForTask(task)

        let requests = await spooler.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[1].pageSet, .even)
        XCTAssertEqual(requests[1].fileURL, sourceURL)
        XCTAssertEqual(requests[1].driverOptions["Duplex"], "NoTumble")
        XCTAssertFalse(
            requests[1].driverOptions.keys.contains {
                $0.lowercased().contains("output")
            }
        )

        guard case .completed = orchestrator.phase else {
            return XCTFail("Expected completed, got \(orchestrator.phase)")
        }
    }

    func testOddPageCountLeavesTheLastBackBlank() async throws {
        let spooler = MockPrintSpooler()
        let notifier = MockDuplexNotifier()
        let orchestrator = DuplexOrchestrator(spooler: spooler, notifier: notifier)
        let document = try makeDocument(pageCount: 5)

        XCTAssertEqual(document.firstPass.pageCount, 3)
        XCTAssertEqual(document.secondPass.pageCount, 2)
        XCTAssertEqual(document.sheetCount, 3)

        let configuration = makeConfiguration()
        let task = orchestrator.start(document: document, configuration: configuration)
        try await waitUntil("odd-page flip prompt") {
            if case .awaitingFlip = orchestrator.phase { return true }
            return false
        }

        let expectedPrompt = FlipPrompt.make(
            printerName: "Epson L1800",
            sheetCount: 3,
            flipAxis: .longEdge,
            mode: .flipBlock,
            hasOddPageCount: true
        )
        let prompt = try XCTUnwrap(orchestrator.phase.prompt)
        XCTAssertEqual(prompt, expectedPrompt)
        XCTAssertEqual(
            prompt.footnote,
            "The document has an odd page count, so the last sheet’s back stays blank."
        )

        orchestrator.confirmFlip()
        await waitForTask(task)

        let requests = await spooler.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[1].pageSet, .even)
        XCTAssertFalse(
            requests[1].driverOptions.keys.contains {
                $0.lowercased().contains("output")
            }
        )

        guard case .completed(let result) = orchestrator.phase else {
            return XCTFail("Expected completed, got \(orchestrator.phase)")
        }
        XCTAssertEqual(result.sourcePageCount, 5)
        XCTAssertEqual(result.sheetCount, 3)
        XCTAssertTrue(result.hadBlankFinalBack)
        XCTAssertEqual(
            notifier.events,
            [
                .flipRequired(expectedPrompt),
                .completed(printerName: "Epson L1800", sheetCount: 3)
            ]
        )
    }

    func testOnePageDocumentCompletesAfterFrontsWithoutFlip() async throws {
        let spooler = MockPrintSpooler()
        let notifier = MockDuplexNotifier()
        let orchestrator = DuplexOrchestrator(spooler: spooler, notifier: notifier)
        let document = try makeDocument(pageCount: 1)

        XCTAssertFalse(document.hasBackSides)
        XCTAssertEqual(document.secondPass.pageCount, 0)

        let task = orchestrator.start(
            document: document,
            configuration: makeConfiguration()
        )
        await waitForTask(task)

        let requests = await spooler.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].pageSet, .odd)
        XCTAssertEqual(requests[0].title, "FlipStack fronts")

        guard case .completed(let result) = orchestrator.phase else {
            return XCTFail("Expected completed, got \(orchestrator.phase)")
        }
        XCTAssertEqual(result.sheetCount, 1)
        XCTAssertEqual(result.sourcePageCount, 1)
        XCTAssertFalse(result.hadBlankFinalBack)
        XCTAssertEqual(orchestrator.progress, 1, accuracy: 0.0001)

        XCTAssertEqual(
            notifier.events,
            [.completed(printerName: "Epson L1800", sheetCount: 1)]
        )
    }

    // MARK: - Cancellation

    func testCancelWhileFrontsIsPrintingCancelsJobAndNeverPrintsBacks() async throws {
        let spooler = MockPrintSpooler()
        let notifier = MockDuplexNotifier()
        let orchestrator = DuplexOrchestrator(spooler: spooler, notifier: notifier)
        await spooler.setJobPolicy(.forever(.processing, impressionsCompleted: 2))

        let document = try makeDocument(pageCount: 4)
        let task = orchestrator.start(
            document: document,
            configuration: makeConfiguration(jobStuckTimeout: 1)
        )

        try await waitUntil("fronts printing") {
            if case .printing(let pass, _) = orchestrator.phase {
                return pass == .fronts
            }
            return false
        }

        let submittedIDs = await spooler.submittedJobIDs
        let jobID = try XCTUnwrap(submittedIDs.first)

        orchestrator.cancel()

        XCTAssertEqual(orchestrator.phase, .cancelled(.fronts))
        await waitForTask(task)
        try await waitUntilAsync("the active job should be canceled") {
            await spooler.cancellations.contains(jobID)
        }

        let requests = await spooler.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].pageSet, .odd)
        XCTAssertFalse(requests.contains { $0.pageSet == .even })
        XCTAssertEqual(
            notifier.events.filter { $0 == .canceled }.count,
            1
        )

        // A second cancel is a no-op and must not notify again.
        orchestrator.cancel()
        XCTAssertEqual(
            notifier.events.filter { $0 == .canceled }.count,
            1
        )
    }

    func testCancelWhileAwaitingFlipReleasesContinuationAndNeverPrintsBacks() async throws {
        let spooler = MockPrintSpooler()
        let notifier = MockDuplexNotifier()
        let orchestrator = DuplexOrchestrator(spooler: spooler, notifier: notifier)
        let document = try makeDocument(pageCount: 4)

        let task = orchestrator.start(
            document: document,
            configuration: makeConfiguration()
        )
        try await waitUntil("flip prompt") {
            if case .awaitingFlip = orchestrator.phase { return true }
            return false
        }

        let prompt = try XCTUnwrap(orchestrator.phase.prompt)
        orchestrator.cancel()

        XCTAssertEqual(orchestrator.phase, .cancelled(.backs))
        XCTAssertEqual(orchestrator.flipAnimationNonce, 0)
        await waitForTask(task)

        // Confirming after cancellation must not sneak in a backs pass.
        orchestrator.confirmFlip()
        try await Task.sleep(nanoseconds: 20_000_000)

        let requests = await spooler.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertFalse(requests.contains { $0.pageSet == .even })
        XCTAssertEqual(orchestrator.flipAnimationNonce, 0)
        XCTAssertEqual(orchestrator.phase, .cancelled(.backs))
        XCTAssertEqual(
            notifier.events,
            [.flipRequired(prompt), .canceled]
        )
    }

    // MARK: - Failure and recovery

    func testPrinterStoppedBetweenPassesFailsBacksThenRetryBacksPrintsOnlyBacks() async throws {
        let spooler = MockPrintSpooler()
        let notifier = MockDuplexNotifier()
        let orchestrator = DuplexOrchestrator(spooler: spooler, notifier: notifier)
        let document = try makeDocument(pageCount: 4)

        let task = orchestrator.start(
            document: document,
            configuration: makeConfiguration()
        )
        try await waitUntil("flip prompt") {
            if case .awaitingFlip = orchestrator.phase { return true }
            return false
        }

        await spooler.setPrinterStopped(true, reasons: ["media-jam-error"])
        orchestrator.confirmFlip()
        await waitForTask(task)

        let expectedFailure = DuplexFailure.printerStoppedBeforeBacks(
            reasons: ["media-jam-error"]
        )
        XCTAssertEqual(orchestrator.phase, .failed(expectedFailure))

        let afterFailure = await spooler.requests
        XCTAssertEqual(afterFailure.count, 1)
        XCTAssertEqual(afterFailure[0].pageSet, .odd)
        XCTAssertFalse(afterFailure.contains { $0.pageSet == .even })
        XCTAssertEqual(
            notifier.events.last,
            .failed(printerName: "Epson L1800", failure: expectedFailure)
        )

        // Recovery: the retry must submit only the backs pass.
        await spooler.setPrinterStopped(false)
        let retryTask = try XCTUnwrap(orchestrator.retryBacks())
        await waitForTask(retryTask)

        let afterRetry = await spooler.requests
        XCTAssertEqual(afterRetry.count, 2)
        XCTAssertEqual(afterRetry[0].pageSet, .odd)
        XCTAssertEqual(afterRetry[1].pageSet, .even)
        XCTAssertEqual(afterRetry[1].title, "FlipStack backs")
        XCTAssertEqual(afterRetry[1].fileURL, sourceURL)
        XCTAssertFalse(afterRetry.dropFirst().contains { $0.pageSet == .odd })

        guard case .completed(let result) = orchestrator.phase else {
            return XCTFail("Expected completed after retryBacks, got \(orchestrator.phase)")
        }
        XCTAssertEqual(result.sheetCount, 2)
        XCTAssertEqual(orchestrator.progress, 1, accuracy: 0.0001)
    }

    func testAbortedJobFailsTheFrontsPass() async throws {
        let spooler = MockPrintSpooler()
        let notifier = MockDuplexNotifier()
        let orchestrator = DuplexOrchestrator(spooler: spooler, notifier: notifier)
        await spooler.setJobPolicy(.sequence([.processing, .aborted]))
        await spooler.setJobReasons(["cups-invalid-job"])

        let document = try makeDocument(pageCount: 4)
        let task = orchestrator.start(
            document: document,
            configuration: makeConfiguration()
        )
        await waitForTask(task)

        let expectedFailure = DuplexFailure.jobFailed(
            pass: .fronts,
            state: .aborted,
            reasons: ["cups-invalid-job"]
        )
        XCTAssertEqual(orchestrator.phase, .failed(expectedFailure))

        let requests = await spooler.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertFalse(requests.contains { $0.pageSet == .even })
        XCTAssertEqual(
            notifier.events.last,
            .failed(printerName: "Epson L1800", failure: expectedFailure)
        )
    }

    func testStuckJobFailsWithTinyTimeoutAndAttemptsCancellation() async throws {
        let spooler = MockPrintSpooler()
        let notifier = MockDuplexNotifier()
        let orchestrator = DuplexOrchestrator(spooler: spooler, notifier: notifier)
        await spooler.setJobPolicy(.forever(.processing, impressionsCompleted: 0))

        let document = try makeDocument(pageCount: 4)
        let configuration = makeConfiguration(
            pollInterval: 0.005,
            jobStuckTimeout: 0.06,
            printerErrorGracePeriod: 0.2
        )
        let task = orchestrator.start(
            document: document,
            configuration: configuration
        )
        await waitForTask(task)

        guard case .failed(.jobStuck(let pass, let seconds)) = orchestrator.phase else {
            return XCTFail("Expected jobStuck, got \(orchestrator.phase)")
        }
        XCTAssertEqual(pass, .fronts)
        XCTAssertGreaterThanOrEqual(seconds, 0.05)

        let submittedIDs = await spooler.submittedJobIDs
        let jobID = try XCTUnwrap(submittedIDs.first)
        try await waitUntilAsync("stuck job cancellation") {
            await spooler.cancellations.contains(jobID)
        }

        let requests = await spooler.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertFalse(requests.contains { $0.pageSet == .even })
    }

    /// A slow photo print can stay in `.processing` with no impressions
    /// counter. As long as CUPS says the printer is actually processing, the
    /// watchdog must not abort it.
    func testSlowProcessingPrinterIsNotDeclaredStuck() async throws {
        let spooler = MockPrintSpooler()
        let notifier = MockDuplexNotifier()
        let orchestrator = DuplexOrchestrator(spooler: spooler, notifier: notifier)
        await spooler.setJobPolicy(.forever(.processing, impressionsCompleted: nil))
        await spooler.setPrinter(state: .processing)

        let document = try makeDocument(pageCount: 4)
        let configuration = makeConfiguration(
            pollInterval: 0.005,
            jobStuckTimeout: 0.05,
            printerErrorGracePeriod: 0.2
        )
        let task = orchestrator.start(document: document, configuration: configuration)

        try await waitUntil("fronts printing") {
            if case .printing(let pass, _) = orchestrator.phase { return pass == .fronts }
            return false
        }
        try await Task.sleep(nanoseconds: 180_000_000)

        guard case .printing(let pass, _) = orchestrator.phase else {
            return XCTFail("A processing printer must not be declared stuck, got \(orchestrator.phase)")
        }
        XCTAssertEqual(pass, .fronts)

        orchestrator.cancel()
        await waitForTask(task)
    }

    // MARK: - Confirmation guards

    func testConfirmInWrongPhaseIsANoOp() async throws {
        let spooler = MockPrintSpooler()
        let orchestrator = DuplexOrchestrator(spooler: spooler)
        await spooler.setJobPolicy(.forever(.processing, impressionsCompleted: 2))

        XCTAssertEqual(orchestrator.phase, .idle)
        orchestrator.confirmFlip()
        XCTAssertEqual(orchestrator.flipAnimationNonce, 0)

        let document = try makeDocument(pageCount: 4)
        let task = orchestrator.start(
            document: document,
            configuration: makeConfiguration(jobStuckTimeout: 1)
        )
        try await waitUntil("fronts printing") {
            if case .printing(let pass, _) = orchestrator.phase {
                return pass == .fronts
            }
            return false
        }

        orchestrator.confirmFlip()
        XCTAssertEqual(orchestrator.flipAnimationNonce, 0)
        XCTAssertTrue(orchestrator.phase.isActive)

        orchestrator.cancel()
        await waitForTask(task)
        XCTAssertEqual(orchestrator.flipAnimationNonce, 0)
    }

    func testConfirmIncrementsNonceExactlyOnce() async throws {
        let spooler = MockPrintSpooler()
        let notifier = MockDuplexNotifier()
        let orchestrator = DuplexOrchestrator(spooler: spooler, notifier: notifier)
        let document = try makeDocument(pageCount: 2)

        let task = orchestrator.start(
            document: document,
            configuration: makeConfiguration()
        )
        try await waitUntil("flip prompt") {
            if case .awaitingFlip = orchestrator.phase { return true }
            return false
        }

        XCTAssertEqual(orchestrator.flipAnimationNonce, 0)
        orchestrator.confirmFlip()
        XCTAssertEqual(orchestrator.flipAnimationNonce, 1)
        orchestrator.confirmFlip()
        XCTAssertEqual(orchestrator.flipAnimationNonce, 1)

        await waitForTask(task)
        XCTAssertEqual(orchestrator.flipAnimationNonce, 1)

        guard case .completed = orchestrator.phase else {
            return XCTFail("Expected completed, got \(orchestrator.phase)")
        }

        orchestrator.confirmFlip()
        XCTAssertEqual(orchestrator.flipAnimationNonce, 1)
        XCTAssertEqual(
            notifier.events.filter {
                if case .flipRequired = $0 { return true }
                return false
            }.count,
            1
        )
    }

    // MARK: - Helpers

    private func makeDocument(
        pageCount: Int,
        title: String = "Sample",
        pageRanges: [PageRange] = []
    ) throws -> DuplexDocument {
        try DuplexDocument.manualDuplex(
            fileURL: sourceURL,
            pageCount: pageCount,
            title: title,
            pageRanges: pageRanges
        )
    }

    private func makeConfiguration(
        axis: FlipAxis = .longEdge,
        ejectsFaceDown: Bool = false,
        driverOptions: [String: String] = [:],
        copies: Int = 1,
        pollInterval: TimeInterval = 0.005,
        jobStuckTimeout: TimeInterval = 0.25,
        printerErrorGracePeriod: TimeInterval = 0.05
    ) -> DuplexConfiguration {
        DuplexConfiguration(
            printerID: "printer-1",
            printerName: "Epson L1800",
            flipAxis: axis,
            ejectsFaceDown: ejectsFaceDown,
            driverOptions: driverOptions,
            copies: copies,
            pollInterval: pollInterval,
            jobStuckTimeout: jobStuckTimeout,
            printerErrorGracePeriod: printerErrorGracePeriod
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ description: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline {
                XCTFail("Timed out waiting for \(description)", file: file, line: line)
                throw TimeoutError()
            }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    private func waitUntilAsync(
        timeout: TimeInterval = 2,
        _ description: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: @MainActor () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) {
            if Date() >= deadline {
                XCTFail("Timed out waiting for \(description)", file: file, line: line)
                throw TimeoutError()
            }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    private func waitForTask(
        _ task: Task<Void, Never>,
        timeout: TimeInterval = 2
    ) async {
        let finished = expectation(description: "duplex orchestrator task finished")
        Task { @MainActor in
            await task.value
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: timeout)
    }
}

private struct TimeoutError: Error {}
