import Foundation
import XCTest
@testable import FlipStackCore

private final class DiscoveryStubRunner: CUPSCommandRunning, @unchecked Sendable {
    enum Outcome {
        case result(CUPSCommandResult)
        case processError(CUPSProcessError)
        case cancelled
    }

    struct Invocation {
        var executable: URL
        var arguments: [String]
        var timeout: TimeInterval
    }

    private let outcome: Outcome
    private(set) var invocations: [Invocation] = []

    init(_ outcome: Outcome) {
        self.outcome = outcome
    }

    func run(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> CUPSCommandResult {
        invocations.append(Invocation(
            executable: executable,
            arguments: arguments,
            timeout: timeout
        ))
        switch outcome {
        case .result(let result):
            return result
        case .processError(let error):
            throw error
        case .cancelled:
            throw CancellationError()
        }
    }
}

final class CUPSDeviceDiscoveryTests: XCTestCase {
    // MARK: - Parsing

    func testParsesDNSSDWithUUIDQueryAndDecodesName() {
        let uri = "dnssd://Epson%20L1800._ipp._tcp.local./?uuid=9f4c2e8a-1b2c-4d5e-8f90-123456789abc"
        let devices = CUPSDeviceDiscovery.parseDevices(from: "network \(uri)")

        XCTAssertEqual(devices.count, 1)
        let device = try? XCTUnwrap(devices.first)
        XCTAssertEqual(device?.name, "Epson L1800")
        XCTAssertEqual(device?.model, "Epson L1800")
        XCTAssertEqual(device?.uri, uri)
        XCTAssertEqual(device?.transport, .wifi)
        XCTAssertEqual(device?.id, uri)
    }

    func testParsesIPPSAndIPPQueueNames() {
        let ippsURI = "ipps://printer.local/ipp/print"
        let ippURI = "ipp://192.168.1.50/printers/Office%20LaserJet"
        let devices = CUPSDeviceDiscovery.parseDevices(from: """
        network \(ippsURI)
        network \(ippURI)
        """)

        XCTAssertEqual(devices.count, 2)

        let ipps = devices.first { $0.uri == ippsURI }
        XCTAssertEqual(ipps?.name, "printer.local")
        XCTAssertEqual(ipps?.transport, .network)

        let ipp = devices.first { $0.uri == ippURI }
        XCTAssertEqual(ipp?.name, "Office LaserJet")
        XCTAssertEqual(ipp?.transport, .network)
    }

    func testParsesUSBWithSpacesAndSerial() {
        let uri = "usb://EPSON/L1800%20Series?serial=ABC123"
        let devices = CUPSDeviceDiscovery.parseDevices(from: "direct \(uri)")

        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices.first?.name, "EPSON L1800 Series")
        XCTAssertEqual(devices.first?.model, "L1800 Series")
        XCTAssertEqual(devices.first?.transport, .usb)
        XCTAssertEqual(devices.first?.uri, uri)
        XCTAssertFalse(devices.first?.name.contains("serial") ?? true)
    }

    func testParsesSocketLPDAndHPBackends() {
        let socketURI = "socket://192.168.1.60:9100"
        let lpdURI = "lpd://print-server.local/queue"
        let hpURI = "hp:/usb/HP_OfficeJet_Pro_8720?serial=XYZ"
        let devices = CUPSDeviceDiscovery.parseDevices(from: """
        network \(socketURI)
        network \(lpdURI)
        direct \(hpURI)
        """)

        let socket = devices.first { $0.uri == socketURI }
        XCTAssertEqual(socket?.name, "192.168.1.60")
        XCTAssertEqual(socket?.transport, .network)

        let lpd = devices.first { $0.uri == lpdURI }
        XCTAssertEqual(lpd?.name, "queue")
        XCTAssertEqual(lpd?.transport, .network)

        let hp = devices.first { $0.uri == hpURI }
        XCTAssertEqual(hp?.name, "HP OfficeJet Pro 8720")
        XCTAssertEqual(hp?.model, "HP OfficeJet Pro 8720")
        XCTAssertEqual(hp?.transport, .usb)
    }

