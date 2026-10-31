import AppKit
import Foundation
import CoreGraphics
import FlipStackCore

enum PrintUtilities {
    static func makeTestPage(printerName: String) throws -> URL {
        try makePDF(size: CGSize(width: 595, height: 842)) { context in
            drawHeader(context, title: L("FlipStack test page"), subtitle: printerName)
            let ink = NSColor(calibratedRed: 1.0, green: 0.34, blue: 0.22, alpha: 1)
            let colors: [(String, NSColor)] = [
                ("Cyan", .cyan),
                ("Magenta", .magenta),
                ("Yellow", .yellow),
                ("Black", .black),
                ("FlipStack coral", ink)
            ]
            var y: CGFloat = 660
            for (name, color) in colors {
                drawText(name, at: CGPoint(x: 64, y: y + 26), size: 11, color: .black)
                context.setFillColor(color.cgColor)
                context.fill(CGRect(x: 64, y: y, width: 420, height: 22))
                y -= 52
            }
            context.setStrokeColor(NSColor.black.withAlphaComponent(0.2).cgColor)
            context.setLineWidth(0.5)
            for step in 0...10 {
                let x = 64 + CGFloat(step) * 42
                context.move(to: CGPoint(x: x, y: 300))
                context.addLine(to: CGPoint(x: x, y: 190))
                context.strokePath()
            }
            drawText(L("Alignment bars: each vertical line should be crisp and evenly spaced."),
                     at: CGPoint(x: 64, y: 160), size: 10, color: .darkGray)
            drawText(L("If lines are broken or colors streak, run a head cleaning cycle."),
                     at: CGPoint(x: 64, y: 140), size: 10, color: .darkGray)
            drawText(String(format: L("Printed by FlipStack · %@"), formattedNow()),
                     at: CGPoint(x: 64, y: 80), size: 9, color: .gray)
        }
    }

    static func makeAlignmentPage(printerName: String) throws -> URL {
        try makePDF(size: CGSize(width: 595, height: 842)) { context in
            drawHeader(context, title: L("Head alignment sheet"), subtitle: printerName)
            drawText(L("1. Print this page at 100% on plain paper."),
                     at: CGPoint(x: 64, y: 700), size: 11, color: .black)
            drawText(L("2. Find the row where the two line segments meet without a step."),
                     at: CGPoint(x: 64, y: 680), size: 11, color: .black)
            drawText(L("3. Enter that row in your printer’s alignment utility."),
                     at: CGPoint(x: 64, y: 660), size: 11, color: .black)

            var y: CGFloat = 590
            for row in 1...12 {
                drawText(String(format: "%02d", row), at: CGPoint(x: 56, y: y - 4), size: 9, color: .darkGray)
                context.setStrokeColor(NSColor.black.cgColor)
                context.setLineWidth(1.2)
                let offset = CGFloat((row % 3) - 1) * 2.2
                context.move(to: CGPoint(x: 90, y: y))
                context.addLine(to: CGPoint(x: 300, y: y + offset))
                context.move(to: CGPoint(x: 300, y: y + offset))
                context.addLine(to: CGPoint(x: 510, y: y))
                context.strokePath()
                y -= 38
            }

            context.setStrokeColor(NSColor.black.withAlphaComponent(0.35).cgColor)
            context.setLineWidth(0.5)
            context.move(to: CGPoint(x: 64, y: 96))
            context.addLine(to: CGPoint(x: 531, y: 96))
            context.strokePath()
            drawText(String(format: L("FlipStack alignment reference · %@"), formattedNow()),
                     at: CGPoint(x: 64, y: 74), size: 9, color: .gray)
        }
    }

