import Combine
import Foundation

/// Drives a two-pass manual duplex print on a simplex printer.
///
/// The state machine is deliberately conservative: the second pass is only
/// submitted after CUPS reports the front pass as *completed* and the user
/// explicitly confirms the physical flip. No page-order option is ever added
/// to a request; the flipped block itself restores the correct order.
@MainActor
public final class DuplexOrchestrator: ObservableObject {
    @Published public private(set) var phase: DuplexPhase
    @Published public private(set) var progress: Double
    @Published public private(set) var flipAnimationNonce: Int

    private let spooler: any PrintSpooling
    private let notifier: (any DuplexNotifying)?

    private var runTask: Task<Void, Never>?
    /// Invalidates work from an earlier or canceled run. Every mutation after
    /// an `await` is guarded by the token captured when the run started.
    private var runToken: UInt64 = 0
    private var document: DuplexDocument?
    private var configuration: DuplexConfiguration?
    private var activePass: DuplexPass?
    private var activeJob: PrintJob?
    private var flipContinuation: CheckedContinuation<Bool, Never>?
    /// Set when `confirmFlip()` arrives after the phase is published but before
    /// the continuation is installed (for example from a synchronous
    /// `@Published` observer). It also makes repeated confirms idempotent.
    private var flipWasConfirmed = false
    private var startedAt: Date?

    /// Number of consecutive polls that may fail to locate a submitted job
    /// before the monitor gives up.
    private static let unknownJobPollLimit = 3

    public init(
        spooler: any PrintSpooling,
        notifier: (any DuplexNotifying)? = nil
    ) {
        self.spooler = spooler
        self.notifier = notifier
        self.phase = .idle
        self.progress = 0
        self.flipAnimationNonce = 0
    }

    // MARK: - Public control

    public var isRunning: Bool {
        phase.isActive
    }

    @discardableResult
    public func start(
        document: DuplexDocument,
        configuration: DuplexConfiguration
    ) -> Task<Void, Never> {
        // A second start while a run is active must never submit another job.
        guard !isRunning else { return Task {} }
        return beginFronts(document: document, configuration: configuration)
    }

    /// Confirms the physical flip. Only valid while the machine is waiting for
    /// the user; resuming the continuation is what actually advances the run.
    public func confirmFlip() {
        guard case .awaitingFlip = phase, !flipWasConfirmed else { return }

        flipWasConfirmed = true
        flipAnimationNonce += 1

        if let continuation = flipContinuation {
            flipContinuation = nil
            continuation.resume(returning: true)
        }
        // Otherwise the confirmation is buffered; `waitForFlipConfirmation`
        // observes the flag as soon as it installs the waiter.
    }

    /// Cancels the active run. This is safe from any phase, but only does work
    /// while a run is active, so a double cancel cannot notify twice.
    public func cancel() {
        guard phase.isActive else { return }

        let pass = activePass
        let job = activeJob

        runToken &+= 1
        runTask?.cancel()
        runTask = nil
        flipWasConfirmed = false
        resolveFlipConfirmation(false)
        activeJob = nil
        activePass = pass

        if let job {
            cancelJobBestEffort(job)
        }

        phase = .cancelled(pass)
        notifier?.handle(.canceled)
    }

    /// Restarts a fronts-pass failure from the beginning. Failures on the backs
    /// pass use `retryBacks()` so the fronts are not printed a second time.
    @discardableResult
    public func retry() -> Task<Void, Never>? {
        guard case .failed(let failure) = phase else { return nil }
        // A failure without a pass (for example the queue being unavailable)
        // is also a fronts-side failure from the user's perspective.
        guard failure.pass == .fronts || failure.pass == nil else { return nil }
        guard let document, let configuration else { return nil }
        return beginFronts(document: document, configuration: configuration)
    }

    /// Retries only the backs pass, after a backs-side failure or a printer
    /// error detected between the passes. Fronts are never reprinted here.
    @discardableResult
    public func retryBacks() -> Task<Void, Never>? {
        guard case .failed(let failure) = phase, failure.canRetryBacks else {
            return nil
        }
        guard let document, let configuration else { return nil }
        return beginBacks(document: document, configuration: configuration)
    }

