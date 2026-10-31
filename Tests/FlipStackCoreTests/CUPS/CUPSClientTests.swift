import Foundation
import XCTest
@testable import FlipStackCore

final class CUPSClientTests: XCTestCase {
    func testListPrintersEnrichesSortsAndSurvivesOneBrokenQueue() async throws {
        let runner = CUPSStubCommandRunner { _, arguments in
            switch arguments {
            case ["-e"]:
                return cupsTestResult("Zeta\nBroken\nAlpha\n")
            case ["-d"]:
                return cupsTestResult("system default destination: Alpha\n")
            case ["-p", "Alpha", "-l"]:
                return cupsTestResult("""
                printer Alpha is idle.  enabled since Fri Oct 30 20:52:21 2026
                \tDescription: Alpha Laser
                \tLocation: Desk
                \tMakeModel: Acme Alpha
                \tInterface: /etc/cups/ppd/Alpha.ppd
                """)
            case ["-v", "Alpha"]:
                return cupsTestResult("device for Alpha: ipp://alpha.local/printers/alpha\n")
            case ["-p", "Broken", "-l"]:
                return cupsTestResult(status: 1, stderr: "lpstat: Invalid destination name in list “Broken”.\n")
            case ["-v", "Broken"]:
                return cupsTestResult(status: 1, stderr: "lpstat: Invalid destination name in list “Broken”.\n")
            case ["-p", "Zeta", "-l"]:
                return cupsTestResult("""
                printer Zeta disabled since Sat 31 Oct 2026 10:00:00 AM CET -
                \treason: media-empty-error
                """)
            case ["-v", "Zeta"]:
                return cupsTestResult("device for Zeta: usb://Zeta/1\n")
            default:
                return cupsTestResult(status: 1, stderr: "unexpected arguments: \(arguments)\n")
            }
        }

        let client = CUPSClient(runner: runner)
        let printers = try await client.listPrinters()

        XCTAssertEqual(printers.map(\.id), ["Alpha", "Broken", "Zeta"])
        XCTAssertEqual(printers[0].name, "Alpha Laser")
        XCTAssertEqual(printers[0].model, "Acme Alpha")
        XCTAssertEqual(printers[0].location, "Desk")
        XCTAssertEqual(printers[0].deviceURI, "ipp://alpha.local/printers/alpha")
        XCTAssertEqual(printers[0].ppdPath, "/etc/cups/ppd/Alpha.ppd")
        XCTAssertTrue(printers[0].isDefault)
        XCTAssertEqual(printers[0].state, .idle)

        XCTAssertEqual(printers[1].state, .unknown)
        XCTAssertNil(printers[1].deviceURI)
        XCTAssertFalse(printers[1].isDefault)

        XCTAssertEqual(printers[2].state, .stopped)
        XCTAssertFalse(printers[2].acceptsJobs)
        XCTAssertEqual(printers[2].stateReasons, ["media-empty-error"])
    }

    func testListPrintersReturnsEmptyWhenNoDestinations() async throws {
        let runner = CUPSStubCommandRunner { _, arguments in
            XCTAssertEqual(arguments, ["-e"])
            return cupsTestResult(status: 1, stderr: "lpstat: No destinations added.\n")
        }
        let printers = try await CUPSClient(runner: runner).listPrinters()
        XCTAssertTrue(printers.isEmpty)
    }

    func testPrinterByID() async throws {
        let runner = CUPSStubCommandRunner { _, arguments in
            switch arguments {
            case ["-p", "Alpha", "-l"]:
                return cupsTestResult("""
                printer Alpha is idle.  enabled since Fri Oct 30 20:52:21 2026
                \tDescription: Alpha Laser
                \tLocation: Desk
                \tInterface: /etc/cups/ppd/Alpha.ppd
                """)
            case ["-v", "Alpha"]:
                return cupsTestResult("device for Alpha: ipp://alpha.local/printers/alpha\n")
            case ["-d"]:
                return cupsTestResult("system default destination: Alpha\n")
            default:
                return cupsTestResult(status: 1, stderr: "unexpected\n")
            }
        }

        let printer = try await CUPSClient(runner: runner).printer(id: "Alpha")
        XCTAssertEqual(printer.id, "Alpha")
        XCTAssertEqual(printer.name, "Alpha Laser")
        XCTAssertTrue(printer.isDefault)
        XCTAssertEqual(printer.deviceURI, "ipp://alpha.local/printers/alpha")
    }

