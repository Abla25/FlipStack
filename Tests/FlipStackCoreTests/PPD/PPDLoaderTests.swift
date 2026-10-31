import Foundation
import XCTest
@testable import FlipStackCore

final class PPDLoaderTests: XCTestCase {
    func testSearchPicksMatchingPPDInsteadOfFirstFile() throws {
        let directory = try CUPSTestTemporaryDirectory(prefix: "FlipStackPPDSearch")
        let brother = try directory.copyFixture("Brother-HL-L2350DW.ppd")
        let epson = try directory.copyFixture("Epson-L1800.ppd")

        // Brother sorts before Epson, so a blind first-file lookup would fail.
        XCTAssertLessThan(brother.lastPathComponent, epson.lastPathComponent)

        let loader = PPDLoader(searchDirectories: [directory.url])
        let epsonPrinter = Printer(
            id: "Test_Epson_L1800",
            name: "Epson L1800 Test",
            model: "Epson L1800 Series"
        )
        XCTAssertEqual(
            loader.locatePPD(for: epsonPrinter)?.resolvingSymlinksInPath(),
            epson.resolvingSymlinksInPath()
        )

        let brotherPrinter = Printer(
            id: "Test_Brother_HL_L2350DW",
            name: "Brother HL-L2350DW Test",
            model: "Brother HL-L2350DW series"
        )
        XCTAssertEqual(
            loader.locatePPD(for: brotherPrinter)?.resolvingSymlinksInPath(),
            brother.resolvingSymlinksInPath()
        )
    }

    func testSearchDoesNotBlindlyPickAnUnrelatedPPD() throws {
        let directory = try CUPSTestTemporaryDirectory(prefix: "FlipStackPPDUnrelated")
        try directory.copyFixture("Brother-HL-L2350DW.ppd")
        try directory.write(Data("*PPD-Adobe: \"4.3\"\n*End\n".utf8), name: "Canon-PIXMA.ppd")

        let loader = PPDLoader(searchDirectories: [directory.url])
        let printer = Printer(
            id: "Test_Epson_L1800",
            name: "Epson L1800 Test",
            model: "Epson L1800 Series"
        )
        XCTAssertNil(loader.locatePPD(for: printer))
    }

    func testSearchRejectsASiblingModelWithADifferentNumber() throws {
        let directory = try CUPSTestTemporaryDirectory(prefix: "FlipStackPPDSibling")
        let sibling = """
        *PPD-Adobe: "4.3"
        *Manufacturer: "Brother"
        *ModelName: "Brother HL-L2300DW series"
        *NickName: "Brother HL-L2300DW series"
        *End
        """
        try directory.write(Data(sibling.utf8), name: "Brother-HL-L2300DW.ppd")

        let loader = PPDLoader(searchDirectories: [directory.url])
        let printer = Printer(
            id: "Test_Brother_HL_L2350DW",
            name: "Brother HL-L2350DW Test",
            model: "Brother HL-L2350DW series"
        )
        XCTAssertNil(loader.locatePPD(for: printer))
    }

    func testSearchMatchesPPDMetadataWhenFilenameIsGeneric() throws {
        let directory = try CUPSTestTemporaryDirectory(prefix: "FlipStackPPDMetadata")
        let contents = """
        *PPD-Adobe: "4.3"
        *Manufacturer: "Epson"
        *ModelName: "Epson L1800 Series"
        *NickName: "Epson L1800 Series"
        *End
        """
        let url = try directory.write(Data(contents.utf8), name: "vendor-driver.ppd")

        let loader = PPDLoader(searchDirectories: [directory.url])
        let printer = Printer(
            id: "Test_Epson_L1800",
            name: "Epson L1800 Test",
            model: "Epson L1800 Series"
        )
        XCTAssertEqual(
            loader.locatePPD(for: printer)?.resolvingSymlinksInPath(),
            url.resolvingSymlinksInPath()
        )
    }

    func testAmbiguousMetadataMatchesReturnNil() throws {
        let directory = try CUPSTestTemporaryDirectory(prefix: "FlipStackPPDAmbiguous")
        let contents = """
        *PPD-Adobe: "4.3"
        *Manufacturer: "Epson"
        *ModelName: "Epson L1800 Series"
        *NickName: "Epson L1800 Series"
        *End
        """
        try directory.write(Data(contents.utf8), name: "vendor-a.ppd")
        try directory.write(Data(contents.utf8), name: "vendor-b.ppd")

        let loader = PPDLoader(searchDirectories: [directory.url])
        let printer = Printer(
            id: "Test_Epson_L1800",
            name: "Epson L1800 Test",
            model: "Epson L1800 Series"
        )
        XCTAssertNil(loader.locatePPD(for: printer))
    }

