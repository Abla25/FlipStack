import Foundation
import XCTest
@testable import FlipStackCore

enum CUPSFixtureLocator {
    static var ppdDirectory: URL {
        if let fixtures = Bundle.module.url(forResource: "Fixtures", withExtension: nil) {
            let candidate = fixtures.appendingPathComponent("PPDs", isDirectory: true)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        if let candidate = Bundle.module.url(
            forResource: "PPDs",
            withExtension: nil,
            subdirectory: "Fixtures"
        ) {
            return candidate
        }

        // Source-tree fallback for tooling that runs tests without resources.
        let supportFile = URL(fileURLWithPath: #filePath)
        let testRoot = supportFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return testRoot.appendingPathComponent("Fixtures/PPDs", isDirectory: true)
    }

    static func ppdURL(_ name: String) -> URL {
        ppdDirectory.appendingPathComponent(name)
    }

    static func ppdData(_ name: String) throws -> Data {
        try Data(contentsOf: ppdURL(name))
    }
}

final class CUPSStubCommandRunner: CUPSCommandRunning, @unchecked Sendable {
    typealias Handler = @Sendable (_ executable: URL, _ arguments: [String]) throws -> CUPSCommandResult

    private let lock = NSLock()
    private let handler: Handler
    private var recorded: [(command: String, arguments: [String])] = []

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    convenience init(result: CUPSCommandResult) {
        self.init { _, _ in result }
    }

    func run(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> CUPSCommandResult {
        record(command: executable.lastPathComponent, arguments: arguments)
        return try handler(executable, arguments)
    }

    private func record(command: String, arguments: [String]) {
        lock.lock()
        recorded.append((command, arguments))
        lock.unlock()
    }

    var invocations: [(command: String, arguments: [String])] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func arguments(for command: String) -> [[String]] {
        invocations.filter { $0.command == command }.map(\.arguments)
    }
}

final class CUPSTestTemporaryDirectory {
    let url: URL

    init(prefix: String = "FlipStackTests") throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    @discardableResult
    func write(_ data: Data, name: String) throws -> URL {
        let destination = url.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: destination)
        return destination
    }

    @discardableResult
    func copyFixture(_ name: String, as destinationName: String? = nil) throws -> URL {
        let data = try CUPSFixtureLocator.ppdData(name)
        return try write(data, name: destinationName ?? name)
    }
}

enum CUPSTestGzip {
    static func compress(_ data: Data) throws -> Data {
        let directory = try CUPSTestTemporaryDirectory(prefix: "FlipStackGzip")
        let input = try directory.write(data, name: "input.ppd")
        let result = try CUPSProcessRunner().runSynchronously(
            executable: URL(fileURLWithPath: "/usr/bin/gzip"),
            arguments: ["-c", "-n", input.path],
            timeout: 15
        )
        guard result.status == 0 else {
            throw NSError(
                domain: "CUPSTestGzip",
                code: Int(result.status),
                userInfo: [NSLocalizedDescriptionKey: result.combinedMessage]
            )
        }
        return result.stdout
    }
}

func cupsTestResult(_ stdout: String = "", status: Int32 = 0, stderr: String = "") -> CUPSCommandResult {
    CUPSCommandResult(status: status, stdout: stdout, stderr: stderr)
}