    func testPrinterDetailRetriesWithMacOSOptionOrder() async throws {
        let runner = CUPSStubCommandRunner { _, arguments in
            switch arguments {
            case ["-p", "Legacy", "-l"]:
                // BSD getopt ignored the trailing -l, so no details follow.
                return cupsTestResult("printer Legacy is idle.  enabled since Fri Oct 30 20:52:21 2026\n")
            case ["-l", "-p", "Legacy"]:
                return cupsTestResult("""
                printer Legacy is idle.  enabled since Fri Oct 30 20:52:21 2026
                \tDescription: Legacy Laser
                \tLocation: Office
                \tInterface: /etc/cups/ppd/Legacy.ppd
                """)
            case ["-v", "Legacy"]:
                return cupsTestResult("device for Legacy: ipp://legacy.local/\n")
            case ["-d"]:
                return cupsTestResult("system default destination: Legacy\n")
            default:
                return cupsTestResult(status: 1, stderr: "unexpected\n")
            }
        }

        let printer = try await CUPSClient(runner: runner).printer(id: "Legacy")
        XCTAssertEqual(printer.name, "Legacy Laser")
        XCTAssertEqual(printer.location, "Office")
        XCTAssertEqual(printer.ppdPath, "/etc/cups/ppd/Legacy.ppd")
        XCTAssertTrue(printer.isDefault)
    }

    func testPrinterByIDMapsInvalidDestination() async throws {
        let runner = CUPSStubCommandRunner { _, arguments in
            XCTAssertEqual(arguments, ["-p", "Nope", "-l"])
            return cupsTestResult(
                status: 1,
                stderr: "lpstat: Invalid destination name in list “Nope”.\n"
            )
        }

        do {
            _ = try await CUPSClient(runner: runner).printer(id: "Nope")
            XCTFail("Expected printerNotFound")
        } catch let error as CUPSCommandError {
            guard case .printerNotFound(let id) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(id, "Nope")
        }
    }

