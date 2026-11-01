import AppKit
import Foundation
import PDFKit
import UniformTypeIdentifiers

/// Turns any accepted user file into a PDF the print pipeline can use.
///
/// - PDFs keep their pages untouched.
/// - Photos (JPEG, HEIC, PNG, TIFF, GIF, WebP, …) are embedded at native
///   resolution: JPEG bytes are copied bit-exact, other formats are stored
///   losslessly. No resampling, no recompression.
/// - Word and text documents (.docx, .doc, .odt, .rtf, .txt, .html, …) are
///   converted to PDF locally — Word formats go through the system `textutil`
///   (RTF keeps formatting), everything else is read directly.
///
/// All output lives in a 0700/0600 SecureTemp directory; only the final PDF
/// URL is returned, and the caller owns deleting its parent directory.
public enum DocumentIngest {
    public enum Kind: String, Equatable, Sendable {
        case pdf
        case image
        case word       // docx / doc / odt — converted via textutil
        case richText   // rtf / rtfd / html
        case plainText  // txt / md / …
        case unsupported
    }

    public enum IngestError: LocalizedError, Equatable, Sendable {
        case empty
        case unsupportedType
        case unreadable
        case conversionFailed(String)
        case cannotWrite

        public var errorDescription: String? {
            switch self {
            case .empty: return "No file was provided."
            case .unsupportedType:
                return "This file type is not supported. FlipStack accepts PDFs, photos, and Word or text documents."
            case .unreadable: return "The file could not be read."
            case .conversionFailed(let tool): return "The document could not be converted (\(tool) failed)."
            case .cannotWrite: return "The converted PDF could not be written."
            }
        }
    }

    /// File extensions FlipStack accepts, used as a fallback when the file
    /// system reports no type identifier.
    public static let acceptedExtensions: Set<String> = [
        "pdf",
        "jpg", "jpeg", "heic", "heif", "png", "tiff", "tif", "gif", "bmp",
        "webp", "ico", "jp2", "psd",
        "docx", "doc", "odt",
        "rtf", "rtfd", "html", "htm",
        "txt", "md", "markdown"
    ]

    /// UTTypes for the open panel and drop validation, app-side.
    public static var acceptedContentTypes: [UTType] {
        var types: [UTType] = [.pdf, .image, .rtf, .plainText, .html]
        for identifier in [
            "org.openxmlformats.wordprocessingml.document", // .docx
            "com.microsoft.word.doc",                          // .doc
            "org.oasis-open.opendocument.text"                 // .odt
        ] {
            if let type = UTType(identifier) {
                types.append(type)
            }
        }
        return types
    }

    /// Classifies a file. The type identifier is authoritative when present;
    /// the extension is the fallback for files without one.
    public static func kind(of url: URL) -> Kind {
        let typeIdentifier = try? url.resourceValues(forKeys: [.typeIdentifierKey]).typeIdentifier
        if let typeIdentifier, let type = UTType(typeIdentifier) {
            if type.conforms(to: .pdf) { return .pdf }
            if type.conforms(to: .image) { return .image }
            if type.conforms(to: .rtf) { return .richText }
            if type.conforms(to: .html) { return .richText }
            if type.conforms(to: .plainText) { return .plainText }
            if typeIdentifier == "org.openxmlformats.wordprocessingml.document"
                || typeIdentifier == "com.microsoft.word.doc"
                || typeIdentifier == "org.oasis-open.opendocument.text" {
                return .word
            }
            if type.conforms(to: .text) || type.conforms(to: .content) == false {
                // Unknown but text-like identifiers fall through to the
                // extension check below.
            }
        }
        switch url.pathExtension.lowercased() {
        case "pdf": return .pdf
        case "jpg", "jpeg", "heic", "heif", "png", "tiff", "tif", "gif", "bmp",
             "webp", "ico", "jp2", "psd": return .image
        case "docx", "doc", "odt": return .word
        case "rtf", "rtfd", "html", "htm": return .richText
        case "txt", "md", "markdown": return .plainText
        default: return .unsupported
        }
    }

    public static func isAccepted(_ url: URL) -> Bool {
        kind(of: url) != .unsupported
    }

    /// A short tag for the document card: PDF, IMG, or DOC.
    public static func formatTag(for kind: Kind) -> String {
        switch kind {
        case .pdf: return "PDF"
        case .image: return "IMG"
        case .word, .richText, .plainText: return "DOC"
        case .unsupported: return "—"
        }
    }

