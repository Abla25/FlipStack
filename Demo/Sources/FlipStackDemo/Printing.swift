import Foundation
import AppKit
import PDFKit
import CoreGraphics
import FlipStackCore

enum Printing {
    /// The currently running `lp` process (killed on Cancel) and its CUPS job id
    /// (cancelled via `cancel` so an already-spooled job does not keep printing).
    static var currentProcess: Process?
    static var currentJobID: Int?
    static var currentPrinterID: String?

    static func cancelCurrent() {
        currentProcess?.terminate()
        currentProcess = nil
        if let job = currentJobID, let pid = currentPrinterID {
            Task { try? await CUPSClient().cancel(jobID: job, printerID: pid) }
            currentJobID = nil
        }
    }

    /// Real CUPS queues via FlipStackCore (lpstat-based, locale-normalised).
    static func listPrinters() async -> [Printer] {
        (try? await CUPSClient().listPrinters()) ?? []
    }

    /// Live status (state + supplies) via FlipStackCore IPP/SNMP clients.
    static func status(for printer: Printer) async -> PrinterStatus {
        await IPPStatusClient().status(for: printer)
    }

    /// Poll a CUPS job until it leaves the active states (`lp` exiting only
    /// means spooled — the flip prompt must wait for real completion).
    static func waitForJob(_ jobID: Int, printer: String, timeout: TimeInterval = 180) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let job = try? await CUPSClient().job(id: jobID, printerID: printer) {
                switch job.state {
                case .completed: return true
                case .canceled, .aborted: return false
                default: break
                }
            }
            try? await Task.sleep(nanoseconds: 600_000_000)
        }
        return false
    }

    /// Find our job by its (privacy-safe) title among the queue's active jobs.
    static func findJob(title: String, printer: String, timeout: TimeInterval = 10) async -> Int? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let jobs = try? await CUPSClient().activeJobs(printerID: printer),
               let j = jobs.first(where: { $0.title == title }) {
                return j.id
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        return nil
    }

    /// Extract the numeric job id from lp's "request id is QUEUE-12 (…)" output.
    static func parseJobID(_ output: String) -> Int? {
        guard let r = output.range(of: "request id is ") else { return nil }
        let rest = String(output[r.upperBound...])
        let token = rest.components(separatedBy: .whitespaces).first ?? ""
        // job id is the digits after the last dash in "QUEUE-42"
        if let dash = token.lastIndex(of: "-") {
            return Int(token[token.index(after: dash)...])
        }
        let digits = token.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
        return Int(digits)
    }

    // MARK: PPD resolution ladder (per printer, cached)
    private static var resolutionCache: [String: [(label: String, dpi: Int)]] = [:]

    static func resolutionChoices(for printer: String) -> [(label: String, dpi: Int)] {
        if let c = resolutionCache[printer] { return c }
        guard let out = run("/usr/bin/lpoptions", ["-p", printer, "-l"]) else { return [] }
        let parsed = parseResolutionChoices(out)
        resolutionCache[printer] = parsed
        return parsed
    }

    /// Parse the "*Resolution: 360x360dpi 720x720dpi …" line of `lpoptions -l`.
    static func parseResolutionChoices(_ output: String) -> [(label: String, dpi: Int)] {
        guard let line = output.split(separator: "\n").first(where: { $0.contains("Resolution:") }) else { return [] }
        var choices: [(label: String, dpi: Int)] = []
        for tok in line.split(separator: " ") {
            let t = String(tok).replacingOccurrences(of: "*", with: "")
            guard t.hasSuffix("dpi") else { continue }
            let first = t.components(separatedBy: "x").first ?? ""
            let dpi = Int(first.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()) ?? 0
            if dpi > 0 { choices.append((label: t, dpi: dpi)) }
        }
        return choices.sorted { $0.dpi < $1.dpi }
    }

    /// Pick the advertised Resolution keyword nearest to the target dpi.
    static func resolutionChoice(for printer: String, targetDPI: Int) -> String? {
        let choices = resolutionChoices(for: printer)
        guard !choices.isEmpty else { return nil }
        return choices.min(by: { abs($0.dpi - targetDPI) < abs($1.dpi - targetDPI) })?.label
    }

    // MARK: PPD-aware color mode
    private static var colorCache: [String: [String]] = [:]

    /// Advertised choices of the color option (ColorModel / ColorMode / cupsColorModel).
    static func colorChoices(for printer: String) -> [String] {
        if let c = colorCache[printer] { return c }
        guard let out = run("/usr/bin/lpoptions", ["-p", printer, "-l"]) else { return [] }
        var found: [String] = []
        for line in out.split(separator: "\n") {
            let lower = line.lowercased()
            guard lower.contains("colormodel") || lower.contains("colormode") || lower.contains("cupscolormodel") else { continue }
            // "*ColorModel/ColorModel: *RGB Mono" → choices after the colon, '*' marks default
            guard let colon = line.firstIndex(of: ":") else { continue }
            for tok in line[line.index(after: colon)...].split(separator: " ") {
                let t = String(tok).replacingOccurrences(of: "*", with: "")
                if !t.isEmpty { found.append(t) }
            }
            break
        }
        colorCache[printer] = found
        return found
    }

    /// Grayscale keyword for this printer's driver: Epson ESC/P-R PPDs expose
    /// "Mono" (not "Gray"), HP exposes "Gray". Falls back to "Gray".
    static func grayscaleKeyword(for printer: String) -> String {
        pickGrayscale(from: colorChoices(for: printer))
    }

    /// Pure: pick the grayscale keyword from PPD color choices (Epson "Mono", HP "Gray").
    static func pickGrayscale(from choices: [String]) -> String {
        let lower = choices.map { $0.lowercased() }
        return lower.first { $0.contains("gray") || $0.contains("grey") || $0.contains("mono") || $0.contains("black") }
            .map { choices[lower.firstIndex(of: $0)!] } ?? "Gray"
    }

    /// Color keyword (RGB/CMYK/Color) or "RGB" fallback.
    static func colorKeyword(for printer: String) -> String {
        let lower = colorChoices(for: printer).map { $0.lowercased() }
        return lower.first { $0.contains("rgb") || $0.contains("cmyk") || $0.contains("color") || $0.contains("colour") }
            .map { colorChoices(for: printer)[lower.firstIndex(of: $0)!] } ?? "RGB"
    }

    /// Submit a print job with CUPS `lp`, hardened: explicit page-set/number-up/
    /// orientation/fit+scaling, privacy title, explicit copies, duplex intent on
    /// both passes, PPD Resolution when known.
    @discardableResult
    static func print(file: URL, printer: String, pageRange: String?, targetDPI: Int,
                      color: Bool, copies: Int, media: String, paper: String,
                      scale: Int = 100, orientation: String = "auto",
                      duplexEdge: String = "long", title: String) -> String {
        guard let target = prepareForPrint(file) else { return "error: cannot read file" }
        var args = ["-d", printer,
                    "-t", title,
                    "-n", "\(copies)",
                    "-o", paper == "A4" ? "media=iso_a4_210x297mm" : "media=na_letter_8.5x11in",
                    "-o", "page-set=all",
                    "-o", "number-up=1",
                    "-o", "orientation-requested=\(orientation == "landscape" ? 4 : 3)",
                    "-o", "fit-to-page=false",
                    "-o", "scaling=\(scale)",
                    "-o", "sides=one-sided",
                    "-o", duplexEdge == "short" ? "Duplex=Tumble" : "Duplex=NoTumble",
                    "-o", "ColorModel=\(color ? colorKeyword(for: printer) : grayscaleKeyword(for: printer))"]
        if let res = resolutionChoice(for: printer, targetDPI: targetDPI) {
            args += ["-o", "Resolution=\(res)"]
        } else {
            args += ["-o", "print-quality=\(PrintMath.qualityLevel(forDPI: targetDPI))"]
        }
        if let range = pageRange, !range.isEmpty { args += ["-o", "page-ranges=\(range)"] }
        if media == "Glossy" || media == "Photo" { args += ["-o", "MediaType=Photo"] }
        args.append(target.path)
        currentPrinterID = printer
        return run("/usr/bin/lp", args) ?? "error: lp failed"
    }

    /// Wrap a photo into a PDF with BIT-EXACT pixels: FlipStackCore's
    /// PDFImageWriter embeds JPEG bytes verbatim via /DCTDecode and everything
    /// else losslessly via /FlateDecode (no recompression, EXIF handled).
    static func photoToPDFURL(_ imageURL: URL) -> URL? {
        guard let img = try? PDFImageWriter.embedImage(at: imageURL) else { return nil }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("flipstack-demo-\(UUID().uuidString).pdf")
        do {
            try PDFImageWriter.writePDF(pages: [img], to: tmp)
            return tmp
        } catch {
            return nil
        }
    }
    static func photoToPDF(_ imageURL: URL) -> PDFDocument? {
        guard let u = photoToPDFURL(imageURL) else { return nil }
        return PDFDocument(url: u)
    }

    private static func prepareForPrint(_ file: URL) -> URL? {
        if PrintMath.isPhoto(file.lastPathComponent) { return photoToPDFURL(file) }
        return file
    }

    /// Simple calibration sheet PDF (sharpness lines + alignment pairs).
    static func calibrationPDF() -> URL? {
        var page = CGRect(x: 0, y: 0, width: 595, height: 842)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &page, nil) else { return nil }
        ctx.setFillColor(NSColor.white.cgColor); ctx.fill(page)
        ctx.setStrokeColor(NSColor.black.cgColor)
        for i in 1...10 {
            ctx.setLineWidth(CGFloat(i) * 0.4)
            ctx.beginPath()
            ctx.move(to: CGPoint(x: 60, y: 700 - CGFloat(i) * 18))
            ctx.addLine(to: CGPoint(x: 535, y: 700 - CGFloat(i) * 18))
            ctx.strokePath()
        }
        for i in 0..<5 {
            ctx.setLineWidth(1)
            ctx.stroke(CGRect(x: 60 + CGFloat(i) * 40, y: 300, width: 20, height: 120))
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11),
                                                    .foregroundColor: NSColor.black]
        "FLIPSTACK CALIBRATION — mark sharpest line & aligned pair"
            .draw(at: CGPoint(x: 60, y: 780), withAttributes: attrs)
        ctx.endPage(); ctx.flush()
        guard let doc = PDFDocument(data: data as Data) else { return nil }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("flipstack-calibration.pdf")
        try? doc.write(to: tmp)
        return tmp
    }

    @discardableResult
    private static func run(_ path: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        currentProcess = p
        do { try p.run() } catch { currentProcess = nil; return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        currentProcess = nil
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
