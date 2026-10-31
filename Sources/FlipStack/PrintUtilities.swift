import AppKit
import Foundation
import CoreGraphics

enum PrintUtilities {
    static func makeTestPage(printerName: String) throws -> URL {
        try makePDF(size: CGSize(width: 595, height: 842)) { context in
            drawHeader(context, title: "FlipStack test page", subtitle: printerName)
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
            drawText("Alignment bars: each vertical line should be crisp and evenly spaced.",
                     at: CGPoint(x: 64, y: 160), size: 10, color: .darkGray)
            drawText("If lines are broken or colors streak, run a head cleaning cycle.",
                     at: CGPoint(x: 64, y: 140), size: 10, color: .darkGray)
            drawText("Printed by FlipStack · \(formattedNow())",
                     at: CGPoint(x: 64, y: 80), size: 9, color: .gray)
        }
    }

    static func makeAlignmentPage(printerName: String) throws -> URL {
        try makePDF(size: CGSize(width: 595, height: 842)) { context in
            drawHeader(context, title: "Head alignment sheet", subtitle: printerName)
            drawText("1. Print this page at 100% on plain paper.",
                     at: CGPoint(x: 64, y: 700), size: 11, color: .black)
            drawText("2. Find the row where the two line segments meet without a step.",
                     at: CGPoint(x: 64, y: 680), size: 11, color: .black)
            drawText("3. Enter that row in your printer’s alignment utility.",
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
            drawText("FlipStack alignment reference · \(formattedNow())",
                     at: CGPoint(x: 64, y: 74), size: 9, color: .gray)
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
        let url = directory.appendingPathComponent("FlipStack-\(UUID().uuidString).pdf")
        try (data as Data).write(to: url, options: .atomic)
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

    private static func formattedNow() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
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
            return "Could not create the PDF."
        }
    }
}
