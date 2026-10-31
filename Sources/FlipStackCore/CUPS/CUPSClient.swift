import Foundation

/// Talks to CUPS through the standard command-line tools. Every executable is
/// addressed by absolute path and arguments are passed to `Process` directly,
/// so queue names, titles, and file paths are never interpreted by a shell.
public final class CUPSClient: PrintSpooling, @unchecked Sendable {
    private enum Tool {
        static let lp = URL(fileURLWithPath: "/usr/bin/lp")
        static let lpstat = URL(fileURLWithPath: "/usr/bin/lpstat")
        static let cancel = URL(fileURLWithPath: "/usr/bin/cancel")
    }

    private static let defaultTimeout: TimeInterval = 20

    private let runner: any CUPSCommandRunning
    private let timeout: TimeInterval

    public init() {
        self.runner = CUPSProcessRunner()
        self.timeout = Self.defaultTimeout
    }

    init(runner: any CUPSCommandRunning, timeout: TimeInterval = CUPSClient.defaultTimeout) {
        self.runner = runner
        self.timeout = timeout
    }

    // MARK: - PrintSpooling

    public func listPrinters() async throws -> [Printer] {
        let result = try await run(Tool.lpstat, ["-e"])
        if result.status != 0 {
            if isNoDestinations(result.combinedMessage) {
                return []
            }
            throw failure(tool: "lpstat", result: result)
        }

        let names = Array(Set(LPStatParser.parsePrinterNames(result.stdoutText)))
            .sorted { lhs, rhs in
                let left = lhs.lowercased()
                let right = rhs.lowercased()
                return left == right ? lhs < rhs : left < right
            }

        guard !names.isEmpty else { return [] }

        let defaultName = try await defaultPrinterName()
        var printers: [Printer] = []
        printers.reserveCapacity(names.count)

        for queue in names {
            let printer = try await loadPrinter(queue: queue, defaultName: defaultName)
            printers.append(printer)
        }

        printers.sort { lhs, rhs in
            let left = lhs.id.lowercased()
            let right = rhs.id.lowercased()
            return left == right ? lhs.id < rhs.id : left < right
        }
        return printers
    }

