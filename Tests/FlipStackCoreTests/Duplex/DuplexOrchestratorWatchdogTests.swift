import XCTest
@testable import FlipStackCore

/// Watchdog/flip-timing behavior of `DuplexOrchestrator`: a long pause at the
/// flip prompt must not consume the backs pass's stuck budget, a reused job
/// id with a different owner (or an older completion) must not resurrect a
/// completion, and a genuinely stuck job must still trip the watchdog.
@MainActor
final class DuplexOrchestratorWatchdogTests: XCTestCase {
    private let sourceURL = URL(fileURLWithPath: "/tmp/FlipStack-Duplex-Watchdog-Test.pdf")

    func testLongFlipDelayDoesNotCancelTheBacksPass() async throws {
        let spooler = MockPrintSpooler()
        let notifier = MockDuplexNotifier()
        let orchestrator = DuplexOrchestrator(spooler: spooler, notifier: notifier)
        let document = try makeDocument(pageCount: 4)
        // A stuck timeout far shorter than the pause we take at the prompt.
        let configuration = makeConfiguration(jobStuckTimeout: 0.3)

        let task = orchestrator.start(document: document, configuration: configuration)
        try await waitUntil("flip prompt") {
            if case .awaitingFlip = orchestrator.phase { return true }
            return false
        }

        // Wait well past jobStuckTimeout while sitting at the flip prompt.
        try await Task.sleep(nanoseconds: 900_000_000)
        guard case .awaitingFlip = orchestrator.phase else {
            return XCTFail("The flip prompt must still be open, got \(orchestrator.phase)")
        }

        orchestrator.confirmFlip()
        await waitForTask(task)

        let requests = await spooler.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].pageSet, .odd)
        XCTAssertEqual(requests[1].pageSet, .even)

        guard case .completed(let result) = orchestrator.phase else {
            return XCTFail("Expected completed after the long flip delay, got \(orchestrator.phase)")
        }
        XCTAssertEqual(result.sheetCount, 2)
        XCTAssertEqual(orchestrator.progress, 1, accuracy: 0.0001)
        XCTAssertEqual(
            notifier.events.filter {
                if case .completed = $0 { return true }
                return false
            }.count,
            1
        )
    }

    func testReusedJobIDWithDifferentOwnerDoesNotResurrectCompletion() async throws {
        let spooler = MockPrintSpooler()
        let orchestrator = DuplexOrchestrator(spooler: spooler)
        await spooler.setJobOwner("alice")
        // Same numeric id, completed, but owned by another user.
        await spooler.setJobPolicy(.spoofedCompletion(owner: "mallory", createdAt: Date()))

        let document = try makeDocument(pageCount: 4)
        let task = orchestrator.start(
            document: document,
            configuration: makeConfiguration(jobStuckTimeout: 0.2)
        )
        await waitForTask(task)

        guard case .failed(.jobStuck(let pass, _)) = orchestrator.phase else {
            return XCTFail("A foreign owner's completion must not complete the job, got \(orchestrator.phase)")
        }
        XCTAssertEqual(pass, .fronts)

        let requests = await spooler.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertFalse(requests.contains { $0.pageSet == .even })

        // The stuck watchdog still fires and cancels the job.
        let submittedIDs = await spooler.submittedJobIDs
        let jobID = try XCTUnwrap(submittedIDs.first)
        try await waitUntilAsync("stuck job cancellation") {
            await spooler.cancellations.contains(jobID)
        }
        // It kept polling instead of accepting the spoofed completion.
        let pollCount = await spooler.jobPollCount
        XCTAssertGreaterThan(pollCount, 3)
    }

    func testReusedJobIDWithOlderCompletionDoesNotResurrectCompletion() async throws {
        let spooler = MockPrintSpooler()
        let orchestrator = DuplexOrchestrator(spooler: spooler)
        await spooler.setJobOwner("alice")
        // Same owner, but the completion predates this job's submission.
        await spooler.setJobPolicy(
            .spoofedCompletion(owner: "alice", createdAt: Date().addingTimeInterval(-3600))
        )

        let document = try makeDocument(pageCount: 4)
        let task = orchestrator.start(
            document: document,
            configuration: makeConfiguration(jobStuckTimeout: 0.2)
        )
        await waitForTask(task)

        guard case .failed(.jobStuck(let pass, _)) = orchestrator.phase else {
            return XCTFail("An older completion must not complete the job, got \(orchestrator.phase)")
        }
        XCTAssertEqual(pass, .fronts)

        let requests = await spooler.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testGenuineCompletionFromSameOwnerAndNewerDateIsAccepted() async throws {
        let spooler = MockPrintSpooler()
        let notifier = MockDuplexNotifier()
        let orchestrator = DuplexOrchestrator(spooler: spooler, notifier: notifier)
        await spooler.setJobOwner("alice")
        // Same owner, and the job keeps its own submission timestamp: a
        // legitimate completion (createdAt is nil, so the record's own
        // submit-time date is kept, which is not older than the submitted job).
        await spooler.setJobPolicy(.spoofedCompletion(owner: "alice", createdAt: nil))

        let document = try makeDocument(pageCount: 4)
        let task = orchestrator.start(
            document: document,
            configuration: makeConfiguration(jobStuckTimeout: 0.3)
        )
        try await waitUntil("flip prompt") {
            if case .awaitingFlip = orchestrator.phase { return true }
            return false
        }
        orchestrator.confirmFlip()
        await waitForTask(task)

        let requests = await spooler.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[1].pageSet, .even)
        guard case .completed = orchestrator.phase else {
            return XCTFail("Expected completed, got \(orchestrator.phase)")
        }
    }

    func testWatchdogStillFiresForGenuinelyStuckBacksPass() async throws {
        let spooler = MockPrintSpooler()
        let notifier = MockDuplexNotifier()
        let orchestrator = DuplexOrchestrator(spooler: spooler, notifier: notifier)
        let document = try makeDocument(pageCount: 4)
        let configuration = makeConfiguration(jobStuckTimeout: 0.3)

        let task = orchestrator.start(document: document, configuration: configuration)
        try await waitUntil("flip prompt") {
            if case .awaitingFlip = orchestrator.phase { return true }
            return false
        }

        // The fronts completed normally; make only the backs job hang forever.
        await spooler.setJobPolicy(.forever(.processing, impressionsCompleted: 0))
        orchestrator.confirmFlip()
        await waitForTask(task)

        guard case .failed(.jobStuck(let pass, let seconds)) = orchestrator.phase else {
            return XCTFail("Expected jobStuck on the backs pass, got \(orchestrator.phase)")
        }
        XCTAssertEqual(pass, .backs)
        XCTAssertGreaterThanOrEqual(seconds, 0.25)

        let requests = await spooler.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].pageSet, .odd)
        XCTAssertEqual(requests[1].pageSet, .even)

        let submittedIDs = await spooler.submittedJobIDs
        XCTAssertEqual(submittedIDs.count, 2)
        try await waitUntilAsync("backs job cancellation") {
            await spooler.cancellations.contains(submittedIDs[1])
        }
    }

    // MARK: - Helpers

    private func makeDocument(pageCount: Int) throws -> DuplexDocument {
        try DuplexDocument.manualDuplex(
            fileURL: sourceURL,
            pageCount: pageCount,
            title: "Watchdog sample"
        )
    }

    private func makeConfiguration(
        jobStuckTimeout: TimeInterval
    ) -> DuplexConfiguration {
        DuplexConfiguration(
            printerID: "printer-1",
            printerName: "Epson L1800",
            flipAxis: .longEdge,
            ejectsFaceDown: false,
            driverOptions: ["PageSize": "A4"],
            copies: 1,
            pollInterval: 0.005,
            jobStuckTimeout: jobStuckTimeout,
            printerErrorGracePeriod: 0.05
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
                throw WatchdogTimeoutError()
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
                throw WatchdogTimeoutError()
            }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    private func waitForTask(
        _ task: Task<Void, Never>,
        timeout: TimeInterval = 3
    ) async {
        let finished = expectation(description: "orchestrator task finished")
        Task { @MainActor in
            await task.value
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: timeout)
    }
}

private struct WatchdogTimeoutError: Error {}