    /// Returns an inactive orchestrator to a clean slate. Refuses to interrupt
    /// a run; use `cancel()` first when a run is active.
    public func reset() {
        guard !isRunning else { return }

        runToken &+= 1
        runTask?.cancel()
        runTask = nil
        flipWasConfirmed = false
        resolveFlipConfirmation(false)

        phase = .idle
        progress = 0
        activePass = nil
        activeJob = nil
        document = nil
        configuration = nil
        startedAt = nil
    }

    // MARK: - Run setup

    private func beginFronts(
        document: DuplexDocument,
        configuration: DuplexConfiguration
    ) -> Task<Void, Never> {
        runToken &+= 1
        let token = runToken

        runTask?.cancel()
        flipWasConfirmed = false
        resolveFlipConfirmation(false)

        self.document = document
        self.configuration = configuration
        self.activePass = .fronts
        self.activeJob = nil
        self.startedAt = Date()
        self.progress = 0
        self.phase = .preparing

        let task = Task { [weak self] in
            guard let self else { return }
            await self.runFronts(
                document: document,
                configuration: configuration,
                token: token
            )
        }
        runTask = task
        return task
    }

    private func beginBacks(
        document: DuplexDocument,
        configuration: DuplexConfiguration
    ) -> Task<Void, Never> {
        runToken &+= 1
        let token = runToken

        runTask?.cancel()
        flipWasConfirmed = false
        resolveFlipConfirmation(false)

        self.document = document
        self.configuration = configuration
        self.activePass = .backs
        self.activeJob = nil
        if startedAt == nil {
            startedAt = Date()
        }
        self.progress = 0.55
        self.phase = .preparing

        let task = Task { [weak self] in
            guard let self else { return }
            await self.runBacks(
                document: document,
                configuration: configuration,
                token: token
            )
        }
        runTask = task
        return task
    }

    // MARK: - Passes

    private func runFronts(
        document: DuplexDocument,
        configuration: DuplexConfiguration,
        token: UInt64
    ) async {
        guard isCurrent(token), !Task.isCancelled else { return }

        guard document.firstPass.pageCount > 0 else {
            finishFailure(
                .invalidDocument("The document has no pages to print on the front sides."),
                configuration: configuration,
                token: token
            )
            return
        }

        // Fail fast on a queue that is already stopped rather than submitting
        // a job that CUPS would hold indefinitely.
        guard await printerAllowsPrinting(
            pass: .fronts,
            configuration: configuration,
            token: token
        ) else { return }

        guard isCurrent(token), !Task.isCancelled else { return }

        let frontsCompleted = await printPass(
            .fronts,
            source: document.firstPass,
            document: document,
            configuration: configuration,
            token: token
        )
        guard frontsCompleted, isCurrent(token), !Task.isCancelled else { return }

        // A one-page document, or an imposed booklet with nothing on the backs,
        // finishes after the fronts without ever asking for a flip.
        guard document.hasBackSides else {
            finishSuccess(
                document: document,
                configuration: configuration,
                token: token
            )
            return
        }

        setProgress(0.5)
        activeJob = nil
        // The fronts are complete. If the user cancels while the flip prompt
        // is open, the meaningful pass to report is the backs that never ran.
        activePass = .backs

        let prompt = FlipPrompt.make(
            printerName: configuration.printerName,
            sheetCount: document.sheetCount,
            flipAxis: configuration.flipAxis,
            mode: configuration.flipMode,
            hasOddPageCount: document.hasOddPageCount
        )
        phase = .awaitingFlip(prompt)

        let confirmed = await waitForFlipConfirmation(prompt, token: token)
        guard confirmed, isCurrent(token), !Task.isCancelled else { return }
        guard case .awaitingFlip = phase else { return }

        // The printer may have gone offline while the user was flipping the
        // stack. Check once more before creating the backs job.
        guard await printerAllowsPrinting(
            pass: .backs,
            configuration: configuration,
            token: token
        ) else { return }

        guard isCurrent(token), !Task.isCancelled else { return }

        let backsCompleted = await printPass(
            .backs,
            source: document.secondPass,
            document: document,
            configuration: configuration,
            token: token
        )
        guard backsCompleted, isCurrent(token), !Task.isCancelled else { return }

        finishSuccess(
            document: document,
            configuration: configuration,
            token: token
        )
    }

