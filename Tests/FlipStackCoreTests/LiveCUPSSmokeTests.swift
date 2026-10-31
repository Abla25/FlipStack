import XCTest
@testable import FlipStackCore

/// Read-only checks against the CUPS installation on the current Mac.
/// These are skipped in CI and never submit a print job.
///
///     FLIPSTACK_LIVE_CUPS=1 swift test --filter LiveCUPSSmoke
final class LiveCUPSSmokeTests: XCTestCase {
    private var enabled: Bool {
        ProcessInfo.processInfo.environment["FLIPSTACK_LIVE_CUPS"] == "1"
    }

    func testLiveQueuesAndPPD() async throws {
        try XCTSkipUnless(enabled, "Set FLIPSTACK_LIVE_CUPS=1 to inspect the local CUPS installation.")

        let client = CUPSClient()
        let printers = try await client.listPrinters()
        XCTAssertFalse(printers.isEmpty, "Expected at least one local CUPS queue.")
        for printer in printers {
            print("QUEUE \(printer.id) state=\(printer.state.rawValue) default=\(printer.isDefault) ppd=\(printer.ppdPath ?? "-") uri=\(printer.deviceURI ?? "-")")
        }

        guard let l1800 = printers.first(where: { $0.id.localizedCaseInsensitiveContains("L1800") }) else {
            throw XCTSkip("No Epson L1800 queue on this Mac.")
        }

        let loader = PPDLoader()
        let url = loader.locatePPD(for: l1800)
        print("L1800 PPD path: \(url?.path ?? "not found")")
        XCTAssertNotNil(url, "Expected to locate the L1800 PPD.")
        guard let url else { return }

        let ppd = try loader.parsePPD(at: url)
        print("PPD nickname: \(ppd.nickname ?? "-") model: \(ppd.makeAndModel ?? "-") options: \(ppd.options.map(\.keyword).joined(separator: ", "))")
        let color = ppd.option(in: .color)
        let paper = ppd.option(in: .paperSize)
        XCTAssertNotNil(color, "Expected a real ColorModel option in the L1800 PPD.")
        XCTAssertNotNil(paper, "Expected a real PageSize option in the L1800 PPD.")
        XCTAssertFalse(ppd.supportsHardwareDuplex, "The L1800 is a simplex printer.")

        let resolver = PrintPresetResolver(ppd: ppd)
        print("Available presets: \(resolver.availablePresets.map(\.rawValue))")
        for preset in resolver.availablePresets {
            let application = resolver.apply(preset, to: [:])
            print("Preset \(preset.rawValue): complete=\(application.isComplete) options=\(application.options) labels=\(application.appliedLabels)")
        }

        let status = await IPPStatusClient().status(for: l1800)
        print("L1800 status: state=\(status.state.rawValue) origin=\(status.origin.rawValue) reasons=\(status.stateReasons) supplies=\(status.supplies.map { "\($0.name):\($0.levelPercent.map(String.init) ?? "?")" }) note=\(status.note ?? "-")")
        XCTAssertEqual(status.printerID, l1800.id)

        let devices = try await CUPSDeviceDiscovery().discoverDevices()
        print("Discovered devices: \(devices.map { "\($0.transport.rawValue):\($0.name)" })")
        for discovered in devices {
            XCTAssertFalse(discovered.uri.isEmpty)
            XCTAssertFalse(discovered.name.isEmpty)
        }
    }
}
