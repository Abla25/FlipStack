import Foundation
import XCTest
@testable import FlipStackCore

final class PPDParserTests: XCTestCase {
    private let parser = PPDParser()

    func testEpsonFixtureParsesRealOptionsOnly() throws {
        let url = CUPSFixtureLocator.ppdURL("Epson-L1800.ppd")
        let document = try parser.parse(url: url)

        XCTAssertEqual(document.nickname, "EPSON L1800 Series")
        XCTAssertEqual(document.manufacturer, "Epson")
        XCTAssertEqual(document.makeAndModel, "Epson L1800 Series")
        XCTAssertEqual(document.sourcePath, url.path)
        XCTAssertFalse(document.supportsHardwareDuplex)
        XCTAssertNil(document.duplexOption)

        XCTAssertEqual(document.options.map(\.keyword), [
            "PageSize", "PageRegion", "ColorModel", "MediaType", "InputSlot",
            "Resolution", "PrintQuality", "InkSet"
        ])
        XCTAssertFalse(document.options.contains { $0.keyword == "Duplex" })
        XCTAssertEqual(document.option(keyword: "PageRegion")?.group, .paperSize)
        XCTAssertEqual(document.option(keyword: "PageRegion")?.choices.map(\.keyword), ["A4", "A5", "Letter", "Legal"])

        let pageSize = try XCTUnwrap(document.paperSizeOption)
        XCTAssertEqual(pageSize.group, .paperSize)
        XCTAssertEqual(pageSize.label, "Page Size")
        XCTAssertEqual(pageSize.choices.map(\.keyword), ["A4", "A5", "Letter", "Legal"])
        XCTAssertEqual(pageSize.defaultChoice, "A4")
        XCTAssertEqual(pageSize.selectedDefault, "A4")

        let color = try XCTUnwrap(document.colorOption)
        XCTAssertEqual(color.group, .color)
        XCTAssertEqual(color.choices.map(\.keyword), ["Color", "Grayscale"])
        XCTAssertEqual(color.defaultChoice, "Color")

        let media = try XCTUnwrap(document.mediaTypeOption)
        XCTAssertEqual(media.group, .mediaType)
        XCTAssertEqual(media.choices.map(\.keyword), ["PLAIN", "PHOTO"])
        XCTAssertEqual(media.defaultChoice, "PLAIN")

        let quality = try XCTUnwrap(document.qualityOption)
        XCTAssertEqual(quality.group, .quality)
        XCTAssertEqual(quality.choices.map(\.keyword), ["360dpi", "720dpi", "1440dpi", "2880dpi"])
        XCTAssertEqual(quality.defaultChoice, "1440dpi")

        XCTAssertEqual(document.option(keyword: "InputSlot")?.group, .mediaType)
        XCTAssertEqual(document.option(keyword: "InkSet")?.group, .other)
        XCTAssertEqual(document.option(keyword: "InkSet")?.defaultChoice, "CMYK")
    }

    func testBrotherFixtureParsesHardwareDuplex() throws {
        let document = try parser.parse(url: CUPSFixtureLocator.ppdURL("Brother-HL-L2350DW.ppd"))
        XCTAssertEqual(document.manufacturer, "Brother")
        XCTAssertEqual(document.makeAndModel, "Brother HL-L2350DW series")
        XCTAssertTrue(document.supportsHardwareDuplex)

        let duplex = try XCTUnwrap(document.duplexOption)
        XCTAssertEqual(duplex.keyword, "Duplex")
        XCTAssertEqual(duplex.group, .duplex)
        XCTAssertEqual(duplex.choices.map(\.keyword), ["None", "DuplexNoTumble", "DuplexTumble"])
        XCTAssertEqual(duplex.defaultChoice, "None")
        XCTAssertEqual(document.option(keyword: "PageSize")?.defaultChoice, "A4")
    }