    private func runBacks(
        document: DuplexDocument,
        configuration: DuplexConfiguration,
        token: UInt64
    ) async {
        guard isCurrent(token), !Task.isCancelled else { return }

        guard await printerAllowsPrinting(
            pass: .backs,
            configuration: configuration,
            token: token
        ) else { return }

        guard isCurrent(token), !Task.isCancelled else { return }

        let completed = await printPass(
            .backs,
            source: document.secondPass,
            document: document,
            configuration: configuration,
            token: token
        )
        guard completed, isCurrent(token), !Task.isCancelled else { return }

        finishSuccess(
            document: document,
            configuration: configuration,
            token: token
        )
    }

    /// Submits one pass and waits for the real CUPS job to complete. Returns
    /// `true` only when the job reached `.completed`; failures are recorded on
    /// the orchestrator before returning `false`.
    private func printPass(
        _ pass: DuplexPass,
        source: PrintSource,
        document: DuplexDocument,
        configuration: DuplexConfiguration,
        token: UInt64
    ) async -> Bool {
        guard isCurrent(token), !Task.isCancelled else { return false }

        activePass = pass
        setProgress(pass == .fronts ? 0.02 : 0.55)
        let singleSidedOptions = configuration.driverOptions.merging(
            ["sides": "one-sided"],
            uniquingKeysWith: { _, forced in forced }
        )
        let request = PrintRequest(
            fileURL: source.fileURL,
            printerID: configuration.printerID,
            title: Self.title(document: document, pass: pass),
            pageSet: source.pageSet,
            pageRanges: source.pageRanges,
            copies: configuration.copies,
            numberUp: source.numberUp,
            orientation: source.orientation,
            driverOptions: document.isSingleSided
                ? singleSidedOptions
                : configuration.driverOptionsWithDuplex,
            fitToPage: configuration.fitToPage,
            scalePercent: configuration.scalePercent
        )

        let job: PrintJob
        do {
            job = try await spooler.submit(request)
        } catch {
            guard isCurrent(token), !Task.isCancelled else { return false }
            finishFailure(
                .submitFailed(pass: pass, message: error.localizedDescription),
                configuration: configuration,
                token: token
            )
            return false
        }

        // Cancellation (or a reset) may land while `submit` is in flight. The
        // job was never shown as active, so cancel it here to avoid printing a
        // stray pass after the user canceled.
        guard isCurrent(token), !Task.isCancelled else {
            cancelJobBestEffort(job)
            return false
        }

        activeJob = job
        phase = .printing(pass: pass, job: job)

        return await monitor(
            pass: pass,
            initialJob: job,
            isSingleSided: document.isSingleSided,
            configuration: configuration,
            token: token
        )
    }

    // MARK: - Job monitoring

