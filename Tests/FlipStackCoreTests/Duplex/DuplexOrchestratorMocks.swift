import Foundation
@testable import FlipStackCore

/// Scriptable in-memory spooler used by the duplex state-machine tests.
actor MockPrintSpooler: PrintSpooling {
    enum JobPolicy: Sendable {
        /// Consumes one state per `job(id:printerID:)` poll and holds the last
        /// state once the sequence is exhausted.
        case sequence([JobState])
        /// Reports the same state (and impression count) on every poll.
        case forever(JobState, impressionsCompleted: Int?)
        /// The submitted job disappears from both live and recent history.
        case missingAfterSubmit
        /// Reports a `.completed` job whose owner/creation date are overridden,
        /// to simulate a reused numeric id belonging to another user or to an
        /// older job.
        case spoofedCompletion(owner: String?, createdAt: Date?)
    }

    struct Submission: Sendable {
        let request: PrintRequest
        let jobID: Int
    }

    enum MockError: LocalizedError, Sendable {
        case submitUnavailable
        case printerLookupFailed

        var errorDescription: String? {
            switch self {
            case .submitUnavailable:
                return "The test queue rejected the job."
            case .printerLookupFailed:
                return "The test queue could not be reached."
            }
        }
    }

    private(set) var submissions: [Submission] = []
    private(set) var cancelledJobIDs: [Int] = []
    private(set) var jobPollCount = 0
    private(set) var printerPollCount = 0

    private var nextJobID = 101
    private var jobRecords: [Int: PrintJob] = [:]
    private var policies: [Int: JobPolicy] = [:]
    private var sequenceIndexes: [Int: Int] = [:]
    private var hiddenJobIDs: Set<Int> = []
    private var defaultPolicy: JobPolicy = .sequence([.pending, .processing, .completed])
    private var jobReasons: [String] = []
    private var submitError: MockError?
    private var printerLookupError: MockError?
    private var jobOwner: String?
    private var storedPrinter = Printer(
        id: "printer-1",
        name: "Epson L1800",
        state: .idle,
        isDefault: true
    )

    // MARK: Configuration

    func setJobPolicy(_ policy: JobPolicy) {
        defaultPolicy = policy
    }

    func setJobReasons(_ reasons: [String]) {
        jobReasons = reasons
    }

    func setSubmitError(_ error: MockError?) {
        submitError = error
    }

    func setPrinterLookupError(_ error: MockError?) {
        printerLookupError = error
    }

    /// Owner stamped on every submitted job, so tests can exercise the
    /// reused-job-id owner check in the orchestrator's monitor loop.
    func setJobOwner(_ owner: String?) {
        jobOwner = owner
    }

    func setPrinter(state: PrinterState, reasons: [String] = []) {
        storedPrinter.state = state
        storedPrinter.stateReasons = reasons
    }

    func setPrinterStopped(_ stopped: Bool, reasons: [String] = ["media-jam-error"]) {
        storedPrinter.state = stopped ? .stopped : .idle
        storedPrinter.stateReasons = stopped ? reasons : []
    }

    // MARK: Read access

    var requests: [PrintRequest] {
        submissions.map(\.request)
    }

    var submittedJobIDs: [Int] {
        submissions.map(\.jobID)
    }

    var cancellations: [Int] {
        cancelledJobIDs
    }

    var printer: Printer {
        storedPrinter
    }

    // MARK: PrintSpooling

    func listPrinters() async throws -> [Printer] {
        [storedPrinter]
    }

    func printer(id: String) async throws -> Printer {
        printerPollCount += 1
        if let printerLookupError {
            throw printerLookupError
        }
        return storedPrinter
    }

    func submit(_ request: PrintRequest) async throws -> PrintJob {
        if let submitError {
            throw submitError
        }

        let jobID = nextJobID
        nextJobID += 1

        let job = PrintJob(
            id: jobID,
            printerID: request.printerID,
            title: request.title,
            state: .pending,
            stateReasons: [],
            impressionsCompleted: 0,
            impressionsTotal: 4,
            createdAt: Date(),
            owner: jobOwner
        )

        submissions.append(Submission(request: request, jobID: jobID))
        jobRecords[jobID] = job
        policies[jobID] = defaultPolicy
        sequenceIndexes[jobID] = 0
        return job
    }

    func job(id: Int, printerID: String) async throws -> PrintJob? {
        jobPollCount += 1

        guard !hiddenJobIDs.contains(id) else { return nil }
        guard var job = jobRecords[id] else { return nil }

        switch policies[id] ?? .sequence([.completed]) {
        case .missingAfterSubmit:
            hiddenJobIDs.insert(id)
            return nil

        case .spoofedCompletion(let owner, let createdAt):
            job.state = .completed
            job.impressionsCompleted = 4
            job.stateReasons = []
            job.owner = owner ?? job.owner
            job.createdAt = createdAt ?? job.createdAt
            jobRecords[id] = job
            return job

        case .forever(let state, let impressions):
            job.state = state
            job.impressionsCompleted = impressions
                ?? Self.impressions(for: state)
            job.stateReasons = state.isTerminal ? jobReasons : []
            jobRecords[id] = job
            return job

        case .sequence(let states):
            guard !states.isEmpty else { return nil }
            let index = min(sequenceIndexes[id] ?? 0, states.count - 1)
            let state = states[index]
            sequenceIndexes[id] = min(index + 1, states.count - 1)
            job.state = state
            job.impressionsCompleted = Self.impressions(for: state)
            job.stateReasons = state.isTerminal ? jobReasons : []
            jobRecords[id] = job
            return job
        }
    }

    func activeJobs(printerID: String) async throws -> [PrintJob] {
        jobRecords.values
            .filter { !hiddenJobIDs.contains($0.id) && $0.isActive }
            .sorted { $0.id > $1.id }
    }

    func recentJobs(printerID: String, limit: Int) async throws -> [PrintJob] {
        jobRecords.values
            .filter { !hiddenJobIDs.contains($0.id) }
            .sorted { $0.id > $1.id }
            .prefix(max(0, limit))
            .map { $0 }
    }

    func cancel(jobID: Int, printerID: String) async throws {
        cancelledJobIDs.append(jobID)
        guard var job = jobRecords[jobID], job.state != .completed else { return }
        job.state = .canceled
        job.stateReasons = ["cancelled-by-user"]
        jobRecords[jobID] = job
    }

    private static func impressions(for state: JobState) -> Int {
        switch state {
        case .completed: return 4
        case .processing: return 2
        case .canceled, .aborted, .stopped: return 1
        default: return 0
        }
    }
}

@MainActor
final class MockDuplexNotifier: DuplexNotifying {
    private(set) var events: [DuplexNotificationEvent] = []

    func handle(_ event: DuplexNotificationEvent) {
        events.append(event)
    }
}
