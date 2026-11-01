import Compression
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Writes a minimal PDF whose pages are images embedded at their native
/// resolution. JPEG sources keep their original bytes bit-exact
/// (`/DCTDecode`); every other format is decoded once and stored losslessly
/// (`/FlateDecode`), so ingesting a photo never re-encodes or downsamples
/// it. The page box equals the pixel size in points (72 dpi nominal), and
/// EXIF orientation is applied with the content-stream matrix, so what you
/// see in the preview is what prints.
public enum PDFImageWriter {
    public enum ImageError: LocalizedError, Equatable, Sendable {
        case unreadableImage
        case unsupportedImage
        case cannotCreateContext
        case cannotWrite

        public var errorDescription: String? {
            switch self {
            case .unreadableImage: return "The image could not be read."
            case .unsupportedImage: return "This image format is not supported."
            case .cannotCreateContext: return "The PDF page could not be created."
            case .cannotWrite: return "The PDF could not be written."
            }
        }
    }

    public struct EmbeddedImage: Sendable {
        /// Pixel width of the stored image.
        public var width: Int
        /// Pixel height of the stored image.
        public var height: Int
        /// EXIF orientation, 1...8.
        public var orientation: Int
        /// Encoded image bytes (original JPEG, or zlib-compressed RGB).
        public var data: Data
        /// PDF filter name, e.g. "/DCTDecode".
        public var filter: String

        public init(width: Int, height: Int, orientation: Int, data: Data, filter: String) {
            self.width = width
            self.height = height
            self.orientation = min(max(orientation, 1), 8)
            self.data = data
            self.filter = filter
        }
    }

    /// Reads an image file and prepares it for embedding. JPEG files keep
    /// their exact bytes; all other ImageIO-readable formats are decoded to
    /// raw RGB (composited on white) and zlib-compressed losslessly.
    public static func embedImage(at url: URL) throws -> EmbeddedImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ImageError.unreadableImage
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
              let height = properties[kCGImagePropertyPixelHeight as String] as? Int,
              width > 0, height > 0 else {
            throw ImageError.unreadableImage
        }
        let orientation = (properties[kCGImagePropertyOrientation as String] as? Int) ?? 1

        if let type = CGImageSourceGetType(source) as String?,
           let utType = UTType(type), utType.conforms(to: .jpeg) {
            // Bit-exact: the original JPEG stream becomes the PDF image.
            let data = try Data(contentsOf: url)
            return EmbeddedImage(
                width: width,
                height: height,
                orientation: orientation,
                data: data,
                filter: "/DCTDecode"
            )
        }

        guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ImageError.unsupportedImage
        }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bytesPerRow = width * 4
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        ) else {
            throw ImageError.cannotCreateContext
        }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let raw = context.data else {
            throw ImageError.cannotCreateContext
        }
        // Strip the leading alpha byte (noneSkipFirst = XRGB): keep RGB.
        let rgba = Data(bytes: raw, count: width * height * 4)
        var rgb = Data(capacity: width * height * 3)
        var offset = 0
        while offset + 4 <= rgba.count {
            rgb.append(rgba.subdata(in: (offset + 1)..<(offset + 4)))
            offset += 4
        }
        let rawData = rgb
        guard let compressed = Self.zlibCompress(rawData), !compressed.isEmpty else {
            // Fall back to uncompressed Flate (stored) blocks.
            return EmbeddedImage(
                width: width,
                height: height,
                orientation: orientation,
                data: rawData,
                filter: "/FlateDecode"
            )
        }
        return EmbeddedImage(
            width: width,
            height: height,
            orientation: orientation,
            data: compressed,
            filter: "/FlateDecode"
        )
    }

    /// zlib-compresses `data` (lossless, RFC 1950: header + raw deflate +
    /// Adler-32), which is what PDF `/FlateDecode` expects. Returns nil on
    /// failure.
    private static func zlibCompress(_ data: Data) -> Data? {
        guard !data.isEmpty else { return data }
        let capacity = data.count + data.count / 100 + 4096
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { outputPointer in
            data.withUnsafeBytes { inputPointer in
                compression_encode_buffer(
                    outputPointer.baseAddress!,
                    capacity,
                    inputPointer.baseAddress!,
                    data.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard written > 0 else { return nil }
        // Some OS versions already emit a full RFC 1950 zlib stream (leading
        // 0x78); only add the manual header + Adler-32 when it is raw deflate.
        if output.first == 0x78 {
            return Data(output.prefix(written))
        }
        var result = Data([0x78, 0x9C])
        result.append(output.prefix(written))
        let adler = Self.adler32(data).bigEndian
        withUnsafeBytes(of: adler) { result.append(contentsOf: $0) }
        return result
    }

    private static func adler32(_ data: Data) -> UInt32 {
        var a: UInt32 = 1
        var b: UInt32 = 0
        for byte in data {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        return (b << 16) | a
    }

    /// Displayed page size in points: the pixel size, swapped for the EXIF
    /// orientations that turn the image 90 degrees.
    public static func pageSize(for image: EmbeddedImage) -> CGSize {
        switch image.orientation {
        case 5, 6, 7, 8:
            return CGSize(width: image.height, height: image.width)
        default:
            return CGSize(width: image.width, height: image.height)
        }
    }

    /// The content-stream matrix that displays the stored image correctly for
    /// its EXIF orientation on a page of `pageSize`.
    private static func contentMatrix(for image: EmbeddedImage, pageSize: CGSize) -> String {
        let w = pageSize.width
        let h = pageSize.height
        func n(_ value: CGFloat) -> String {
            String(format: "%.2f", value)
        }
        switch image.orientation {
        case 1: return "\(n(w)) 0 0 \(n(h)) 0 0"
        case 2: return "\(n(-w)) 0 0 \(n(h)) \(n(w)) 0"
        case 3: return "\(n(-w)) 0 0 \(n(-h)) \(n(w)) \(n(h))"
        case 4: return "\(n(w)) 0 0 \(n(-h)) 0 \(n(h))"
        case 5: return "0 \(n(w)) \(n(h)) 0 0 0"
        case 6: return "0 \(n(w)) \(n(-h)) 0 \(n(h)) 0"
        case 7: return "0 \(n(-w)) \(n(-h)) 0 \(n(h)) \(n(w))"
        case 8: return "0 \(n(-w)) \(n(h)) 0 0 \(n(h))"
        default: return "\(n(w)) 0 0 \(n(h)) 0 0"
        }
    }

    /// Writes a single PDF with one page per image, in order.
    public static func writePDF(pages: [EmbeddedImage], to url: URL) throws {
        guard !pages.isEmpty else { throw ImageError.cannotWrite }
        var objects: [Int: Data] = [:]

        let firstPageObject = 3
        let kids = (0..<pages.count)
            .map { "\(firstPageObject + $0 * 3) 0 R" }
            .joined(separator: " ")
        objects[1] = "<< /Type /Catalog /Pages 2 0 R >>\n".data(using: .utf8)!
        objects[2] = "<< /Type /Pages /Count \(pages.count) /Kids [\(kids)] >>\n".data(using: .utf8)!

        for (index, image) in pages.enumerated() {
            let pageObject = firstPageObject + index * 3
            let contentObject = pageObject + 1
            let imageObject = pageObject + 2
            let size = pageSize(for: image)
            func n(_ value: CGFloat) -> String { String(format: "%.2f", value) }
            objects[pageObject] = (
                "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 \(n(size.width)) \(n(size.height))] " +
                "/Resources << /XObject << /Im0 \(imageObject) 0 R >> >> /Contents \(contentObject) 0 R >>\n"
            ).data(using: .utf8)!

            let content = "q \(contentMatrix(for: image, pageSize: size)) cm /Im0 Do Q\n"
            var contentObjectData = "<< /Length \(content.utf8.count) >>\nstream\n".data(using: .utf8)!
            contentObjectData.append(content.data(using: .utf8)!)
            contentObjectData.append("endstream\n".data(using: .utf8)!)
            objects[contentObject] = contentObjectData

            var imageObjectData = (
                "<< /Type /XObject /Subtype /Image /Width \(image.width) /Height \(image.height) " +
                "/ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter \(image.filter) /Length \(image.data.count) >>\nstream\n"
            ).data(using: .utf8)!
            imageObjectData.append(image.data)
            imageObjectData.append("\nendstream\n".data(using: .utf8)!)
            objects[imageObject] = imageObjectData
        }

        var pdf = Data("%PDF-1.7\n%\u{E2}\u{E3}\u{CF}\u{D3}\n".data(using: .utf8)!)
        var offsets: [Int] = [0]
        let objectCount = objects.count
        for number in 1...objectCount {
            offsets.append(pdf.count)
            pdf.append("\(number) 0 obj\n".data(using: .utf8)!)
            pdf.append(objects[number]!)
            pdf.append("endobj\n".data(using: .utf8)!)
        }
        let xrefStart = pdf.count
        pdf.append("xref\n0 \(objectCount + 1)\n".data(using: .utf8)!)
        pdf.append("0000000000 65535 f \n".data(using: .utf8)!)
        for number in 1...objectCount {
            pdf.append(String(format: "%010d 00000 n \n", offsets[number]).data(using: .utf8)!)
        }
        pdf.append(
            "trailer\n<< /Size \(objectCount + 1) /Root 1 0 R >>\nstartxref\n\(xrefStart)\n%%EOF\n".data(using: .utf8)!
        )

        do {
            try SecureTemp.secureParent(of: url)
            try SecureTemp.write(pdf, to: url)
        } catch {
            throw ImageError.cannotWrite
        }
    }
}