    func testExactNicknameIsPreferredOverAFilenameMatch() throws {
        let directory = try CUPSTestTemporaryDirectory(prefix: "FlipStackPPDNickname")
        let filenameMatch = """
        *PPD-Adobe: "4.3"
        *Manufacturer: "Epson"
        *ModelName: "Epson L1800"
        *NickName: "Office Queue"
        *End
        """
        let nicknameMatch = """
        *PPD-Adobe: "4.3"
        *Manufacturer: "Epson"
        *ModelName: "Epson L1800"
        *NickName: "Epson L1800 Series"
        *End
        """
        try directory.write(Data(filenameMatch.utf8), name: "Test_Epson_L1800.ppd")
        let preferred = try directory.write(Data(nicknameMatch.utf8), name: "driver-x.ppd")

        let loader = PPDLoader(searchDirectories: [directory.url])
        let printer = Printer(
            id: "Test_Epson_L1800_Queue",
            name: "Epson L1800 Test",
            model: "Epson L1800 Series"
        )
        XCTAssertEqual(
            loader.locatePPD(for: printer)?.resolvingSymlinksInPath(),
            preferred.resolvingSymlinksInPath()
        )
    }

    func testConfiguredPPDPathWinsOverSearchDirectory() throws {
        let directory = try CUPSTestTemporaryDirectory(prefix: "FlipStackPPDPath")
        let custom = try directory.copyFixture("Epson-L1800.ppd", as: "Custom-Queue.ppd")
        let searchDirectory = try CUPSTestTemporaryDirectory(prefix: "FlipStackPPDPathSearch")
        try searchDirectory.copyFixture("Brother-HL-L2350DW.ppd")

        let loader = PPDLoader(searchDirectories: [searchDirectory.url])
        let printer = Printer(
            id: "Custom_Queue",
            name: "Custom Queue",
            model: "Epson L1800 Series",
            ppdPath: custom.path
        )
        XCTAssertEqual(
            loader.locatePPD(for: printer)?.resolvingSymlinksInPath(),
            custom.resolvingSymlinksInPath()
        )
    }

    func testParsePPDReturnsSourcePathAndCaches() throws {
        let directory = try CUPSTestTemporaryDirectory(prefix: "FlipStackPPDParse")
        let url = try directory.copyFixture("Epson-L1800.ppd")
        let loader = PPDLoader(searchDirectories: [directory.url])

        let first = try loader.parsePPD(at: url)
        let second = try loader.parsePPD(at: url)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.sourcePath, url.path)
        XCTAssertEqual(first.nickname, "EPSON L1800 Series")
    }

    func testGzippedPPDCanBeLocatedAndParsed() throws {
        let directory = try CUPSTestTemporaryDirectory(prefix: "FlipStackPPDGzipSearch")
        let data = try CUPSFixtureLocator.ppdData("Epson-L1800.ppd")
        let gzipped = try CUPSTestGzip.compress(data)
        let url = try directory.write(gzipped, name: "Epson-L1800.ppd.gz")

        let loader = PPDLoader(searchDirectories: [directory.url])
        let printer = Printer(
            id: "Test_Epson_L1800",
            name: "Epson L1800 Test",
            model: "Epson L1800 Series"
        )
        XCTAssertEqual(
            loader.locatePPD(for: printer)?.resolvingSymlinksInPath(),
            url.resolvingSymlinksInPath()
        )

        let document = try loader.parsePPD(at: url)
        XCTAssertEqual(document.nickname, "EPSON L1800 Series")
        XCTAssertEqual(
            document.sourcePath.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() },
            url.resolvingSymlinksInPath()
        )
        XCTAssertFalse(document.supportsHardwareDuplex)
    }

    func testSymlinkedPPDFileIsHandled() throws {
        let directory = try CUPSTestTemporaryDirectory(prefix: "FlipStackPPDSymlink")
        let fixture = CUPSFixtureLocator.ppdURL("Epson-L1800.ppd")
        let link = directory.url.appendingPathComponent("Test_Epson_L1800.ppd")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture)

        let loader = PPDLoader(searchDirectories: [directory.url])
        let printer = Printer(
            id: "Test_Epson_L1800",
            name: "Epson L1800 Test",
            model: "Epson L1800 Series"
        )
        XCTAssertEqual(
            loader.locatePPD(for: printer)?.resolvingSymlinksInPath(),
            link.resolvingSymlinksInPath()
        )
        XCTAssertEqual(try loader.parsePPD(at: link).nickname, "EPSON L1800 Series")
    }

    func testMissingSearchDirectoryIsHarmless() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("FlipStack-missing-\(UUID().uuidString)", isDirectory: true)
        let loader = PPDLoader(searchDirectories: [missing])
        let printer = Printer(id: "Test_Queue", name: "Test Queue", model: "Epson L1800")
        XCTAssertNil(loader.locatePPD(for: printer))
    }

    func testQueueNameExactMatchWorksWhenModelIsMissing() throws {
        let directory = try CUPSTestTemporaryDirectory(prefix: "FlipStackPPDQueue")
        let url = try directory.copyFixture("Epson-L1800.ppd", as: "Test_Queue_Exact.ppd")
        let loader = PPDLoader(searchDirectories: [directory.url])
        let printer = Printer(id: "Test_Queue_Exact", name: "Test Queue Exact")
        XCTAssertEqual(
            loader.locatePPD(for: printer)?.resolvingSymlinksInPath(),
            url.resolvingSymlinksInPath()
        )
    }
}
