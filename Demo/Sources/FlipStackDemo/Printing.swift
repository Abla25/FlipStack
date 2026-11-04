import Foundation
import AppKit
import PDFKit
import CoreGraphics
import CoreText
import FlipStackCore

// MARK: - Results

/// Outcome of one `lp` submission.
struct PrintSubmissionResult {
    let jobID: Int?
    let succeeded: Bool
    let message: String

    init(jobID: Int?, succeeded: Bool, message: String) {
        self.jobID = jobID
        self.succeeded = succeeded
        self.message = message
    }

    static func failure(_ message: String) -> PrintSubmissionResult {
        PrintSubmissionResult(jobID: nil, succeeded: false, message: message)
    }
}

/// Final state of a spooled CUPS job.
enum JobOutcome: Equatable {
    /// The queue reported the job as completed.
    case completed
    /// The job was canceled/aborted, or the queue reported a failure reason.
    case failed(String)
    /// The job was still active when the timeout expired.
    case timedOut
    /// CUPS could not tell us (job history purged / never visible). This is
    /// deliberately not a failure: a job that already finished can disappear
    /// from history between polls.
    case unknown
}

// MARK: - Print engine

/// v1.0.2 print engine.
///
/// Contract used by `AppModel`:
/// - `submit` is **blocking** (it waits for `lp` to exit, at most
///   `processTimeout`) and must be called off the main actor.
/// - `waitForJob`/`cancel` are async and cancellation-aware.
/// - `makePrintablePDF` converts photos to a bit-exact PDF and validates PDFs.
///
/// Notes on v1.0.1 removal:
/// - The shared `currentProcess`/`currentJobID` statics are gone. Cancellation
///   is job-id based via `CUPSClient.cancel`, so no cross-flow mutable state can
///   leak from one print to the next.
/// - Success is decided by the `lp` exit status plus a parsed job id, never by
///   `contains("error")` (which missed localized/Capitalized CUPS errors and
///   reported failed prints as successes).
/// - Manual duplex always sends `sides=one-sided`; no bogus `Duplex=` keywords.
enum Printing {
    static let processTimeout: TimeInterval = 20

    private static let lpPath = "/usr/bin/lp"
    private static let lpoptionsPath = "/usr/bin/lpoptions"

    // MARK: Queues

    /// Real CUPS queues via FlipStackCore (lpstat-based, locale-normalised).
    static func listPrinters() async -> [Printer] {
        (try? await CUPSClient().listPrinters()) ?? []
    }

    // MARK: Submission

    /// Submit one manual-duplex pass. Blocking: call off the main actor.
    static func submit(
        file: URL,
        printer: String,
        pageRange: String?,
        paper: String,
        orientationRequested: Int?,
        scale: Int,
        color: Bool,
        copies: Int,
        media: String,
        tray: String,
        title: String
    ) -> PrintSubmissionResult {
        submit(
            file: file,
            printer: printer,
            pageRange: pageRange,
            paper: paper,
            orientationRequested: orientationRequested,
            scale: scale,
            color: color,
            copies: copies,
            media: media,
            tray: tray,
            title: title,
            targetDPI: nil
        )
    }

    /// Extended variant: also picks the queue's advertised `Resolution` keyword
    /// nearest to `targetDPI` (falls back to `print-quality`). The main call
    /// site passes the DPI computed by `PrintMath`.
    static func submit(
        file: URL,
        printer: String,
        pageRange: String?,
        paper: String,
        orientationRequested: Int?,
        scale: Int,
        color: Bool,
        copies: Int,
        media: String,
        tray: String,
        title: String,
        targetDPI: Int?
    ) -> PrintSubmissionResult {
        guard !printer.isEmpty else {
            return .failure("Print failed: no printer selected.")
        }
        guard let printable = makePrintablePDF(file: file) else {
            return .failure("Print failed: cannot read “\(file.lastPathComponent)” as a printable document.")
        }

        let choices = ppdChoices(for: printer)
        let unique = uniqueTitle(title)
        let arguments = PrintOptionBuilder.arguments(
            file: printable,
            printer: printer,
            pageRange: pageRange,
            paperMediaName: PrintMath.paperMediaName(paper),
            orientationRequested: orientationRequested,
            scale: scale,
            color: color,
            copies: copies,
            media: media,
            tray: tray,
            title: unique,
            ppd: choices,
            targetDPI: targetDPI
        )

        guard let invocation = runTool(lpPath, arguments, timeout: processTimeout) else {
            return .failure("Print failed: could not launch lp.")
        }
        if invocation.timedOut {
            return .failure("Print failed: lp did not respond within \(Int(processTimeout)) s.")
        }

        let result = PrintSubmissionEvaluator.evaluate(
            exitStatus: invocation.status,
            output: invocation.output,
            printerID: printer
        )
        if result.succeeded { return result }

        // Last-resort fallback: lp exited cleanly but printed an output shape we
        // do not understand (older/localized CUPS). Look for the job by our
        // unique title, newest first, before declaring failure.
        if invocation.status == 0,
           let jobID = findNewestJob(printer: printer, matchingTitle: unique) {
            return PrintSubmissionResult(
                jobID: jobID,
                succeeded: true,
                message: "Job \(jobID) submitted."
            )
        }
        return result
    }

