import Foundation

/// Abstraction over `lp`, `lpstat`, `cancel` and PPD discovery. Injected so the
/// duplex state machine can be tested without touching a real print queue.
public protocol PrintSpooling: Sendable {
    func listPrinters() async throws -> [Printer]
    func printer(id: String) async throws -> Printer
    func submit(_ request: PrintRequest) async throws -> PrintJob
    /// Returns the latest known state, including recently completed jobs.
    /// `nil` means the job is no longer known to CUPS (for example, history was cleared).
    func job(id: Int, printerID: String) async throws -> PrintJob?
    func activeJobs(printerID: String) async throws -> [PrintJob]
    func recentJobs(printerID: String, limit: Int) async throws -> [PrintJob]
    func cancel(jobID: Int, printerID: String) async throws
}

public protocol PPDProviding: Sendable {
    func locatePPD(for printer: Printer) -> URL?
    func parsePPD(at url: URL) throws -> PPDDocument
}

public protocol PrinterStatusProviding: Sendable {
    /// Never throws: a missing network or unsupported device yields `.unavailable`.
    func status(for printer: Printer) async -> PrinterStatus
}
