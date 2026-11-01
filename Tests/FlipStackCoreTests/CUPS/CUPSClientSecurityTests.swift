import Foundation
import XCTest
@testable import FlipStackCore

/// Security regression tests: the print subprocess must never receive a
/// document path or a hostile printer id as a flag, and temp files derived
/// from documents must be created with restrictive permissions.
final class CUPSClientSecurityTests: XCTestCase {
    func testSubmitNeverPutsTheSourceDocumentPathInLPArguments() async throws {
        let directory = try CUPSTestTemporaryDirectory(prefix: "FlipStackSecPath")
        let secretName = "My Private Thesis Final.pdf"
        let file = try directory.write(Data("pdf".utf8), name: secretName)

        let runner = CUPSStubCommandRunner { executable, arguments in
            if executable.lastPathComponent == "lpstat" {
                return cupsTestResult("printer Test_Queue is idle. enabled since Jan 01\n")
            }
            XCTAssertEqual(executable.lastPathComponent, "lp")
            return cupsTestResult("request id is Test_Queue-88 (1 file(s))\n")
        }

        let request = PrintRequest(
            fileURL: file,
            printerID: "Test_Queue",
            title: "FlipStack fronts"
        )
        _ = try await CUPSClient(runner: runner).submit(request)

        let lpArguments = runner.arguments(for: "lp").flatMap { $0 }
        XCTAssertFalse(
            lpArguments.contains { $0.contains(secretName) || $0 == file.path },
            "lp argv must use the neutral spool copy, not the user's file path"
        )
        XCTAssertTrue(lpArguments.contains { $0.hasSuffix("/document.pdf") })
        XCTAssertFalse(lpArguments.contains("My Private Thesis Final"))
    }

    func testSubmitRejectsHostilePrinterIDs() async throws {
        let directory = try CUPSTestTemporaryDirectory(prefix: "FlipStackSecID")
        let file = try directory.write(Data("pdf".utf8), name: "input.pdf")

        let runner = CUPSStubCommandRunner { executable, _ in
            if executable.lastPathComponent == "lpstat" {
                return cupsTestResult("printer Test_Queue is idle. enabled since Jan 01\n")
            }
            return cupsTestResult("request id is Test_Queue-88 (1 file(s))\n")
        }

        // Arguments are passed as an array (no shell), so only a leading dash
        // could turn the id into a flag; those must be rejected outright.
        for hostile in ["", "-o", "--help", "-d", "/etc/passwd", "..", "."] {
            let request = PrintRequest(fileURL: file, printerID: hostile, title: "t")
            do {
                _ = try await CUPSClient(runner: runner).submit(request)
                XCTFail("Expected rejection for printer id \(hostile.debugDescription)")
            } catch let error as CUPSCommandError {
                guard case .printerNotFound = error else {
                    return XCTFail("Unexpected error for \(hostile.debugDescription): \(error)")
                }
            }
        }
        XCTAssertTrue(runner.invocations.isEmpty, "No lp invocation may happen for a rejected id")
    }

    func testSecureTempCreatesDirectoriesWith0700AtCreation() throws {
        let directory = try SecureTemp.makeDirectory(prefix: "SecTest")
        defer { try? FileManager.default.removeItem(at: directory) }

        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        let permissions = attributes[.posixPermissions] as? Int ?? 0
        XCTAssertEqual(permissions & 0o777, 0o700)

        let parent = directory.deletingLastPathComponent()
        let parentAttributes = try FileManager.default.attributesOfItem(atPath: parent.path)
        let parentPermissions = parentAttributes[.posixPermissions] as? Int ?? 0
        XCTAssertEqual(parentPermissions & 0o777, 0o700)
    }

    func testSecureTempWritesFilesWith0600AtCreation() throws {
        let directory = try SecureTemp.makeDirectory(prefix: "SecWrite")
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("out.pdf")
        try SecureTemp.write(Data("pdf".utf8), to: url)

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = attributes[.posixPermissions] as? Int ?? 0
        XCTAssertEqual(permissions & 0o777, 0o600)
        XCTAssertEqual(try Data(contentsOf: url), Data("pdf".utf8))
    }
}
