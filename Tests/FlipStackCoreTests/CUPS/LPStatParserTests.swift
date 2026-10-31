import XCTest
@testable import FlipStackCore

final class LPStatParserTests: XCTestCase {
    func testPrinterNamesIgnoreWarningsAndEmptyLines() {
        let output = """
        EPSON_L1800_Series
        Studio_Printer

        lpstat: No destinations added.
        """
        XCTAssertEqual(
            LPStatParser.parsePrinterNames(output),
            ["EPSON_L1800_Series", "Studio_Printer"]
        )
    }

    func testDefaultPrinterEnglishAndItalian() {
        XCTAssertEqual(
            LPStatParser.parseDefaultPrinter("system default destination: Studio_Printer\n"),
            "Studio_Printer"
        )
        XCTAssertEqual(
            LPStatParser.parseDefaultPrinter("destinazione predefinita di sistema: Studio_Printer\n"),
            "Studio_Printer"
        )
        XCTAssertNil(LPStatParser.parseDefaultPrinter("no system default destination\n"))
    }

    func testDeviceURIEnglishAndItalian() {
        XCTAssertEqual(
            LPStatParser.parseDeviceURI(
                "device for EPSON_L1800_Series: usb://EPSON/L1800%20Series?serial=123\n",
                queue: "EPSON_L1800_Series"
            ),
            "usb://EPSON/L1800%20Series?serial=123"
        )
        XCTAssertEqual(
            LPStatParser.parseDeviceURI(
                "dispositivo per Studio_Printer: dnssd://HP%20ENVY._ipp._tcp.local./?uuid=abc\n",
                queue: "Studio_Printer"
            ),
            "dnssd://HP%20ENVY._ipp._tcp.local./?uuid=abc"
        )
    }

    func testIdlePrinterDetail() {
        let output = """
        printer EPSON_L1800_Series is idle.  enabled since Fri Oct 30 20:52:21 2026
        \tDescription: EPSON L1800 Series
        \tLocation: Studio
        \tMakeModel: Epson L1800
        \tInterface: /etc/cups/ppd/EPSON_L1800_Series.ppd
        \tAlerts: offline-report
        """
        let detail = LPStatParser.parsePrinterDetail(output, queue: "EPSON_L1800_Series")
        XCTAssertEqual(detail?.state, .idle)
        XCTAssertEqual(detail?.acceptsJobs, true)
        XCTAssertEqual(detail?.description, "EPSON L1800 Series")
        XCTAssertEqual(detail?.location, "Studio")
        XCTAssertEqual(detail?.model, "Epson L1800")
        XCTAssertEqual(detail?.ppdPath, "/etc/cups/ppd/EPSON_L1800_Series.ppd")
        XCTAssertEqual(detail?.stateReasons, ["offline-report"])
        XCTAssertNil(detail?.printingJobID)
    }

    func testProcessingPrinterDetail() {
        let output = """
        printer L1800 now printing L1800-42.  enabled since Fri Oct 30 20:52:21 2026
        \tDescription: Epson
        """
        let detail = LPStatParser.parsePrinterDetail(output, queue: "L1800")
        XCTAssertEqual(detail?.state, .processing)
        XCTAssertEqual(detail?.acceptsJobs, true)
        XCTAssertEqual(detail?.printingJobID, 42)
    }

    func testDisabledPrinterDetailAndReasons() {
        let output = """
        printer L1800 disabled since Sat 31 Oct 2026 10:00:00 AM CET -
        \treason: media-empty-error
        \tAlerts: marker-supply-low-warning, offline-report
        """
        let detail = LPStatParser.parsePrinterDetail(output, queue: "L1800")
        XCTAssertEqual(detail?.state, .stopped)
        XCTAssertEqual(detail?.acceptsJobs, false)
        XCTAssertEqual(detail?.stateReasons, [
            "media-empty-error",
            "marker-supply-low-warning",
            "offline-report"
        ])
    }

    func testItalianPrinterDetail() {
        let output = """
        la stampante Studio_Printer è in attesa.  Abilitata da Fri Oct 30 20:47:42 2026
        \tDescrizione: HP ENVY 4500 series
        \tPosizione: Cucina
        \tInterfaccia: /private/etc/cups/ppd/Studio_Printer.ppd
        \tAvvisi: offline-report
        """
        let detail = LPStatParser.parsePrinterDetail(output, queue: "Studio_Printer")
        XCTAssertEqual(detail?.state, .idle)
        XCTAssertEqual(detail?.description, "HP ENVY 4500 series")
        XCTAssertEqual(detail?.location, "Cucina")
        XCTAssertEqual(detail?.ppdPath, "/private/etc/cups/ppd/Studio_Printer.ppd")
        XCTAssertEqual(detail?.stateReasons, ["offline-report"])
    }

