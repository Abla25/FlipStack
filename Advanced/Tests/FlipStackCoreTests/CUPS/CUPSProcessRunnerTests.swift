import Foundation
import XCTest
@testable import FlipStackCore

final class CUPSProcessRunnerTests: XCTestCase {
    func testCapturesStandardOutputAndStatus() async throws {
        let result = try await CUPSProcessRunner().run(
            executable: URL(fileURLWithPath: "/bin/echo"),
            arguments: ["hello", "print"],
            timeout: 5
        )
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdoutText, "hello print\n")
        XCTAssertTrue(result.stderr.isEmpty)
    }

    func testMissingExecutableIsReported() async throws {
        do {
            _ = try await CUPSProcessRunner().run(
                executable: URL(fileURLWithPath: "/tmp/FlipStack-no-such-tool"),
                arguments: [],
                timeout: 1
            )
            XCTFail("Expected executableNotFound")
        } catch let error as CUPSProcessError {
            guard case .executableNotFound = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testTaskCancellationTerminatesTheProcess() async throws {
        let task = Task {
            try await CUPSProcessRunner().run(
                executable: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["10"],
                timeout: 20
            )
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testTimeoutTerminatesTheProcess() async throws {
        let started = Date()
        do {
            _ = try await CUPSProcessRunner().run(
                executable: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["5"],
                timeout: 0.25
            )
            XCTFail("Expected timedOut")
        } catch let error as CUPSProcessError {
            guard case .timedOut(let tool) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(tool, "sleep")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 4)
    }
}
