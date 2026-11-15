import Foundation

/// Tiny append-only diagnostic log for the print flow
/// (`~/Library/Logs/FlipStack.log`). Used to diagnose real-printer issues
/// without sending documents anywhere. Never logs document content or paths.
enum FlowLog {
    private static let queue = DispatchQueue(label: "app.flipstack.flowlog")
    private static let maxSize = 512 * 1024

    static var url: URL {
        if let override = ProcessInfo.processInfo.environment["FLIPSTACK_LOG_PATH"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        return base.appendingPathComponent("Logs/FlipStack.log")
    }

    static func write(_ message: String) {
        queue.async {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let line = "\(formatter.string(from: Date())) \(message)\n"
            if ProcessInfo.processInfo.environment["FLIPSTACK_LOG_STDOUT"] == "1" {
                FileHandle.standardError.write(Data(line.utf8))
            }
            let url = Self.url
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                if let data = line.data(using: .utf8) {
                    if let handle = try? FileHandle(forWritingTo: url) {
                        defer { try? handle.close() }
                        try? handle.seekToEnd()
                        try? handle.write(contentsOf: data)
                        let size = (try? handle.seekToEnd()) ?? 0
                        if size > UInt64(Self.maxSize) {
                            // keep the log bounded: truncate to the tail
                            let all = try? Data(contentsOf: url)
                            if let all, all.count > Self.maxSize / 2 {
                                try? all.suffix(Self.maxSize / 2).write(to: url)
                            }
                        }
                    } else {
                        try? data.write(to: url, options: .atomic)
                    }
                }
            } catch {
                // logging must never affect the app
            }
        }
    }
}