    func testQuotedEscapedCommentsTabsAndDuplicateGroups() {
        let contents = """
        *PPD-Adobe: "4.3"
        *% A comment that looks like *OpenUI *Bogus/Bogus: PickOne
        *Manufacturer: "Acme"
        *ModelName: "Acme 100"
        *MakeModel: "Acme 100 Deluxe"
        *NickName: "Acme \\"100\\""
        *OpenUI *ColorModel/Color\\: Model: PickOne
        *DefaultColorModel: gray
        *ColorModel Color/Color: "<</cupsColorSpace 19>>setpagedevice"
        \t*colormodel gray/Grayscale: "<</cupsColorSpace 18>>setpagedevice"
        *ColorModel Color/Duplicate: "ignored"
        *CloseUI: *ColorModel
        *OpenUI *PageSize/"Paper Size": PickOne
        *DefaultPageSize: A4
        *PageSize A4/A4: ""
        *PageSize A5: ""
        *CloseUI: *PageSize
        *OpenUI *PageSize/Page Size: PickOne
        *PageSize Legal/Legal: ""
        *CloseUI: *PageSize
        *OpenUI *Empty/Empty: PickOne
        *CloseUI: *Empty
        *OpenUI *Duplex/2-Sided: PickOne
        *DefaultDuplex: None
        *Duplex None/Off: ""
        *CloseUI: *Duplex
        *End
        """

        let document = parser.parse(contents: contents, sourcePath: "/tmp/inline.ppd")
        XCTAssertEqual(document.nickname, "Acme \"100\"")
        XCTAssertEqual(document.manufacturer, "Acme")
        XCTAssertEqual(document.makeAndModel, "Acme 100 Deluxe")
        XCTAssertEqual(document.sourcePath, "/tmp/inline.ppd")
        XCTAssertFalse(document.supportsHardwareDuplex)

        XCTAssertEqual(document.options.map(\.keyword), ["ColorModel", "PageSize", "Duplex"])
        XCTAssertFalse(document.options.contains { $0.keyword == "Empty" })

        let color = document.option(keyword: "ColorModel")
        XCTAssertEqual(color?.label, "Color: Model")
        XCTAssertEqual(color?.choices.map(\.keyword), ["Color", "gray"])
        XCTAssertEqual(color?.choices.first?.label, "Color")
        XCTAssertEqual(color?.defaultChoice, "gray")

        let pageSize = document.option(keyword: "PageSize")
        XCTAssertEqual(pageSize?.label, "Paper Size")
        XCTAssertEqual(pageSize?.choices.map(\.keyword), ["A4", "A5", "Legal"])
        XCTAssertEqual(pageSize?.choices.first(where: { $0.keyword == "A5" })?.label, "A5")
        XCTAssertEqual(pageSize?.defaultChoice, "A4")

        let duplicate = document.option(keyword: "PageSize")?.choices.filter { $0.keyword == "Legal" }
        XCTAssertEqual(duplicate?.count, 1)
    }

    func testCupsSpecificOptionsAreMarkedPseudo() {
        let contents = """
        *OpenUI *cupsColorModel/Color Model: PickOne
        *cupsColorModel RGB/Color: ""
        *CloseUI: *cupsColorModel
        *OpenUI *cupsPrintQuality/Quality: PickOne
        *cupsPrintQuality Normal/Normal: ""
        *CloseUI: *cupsPrintQuality
        *OpenUI *PageSize/Paper Size: PickOne
        *PageSize A4/A4: ""
        *CloseUI: *PageSize
        """
        let document = parser.parse(contents: contents)
        XCTAssertEqual(document.option(keyword: "cupsColorModel")?.isPseudoOption, true)
        XCTAssertEqual(document.option(keyword: "cupsPrintQuality")?.isPseudoOption, true)
        XCTAssertEqual(document.option(keyword: "PageSize")?.isPseudoOption, false)
        XCTAssertEqual(document.option(keyword: "cupsColorModel")?.group, .color)
        XCTAssertEqual(document.option(keyword: "cupsPrintQuality")?.group, .quality)
    }

    func testInvalidDefaultChoiceIsNotReported() {
        let contents = """
        *OpenUI *PageSize/Paper Size: PickOne
        *DefaultPageSize: B5
        *PageSize A4/A4: ""
        *CloseUI: *PageSize
        """
        let document = parser.parse(contents: contents)
        XCTAssertEqual(document.options.count, 1)
        XCTAssertNil(document.options[0].defaultChoice)
        XCTAssertEqual(document.options[0].selectedDefault, "A4")
    }

    func testGroupMappingIsCaseInsensitive() {
        let contents = """
        *OpenUI *colormodel/Color: PickOne
        *ColorModel Color/Color: ""
        *CloseUI: *colormodel
        *OpenUI *MEDIASIZE/Size: PickOne
        *MediaSize A4/A4: ""
        *CloseUI: *MEDIASIZE
        *OpenUI *cupsPrintQuality/Quality: PickOne
        *cupsPrintQuality Normal/Normal: ""
        *CloseUI: *cupsPrintQuality
        """
        let document = parser.parse(contents: contents)
        XCTAssertEqual(document.option(keyword: "colormodel")?.group, .color)
        XCTAssertEqual(document.option(keyword: "MEDIASIZE")?.group, .paperSize)
        XCTAssertEqual(document.option(keyword: "cupsPrintQuality")?.group, .quality)
    }