    func testEmptyPrinterIDIsRejectedWithoutRunningACommand() async throws {
        let runner = CUPSStubCommandRunner { _, _ in
            XCTFail("No command should run")
            return cupsTestResult()
        }
        do {
            _ = try await CUPSClient(runner: runner).printer(id: "  ")
            XCTFail("Expected printerNotFound")
        } catch let error as CUPSCommandError {
            guard case .printerNotFound = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertTrue(runner.invocations.isEmpty)
    }

    func testActiveJobsUseThePrintingQueueState() async throws {
        let runner = CUPSStubCommandRunner { _, arguments in
            switch arguments {
            case ["-W", "not-completed", "-o", "L1800"]:
                return cupsTestResult("""
                L1800-42  demo-user  1024   Fri Oct 30 20:52:21 2026
                L1800-43  demo-user  1024   Fri Oct 30 20:53:21 2026
                """)
            case ["-p", "L1800"]:
                return cupsTestResult("printer L1800 now printing L1800-42.  enabled since Fri Oct 30 20:52:21 2026\n")
            default:
                return cupsTestResult(status: 1, stderr: "unexpected\n")
            }
        }

        let jobs = try await CUPSClient(runner: runner).activeJobs(printerID: "L1800")
        XCTAssertEqual(jobs.map(\.id), [42, 43])
        XCTAssertEqual(jobs[0].state, .processing)
        XCTAssertEqual(jobs[1].state, .pending)
    }

    func testRecentJobsSortsNewestFirstAndAppliesLimit() async throws {
        let runner = CUPSStubCommandRunner { _, arguments in
            XCTAssertEqual(arguments, ["-W", "completed", "-o", "L1800"])
            return cupsTestResult("""
            L1800-49  demo-user  1024   Fri Oct 30 20:50:21 2026
            L1800-51  demo-user  1024   Fri Oct 30 20:52:21 2026
            L1800-50  demo-user  1024   Fri Oct 30 20:51:21 2026
            """)
        }

        let jobs = try await CUPSClient(runner: runner).recentJobs(printerID: "L1800", limit: 2)
        XCTAssertEqual(jobs.map(\.id), [51, 50])
        XCTAssertEqual(jobs.map(\.state), [.completed, .completed])
    }

    func testRecentJobsWithZeroLimitSkipsCUPS() async throws {
        let runner = CUPSStubCommandRunner { _, _ in
            XCTFail("No command should run")
            return cupsTestResult()
        }
        let jobs = try await CUPSClient(runner: runner).recentJobs(printerID: "L1800", limit: 0)
        XCTAssertTrue(jobs.isEmpty)
        XCTAssertTrue(runner.invocations.isEmpty)
    }

    func testJobActiveStateComesFromTheQueue() async throws {
        let runner = CUPSStubCommandRunner { _, arguments in
            switch arguments {
            case ["-W", "not-completed", "-o", "L1800"]:
                return cupsTestResult("L1800-70  demo-user  1024   Fri Oct 30 20:52:21 2026\n")
            case ["-p", "L1800"]:
                return cupsTestResult("printer L1800 now printing L1800-70.  enabled since Fri Oct 30 20:52:21 2026\n")
            default:
                return cupsTestResult(status: 1, stderr: "unexpected\n")
            }
        }

        let job = try await CUPSClient(runner: runner).job(id: 70, printerID: "L1800")
        XCTAssertEqual(job?.id, 70)
        XCTAssertEqual(job?.state, .processing)
    }

    func testJobFallsBackToCompletionHistory() async throws {
        let runner = CUPSStubCommandRunner { _, arguments in
            switch arguments {
            case ["-W", "not-completed", "-o", "L1800"]:
                return cupsTestResult("")
            case ["-W", "completed", "-o", "L1800"]:
                return cupsTestResult("L1800-60  demo-user  1024   Fri Oct 30 20:52:21 2026\n")
            default:
                return cupsTestResult(status: 1, stderr: "unexpected\n")
            }
        }

        let job = try await CUPSClient(runner: runner).job(id: 60, printerID: "L1800")
        XCTAssertEqual(job?.id, 60)
        XCTAssertEqual(job?.state, .completed)
    }

    func testCompletedJobHistoryCanReportCancellation() async throws {
        let runner = CUPSStubCommandRunner { _, arguments in
            switch arguments {
            case ["-W", "not-completed", "-o", "L1800"]:
                return cupsTestResult("")
            case ["-W", "completed", "-o", "L1800"]:
                return cupsTestResult("L1800-80  demo-user  1024   Fri Oct 30 20:52:21 2026\n")
            case ["-l", "-W", "completed", "-o", "L1800"]:
                return cupsTestResult("""
                L1800-80  demo-user  1024   Fri Oct 30 20:52:21 2026
                \tStatus:
                \tAlerts: job-canceled-by-user
                """)
            default:
                return cupsTestResult(status: 1, stderr: "unexpected\n")
            }
        }

        let job = try await CUPSClient(runner: runner).job(id: 80, printerID: "L1800")
        XCTAssertEqual(job?.id, 80)
        XCTAssertEqual(job?.state, .canceled)
    }

    func testJobReturnsNilWhenHistoryWasCleared() async throws {
        let runner = CUPSStubCommandRunner { _, arguments in
            switch arguments {
            case ["-W", "not-completed", "-o", "L1800"]:
                return cupsTestResult("")
            case ["-W", "completed", "-o", "L1800"]:
                return cupsTestResult("")
            default:
                return cupsTestResult(status: 1, stderr: "unexpected\n")
            }
        }

        let job = try await CUPSClient(runner: runner).job(id: 61, printerID: "L1800")
        XCTAssertNil(job)
    }

    func testSubmitBuildsExactArgumentsAndReturnsPendingJob() async throws {
        let directory = try CUPSTestTemporaryDirectory(prefix: "FlipStackSubmit")
        let file = try directory.write(Data("pdf".utf8), name: "A Report With Spaces.pdf")

        let runner = CUPSStubCommandRunner { _, arguments in
            XCTAssertEqual(arguments, [
                "-d", "Test_Queue",
                "-t", "A Report",
                "-n", "1",
                "-o", "page-set=odd",
                "-o", "number-up=2",
                "-o", "orientation-requested=3",
                "-o", "scaling=100",
                "-o", "Duplex=NoTumble",
                file.path
            ])
            return cupsTestResult("request id is Test_Queue-88 (1 file(s))\n")
        }

        let request = PrintRequest(
            fileURL: file,
            printerID: "Test_Queue",
            title: "A Report",
            pageSet: .odd,
            numberUp: 2,
            driverOptions: ["Duplex": "NoTumble"]
        )
        let job = try await CUPSClient(runner: runner).submit(request)

        XCTAssertEqual(job.id, 88)
        XCTAssertEqual(job.printerID, "Test_Queue")
        XCTAssertEqual(job.title, "A Report")
        XCTAssertEqual(job.state, .pending)
        XCTAssertEqual(job.documentCount, 1)
    }

    func testSubmitRejectsMissingFileBeforeRunningLP() async throws {
        let runner = CUPSStubCommandRunner { _, _ in
            XCTFail("lp must not run")
            return cupsTestResult()
        }
        let request = PrintRequest(
            fileURL: URL(fileURLWithPath: "/tmp/FlipStack-definitely-missing.pdf"),
            printerID: "L1800",
            title: "Missing"
        )

        do {
            _ = try await CUPSClient(runner: runner).submit(request)
            XCTFail("Expected fileNotFound")
        } catch let error as CUPSCommandError {
            guard case .fileNotFound(let path) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(path, request.fileURL.path)
        }
        XCTAssertTrue(runner.invocations.isEmpty)
    }

    func testSubmitMapsLPFailure() async throws {
        let directory = try CUPSTestTemporaryDirectory(prefix: "FlipStackSubmitFail")
        let file = try directory.write(Data("pdf".utf8), name: "input.pdf")
        let runner = CUPSStubCommandRunner { _, _ in
            cupsTestResult(status: 1, stderr: "lp: The printer or class does not exist.\n")
        }

        do {
            _ = try await CUPSClient(runner: runner).submit(
                PrintRequest(fileURL: file, printerID: "Nope", title: "Test")
            )
            XCTFail("Expected commandFailed")
        } catch let error as CUPSCommandError {
            guard case .commandFailed(let tool, let status, let message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(tool, "lp")
            XCTAssertEqual(status, 1)
            XCTAssertTrue(message.contains("does not exist"))
        }
    }

    func testSubmitRejectsUnparseableOutput() async throws {
        let directory = try CUPSTestTemporaryDirectory(prefix: "FlipStackSubmitOutput")
        let file = try directory.write(Data("pdf".utf8), name: "input.pdf")
        let runner = CUPSStubCommandRunner { _, _ in
            cupsTestResult("something unexpected\n")
        }

        do {
            _ = try await CUPSClient(runner: runner).submit(
                PrintRequest(fileURL: file, printerID: "L1800", title: "Test")
            )
            XCTFail("Expected invalidOutput")
        } catch let error as CUPSCommandError {
            guard case .invalidOutput(let output) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(output.contains("unexpected"))
        }
    }

    func testCancelTreatsMissingJobAsSuccess() async throws {
        let runner = CUPSStubCommandRunner { _, arguments in
            XCTAssertEqual(arguments, ["42"])
            return cupsTestResult(
                status: 1,
                stderr: "cancel: cancel-job non riuscito: La stampa #42 non esiste.\n"
            )
        }
        try await CUPSClient(runner: runner).cancel(jobID: 42, printerID: "L1800")
    }

    func testCancelMapsRealFailure() async throws {
        let runner = CUPSStubCommandRunner { _, _ in
            cupsTestResult(status: 1, stderr: "cancel: Permission denied\n")
        }

        do {
            try await CUPSClient(runner: runner).cancel(jobID: 42, printerID: "L1800")
            XCTFail("Expected commandFailed")
        } catch let error as CUPSCommandError {
            guard case .commandFailed(let tool, _, let message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(tool, "cancel")
            XCTAssertTrue(message.contains("Permission denied"))
        }
    }

    func testCancelRejectsNonPositiveJobID() async throws {
        let runner = CUPSStubCommandRunner { _, _ in
            XCTFail("No command should run")
            return cupsTestResult()
        }
        do {
            try await CUPSClient(runner: runner).cancel(jobID: 0, printerID: "L1800")
            XCTFail("Expected jobNotFound")
        } catch let error as CUPSCommandError {
            guard case .jobNotFound(let id) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(id, 0)
        }
    }

    func testTimeoutAndMissingToolAreMapped() async throws {
        let timeoutRunner = CUPSStubCommandRunner { _, _ in
            throw CUPSProcessError.timedOut("lpstat")
        }
        do {
            _ = try await CUPSClient(runner: timeoutRunner).listPrinters()
            XCTFail("Expected timedOut")
        } catch let error as CUPSCommandError {
            guard case .timedOut(let tool) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(tool, "lpstat")
        }

        let missingRunner = CUPSStubCommandRunner { _, _ in
            throw CUPSProcessError.executableNotFound("/usr/bin/lpstat")
        }
        do {
            _ = try await CUPSClient(runner: missingRunner).listPrinters()
            XCTFail("Expected toolNotFound")
        } catch let error as CUPSCommandError {
            guard case .toolNotFound(let tool) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(tool, "lpstat")
        }
    }
}
