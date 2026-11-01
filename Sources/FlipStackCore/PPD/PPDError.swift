import Foundation

/// Errors surfaced while reading or decompressing a PPD file.
public enum PPDError: LocalizedError, Equatable, Sendable {
    case fileNotFound(String)
    case unreadableFile(String)
    case decompressionFailed(String)
    case toolNotFound(String)
    case timedOut(String)

    public var errorDescription: String? {
        switch self {
        // System PPD paths only: keep the filename for diagnosis, never the
        // full path.
        case .fileNotFound(let path):
            return "The printer driver file \((path as NSString).lastPathComponent) does not exist."
        case .unreadableFile(let path):
            return "The printer driver file \((path as NSString).lastPathComponent) could not be read."
        case .decompressionFailed(let message):
            let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return "The PPD could not be decompressed\(detail.isEmpty ? "." : ": \(detail)")"
        case .toolNotFound(let tool):
            return "The system tool “\(tool)” was not found."
        case .timedOut(let tool):
            return "\(tool) did not respond in time."
        }
    }
}
