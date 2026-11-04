import XCTest
import AppKit
import PDFKit
@testable import FlipStackDemo

/// Pure print-engine tests. Nothing in this file submits a CUPS job: only the
/// argument builder, the parsers and the PDF preparation are exercised.
final class PrintingTests: XCTestCase {

    // MARK: - Helpers

    private func optionPairs(_ arguments: [String]) -> [String: String] {
        var pairs: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            if arguments[index] == "-o", index + 1 < arguments.count {
                let pair = arguments[index + 1]
                if let equals = pair.firstIndex(of: "=") {
                    pairs[String(pair[..<equals])] = String(pair[pair.index(after: equals)...])
                } else {
                    pairs[pair] = ""
                }
                index += 2
            } else {
                index += 1
            }
        }
        return pairs
    }

    private let samplePPD = PPDChoices(
        colorOptionKeyword: "ColorModel",
        colorValues: ["RGB", "Mono"],
        resolutionValues: ["180x180dpi", "360x360dpi", "720x720dpi"],
        mediaValues: ["A4", "A3", "Letter"],
        mediaTypeValues: ["stationery", "photographic-glossy", "*any"],
        inputSlotValues: ["auto", "main", "rear"],
        printQualityValues: ["Draft", "Normal", "High"]
    )

    private func build(
        ppd: PPDChoices,
        pageRange: String? = "1,3,5,7",
        paper: String = "A4",
        orientation: Int? = nil,
        scale: Int = 100,
        color: Bool = false,
        copies: Int = 1,
        media: String = "Plain",
        tray: String = "auto",
        targetDPI: Int? = nil
    ) -> [String] {
        PrintOptionBuilder.arguments(
            file: URL(fileURLWithPath: "/tmp/fixture.pdf"),
            printer: "CASA",
            pageRange: pageRange,
            paperMediaName: PrintMath.paperMediaName(paper),
            orientationRequested: orientation,
            scale: scale,
            color: color,
            copies: copies,
            media: media,
            tray: tray,
            title: "FlipStack — fronts [120000-abcd]",
            ppd: ppd,
            targetDPI: targetDPI
        )
    }

    // MARK: - PPD parsing

    func testPPDColorOptionKeywordsAcrossDrivers() {
        let epson = PPDOptionParser.parse("ColorModel/ColorModel: *RGB Mono")
        XCTAssertEqual(epson.colorOptionKeyword, "ColorModel")
        XCTAssertEqual(epson.colorValues, ["RGB", "Mono"])
        XCTAssertEqual(epson.grayscaleKeyword(), "Mono")
        XCTAssertEqual(epson.colorKeyword(), "RGB")

        let hp = PPDOptionParser.parse(
            "ColorModel/Color Mode: Gray Gray16 DeviceGray DeviceGray16 *RGB AdobeRGB DeviceRGB DeviceRGB16"
        )
        XCTAssertEqual(hp.colorOptionKeyword, "ColorModel")
        XCTAssertEqual(hp.grayscaleKeyword(), "Gray")
        XCTAssertEqual(hp.colorKeyword(), "RGB")

        let cupsColorModel = PPDOptionParser.parse("cupsColorModel/Color: Gray RGB")
        XCTAssertEqual(cupsColorModel.colorOptionKeyword, "cupsColorModel")

        let colorMode = PPDOptionParser.parse("ColorMode/Colore: *RGB Mono")
        XCTAssertEqual(colorMode.colorOptionKeyword, "ColorMode")
        XCTAssertEqual(colorMode.grayscaleKeyword(), "Mono")
    }

    func testGrayscaleKeywordPrefersPlainChoice() {
        let choices = PPDChoices(colorOptionKeyword: "ColorModel",
                                 colorValues: ["RGB", "Gray16", "Gray"])
        XCTAssertEqual(choices.grayscaleKeyword(), "Gray")
    }

    func testGrayscaleAndColorFallbacks() {
        let noChoices = PPDChoices.none
        XCTAssertEqual(noChoices.grayscaleKeyword(), "Gray")
        XCTAssertEqual(noChoices.colorKeyword(), "RGB")

        let onlyCmyk = PPDChoices(colorOptionKeyword: "ColorModel", colorValues: ["Gray", "CMYK"])
        XCTAssertEqual(onlyCmyk.colorKeyword(), "CMYK")
        XCTAssertEqual(onlyCmyk.grayscaleKeyword(), "Gray")
    }

    func testPPDParsingIsLocaleIndependent() {
        // Localized label after the slash, Italian collection: keys must match.
        let output = """
        ColorModel/Modello colore: *RGB Mono
        cupsPrintQuality/Qualità: Draft *Normal High
        Duplex/Fronte-retro: None *DuplexNoTumble DuplexTumble
        PageSize/Formato carta: *A4 A3 Letter
        MediaType/Tipo di supporto: stationery photographic-glossy *any
        InputSlot/Alimentazione: auto main rear
        """
        let parsed = PPDOptionParser.parse(output)
        XCTAssertEqual(parsed.colorOptionKeyword, "ColorModel")
        XCTAssertEqual(parsed.grayscaleKeyword(), "Mono")
        XCTAssertEqual(parsed.mediaValues, ["A4", "A3", "Letter"])
        XCTAssertEqual(parsed.mediaTypeValues, ["stationery", "photographic-glossy", "any"])
        XCTAssertEqual(parsed.inputSlotValues, ["auto", "main", "rear"])
    }

    // MARK: - Resolution

    func testResolutionParsingLocaleSafe() {
        let parsed = PPDOptionParser.parse(
            "Resolution/Risoluzione: 180x180dpi/180 DPI *360x360dpi/360 DPI 720x720dpi/Alta qualità"
        )
        XCTAssertEqual(parsed.resolutionValues, ["180x180dpi", "360x360dpi", "720x720dpi"])
        XCTAssertEqual(PPDChoices.dpi(forResolutionKeyword: "360x360dpi"), 360)
        XCTAssertEqual(PPDChoices.dpi(forResolutionKeyword: "600dpi"), 600)
        XCTAssertNil(PPDChoices.dpi(forResolutionKeyword: "Alta qualità"))
    }

    func testResolutionNearestToTarget() {
        let choices = PPDOptionParser.parse(
            "Resolution/Resolution: 180x180dpi *360x360dpi 720x720dpi"
        )
        XCTAssertEqual(choices.resolutionKeyword(forTargetDPI: 600), "720x720dpi")
        XCTAssertEqual(choices.resolutionKeyword(forTargetDPI: 400), "360x360dpi")
        XCTAssertEqual(choices.resolutionKeyword(forTargetDPI: 100), "180x180dpi")
        XCTAssertNil(PPDChoices.none.resolutionKeyword(forTargetDPI: 600))
    }

    // MARK: - Media / tray validation

    func testMediaTypeOnlyWhenAdvertised() {
        XCTAssertNil(PPDChoices.none.mediaTypeKeyword(for: "Glossy"))
        XCTAssertEqual(samplePPD.mediaTypeKeyword(for: "Glossy"), "photographic-glossy")
        XCTAssertEqual(samplePPD.mediaTypeKeyword(for: "Photo"), "photographic-glossy")
        XCTAssertNil(samplePPD.mediaTypeKeyword(for: "Plain"))
        XCTAssertNil(samplePPD.mediaTypeKeyword(for: "Recycled"))
        let numericL1800 = PPDChoices(mediaTypeValues: ["0", "92", "13", "15"])
        XCTAssertNil(numericL1800.mediaTypeKeyword(for: "Glossy"))
    }

    func testTrayOnlyWhenAdvertised() {
        XCTAssertNil(samplePPD.inputSlotKeyword(for: "auto"))
        XCTAssertEqual(samplePPD.inputSlotKeyword(for: "tray1"), nil) // not advertised
        XCTAssertNil(PPDChoices.none.inputSlotKeyword(for: "tray1"))
        let withTrays = PPDChoices(inputSlotValues: ["auto", "tray1", "tray2"])
        XCTAssertEqual(withTrays.inputSlotKeyword(for: "tray1"), "tray1")
        XCTAssertEqual(withTrays.inputSlotKeyword(for: "tray2"), "tray2")
    }

    // MARK: - Paper mapping

    func testPaperMediaNames() {
        XCTAssertEqual(PrintMath.paperMediaName("A4"), "iso_a4_210x297mm")
        XCTAssertEqual(PrintMath.paperMediaName("A3"), "iso_a3_297x420mm")
        XCTAssertEqual(PrintMath.paperMediaName("Letter"), "na_letter_8.5x11in")
        XCTAssertEqual(PrintMath.paperMediaName("Photo 4×6"), "na_index-4x6_4x6in")
        XCTAssertEqual(PrintMath.paperMediaName("Photo 4x6"), "na_index-4x6_4x6in")
        XCTAssertEqual(PrintMath.paperMediaName("Bogus"), "iso_a4_210x297mm")
    }

    // MARK: - Argument builder

    func testBuilderCoreArguments() {
        let args = build(ppd: samplePPD)
        let pairs = optionPairs(args)

        XCTAssertEqual(args.first, "-d")
        XCTAssertEqual(args.dropFirst().first, "CASA")
        XCTAssertTrue(args.contains("-t"))
        XCTAssertTrue(args.contains("FlipStack — fronts [120000-abcd]"))
        XCTAssertEqual(pairs["media"], "iso_a4_210x297mm")
        XCTAssertEqual(pairs["page-set"], "all")
        XCTAssertEqual(pairs["number-up"], "1")
        XCTAssertEqual(pairs["sides"], "one-sided")
        XCTAssertEqual(pairs["scaling"], "100")
        XCTAssertEqual(pairs["fit-to-page"], "false")
        XCTAssertEqual(pairs["page-ranges"], "1,3,5,7")
        XCTAssertEqual(pairs["ColorModel"], "Mono")
        XCTAssertEqual(args.last, "/tmp/fixture.pdf")
    }

    func testBuilderNeverEmitsInvalidDuplexKeywords() {
        let args = build(ppd: samplePPD)
        XCTAssertFalse(args.contains { $0.lowercased().hasPrefix("duplex") })
        XCTAssertFalse(args.contains { $0.lowercased().hasPrefix("sides=two-sided") })
    }

    func testBuilderOrientationAndScaleVerbatim() {
        let portrait = optionPairs(build(ppd: samplePPD, orientation: 3))
        XCTAssertEqual(portrait["orientation-requested"], "3")

        let reverseLandscape = optionPairs(build(ppd: samplePPD, orientation: 6, scale: 125))
        XCTAssertEqual(reverseLandscape["orientation-requested"], "6")
        XCTAssertEqual(reverseLandscape["scaling"], "125")

        let auto = build(ppd: samplePPD, orientation: nil)
        XCTAssertFalse(auto.contains("orientation-requested=3"))
    }

    func testBuilderUsesAdvertisedColorOptionKeyword() {
        let choices = PPDChoices(colorOptionKeyword: "ColorMode", colorValues: ["Gray", "RGB"])
        let gray = optionPairs(build(ppd: choices, color: false))
        XCTAssertEqual(gray["ColorMode"], "Gray")
        XCTAssertNil(gray["ColorModel"])

        let color = optionPairs(build(ppd: choices, color: true))
        XCTAssertEqual(color["ColorMode"], "RGB")
    }

    func testBuilderResolutionWhenAdvertisedOtherwiseQuality() {
        let withResolution = optionPairs(build(ppd: samplePPD, targetDPI: 600))
        XCTAssertEqual(withResolution["Resolution"], "720x720dpi")
        XCTAssertNil(withResolution["print-quality"])

        let noResolution = optionPairs(build(ppd: PPDChoices.none, targetDPI: 180))
        XCTAssertEqual(noResolution["print-quality"], "3")
        XCTAssertNil(noResolution["Resolution"])

        let noDPI = optionPairs(build(ppd: samplePPD, targetDPI: nil))
        XCTAssertNil(noDPI["Resolution"])
        XCTAssertNil(noDPI["print-quality"])
    }

    func testBuilderOmitsUnsupportedMediaAndTray() {
        let pairs = optionPairs(build(ppd: samplePPD))
        XCTAssertNil(pairs["MediaType"])
        XCTAssertNil(pairs["InputSlot"])

        let glossy = optionPairs(build(ppd: samplePPD, media: "Glossy"))
        XCTAssertEqual(glossy["MediaType"], "photographic-glossy")

        let withTrays = PPDChoices(inputSlotValues: ["tray1", "tray2"])
        let tray = optionPairs(build(ppd: withTrays, tray: "tray2"))
        XCTAssertEqual(tray["InputSlot"], "tray2")
    }

    func testBuilderOmitsEmptyPageRangeAndClampsCopies() {
        let noRange = build(ppd: samplePPD, pageRange: nil, copies: 0)
        let pairs = optionPairs(noRange)
        XCTAssertNil(pairs["page-ranges"])
        if let n = noRange.firstIndex(of: "-n"), noRange.count > n + 1 {
            XCTAssertEqual(noRange[n + 1], "1")
        } else {
            XCTFail("missing -n")
        }
    }

    // MARK: - lp output parsing / failure detection

    func testSubmittedJobParsingEnglish() throws {
        let parsed = try XCTUnwrap(
            SubmittedJobParser.parse("request id is CASA-42 (1 file(s))", printerID: "CASA")
        )
        XCTAssertEqual(parsed.id, 42)
        XCTAssertEqual(parsed.documentCount, 1)
    }

    func testSubmittedJobParsingItalian() throws {
        let detailed = try XCTUnwrap(
            SubmittedJobParser.parse("richiesta id è CASA-7 (1 file(s))", printerID: "CASA")
        )
        XCTAssertEqual(detailed.id, 7)

        let plain = try XCTUnwrap(
            SubmittedJobParser.parse("id della richiesta è RUB-9", printerID: "RUB")
        )
        XCTAssertEqual(plain.id, 9)

        let plain2 = try XCTUnwrap(
            SubmittedJobParser.parse("id richiesta CASA-11", printerID: "CASA")
        )
        XCTAssertEqual(plain2.id, 11)
    }

    func testSubmittedJobParsingRejectsWrongQueueAndGarbage() {
        XCTAssertNil(SubmittedJobParser.parse("request id is OTHER-5 (1 file(s))", printerID: "CASA"))
        XCTAssertNil(SubmittedJobParser.parse("request id is CASA-5 (1 file(s))", printerID: "CASA-2"))
        XCTAssertNil(SubmittedJobParser.parse("", printerID: "CASA"))
        XCTAssertNil(SubmittedJobParser.parse("lp: success?", printerID: "CASA"))
    }

    func testEvaluatorFailsOnNonZeroStatusEvenWithoutWordError() {
        // v1.0.1 regression: this exact output was treated as success because it
        // has no lowercase "error" substring.
        let result = PrintSubmissionEvaluator.evaluate(
            exitStatus: 1,
            output: "/usr/bin/lp: No such file or directory",
            printerID: "CASA"
        )
        XCTAssertFalse(result.succeeded)
        XCTAssertNil(result.jobID)
        XCTAssertTrue(result.message.contains("No such file or directory"))

        let italian = PrintSubmissionEvaluator.evaluate(
            exitStatus: 1,
            output: "lp: errore - destinazione sconosciuta",
            printerID: "CASA"
        )
        XCTAssertFalse(italian.succeeded)
        XCTAssertTrue(italian.message.contains("destinazione sconosciuta"))

        let silent = PrintSubmissionEvaluator.evaluate(exitStatus: 2, output: "", printerID: "CASA")
        XCTAssertFalse(silent.succeeded)
        XCTAssertTrue(silent.message.contains("2"))
    }

    func testEvaluatorSuccessRequiresJobID() {
        let ok = PrintSubmissionEvaluator.evaluate(
            exitStatus: 0,
            output: "request id is CASA-42 (1 file(s))",
            printerID: "CASA"
        )
        XCTAssertTrue(ok.succeeded)
        XCTAssertEqual(ok.jobID, 42)

        // Zero exit status without a job id must never be reported as success.
        let garbage = PrintSubmissionEvaluator.evaluate(exitStatus: 0, output: "garbage", printerID: "CASA")
        XCTAssertFalse(garbage.succeeded)
        XCTAssertNil(garbage.jobID)

        let empty = PrintSubmissionEvaluator.evaluate(exitStatus: 0, output: "", printerID: "CASA")
        XCTAssertFalse(empty.succeeded)
    }

    // MARK: - Job outcome mapping

    func testJobOutcomeMapping() {
        XCTAssertEqual(Printing.outcome(forState: "completed", reasons: []), .completed)
        XCTAssertEqual(
            Printing.outcome(forState: "canceled", reasons: ["cancelled-by-user"]),
            .failed("cancelled-by-user")
        )
        XCTAssertEqual(Printing.outcome(forState: "aborted", reasons: []), .failed("aborted"))

        for waiting in ["pending", "held", "processing", "stopped", "unknown"] {
            XCTAssertNil(Printing.outcome(forState: waiting, reasons: []),
                         "\(waiting) must keep waiting")
        }
    }

    // MARK: - Title uniqueness

    func testUniqueTitleIsUniqueAndKeepsBase() {
        let first = Printing.uniqueTitle("FlipStack — fronts")
        let second = Printing.uniqueTitle("FlipStack — fronts")
        XCTAssertTrue(first.hasPrefix("FlipStack — fronts ["))
        XCTAssertTrue(first.hasSuffix("]"))
        XCTAssertNotEqual(first, second)
    }

    // MARK: - Printable file preparation (no spooling)

    func testMakePrintablePDFAcceptsValidPDF() throws {
        let pdf = try XCTUnwrap(Printing.calibrationPDF())
        defer { try? FileManager.default.removeItem(at: pdf) }
        let printable = Printing.makePrintablePDF(file: pdf)
        XCTAssertEqual(printable?.path, pdf.path)
    }

    func testMakePrintablePDFConvertsPhotoToSinglePagePDF() throws {
        let image = NSImage(size: NSSize(width: 40, height: 24))
        image.lockFocus()
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: 40, height: 24).fill()
        image.unlockFocus()
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("flipstack-test-\(UUID().uuidString).png")
        try png.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let printable = try XCTUnwrap(Printing.makePrintablePDF(file: source))
        defer { try? FileManager.default.removeItem(at: printable) }
        XCTAssertEqual(printable.pathExtension.lowercased(), "pdf")
        XCTAssertEqual(PDFDocument(url: printable)?.pageCount, 1)
    }

    func testMakePrintablePDFRejectsCorruptAndUnsupportedFiles() throws {
        let corrupt = FileManager.default.temporaryDirectory
            .appendingPathComponent("flipstack-test-\(UUID().uuidString).pdf")
        try Data("not a pdf".utf8).write(to: corrupt)
        defer { try? FileManager.default.removeItem(at: corrupt) }
        XCTAssertNil(Printing.makePrintablePDF(file: corrupt))

        let zeroByte = FileManager.default.temporaryDirectory
            .appendingPathComponent("flipstack-test-\(UUID().uuidString).pdf")
        FileManager.default.createFile(atPath: zeroByte.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: zeroByte) }
        XCTAssertNil(Printing.makePrintablePDF(file: zeroByte))

        let docx = FileManager.default.temporaryDirectory
            .appendingPathComponent("flipstack-test-\(UUID().uuidString).docx")
        try Data().write(to: docx)
        defer { try? FileManager.default.removeItem(at: docx) }
        XCTAssertNil(Printing.makePrintablePDF(file: docx))

        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("flipstack-test-\(UUID().uuidString).pdf")
        XCTAssertNil(Printing.makePrintablePDF(file: missing))
    }

    // MARK: - Calibration sheet

    func testCalibrationPDFIsReadable() throws {
        let url = try XCTUnwrap(Printing.calibrationPDF())
        defer { try? FileManager.default.removeItem(at: url) }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = try XCTUnwrap(attributes[.size] as? Int)
        XCTAssertGreaterThan(size, 0)
        let document = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(document.pageCount, 1)
    }
}