    /// A deliberately generic orientation sheet. It contains no document
    /// content and no printer-specific metadata, so it is safe to leave beside
    /// the printer or discard.
    static func makeFlipCalibrationPage() throws -> URL {
        try makePDF(size: CGSize(width: 595, height: 842)) { context in
            let coral = NSColor(calibratedRed: 0.92, green: 0.31, blue: 0.19, alpha: 1)
            let graphite = NSColor(calibratedWhite: 0.16, alpha: 1)
            let mid = NSColor(calibratedWhite: 0.42, alpha: 1)
            let pale = NSColor(calibratedWhite: 0.93, alpha: 1)

            // Sheet frame and edge markers.
            context.setStrokeColor(graphite.cgColor)
            context.setLineWidth(1.4)
            context.stroke(CGRect(x: 36, y: 36, width: 523, height: 770))

            context.setFillColor(coral.cgColor)
            context.fill(CGRect(x: 48, y: 780, width: 42, height: 4))

            drawText(L("FLIPSTACK"), at: CGPoint(x: 102, y: 776), size: 10, color: graphite, weight: .bold)
            drawText(L("FLIP CALIBRATION SHEET"), at: CGPoint(x: 48, y: 742), size: 24, color: graphite, weight: .bold)
            drawText(L("One sheet. No document content."), at: CGPoint(x: 48, y: 720), size: 12, color: mid)

            drawCenteredText(L("TOP EDGE · SHORT EDGE"), centerX: 297.5, y: 786, size: 11, color: graphite, weight: .semibold)
            drawCenteredText(L("BOTTOM EDGE · SHORT EDGE"), centerX: 297.5, y: 48, size: 11, color: graphite, weight: .semibold)

            // Left and right are the long edges of this portrait sheet.
            context.setFillColor(pale.cgColor)
            context.fill(CGRect(x: 48, y: 376, width: 76, height: 72))
            context.fill(CGRect(x: 471, y: 376, width: 76, height: 72))
            drawText(L("LEFT"), at: CGPoint(x: 58, y: 432), size: 13, color: graphite, weight: .bold)
            drawText(L("EDGE"), at: CGPoint(x: 58, y: 416), size: 13, color: graphite, weight: .bold)
            drawText(L("LONG EDGE"), at: CGPoint(x: 48, y: 396), size: 9, color: graphite, weight: .semibold)
            drawText(L("RIGHT"), at: CGPoint(x: 481, y: 432), size: 13, color: graphite, weight: .bold)
            drawText(L("EDGE"), at: CGPoint(x: 481, y: 416), size: 13, color: graphite, weight: .bold)
            drawText(L("LONG EDGE"), at: CGPoint(x: 478, y: 396), size: 9, color: graphite, weight: .semibold)

            // A single strong top arrow, visible at a glance.
            context.setStrokeColor(graphite.cgColor)
            context.setLineWidth(6)
            context.setLineCap(.round)
            context.move(to: CGPoint(x: 297.5, y: 590))
            context.addLine(to: CGPoint(x: 297.5, y: 700))
            context.strokePath()
            context.setFillColor(graphite.cgColor)
            context.move(to: CGPoint(x: 297.5, y: 718))
            context.addLine(to: CGPoint(x: 276, y: 688))
            context.addLine(to: CGPoint(x: 319, y: 688))
            context.closePath()
            context.fillPath()
            drawText(L("TOP"), at: CGPoint(x: 330, y: 676), size: 12, color: graphite, weight: .bold)

            // The printed side marker.
            let block = CGRect(x: 177, y: 270, width: 241, height: 350)
            context.setFillColor(pale.cgColor)
            context.fill(block)
            context.setStrokeColor(NSColor(calibratedWhite: 0.78, alpha: 1).cgColor)
            context.setLineWidth(0.8)
            context.stroke(block)
            drawCenteredText(L("PRINTED"), centerX: 297.5, y: 518, size: 34, color: graphite, weight: .bold)
            drawCenteredText(L("SIDE"), centerX: 297.5, y: 480, size: 34, color: graphite, weight: .bold)
            drawCenteredText(L("This is the printed side"), centerX: 297.5, y: 446, size: 12, color: mid)

            context.setFillColor(coral.cgColor)
            context.fill(CGRect(x: 209, y: 354, width: 177, height: 7))
            context.setFillColor(NSColor(calibratedWhite: 0.82, alpha: 1).cgColor)
            context.fill(CGRect(x: 209, y: 336, width: 121, height: 5))
            context.fill(CGRect(x: 209, y: 323, width: 152, height: 5))

            drawCenteredText(L("1  NOTE WHICH SIDE LANDED UP"), centerX: 297.5, y: 236, size: 10, color: graphite, weight: .semibold)
            drawCenteredText(L("2  CONFIRM THE TURN IN FLIPSTACK"), centerX: 297.5, y: 218, size: 10, color: graphite, weight: .semibold)
            drawCenteredText(L("Nothing is written to the sheet. This sheet is safe to discard."), centerX: 297.5, y: 190, size: 10, color: mid)

            context.setFillColor(coral.cgColor)
            context.fill(CGRect(x: 48, y: 128, width: 8, height: 8))
            context.fill(CGRect(x: 539, y: 128, width: 8, height: 8))
            drawText(L("FlipStack flip calibration"), at: CGPoint(x: 48, y: 96), size: 9, color: mid)
            drawText(L("This sheet is safe to discard."), at: CGPoint(x: 48, y: 80), size: 9, color: mid)
        }
    }

    private static func makePDF(size: CGSize, draw: (CGContext) -> Void) throws -> URL {
        let data = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: size)
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw PrintUtilityError.cannotCreatePDF
        }
        context.beginPDFPage(nil)
        context.setFillColor(NSColor.white.cgColor)
        context.fill(mediaBox)

        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        draw(context)
        NSGraphicsContext.restoreGraphicsState()

        context.endPDFPage()
        context.closePDF()

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FlipStack", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        let url = directory.appendingPathComponent("FlipStack-\(UUID().uuidString).pdf")
        try (data as Data).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
        return url
    }

    private static func drawHeader(_ context: CGContext, title: String, subtitle: String) {
        let coral = NSColor(calibratedRed: 1.0, green: 0.34, blue: 0.22, alpha: 1)
        context.setFillColor(coral.cgColor)
        context.fill(CGRect(x: 64, y: 780, width: 34, height: 4))
        drawText(title, at: CGPoint(x: 64, y: 730), size: 26, color: .black, weight: .bold)
        drawText(subtitle, at: CGPoint(x: 64, y: 708), size: 12, color: .darkGray)
    }

    private static func drawText(
        _ text: String,
        at point: CGPoint,
        size: CGFloat,
        color: NSColor,
        weight: NSFont.Weight = .regular
    ) {
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color
        ]
        (text as NSString).draw(at: point, withAttributes: attributes)
    }

    private static func drawCenteredText(
        _ text: String,
        centerX: CGFloat,
        y: CGFloat,
        size: CGFloat,
        color: NSColor,
        weight: NSFont.Weight = .regular
    ) {
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color
        ]
        let width = (text as NSString).size(withAttributes: attributes).width
        (text as NSString).draw(
            at: CGPoint(x: centerX - width / 2, y: y),
            withAttributes: attributes
        )
    }

    private static func formattedNow() -> String {
        let formatter = DateFormatter()
        formatter.locale = AppLanguage.current.locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: Date())
    }
}

enum PrintUtilityError: LocalizedError {
    case cannotCreatePDF

    var errorDescription: String? {
        switch self {
        case .cannotCreatePDF:
            return L("Could not create the PDF.")
        }
    }
}