    // MARK: Job monitoring

    /// Poll CUPS until the job reaches a terminal state or `timeout` expires.
    ///
    /// - `.completed`: job done.
    /// - `.failed(reason)`: canceled/aborted.
    /// - `.timedOut`: still pending/held/processing/stopped at the deadline.
    /// - `.unknown`: CUPS has no record of the job (purged history). Not a
    ///   failure — callers should treat it like the old "assume it worked"
    ///   fallback, ideally showing a softer message.
    ///
    /// Honours Task cancellation: a cancelled wait returns `.unknown`
    /// immediately so a superseded flow cannot flip UI state later.
    static func waitForJob(_ jobID: Int, printer: String, timeout: TimeInterval) async -> JobOutcome {
        guard jobID > 0, !printer.isEmpty else { return .unknown }
        let client = CUPSClient()
        let deadline = Date().addingTimeInterval(max(timeout, 0.5))
        var missingPolls = 0

        while true {
            if Task.isCancelled { return .unknown }

            if let job = try? await client.job(id: jobID, printerID: printer) {
                missingPolls = 0
                if let outcome = outcome(for: job) { return outcome }
            } else {
                // `job(id:)` returns nil for jobs outside active + completed
                // history. One nil poll can be a race; three in a row means
                // CUPS genuinely does not know the job.
                missingPolls += 1
                if missingPolls >= 3 { return .unknown }
            }

            if Date() >= deadline { return .timedOut }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    /// Maps one CUPS job snapshot to an outcome. `nil` means "keep waiting".
    static func outcome(for job: PrintJob?) -> JobOutcome? {
        guard let job else { return nil }
        return outcome(forState: job.state.rawValue, reasons: job.stateReasons)
    }

    /// Pure state mapping shared with tests (no FlipStackCore types needed).
    /// `stopped`/`held` keep waiting: the queue may resume, and reporting a
    /// failure early would make users retry into a duplicate print.
    static func outcome(forState rawState: String, reasons: [String]) -> JobOutcome? {
        switch rawState {
        case "completed":
            return .completed
        case "canceled", "aborted":
            let reason = reasons.first { !$0.isEmpty } ?? rawState
            return .failed(reason)
        default:
            return nil
        }
    }

    /// Cancel a spooled CUPS job. Idempotent; a job that already finished is
    /// treated as successfully canceled.
    static func cancel(jobID: Int?, printer: String) async {
        guard let jobID, jobID > 0, !printer.isEmpty else { return }
        try? await CUPSClient().cancel(jobID: jobID, printerID: printer)
    }

    // MARK: Printable file preparation

    /// Returns a file `lp` can actually print:
    /// - photos are wrapped in a bit-exact PDF (`PDFImageWriter`, DCTDecode for
    ///   JPEG, FlateDecode for everything else — no recompression);
    /// - PDFs are validated (readable, at least one page);
    /// - everything else (DOCX, corrupt/0-byte files) returns `nil` so the UI
    ///   can show a real error instead of spooling garbage.
    static func makePrintablePDF(file: URL) -> URL? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }

        if PrintMath.isPhoto(file.lastPathComponent) {
            guard let image = try? PDFImageWriter.embedImage(at: file) else { return nil }
            let temporary = FileManager.default.temporaryDirectory
                .appendingPathComponent("flipstack-print-\(UUID().uuidString).pdf")
            do {
                try PDFImageWriter.writePDF(pages: [image], to: temporary)
                return temporary
            } catch {
                return nil
            }
        }

        guard file.pathExtension.lowercased() == "pdf" else { return nil }
        guard let document = PDFDocument(url: file), document.pageCount > 0 else { return nil }
        return file
    }

    // MARK: Calibration sheet

    /// Simple calibration sheet (sharpness lines + alignment pairs).
    ///
    /// Text is drawn with CoreText (the CoreGraphics PDF context has no AppKit
    /// graphics context, which is why the old AppKit `draw(at:)` version
    /// produced blank sheets on some systems). The file is verified before it
    /// is returned so the UI never sends a 0-byte sheet.
    static func calibrationPDF() -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("flipstack-calibration-\(UUID().uuidString).pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            return nil
        }