    func testGzipRoundTripFromDataAndURL() throws {
        let data = try CUPSFixtureLocator.ppdData("Epson-L1800.ppd")
        let gzipped = try CUPSTestGzip.compress(data)
        XCTAssertEqual(Array(gzipped.prefix(2)), [0x1f, 0x8b])

        let fromData = try parser.parse(data: gzipped, sourcePath: "/tmp/from-data.ppd.gz")
        XCTAssertEqual(fromData.nickname, "EPSON L1800 Series")
        XCTAssertEqual(fromData.options.map(\.keyword), [
            "PageSize", "PageRegion", "ColorModel", "MediaType", "InputSlot",
            "Resolution", "PrintQuality", "InkSet"
        ])
        XCTAssertEqual(fromData.sourcePath, "/tmp/from-data.ppd.gz")

        let directory = try CUPSTestTemporaryDirectory(prefix: "FlipStackPPDGzip")
        let url = try directory.write(gzipped, name: "Epson-L1800.ppd.gz")
        let fromURL = try parser.parse(url: url)
        XCTAssertEqual(fromURL.sourcePath, url.path)
        XCTAssertEqual(fromURL.options.map(\.keyword), fromData.options.map(\.keyword))
    }

    func testCorruptGzipThrowsClearError() throws {
        let directory = try CUPSTestTemporaryDirectory(prefix: "FlipStackPPDBadGzip")
        let url = try directory.write(Data([0x1f, 0x8b, 0x00, 0x00, 0x00]), name: "bad.ppd.gz")

        do {
            _ = try parser.parse(url: url)
            XCTFail("Expected decompressionFailed")
        } catch let error as PPDError {
            guard case .decompressionFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testEmptyAndMissingMetadataAreNotFabricated() {
        let document = parser.parse(contents: "*PPD-Adobe: \"4.3\"\n*End\n")
        XCTAssertNil(document.nickname)
        XCTAssertNil(document.manufacturer)
        XCTAssertNil(document.makeAndModel)
        XCTAssertTrue(document.options.isEmpty)
        XCTAssertFalse(document.supportsHardwareDuplex)
        XCTAssertTrue(document.isEmpty)
    }

    func testPaperDimensionsAndImageableAreasAreParsed() throws {
        let epson = try parser.parse(url: CUPSFixtureLocator.ppdURL("Epson-L1800.ppd"))
        XCTAssertEqual(epson.paperDimensions["a4"], CGSize(width: 595.28, height: 841.89))
        XCTAssertEqual(epson.paperDimensions["letter"], CGSize(width: 612, height: 792))
        XCTAssertEqual(epson.paperSize(for: "A4"), CGSize(width: 595.28, height: 841.89))
        XCTAssertEqual(epson.imageableArea(for: "A4"), CGRect(x: 0, y: 0, width: 595.28, height: 841.89))

        let brother = try parser.parse(url: CUPSFixtureLocator.ppdURL("Brother-HL-L2350DW.ppd"))
        XCTAssertEqual(brother.paperSize(for: "Letter"), CGSize(width: 612, height: 792))
        XCTAssertNotNil(brother.imageableArea(for: "legal"))
    }

    func testPaperSizeFallsBackToCatalogWhenPPDHasNoDimension() {
        let document = parser.parse(contents: """
        *PPD-Adobe: "4.3"
        *OpenUI *PageSize/Paper: PickOne
        *DefaultPageSize: na-letter
        *PageSize na-letter/US Letter: ""
        *CloseUI: *PageSize
        *End
        """)
        XCTAssertEqual(document.paperSize(for: "na-letter"), CGSize(width: 612, height: 792))
        XCTAssertNil(document.paperSize(for: "custom-unknown"))
    }

    func testInlinePaperDimensionAndImageableAreaParsing() {
        let document = parser.parse(contents: """
        *PPD-Adobe: "4.3"
        *PaperDimension A4: "595.28 841.89"
        *PaperDimension 4x6: "288 432"
        *ImageableArea A4: "18 12 577.28 829.89"
        *PaperDimension Broken: "not numbers"
        *ImageableArea Broken: "1 2 3"
        *End
        """)
        XCTAssertEqual(document.paperDimensions["a4"], CGSize(width: 595.28, height: 841.89))
        XCTAssertEqual(document.paperSize(for: "4x6"), CGSize(width: 288, height: 432))
        XCTAssertEqual(
            document.imageableArea(for: "A4"),
            CGRect(x: 18, y: 12, width: 559.28, height: 817.89)
        )
        XCTAssertNil(document.paperDimensions["broken"])
        XCTAssertNil(document.imageableAreas["broken"])
    }
}