    public func printer(id: String) async throws -> Printer {
        let queue = try validatedPrinterID(id)
        let detailResult = try await printerDetailResult(queue: queue)

        guard detailResult.status == 0 else {
            throw failure(tool: "lpstat", result: detailResult, printerID: queue)
        }

        let output = detailResult.stdoutText
        guard let detail = LPStatParser.parsePrinterDetail(output, queue: queue) else {
            if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw CUPSCommandError.printerNotFound(queue)
            }
            throw CUPSCommandError.invalidOutput(output.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let resolvedDeviceURI: String?
        do {
            resolvedDeviceURI = try await deviceURI(for: queue)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // The device URI is optional enrichment; do not hide the queue
            // just because `lpstat -v` failed.
            resolvedDeviceURI = nil
        }
        let isDefault = try await isDefaultPrinter(queue)
        return makePrinter(
            queue: queue,
            detail: detail,
            deviceURI: resolvedDeviceURI,
            isDefault: isDefault
        )
    }

    public func activeJobs(printerID: String) async throws -> [PrintJob] {
        let queue = try validatedPrinterID(printerID)
        let result = try await run(Tool.lpstat, ["-W", "not-completed", "-o", queue])

        guard result.status == 0 else {
            throw failure(tool: "lpstat", result: result, printerID: queue)
        }

        var jobs = LPStatParser.parseJobs(
            result.stdoutText,
            printerID: queue,
            defaultState: .pending
        ).filter { $0.printerID.caseInsensitiveCompare(queue) == .orderedSame }

        if !jobs.isEmpty,
           let printingID = try await currentPrintingJobID(queue: queue),
           let index = jobs.firstIndex(where: { $0.id == printingID }) {
            jobs[index].state = .processing
        }

        jobs.sort { $0.id < $1.id }
        return jobs
    }

    public func recentJobs(printerID: String, limit: Int) async throws -> [PrintJob] {
        guard limit > 0 else { return [] }
        let queue = try validatedPrinterID(printerID)
        // The long form includes job state/alerts, so canceled and aborted
        // history entries are not mistaken for successful completion.
        let result = try await run(Tool.lpstat, ["-l", "-W", "completed", "-o", queue])

        guard result.status == 0 else {
            throw failure(tool: "lpstat", result: result, printerID: queue)
        }

        var jobs = LPStatParser.parseJobs(
            result.stdoutText,
            printerID: queue,
            defaultState: .completed
        ).filter { $0.printerID.caseInsensitiveCompare(queue) == .orderedSame }

        jobs.sort { $0.id > $1.id }
        if jobs.count > limit {
            jobs = Array(jobs.prefix(limit))
        }
        return jobs
    }

    public func job(id: Int, printerID: String) async throws -> PrintJob? {
        guard id > 0 else { return nil }
        let queue = try validatedPrinterID(printerID)

        let activeResult = try await run(Tool.lpstat, ["-W", "not-completed", "-o", queue])
        guard activeResult.status == 0 else {
            throw failure(tool: "lpstat", result: activeResult, printerID: queue)
        }

        var active = LPStatParser.parseJobs(
            activeResult.stdoutText,
            printerID: queue,
            defaultState: .pending
        )
        if let index = active.firstIndex(where: { $0.id == id }) {
            if let printingID = try await currentPrintingJobID(queue: queue), printingID == id {
                active[index].state = .processing
            }

            // Some backends leave a finished job visible in
            // `lpstat -W not-completed` for a while. Completion history is
            // authoritative: if the same id is already there, the physical
            // job is done and the UI must not stay on "Printing".
            if let completed = try? await completedJob(
                id: id,
                printerID: queue,
                activeJob: active[index]
            ) {
                return completed
            }
            return active[index]
        }

        guard let job = try await completedJob(id: id, printerID: queue, activeJob: nil) else {
            return nil
        }
        return job
    }

    public func submit(_ request: PrintRequest) async throws -> PrintJob {
        let queue = try validatedPrinterID(request.printerID)

        let path = request.fileURL.path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              FileManager.default.isReadableFile(atPath: path) else {
            throw CUPSCommandError.fileNotFound(path)
        }

        // Never expose the user's document path or filename in `lp` argv,
        // where `ps` can see it. CUPS reads this private, neutrally named copy
        // during submission; the directory is removed immediately afterward.
        let spoolDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FlipStack", isDirectory: true)
            .appendingPathComponent("Spool-\(UUID().uuidString)", isDirectory: true)
        let neutralURL = spoolDirectory.appendingPathComponent("document.pdf")
        do {
            try FileManager.default.createDirectory(
                at: spoolDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.copyItem(at: request.fileURL, to: neutralURL)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: neutralURL.path
            )
        } catch {
            try? FileManager.default.removeItem(at: spoolDirectory)
            throw CUPSCommandError.fileNotFound(path)
        }
        defer { try? FileManager.default.removeItem(at: spoolDirectory) }

        var validated = request
        validated.printerID = queue
        validated.fileURL = neutralURL
        let arguments = CUPSOptionBuilder.arguments(for: validated)

        let result = try await run(Tool.lp, arguments)
        guard result.status == 0 else {
            throw failure(tool: "lp", result: result)
        }

        guard let submitted = LPStatParser.parseSubmittedJob(result.stdoutText, printerID: queue) else {
            throw CUPSCommandError.invalidOutput(
                result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        return PrintJob(
            id: submitted.id,
            printerID: queue,
            title: request.title,
            state: .pending,
            createdAt: Date(),
            documentCount: submitted.documentCount
        )
    }

    /// Cancellation is idempotent: a job that no longer exists (or already
    /// finished) is treated as successfully canceled, because the caller's
    /// desired end state is already true. Other errors are reported.
    public func cancel(jobID: Int, printerID: String) async throws {
        _ = try validatedPrinterID(printerID)
        guard jobID > 0 else {
            throw CUPSCommandError.jobNotFound(jobID)
        }

        let result = try await run(Tool.cancel, [String(jobID)])
        guard result.status != 0 else { return }

        if isAlreadyGone(result.combinedMessage) {
            return
        }
        throw failure(tool: "cancel", result: result)
    }

    // MARK: - Enrichment

    private func loadPrinter(queue: String, defaultName: String?) async throws -> Printer {
        var detailResult: CUPSCommandResult?
        do {
            detailResult = try await printerDetailResult(queue: queue)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            detailResult = nil
        }

        let detail = detailResult.flatMap { result in
            result.status == 0 ? LPStatParser.parsePrinterDetail(result.stdoutText, queue: queue) : nil
        }

        let resolvedDeviceURI: String?
        do {
            resolvedDeviceURI = try await deviceURI(for: queue)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // A queue may disappear between listing and enrichment. Keep the
            // printer with the information already gathered.
            return Printer(
                id: queue,
                name: detail?.description ?? queue,
                model: detail?.model,
                location: detail?.location,
                deviceURI: nil,
                state: detail?.state ?? .unknown,
                stateReasons: detail?.stateReasons ?? [],
                isDefault: queue.caseInsensitiveCompare(defaultName ?? "") == .orderedSame,
                acceptsJobs: detail?.acceptsJobs ?? true,
                ppdPath: detail?.ppdPath,
                printingJobID: detail?.printingJobID
            )
        }

        return makePrinter(
            queue: queue,
            detail: detail,
            deviceURI: resolvedDeviceURI,
            isDefault: queue.caseInsensitiveCompare(defaultName ?? "") == .orderedSame
        )
    }

    private func makePrinter(
        queue: String,
        detail: LPStatPrinterDetail?,
        deviceURI: String?,
        isDefault: Bool
    ) -> Printer {
        Printer(
            id: queue,
            name: detail?.description ?? queue,
            model: detail?.model,
            location: detail?.location,
            deviceURI: deviceURI,
            state: detail?.state ?? .unknown,
            stateReasons: detail?.stateReasons ?? [],
            isDefault: isDefault,
            acceptsJobs: detail?.acceptsJobs ?? true,
            ppdPath: detail?.ppdPath,
            printingJobID: detail?.printingJobID
        )
    }

    private func defaultPrinterName() async throws -> String? {
        do {
            let result = try await run(Tool.lpstat, ["-d"])
            guard result.status == 0 else { return nil }
            return LPStatParser.parseDefaultPrinter(result.stdoutText)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
    }

    private func isDefaultPrinter(_ queue: String) async throws -> Bool {
        guard let name = try await defaultPrinterName() else { return false }
        return name.caseInsensitiveCompare(queue) == .orderedSame
    }

    private func deviceURI(for queue: String) async throws -> String? {
        let result = try await run(Tool.lpstat, ["-v", queue])
        guard result.status == 0 else { return nil }
        return LPStatParser.parseDeviceURI(result.stdoutText, queue: queue)
    }

    /// `lpstat` on macOS uses BSD option parsing, so a trailing `-l` after the
    /// queue positional is ignored. Try the documented form first (which also
    /// keeps simple fixtures working) and fall back to `-l -p <queue>` when no
    /// long listing was produced.
    private func printerDetailResult(queue: String) async throws -> CUPSCommandResult {
        let primary = try await run(Tool.lpstat, ["-p", queue, "-l"])
        guard primary.status == 0,
              !LPStatParser.hasDetailedPrinterOutput(primary.stdoutText) else {
            return primary
        }

        do {
            let retry = try await run(Tool.lpstat, ["-l", "-p", queue])
            if retry.status == 0, LPStatParser.hasDetailedPrinterOutput(retry.stdoutText) {
                return retry
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Keep the primary result; the caller will decide how much
            // information is enough to represent the queue.
        }
        return primary
    }

    /// Completion history without `-l` does not say whether a job completed or
    /// was canceled. Ask for the long form before reporting terminal success.
    /// Failure to get the long form leaves the ordinary completion result.
    private func completedJob(
        id: Int,
        printerID queue: String,
        activeJob: PrintJob?
    ) async throws -> PrintJob? {
        let completedResult = try await run(Tool.lpstat, ["-W", "completed", "-o", queue])
        guard completedResult.status == 0 else {
            throw failure(tool: "lpstat", result: completedResult, printerID: queue)
        }

        let completed = LPStatParser.parseJobs(
            completedResult.stdoutText,
            printerID: queue,
            defaultState: .completed
        )
        guard let job = completed.first(where: { $0.id == id }) else { return nil }
        if let activeJob, activeJob.state == .completed { return activeJob }
        // CUPS job ids can be reused after scheduler history is cleared. A
        // completion timestamp older than the active job's creation timestamp
        // is old history, not this job.
        if let activeJob,
           let activeCreated = activeJob.createdAt,
           let completedAt = job.createdAt,
           completedAt < activeCreated {
            return activeJob
        }
        return try await enrichCompletedJob(job, queue: queue)
    }

    private func enrichCompletedJob(_ job: PrintJob, queue: String) async throws -> PrintJob {
        do {
            let result = try await run(Tool.lpstat, ["-l", "-W", "completed", "-o", queue])
            guard result.status == 0 else { return job }
            let detailed = LPStatParser.parseJobs(
                result.stdoutText,
                printerID: queue,
                defaultState: .completed
            )
            return detailed.first {
                $0.id == job.id && $0.printerID.caseInsensitiveCompare(queue) == .orderedSame
            } ?? job
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return job
        }
    }

    private func currentPrintingJobID(queue: String) async throws -> Int? {
        do {
            let result = try await run(Tool.lpstat, ["-p", queue])
            guard result.status == 0 else { return nil }
            return LPStatParser.parsePrinterDetail(result.stdoutText, queue: queue)?.printingJobID
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
    }

    // MARK: - Command plumbing

    private func run(_ executable: URL, _ arguments: [String]) async throws -> CUPSCommandResult {
        do {
            return try await runner.run(executable: executable, arguments: arguments, timeout: timeout)
        } catch let error as CUPSProcessError {
            switch error {
            case .executableNotFound(let path):
                throw CUPSCommandError.toolNotFound((path as NSString).lastPathComponent)
            case .timedOut(let tool):
                throw CUPSCommandError.timedOut(tool: tool)
            case .launchFailed(let message):
                throw CUPSCommandError.commandFailed(
                    tool: executable.lastPathComponent,
                    status: -1,
                    message: message
                )
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as CUPSCommandError {
            throw error
        } catch {
            throw CUPSCommandError.commandFailed(
                tool: executable.lastPathComponent,
                status: -1,
                message: error.localizedDescription
            )
        }
    }

    private func validatedPrinterID(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("-"), trimmed != ".", trimmed != "..",
              !trimmed.contains("/") else {
            throw CUPSCommandError.printerNotFound(value)
        }
        return trimmed
    }

    private func failure(
        tool: String,
        result: CUPSCommandResult,
        printerID: String? = nil
    ) -> CUPSCommandError {
        let message = result.combinedMessage
        if let printerID, isMissingPrinter(message) {
            return .printerNotFound(printerID)
        }
        if result.status == 0, message.isEmpty {
            return .invalidOutput("")
        }
        return .commandFailed(tool: tool, status: result.status, message: message)
    }

    private func isMissingPrinter(_ message: String) -> Bool {
        let lower = message.lowercased()
        return containsAny(lower, [
            "invalid destination",
            "nome di destinazione non valido",
            "destinazione non valida",
            "unknown destination",
            "no such destination",
            "no such printer",
            "printer does not exist",
            "la stampante non esiste",
            "non esiste",
            "not found",
            "non trovata",
            "non trovato"
        ])
    }

    private func isNoDestinations(_ message: String) -> Bool {
        let lower = message.lowercased()
        return containsAny(lower, [
            "no destinations added",
            "no printers",
            "nessuna destinazione",
            "nessuna stampante"
        ])
    }

    private func isAlreadyGone(_ message: String) -> Bool {
        let lower = message.lowercased()
        return containsAny(lower, [
            "not found",
            "no such job",
            "unknown job",
            "invalid job",
            "does not exist",
            "non esiste",
            "non trovata",
            "non trovato",
            "sconosciut",
            "already completed",
            "already canceled",
            "already cancelled",
            "già completat",
            "già annullat"
        ])
    }

    private func containsAny(_ value: String, _ needles: [String]) -> Bool {
        needles.contains { value.contains($0) }
    }
}