    private func monitor(
        pass: DuplexPass,
        initialJob: PrintJob,
        isSingleSided: Bool,
        configuration: DuplexConfiguration,
        token: UInt64
    ) async -> Bool {
        let pollInterval = max(0.001, configuration.pollInterval)
        let pollNanoseconds = Self.nanoseconds(for: pollInterval)
        let stuckTimeout = max(0, configuration.jobStuckTimeout)
        let errorGracePeriod = max(0, configuration.printerErrorGracePeriod)

        var currentJob = initialJob
        var lastState = currentJob.state
        var lastImpressions = currentJob.impressionsCompleted
        var lastActivity = Date()
        var unknownPolls = 0
        var printerErrorSince: Date?
        var printerReportsProcessing = false

        while true {
            guard isCurrent(token), !Task.isCancelled else { return false }

            // Prefer the authoritative job lookup. The recent list is only a
            // fallback for queues that drop a job from `lpstat -W` after it
            // reaches a terminal state.
            var latest: PrintJob?
            do {
                latest = try await spooler.job(
                    id: initialJob.id,
                    printerID: configuration.printerID
                )
            } catch {
                latest = nil
            }
            guard isCurrent(token), !Task.isCancelled else { return false }

            if latest == nil {
                do {
                    let recent = try await spooler.recentJobs(
                        printerID: configuration.printerID,
                        limit: 20
                    )
                    latest = recent.first(where: { $0.id == initialJob.id })
                } catch {
                    latest = nil
                }
                guard isCurrent(token), !Task.isCancelled else { return false }
            }

            if let latest {
                unknownPolls = 0
                if latest != currentJob {
                    currentJob = latest
                    activeJob = latest
                    phase = .printing(pass: pass, job: latest)
                }
            } else {
                unknownPolls += 1
                if unknownPolls >= Self.unknownJobPollLimit {
                    finishFailure(
                        .monitorFailed(
                            pass: pass,
                            message: "The print job is no longer in the print queue."
                        ),
                        configuration: configuration,
                        token: token
                    )
                    return false
                }
            }

            if let fraction = currentJob.progress {
                if isSingleSided {
                    setProgress(0.02 + 0.97 * fraction)
                } else {
                    switch pass {
                    case .fronts:
                        setProgress(0.02 + 0.43 * fraction)
                    case .backs:
                        setProgress(0.55 + 0.44 * fraction)
                    }
                }
            }

            switch currentJob.state {
            case .completed:
                activeJob = currentJob
                return true
            case .canceled, .aborted, .stopped:
                if currentJob.state == .stopped {
                    cancelJobBestEffort(currentJob)
                }
                finishFailure(
                    .jobFailed(
                        pass: pass,
                        state: currentJob.state,
                        reasons: currentJob.stateReasons
                    ),
                    configuration: configuration,
                    token: token
                )
                return false
            default:
                break
            }

            let now = Date()
            if currentJob.state != lastState
                || currentJob.impressionsCompleted != lastImpressions {
                lastState = currentJob.state
                lastImpressions = currentJob.impressionsCompleted
                lastActivity = now
            }

            if now.timeIntervalSince(lastActivity) >= stuckTimeout {
                // A queue that is genuinely printing can be quiet for a long
                // time (large photo prints have no impressions counter in
                // lpstat). Only call it stuck when the printer itself is not
                // reporting active work, or after a much longer hard cap.
                let effectiveTimeout = printerReportsProcessing ? stuckTimeout * 6 : stuckTimeout
                if now.timeIntervalSince(lastActivity) >= effectiveTimeout {
                    cancelJobBestEffort(currentJob)
                    finishFailure(
                        .jobStuck(
                            pass: pass,
                            seconds: now.timeIntervalSince(lastActivity)
                        ),
                        configuration: configuration,
                        token: token
                    )
                    return false
                }
            }

            // A stopped queue can be temporary (paper, cover, a spooler
            // hiccup). Give it a grace period, then stop the run.
            do {
                let printer = try await spooler.printer(id: configuration.printerID)
                guard isCurrent(token), !Task.isCancelled else { return false }

                let hasProblem = printer.state == .stopped
                    || !printer.acceptsJobs
                    || printer.hasError
                printerReportsProcessing = printer.state == .processing
                if hasProblem {
                    if printerErrorSince == nil {
                        printerErrorSince = Date()
                    }
                    if let since = printerErrorSince,
                       Date().timeIntervalSince(since) >= errorGracePeriod {
                        cancelJobBestEffort(currentJob)
                        finishFailure(
                            .printerStopped(
                                pass: pass,
                                reasons: printer.stateReasons
                            ),
                            configuration: configuration,
                            token: token
                        )
                        return false
                    }
                } else {
                    printerErrorSince = nil
                }
            } catch {
                // Status lookup failures are not job failures. The job lookup
                // and stuck watchdog still protect the run.
            }

            do {
                try await Task.sleep(nanoseconds: pollNanoseconds)
            } catch {
                return false
            }
        }
    }

    /// Checks the queue once before a pass is submitted. Used for the initial
    /// fronts preflight and for the mandatory check between passes.
    private func printerAllowsPrinting(
        pass: DuplexPass,
        configuration: DuplexConfiguration,
        token: UInt64
    ) async -> Bool {
        guard isCurrent(token), !Task.isCancelled else { return false }

        do {
            let printer = try await spooler.printer(id: configuration.printerID)
            guard isCurrent(token), !Task.isCancelled else { return false }

            if printer.state == .stopped || !printer.acceptsJobs || printer.hasError {
                finishFailure(
                    .printerStopped(pass: pass, reasons: printer.stateReasons),
                    configuration: configuration,
                    token: token
                )
                return false
            }
            return true
        } catch {
            guard isCurrent(token), !Task.isCancelled else { return false }
            finishFailure(
                .printerUnavailable(error.localizedDescription),
                configuration: configuration,
                token: token
            )
            return false
        }
    }