    func testActiveJobsParseQueuePrefixedAndNumericIds() {
        let output = """
        EPSON_L1800_Series-44  demo-user  3548160   Fri Oct 30 20:52:21 2026
        L1800-43  demo-user  1972224   Sat 31 Oct 2026 10:12:34 AM CET 1 1 - localhost My Document.pdf
        42  demo-user  1024   Mon Nov  2 09:00:00 2026
        """
        let jobs = LPStatParser.parseJobs(output, printerID: "L1800", defaultState: .pending)
        XCTAssertEqual(jobs.count, 3)

        XCTAssertEqual(jobs[0].id, 44)
        XCTAssertEqual(jobs[0].printerID, "EPSON_L1800_Series")
        XCTAssertEqual(jobs[0].owner, "demo-user")
        XCTAssertEqual(jobs[0].state, .pending)
        XCTAssertNotNil(jobs[0].createdAt)

        XCTAssertEqual(jobs[1].id, 43)
        XCTAssertEqual(jobs[1].printerID, "L1800")
        XCTAssertEqual(jobs[1].title, "My Document.pdf")
        XCTAssertEqual(jobs[1].documentCount, 1)
        XCTAssertNotNil(jobs[1].createdAt)

        XCTAssertEqual(jobs[2].id, 42)
        XCTAssertEqual(jobs[2].printerID, "L1800")
        XCTAssertEqual(jobs[2].owner, "demo-user")
    }

    func testISODateFixtureIsParsedConservatively() {
        let output = "L1800-46  demo-user  1024   2026-10-31 10:12:34  report.pdf\n"
        let jobs = LPStatParser.parseJobs(output, printerID: "L1800", defaultState: .pending)
        XCTAssertEqual(jobs.count, 1)
        XCTAssertEqual(jobs[0].id, 46)
        XCTAssertEqual(jobs[0].title, "report.pdf")
        XCTAssertNotNil(jobs[0].createdAt)
    }

    func testJobTitleContainingADashIsPreserved() {
        let output = "L1800-45  demo-user  1024   Fri Oct 30 20:52:21 2026  My - Report\n"
        let jobs = LPStatParser.parseJobs(output, printerID: "L1800", defaultState: .pending)
        XCTAssertEqual(jobs.first?.title, "My - Report")
    }

    func testCompletedJobsUseCompletedDefaultState() {
        let output = """
        L1800-50  demo-user  2048   Fri Oct 30 20:52:21 2026
        L1800-51  demo-user  4096   Fri Oct 30 20:53:21 2026
        """
        let jobs = LPStatParser.parseJobs(output, printerID: "L1800", defaultState: .completed)
        XCTAssertEqual(jobs.map(\.id), [50, 51])
        XCTAssertEqual(jobs.map(\.state), [.completed, .completed])
    }

    func testCanceledJobInCompletionHistory() {
        let output = """
        L1800-52  demo-user  2048   Fri Oct 30 20:54:21 2026
        \tStatus:
        \tAlerts: job-canceled-by-user
        """
        let jobs = LPStatParser.parseJobs(output, printerID: "L1800", defaultState: .completed)
        XCTAssertEqual(jobs.count, 1)
        XCTAssertEqual(jobs[0].state, .canceled)
        XCTAssertTrue(jobs[0].stateReasons.contains("job-canceled-by-user"))
    }

    func testLocalizedDateDoesNotLoseTheJob() {
        let output = """
        L1800-53  demo-user  1024   gio 31 ott 2026 10:12:34
        """
        let jobs = LPStatParser.parseJobs(output, printerID: "L1800", defaultState: .pending)
        XCTAssertEqual(jobs.count, 1)
        XCTAssertEqual(jobs[0].id, 53)
        XCTAssertEqual(jobs[0].owner, "demo-user")
    }

    func testSubmittedJobParsing() {
        XCTAssertEqual(
            LPStatParser.parseSubmittedJob(
                "request id is L1800-77 (1 file(s))\n",
                printerID: "L1800"
            )?.id,
            77
        )
        XCTAssertEqual(
            LPStatParser.parseSubmittedJob(
                "request id is L1800-77 (1 file(s))\n",
                printerID: "L1800"
            )?.documentCount,
            1
        )
        XCTAssertEqual(
            LPStatParser.parseSubmittedJob(
                "richiesta inviata: id L1800-78 (2 file(s))\n",
                printerID: "L1800"
            )?.id,
            78
        )
        XCTAssertEqual(
            LPStatParser.parseSubmittedJob(
                "request id is 79\n",
                printerID: "L1800"
            )?.id,
            79
        )
        XCTAssertNil(
            LPStatParser.parseSubmittedJob(
                "request id is OTHER-80 (1 file(s))\n",
                printerID: "L1800"
            )
        )
    }

    func testJobIdentifierForms() {
        XCTAssertEqual(LPStatParser.jobIdentifier("L1800-42")?.id, 42)
        XCTAssertEqual(LPStatParser.jobIdentifier("L1800-42")?.queue, "L1800")
        XCTAssertEqual(LPStatParser.jobIdentifier("42")?.id, 42)
        XCTAssertNil(LPStatParser.jobIdentifier("L1800-"))
        XCTAssertNil(LPStatParser.jobIdentifier("L1800-x"))
    }
}
