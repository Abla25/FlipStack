import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// A command invocation result. Output is kept as `Data` so a gzip stream can
/// be handed to the PPD parser without an extra encoding round-trip.
struct CUPSCommandResult: Sendable, Equatable {
    var status: Int32
    var stdout: Data
    var stderr: Data

    init(status: Int32, stdout: Data = Data(), stderr: Data = Data()) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }

    init(status: Int32, stdout: String, stderr: String = "") {
        self.status = status
        self.stdout = Data(stdout.utf8)
        self.stderr = Data(stderr.utf8)
    }

    var stdoutText: String {
        String(decoding: stdout, as: UTF8.self)
    }

    var stderrText: String {
        String(decoding: stderr, as: UTF8.self)
    }

    var combinedMessage: String {
        [stderrText, stdoutText]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

/// Injection seam for tests. Production always uses `CUPSProcessRunner`.
protocol CUPSCommandRunning: Sendable {
    func run(executable: URL, arguments: [String], timeout: TimeInterval) async throws -> CUPSCommandResult
}

enum CUPSProcessError: Error, Equatable, Sendable {
    case executableNotFound(String)
    case timedOut(String)
    case launchFailed(String)
}

extension CUPSProcessError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .executableNotFound(let path):
            return "The executable at \(path) was not found."
        case .timedOut(let tool):
            return "\(tool) did not respond in time."
        case .launchFailed(let message):
            return "Could not launch the command: \(message)"
        }
    }
}

/// Runs a process directly (never through a shell), reads stdout and stderr
/// concurrently to avoid pipe deadlocks, and enforces a timeout.
struct CUPSProcessRunner: CUPSCommandRunning {
    func run(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> CUPSCommandResult {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw CUPSProcessError.executableNotFound(executable.path)
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.environment = Self.englishEnvironment()

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()
            throw CUPSProcessError.launchFailed(error.localizedDescription)
        }

        // The child owns the write ends after run(). Closing our copies lets
        // the reader threads observe EOF when the child exits.
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()

        let state = CUPSRunningProcess(process: process)
        let effectiveTimeout = timeout > 0 ? timeout : 20

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let readers = DispatchGroup()
                let stdoutBox = CUPSDataBox()
                let stderrBox = CUPSDataBox()

                readers.enter()
                DispatchQueue.global(qos: .utility).async {
                    stdoutBox.data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    readers.leave()
                }

                readers.enter()
                DispatchQueue.global(qos: .utility).async {
                    stderrBox.data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    readers.leave()
                }

                let timeoutItem = DispatchWorkItem {
                    state.timeOut()
                }
                DispatchQueue.global(qos: .utility).asyncAfter(
                    deadline: .now() + effectiveTimeout,
                    execute: timeoutItem
                )

                DispatchQueue.global(qos: .utility).async {
                    process.waitUntilExit()
                    readers.wait()

                    // The timeout item may still fire, but `finish()` makes it
                    // a no-op, so it cannot terminate a reused process object.
                    let outcome = state.finish()
                    switch outcome {
                    case .timedOut:
                        continuation.resume(throwing: CUPSProcessError.timedOut(executable.lastPathComponent))
                    case .cancelled:
                        continuation.resume(throwing: CancellationError())
                    case nil:
                        if Task.isCancelled {
                            continuation.resume(throwing: CancellationError())
                        } else {
                            continuation.resume(returning: CUPSCommandResult(
                                status: process.terminationStatus,
                                stdout: stdoutBox.data,
                                stderr: stderrBox.data
                            ))
                        }
                    }
                }
            }
        } onCancel: {
            state.cancel()
        }
    }

    /// Synchronous variant used by the PPD gzip path, whose public API is
    /// synchronous. It keeps the same concurrent-read and timeout guarantees.
    func runSynchronously(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval
    ) throws -> CUPSCommandResult {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw CUPSProcessError.executableNotFound(executable.path)
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.environment = Self.englishEnvironment()

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()
            throw CUPSProcessError.launchFailed(error.localizedDescription)
        }

        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()

        let readers = DispatchGroup()
        let stdoutBox = CUPSDataBox()
        let stderrBox = CUPSDataBox()

        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            stdoutBox.data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            readers.leave()
        }

        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            stderrBox.data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            readers.leave()
        }

        let effectiveTimeout = timeout > 0 ? timeout : 20
        if exited.wait(timeout: .now() + effectiveTimeout) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut {
                let pid = process.processIdentifier
                if pid > 0 {
                    kill(pid, SIGKILL)
                }
                _ = exited.wait(timeout: .now() + 2)
            }
            readers.wait()
            throw CUPSProcessError.timedOut(executable.lastPathComponent)
        }

        process.waitUntilExit()
        readers.wait()
        return CUPSCommandResult(
            status: process.terminationStatus,
            stdout: stdoutBox.data,
            stderr: stderrBox.data
        )
    }
}

extension CUPSProcessRunner {
    /// CUPS tools normally honor the C locale. Apple's `lpstat` localizes
    /// independently on some releases, so the parser also understands the
    /// common localized labels and dates.
    private static func englishEnvironment() -> [String: String] {
        let source = ProcessInfo.processInfo.environment
        // Do not hand arbitrary developer-shell secrets (tokens, cloud keys,
        // SSH agents) to CUPS helper tools. Keep only what the tools need plus
        // the deliberately supported CUPS environment values.
        let allowed = [
            "PATH", "HOME", "TMPDIR", "USER", "LOGNAME",
            "CUPS_SERVER", "CUPS_SERVERROOT", "CUPS_DATADIR",
            "CUPS_CACHEDIR", "CUPS_STATEDIR", "CUPS_ENCRYPTION"
        ]
        var environment: [String: String] = [:]
        for key in allowed {
            if let value = source[key] { environment[key] = value }
        }
        environment["LC_ALL"] = "C"
        environment["LANG"] = "C"
        return environment
    }
}

/// Small mutable box written by one reader thread and read after the dispatch
/// group joins, which provides the needed synchronization.
private final class CUPSDataBox: @unchecked Sendable {
    var data = Data()
}

private final class CUPSRunningProcess: @unchecked Sendable {
    enum Outcome {
        case timedOut
        case cancelled
    }

    private let lock = NSLock()
    private let process: Process
    private var outcome: Outcome?
    private var finished = false
    private var killWorkItem: DispatchWorkItem?

    init(process: Process) {
        self.process = process
    }

    func timeOut() {
        signal(.timedOut)
    }

    func cancel() {
        signal(.cancelled)
    }

    func finish() -> Outcome? {
        lock.lock()
        finished = true
        let result = outcome
        lock.unlock()
        killWorkItem?.cancel()
        return result
    }

    private func signal(_ newOutcome: Outcome) {
        lock.lock()
        guard !finished, outcome == nil else {
            lock.unlock()
            return
        }
        outcome = newOutcome
        let pid = process.processIdentifier
        lock.unlock()

        process.terminate()
        scheduleForcedKill(pid: pid)
    }

    private func scheduleForcedKill(pid: pid_t) {
        guard pid > 0 else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let stillRunning = !self.finished
            self.lock.unlock()
            if stillRunning {
                kill(pid, SIGKILL)
            }
        }
        lock.lock()
        killWorkItem = item
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2, execute: item)
    }
}
