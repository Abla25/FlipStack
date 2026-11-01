import AppKit
import CoreText
import Foundation

/// Renders an attributed string (RTF, plain text, or text converted from
/// Word documents) into a paginated PDF on US Letter, using CoreText. Used
/// for non-image documents, where there is no pixel quality to preserve.
public enum PDFTextRenderer {
    public enum TextError: LocalizedError, Equatable, Sendable {
        case unreadableText
        case cannotCreateContext

        public var errorDescription: String? {
            switch self {
            case .unreadableText: return "The document text could not be read."
            case .cannotCreateContext: return "The PDF could not be created."
            }
        }
    }

    private static let pageSize = CGSize(width: 612, height: 792) // US Letter, points
    private static let margin: CGFloat = 54 // 0.75 in

    /// Renders `text` into PDF data, paginating with a framesetter.
    public static func render(_ text: NSAttributedString) throws -> Data {
        guard text.length > 0 else { throw TextError.unreadableText }
        let framesetter = CTFramesetterCreateWithAttributedString(text as CFAttributedString)

        let data = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw TextError.cannotCreateContext
        }

        let path = CGPath(
            rect: CGRect(
                x: margin,
                y: margin,
                width: pageSize.width - margin * 2,
                height: pageSize.height - margin * 2
            ),
            transform: nil
        )

        var currentIndex = 0
        let totalLength = text.length
        while currentIndex < totalLength {
            context.beginPDFPage(nil)
            context.saveGState()
            // CoreText draws top-down; flip the context so text is upright.
            context.translateBy(x: 0, y: pageSize.height)
            context.scaleBy(x: 1, y: -1)

            let frame = CTFramesetterCreateFrame(
                framesetter,
                CFRange(location: currentIndex, length: 0),
                path,
                nil
            )
            CTFrameDraw(frame, context)
            let visibleRange = CTFrameGetVisibleStringRange(frame)
            currentIndex += visibleRange.length

            context.restoreGState()
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }
}