    // MARK: - Flip confirmation

    /// Installs the continuation *before* posting the notification, so a
    /// notifier that confirms synchronously cannot deadlock the flow. A
    /// confirmation buffered by a synchronous phase observer is honored too.
    private func waitForFlipConfirmation(
        _ prompt: FlipPrompt,
        token: UInt64
    ) async -> Bool {
        guard isCurrent(token), !Task.isCancelled else { return false }
        if flipWasConfirmed {
            // A synchronous observer (or a notification action) confirmed as
            // soon as `.awaitingFlip` was published. Nothing left to ask the
            // user; do not post a stale notification.
            return true
        }

        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            guard isCurrent(token), !Task.isCancelled else {
                continuation.resume(returning: false)
                return
            }
            if flipWasConfirmed {
                continuation.resume(returning: true)
                return
            }
            flipContinuation = continuation
            notifier?.handle(.flipRequired(prompt))
        }
    }

    private func resolveFlipConfirmation(_ confirmed: Bool) {
        guard let continuation = flipContinuation else { return }
        flipContinuation = nil
        continuation.resume(returning: confirmed)
    }

    // MARK: - Completion

    private func finishSuccess(
        document: DuplexDocument,
        configuration: DuplexConfiguration,
        token: UInt64
    ) {
        guard isCurrent(token) else { return }

        let elapsed = max(0, Date().timeIntervalSince(startedAt ?? Date()))
        let result = DuplexResult(
            printerName: configuration.printerName,
            sourcePageCount: document.sourcePageCount,
            sheetCount: document.sheetCount,
            isBooklet: document.isBooklet,
            hadBlankFinalBack: document.hasBackSides && document.hasBlankFinalBack,
            elapsed: elapsed,
            isSingleSided: document.isSingleSided
        )

        // Invalidate any late work before publishing the terminal state.
        runToken &+= 1
        runTask = nil
        activeJob = nil
        activePass = nil
        progress = 1
        phase = .completed(result)

        notifier?.handle(
            .completed(
                printerName: configuration.printerName,
                sheetCount: document.sheetCount
            )
        )
    }

    private func finishFailure(
        _ failure: DuplexFailure,
        configuration: DuplexConfiguration,
        token: UInt64
    ) {
        guard isCurrent(token) else { return }

        runToken &+= 1
        runTask = nil
        activeJob = nil
        activePass = failure.pass ?? activePass
        phase = .failed(failure)

        notifier?.handle(
            .failed(printerName: configuration.printerName, failure: failure)
        )
    }

    // MARK: - Helpers

    private func isCurrent(_ token: UInt64) -> Bool {
        token == runToken
    }

    private func setProgress(_ value: Double) {
        let clamped = min(max(value, 0), 1)
        // Progress never moves backwards during a run.
        if clamped > progress {
            progress = clamped
        }
    }

    private func cancelJobBestEffort(_ job: PrintJob) {
        let spooler = self.spooler
        let jobID = job.id
        let printerID = job.printerID
        Task {
            try? await spooler.cancel(jobID: jobID, printerID: printerID)
        }
    }

    /// CUPS job titles are visible to the queue owner and may be retained in
    /// spool metadata. Keep the document name in FlipStack's in-memory queue
    /// labels; never send it to CUPS.
    private static func title(document: DuplexDocument, pass: DuplexPass) -> String {
        if document.isSingleSided {
            return "FlipStack job"
        }
        if document.isBooklet {
            return "FlipStack booklet \(pass.rawValue)"
        }
        return "FlipStack \(pass.rawValue)"
    }

    private static func nanoseconds(for interval: TimeInterval) -> UInt64 {
        let seconds = min(max(interval, 0.001), 60)
        return UInt64((seconds * 1_000_000_000).rounded())
    }
}