    func testParsesIPv6IPPHost() {
        let uri = "ipp://[fe80::1]:631/ipp/print"
        let devices = CUPSDeviceDiscovery.parseDevices(from: "network \(uri)")
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices.first?.name, "fe80::1")
        XCTAssertEqual(devices.first?.transport, .network)
    }

    func testIPPURIWithBonjourServiceTypeIsWifi() {
        let uri = "ipps://Epson%20L1800._ipps._tcp.local./ipp/print"
        let devices = CUPSDeviceDiscovery.parseDevices(from: "network \(uri)")
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices.first?.name, "Epson L1800")
        XCTAssertEqual(devices.first?.transport, .wifi)
    }

    func testDeduplicatesAndSortsByTransportThenName() {
        let devices = CUPSDeviceDiscovery.parseDevices(from: """
        network socket://zebra.local:9100
        network dnssd://Zebra%20Label._ipp._tcp.local./?uuid=1
        network ipp://alpha.local/ipp/print
        direct usb://Brother/HL-L2350DW%20series?serial=2
        network dnssd://Alpha%20Printer._ipp._tcp.local./?uuid=3
        direct usb://Canon/MG5300%20series?serial=4
        network socket://zebra.local:9100
        """)

        XCTAssertEqual(devices.map(\.name), [
            "Brother HL-L2350DW series",
            "Canon MG5300 series",
            "Alpha Printer",
            "Zebra Label",
            "alpha.local",
            "zebra.local"
        ])
        XCTAssertEqual(devices.filter { $0.transport == .network }.count, 2)
        XCTAssertEqual(devices.filter { $0.transport == .usb }.count, 2)
        XCTAssertEqual(devices.filter { $0.transport == .wifi }.count, 2)
    }

    func testIgnoresPseudoDevicesAndUnsupportedBackends() {
        let output = """
        network cups-brf:/printers
        direct file:/dev/null
        direct scsi:/dev/scsi0
        serial serial:/dev/tty0
        network beh
        network smb://server/share
        garbage
        network ipp://
        direct usb://
        network socket://
        network lpd:///queue
        network ipp://host:notaport/ipp/print
        """

        XCTAssertTrue(CUPSDeviceDiscovery.parseDevices(from: output).isEmpty)
    }

    func testIgnoresMalformedLinesButKeepsValidOnes() {
        let validURI = "socket://192.168.1.9:9100"
        let output = """
        direct
        network
        network ipp:///printers/queue
        network ipp://host:abc/ipp/print
        network socket://
        direct usb://Vendor/Product%ZZ?serial=1
        network dnssd://
        network \(validURI)
        """

        let devices = CUPSDeviceDiscovery.parseDevices(from: output)
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices.first?.uri, validURI)
        XCTAssertEqual(devices.first?.transport, .network)
    }

    func testEmptyAndWhitespaceOutputProduceNoDevices() {
        XCTAssertTrue(CUPSDeviceDiscovery.parseDevices(from: "").isEmpty)
        XCTAssertTrue(CUPSDeviceDiscovery.parseDevices(from: " \n\t\r\n ").isEmpty)
    }

    func testIgnoredErrorLinesDoNotBecomePrinters() {
        let output = """
        lpinfo: Bad file descriptor
        warning: something happened
        debug: backend list
        network socket://192.168.1.9:9100
        """
        let devices = CUPSDeviceDiscovery.parseDevices(from: output)
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices.first?.name, "192.168.1.9")
    }

    // MARK: - Discovery command

    func testDiscoveryRunsLpinfoDirectlyWithTimeout() async throws {
        let uri = "usb://EPSON/L1800%20Series?serial=1"
        let runner = DiscoveryStubRunner(.result(CUPSCommandResult(
            status: 0,
            stdout: "direct \(uri)\n"
        )))
        let discovery = CUPSDeviceDiscovery(runner: runner, timeout: 8)

        let devices = try await discovery.discoverDevices()

        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices.first?.uri, uri)
        XCTAssertEqual(runner.invocations.count, 1)
        XCTAssertEqual(runner.invocations.first?.executable.path, "/usr/sbin/lpinfo")
        XCTAssertEqual(runner.invocations.first?.arguments, ["-v"])
        XCTAssertEqual(runner.invocations.first?.timeout, 8)
    }

    func testCommandFailureBecomesDescriptiveDiscoveryError() async {
        let runner = DiscoveryStubRunner(.result(CUPSCommandResult(
            status: 1,
            stdout: "",
            stderr: "lpinfo: forbidden"
        )))
        let discovery = CUPSDeviceDiscovery(runner: runner, timeout: 2)

        do {
            _ = try await discovery.discoverDevices()
            XCTFail("Expected discovery to throw")
        } catch let error as PrinterDiscoveryError {
            XCTAssertEqual(error, .commandFailed(status: 1, message: "lpinfo: forbidden"))
            XCTAssertFalse(error.localizedDescription.isEmpty)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testMissingToolIsReported() async {
        let runner = DiscoveryStubRunner(.processError(
            .executableNotFound("/usr/sbin/lpinfo")
        ))
        let discovery = CUPSDeviceDiscovery(runner: runner, timeout: 2)

        do {
            _ = try await discovery.discoverDevices()
            XCTFail("Expected discovery to throw")
        } catch let error as PrinterDiscoveryError {
            XCTAssertEqual(error, .toolNotFound("/usr/sbin/lpinfo"))
            XCTAssertFalse(error.localizedDescription.isEmpty)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testTimeoutIsReported() async {
        let runner = DiscoveryStubRunner(.processError(.timedOut("lpinfo")))
        let discovery = CUPSDeviceDiscovery(runner: runner, timeout: 2)

        do {
            _ = try await discovery.discoverDevices()
            XCTFail("Expected discovery to throw")
        } catch let error as PrinterDiscoveryError {
            XCTAssertEqual(error, .timedOut("lpinfo"))
            XCTAssertFalse(error.localizedDescription.isEmpty)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testLaunchFailureMapsToCommandFailure() async {
        let runner = DiscoveryStubRunner(.processError(.launchFailed("permission denied")))
        let discovery = CUPSDeviceDiscovery(runner: runner, timeout: 2)

        do {
            _ = try await discovery.discoverDevices()
            XCTFail("Expected discovery to throw")
        } catch let error as PrinterDiscoveryError {
            XCTAssertEqual(error, .commandFailed(status: -1, message: "permission denied"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCancellationIsNotSwallowed() async {
        let runner = DiscoveryStubRunner(.cancelled)
        let discovery = CUPSDeviceDiscovery(runner: runner, timeout: 2)

        do {
            _ = try await discovery.discoverDevices()
            XCTFail("Expected discovery to throw")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testEmptySuccessfulCommandReturnsEmptyList() async throws {
        let runner = DiscoveryStubRunner(.result(CUPSCommandResult(status: 0, stdout: "")))
        let discovery = CUPSDeviceDiscovery(runner: runner, timeout: 2)
        let devices = try await discovery.discoverDevices()
        XCTAssertTrue(devices.isEmpty)
    }
}