        context.beginPDFPage(nil)
        context.setFillColor(NSColor.white.cgColor)
        context.fill(mediaBox)
        context.setStrokeColor(NSColor.black.cgColor)

        for index in 1...10 {
            context.setLineWidth(CGFloat(index) * 0.4)
            context.beginPath()
            context.move(to: CGPoint(x: 60, y: 700 - CGFloat(index) * 18))
            context.addLine(to: CGPoint(x: 535, y: 700 - CGFloat(index) * 18))
            context.strokePath()
        }
        for index in 0..<5 {
            context.setLineWidth(1)
            context.stroke(CGRect(x: 60 + CGFloat(index) * 40, y: 300, width: 20, height: 120))
        }

        drawText("FLIPSTACK CALIBRATION — mark sharpest line & aligned pair",
                 in: context, at: CGPoint(x: 60, y: 780), size: 11)
        drawText("1. Print this sheet on plain A4, 100% scale.",
                 in: context, at: CGPoint(x: 60, y: 250), size: 11)
        drawText("2. Mark the sharpest line block and the aligned pair.",
                 in: context, at: CGPoint(x: 60, y: 230), size: 11)
        context.endPDFPage()
        context.flush()

        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int, size > 0 else {
            return nil
        }
        return url
    }

    // MARK: - PPD

    /// The queue's advertised option choices. When `lpoptions` fails (queue
    /// missing/renamed) the engine falls back to conventional keywords.
    static func ppdChoices(for printer: String) -> PPDChoices {
        guard !printer.isEmpty,
              let invocation = runTool(lpoptionsPath, ["-p", printer, "-l"], timeout: processTimeout),
              !invocation.timedOut,
              invocation.status == 0 else {
            return .none
        }
        return PPDOptionParser.parse(invocation.output)
    }

    // MARK: - Helpers

    /// Unique title per pass: CUPS job history and the fallback lookup stay
    /// unambiguous even if the user retries within the same second.
    static func uniqueTitle(_ base: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "HHmmss"
        let token = UUID().uuidString.prefix(4).lowercased()
        return "\(base) [\(formatter.string(from: Date()))-\(token)]"
    }

    /// Synchronous bridge used only by the `lp`-output fallback. `submit` is
    /// blocking by contract; call sites run it off the main actor, so the
    /// semaphore cannot stall the UI.
    private static func findNewestJob(printer: String, matchingTitle title: String) -> Int? {
        let semaphore = DispatchSemaphore(value: 0)
        var found: Int?
        Task {
            let deadline = Date().addingTimeInterval(2.5)
            while Date() < deadline {
                if let jobs = try? await CUPSClient().activeJobs(printerID: printer) {
                    let matching = jobs.filter {
                        $0.title == title || $0.title.hasPrefix(title)
                    }
                    found = matching.max(by: { $0.id < $1.id })?.id
                    if found != nil { break }
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 3)
        return found
    }

    // MARK: Process execution

    private struct ToolInvocation {
        var status: Int32
        var output: String
        var timedOut: Bool
    }

    /// Runs a CUPS CLI tool with a hard timeout and captures stdout+stderr.
    ///
    /// Pipe output is drained on a background reader thread so large
    /// `lpoptions` dumps cannot deadlock on a full pipe buffer.
    private static func runTool(
        _ executable: String,
        _ arguments: [String],
        timeout: TimeInterval
    ) -> ToolInvocation? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let handle = pipe.fileHandleForReading
        let lock = NSLock()
        var buffer = Data()
        handle.readabilityHandler = { readable in
            let chunk = readable.availableData
            lock.lock()
            buffer.append(chunk)
            lock.unlock()
        }

        do {
            try process.run()
        } catch {
            handle.readabilityHandler = nil
            return nil
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        let timedOut = process.isRunning
        if timedOut {
            process.terminate()
        }
        process.waitUntilExit()
        handle.readabilityHandler = nil
        if let rest = try? handle.readToEnd(), !rest.isEmpty {
            lock.lock()
            buffer.append(rest)
            lock.unlock()
        }

        lock.lock()
        let data = buffer
        lock.unlock()
        let output = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ToolInvocation(
            status: process.terminationStatus,
            output: output,
            timedOut: timedOut
        )
    }

    private static func drawText(
        _ string: String,
        in context: CGContext,
        at point: CGPoint,
        size: CGFloat
    ) {
        let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): NSColor.black.cgColor,
        ]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: string, attributes: attributes)
        )
        context.textPosition = point
        CTLineDraw(line, context)
    }
}