    /// Builds one PDF from one or more accepted files, preserving order:
    /// PDF pages first come from PDF inputs, then photo pages, then rendered
    /// text pages — matching the order the files were provided.
    @discardableResult
    public static func makePDF(from urls: [URL]) throws -> URL {
        let accepted = urls.filter { isAccepted($0) }
        guard accepted.count == urls.count, !urls.isEmpty else {
            throw IngestError.unsupportedType
        }

        var images: [PDFImageWriter.EmbeddedImage] = []
        var textInputs: [URL] = []
        let merged = PDFDocument()

        for url in accepted {
            switch kind(of: url) {
            case .pdf:
                guard let document = PDFDocument(url: url) else {
                    throw IngestError.unreadable
                }
                for index in 0..<document.pageCount {
                    guard let page = document.page(at: index),
                          let copy = page.copy() as? PDFPage else { continue }
                    merged.insert(copy, at: merged.pageCount)
                }
            case .image:
                images.append(try PDFImageWriter.embedImage(at: url))
            case .word, .richText, .plainText:
                textInputs.append(url)
            case .unsupported:
                throw IngestError.unsupportedType
            }
        }

        // Photos: one page per image, embedded at native resolution.
        if !images.isEmpty {
            let staging = try SecureTemp.makeDirectory(prefix: "IngestImages")
            defer { try? FileManager.default.removeItem(at: staging) }
            let imagePDF = staging.appendingPathComponent("images.pdf")
            try PDFImageWriter.writePDF(pages: images, to: imagePDF)
            guard let document = PDFDocument(url: imagePDF) else {
                throw IngestError.cannotWrite
            }
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index),
                      let copy = page.copy() as? PDFPage else { continue }
                merged.insert(copy, at: merged.pageCount)
            }
        }

        // Word / text: render locally to PDF pages.
        for url in textInputs {
            let data = try renderTextPDF(for: url)
            guard let document = PDFDocument(data: data), document.pageCount > 0 else {
                throw IngestError.conversionFailed(url.pathExtension)
            }
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index),
                      let copy = page.copy() as? PDFPage else { continue }
                merged.insert(copy, at: merged.pageCount)
            }
        }

        guard merged.pageCount > 0 else { throw IngestError.unreadable }
        guard let data = merged.dataRepresentation() else { throw IngestError.cannotWrite }

        let outputDirectory = try SecureTemp.makeDirectory(prefix: "Ingest")
        let output = outputDirectory.appendingPathComponent("document.pdf")
        try SecureTemp.write(data, to: output)
        return output
    }

    /// Renders a Word/text file to PDF data. Word formats go through the
    /// system `textutil` into RTF (keeping formatting); RTF and plain text
    /// are read directly. The subprocess runs with the scrubbed environment.
    private static func renderTextPDF(for url: URL) throws -> Data {
        let attributed: NSAttributedString
        switch kind(of: url) {
        case .richText:
            if url.pathExtension.lowercased() == "html" || url.pathExtension.lowercased() == "htm" {
                attributed = try NSAttributedString(
                    url: url,
                    options: [.documentType: NSAttributedString.DocumentType.html],
                    documentAttributes: nil
                )
            } else {
                attributed = try NSAttributedString(
                    url: url,
                    options: [.documentType: NSAttributedString.DocumentType.rtf],
                    documentAttributes: nil
                )
            }
        case .plainText:
            let raw = try Data(contentsOf: url)
            let text = String(data: raw, encoding: .utf8)
                ?? String(data: raw, encoding: .utf16)
                ?? String(decoding: raw, as: UTF8.self)
            attributed = NSAttributedString(string: text)
        case .word:
            let staging = try SecureTemp.makeDirectory(prefix: "IngestText")
            defer { try? FileManager.default.removeItem(at: staging) }
            let rtfURL = staging.appendingPathComponent("input.rtf")
            let result = try CUPSProcessRunner().runSynchronously(
                executable: URL(fileURLWithPath: "/usr/bin/textutil"),
                arguments: ["-convert", "rtf", url.path, "-output", rtfURL.path],
                timeout: 120
            )
            guard result.status == 0,
                  FileManager.default.fileExists(atPath: rtfURL.path),
                  let converted = try? NSAttributedString(
                    url: rtfURL,
                    options: [.documentType: NSAttributedString.DocumentType.rtf],
                    documentAttributes: nil
                  ) else {
                throw IngestError.conversionFailed("textutil")
            }
            attributed = converted
        default:
            throw IngestError.unsupportedType
        }
        return try PDFTextRenderer.render(attributed)
    }
}
