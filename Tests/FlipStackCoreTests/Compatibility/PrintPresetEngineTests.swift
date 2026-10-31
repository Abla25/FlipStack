import Foundation
import XCTest
@testable import FlipStackCore

private enum CompatibilityPresetFixtures {
    static var ppdDirectory: URL {
        if let fixtures = Bundle.module.url(forResource: "Fixtures", withExtension: nil) {
            let candidate = fixtures.appendingPathComponent("PPDs", isDirectory: true)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        let testRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return testRoot.appendingPathComponent("Fixtures/PPDs", isDirectory: true)
    }

    static func document(_ name: String) throws -> PPDDocument {
        try PPDParser().parse(url: ppdDirectory.appendingPathComponent(name))
    }
}

final class PrintPresetEngineTests: XCTestCase {
    private let parser = PPDParser()

    // MARK: - Epson fixture

    func testEpsonPresetsResolveToRealPPDChoices() throws {
        let ppd = try CompatibilityPresetFixtures.document("Epson-L1800.ppd")
        let resolver = PrintPresetResolver(ppd: ppd)

        XCTAssertEqual(resolver.availablePresets, PrintQualityPreset.allCases)

        let eco = resolver.apply(.eco, to: [:])
        XCTAssertEqual(eco.options["Resolution"], "360dpi")
        XCTAssertEqual(eco.options["PrintQuality"], "Normal")
        XCTAssertEqual(eco.options["MediaType"], "PLAIN")
        XCTAssertEqual(eco.options["ColorModel"], "Color")
        XCTAssertEqual(eco.options.count, 4)
        XCTAssertTrue(eco.isComplete)
        XCTAssertEqual(eco.appliedLabels, ["360 dpi", "Normal quality", "Plain Paper", "Color"])

        let standard = resolver.apply(.standard, to: [:])
        XCTAssertEqual(standard.options["Resolution"], "720dpi")
        XCTAssertEqual(standard.options["PrintQuality"], "Normal")
        XCTAssertEqual(standard.options["MediaType"], "PLAIN")
        XCTAssertEqual(standard.options["ColorModel"], "Color")
        XCTAssertTrue(standard.isComplete)

        let high = resolver.apply(.high, to: [:])
        XCTAssertEqual(high.options["Resolution"], "2880dpi")
        XCTAssertEqual(high.options["PrintQuality"], "High")
        XCTAssertEqual(high.options["MediaType"], "PLAIN")
        XCTAssertEqual(high.options["ColorModel"], "Color")
        XCTAssertTrue(high.isComplete)

        let photo = resolver.apply(.photo, to: [:])
        XCTAssertEqual(photo.options["Resolution"], "2880dpi")
        XCTAssertEqual(photo.options["PrintQuality"], "High")
        XCTAssertEqual(photo.options["MediaType"], "PHOTO")
        XCTAssertEqual(photo.options["ColorModel"], "Color")
        XCTAssertTrue(photo.isComplete)
        XCTAssertTrue(photo.appliedLabels.contains("Photo Paper"))
    }

    func testEpsonPresetsPreserveUnrelatedBaseOptions() throws {
        let ppd = try CompatibilityPresetFixtures.document("Epson-L1800.ppd")
        let resolver = PrintPresetResolver(ppd: ppd)
        let base = [
            "PageSize": "A5",
            "Duplex": "None",
            "InputSlot": "Manual",
            "MediaType": "PHOTO",
            "cupsFoo": "bar"
        ]

        let application = resolver.apply(.standard, to: base)

        XCTAssertEqual(application.options["PageSize"], "A5")
        XCTAssertEqual(application.options["Duplex"], "None")
        XCTAssertEqual(application.options["InputSlot"], "Manual")
        XCTAssertEqual(application.options["cupsFoo"], "bar")
        XCTAssertEqual(application.options["MediaType"], "PLAIN")
        XCTAssertEqual(application.options["Resolution"], "720dpi")
    }

    func testControlledBaseKeysAreReplacedCaseInsensitively() throws {
        let ppd = try CompatibilityPresetFixtures.document("Epson-L1800.ppd")
        let resolver = PrintPresetResolver(ppd: ppd)
        let base = [
            "resolution": "360dpi",
            "mediaTYPE": "PHOTO",
            "PageSize": "A5"
        ]

        let application = resolver.apply(.high, to: base)

        XCTAssertEqual(application.options["Resolution"], "2880dpi")
        XCTAssertNil(application.options["resolution"])
        XCTAssertEqual(application.options["MediaType"], "PLAIN")
        XCTAssertNil(application.options["mediaTYPE"])
        XCTAssertEqual(application.options["PageSize"], "A5")
    }

    // MARK: - Brother fixture

    func testBrotherFixtureUsesOnlyAdvertisedChoices() throws {
        let ppd = try CompatibilityPresetFixtures.document("Brother-HL-L2350DW.ppd")
        let resolver = PrintPresetResolver(ppd: ppd)

        XCTAssertEqual(resolver.availablePresets, PrintQualityPreset.allCases)

        let eco = resolver.apply(.eco, to: [:])
        XCTAssertEqual(eco.options["Resolution"], "600dpi")
        XCTAssertEqual(eco.options["PrintQuality"], "Normal")
        XCTAssertEqual(eco.options["MediaType"], "PLAIN")
        XCTAssertEqual(eco.options["ColorModel"], "Gray")
        XCTAssertTrue(eco.isComplete)

        let standard = resolver.apply(.standard, to: [:])
        XCTAssertEqual(standard.options["Resolution"], "600dpi")
        XCTAssertEqual(standard.options["PrintQuality"], "Normal")
        XCTAssertTrue(standard.isComplete)

        let high = resolver.apply(.high, to: [:])
        XCTAssertEqual(high.options["Resolution"], "1200dpi")
        XCTAssertEqual(high.options["PrintQuality"], "High")
        XCTAssertEqual(high.options["MediaType"], "PLAIN")
        XCTAssertTrue(high.isComplete)

        // This monochrome laser has no photo media. Photo still selects the
        // highest real quality choices, leaves the media to the base/system,
        // and reports that it is incomplete.
        let photo = resolver.apply(.photo, to: [:])
        XCTAssertEqual(photo.options["Resolution"], "1200dpi")
        XCTAssertEqual(photo.options["PrintQuality"], "High")
        XCTAssertEqual(photo.options["ColorModel"], "Gray")
        XCTAssertNil(photo.options["MediaType"])
        XCTAssertFalse(photo.isComplete)
        XCTAssertFalse(photo.appliedLabels.contains("Plain Paper"))
    }

    // MARK: - Synthetic PPD

    func testSyntheticPPDMapsEveryPreset() throws {
        let resolver = PrintPresetResolver(ppd: parser.parse(contents: Self.syntheticPPD))

        let eco = resolver.apply(.eco, to: [:])
        XCTAssertEqual(eco.options["Resolution"], "600dpi")
        XCTAssertEqual(eco.options["PrintQuality"], "Draft")
        XCTAssertEqual(eco.options["MediaType"], "Plain")
        XCTAssertEqual(eco.options["ColorModel"], "Color")
        XCTAssertNil(eco.options["ColorProfile"])
        XCTAssertTrue(eco.isComplete)

        let standard = resolver.apply(.standard, to: [:])
        XCTAssertEqual(standard.options["Resolution"], "1200dpi")
        XCTAssertEqual(standard.options["PrintQuality"], "Normal")
        XCTAssertEqual(standard.options["MediaType"], "Plain")
        XCTAssertTrue(standard.isComplete)

        let high = resolver.apply(.high, to: [:])
        XCTAssertEqual(high.options["Resolution"], "2400dpi")
        XCTAssertEqual(high.options["PrintQuality"], "Best")
        XCTAssertEqual(high.options["MediaType"], "Plain")
        XCTAssertTrue(high.isComplete)

        let photo = resolver.apply(.photo, to: [:])
        XCTAssertEqual(photo.options["Resolution"], "4800dpi")
        XCTAssertEqual(photo.options["PrintQuality"], "Photo")
        XCTAssertEqual(photo.options["MediaType"], "Glossy")
        XCTAssertEqual(photo.options["ColorModel"], "Color")
        XCTAssertEqual(photo.options["ColorProfile"], "ProPhoto")
        XCTAssertTrue(photo.isComplete)
        XCTAssertTrue(photo.appliedLabels.contains("ProPhoto RGB profile"))
    }

    func testPhotoPresetPrefersGlossyPhotoMedia() {
        let resolver = PrintPresetResolver(ppd: parser.parse(contents: Self.syntheticPPD))
        let photo = resolver.apply(.photo, to: [:])
        XCTAssertEqual(photo.options["MediaType"], "Glossy")
    }

    func testColorProfileIsOptionalAndOnlyChangedByPhoto() {
        let resolver = PrintPresetResolver(ppd: parser.parse(contents: Self.syntheticPPD))
        let base = ["PageSize": "A4", "ColorProfile": "sRGB"]

        let eco = resolver.apply(.eco, to: base)
        XCTAssertEqual(eco.options["ColorProfile"], "sRGB")

        let standard = resolver.apply(.standard, to: base)
        XCTAssertEqual(standard.options["ColorProfile"], "sRGB")

        let high = resolver.apply(.high, to: base)
        XCTAssertEqual(high.options["ColorProfile"], "sRGB")

        let photo = resolver.apply(.photo, to: base)
        XCTAssertEqual(photo.options["ColorProfile"], "ProPhoto")
    }

    func testQualityLabelsContainingQualityWordRankCorrectly() {
        let contents = """
        *PPD-Adobe: "4.3"
        *OpenUI *Resolution/Resolution: PickOne
        *Resolution 600dpi/Basic: ""
        *Resolution 1200dpi/Standard: ""
        *Resolution 2400dpi/Fine: ""
        *Resolution 4800dpi/Photo: ""
        *CloseUI: *Resolution
        *OpenUI *PrintQuality/Print Quality: PickOne
        *PrintQuality Draft/Draft Quality: ""
        *PrintQuality Normal/Normal Quality: ""
        *PrintQuality High/High Quality: ""
        *PrintQuality Best/Best Quality: ""
        *PrintQuality Photo/Photo Quality: ""
        *CloseUI: *PrintQuality
        *OpenUI *MediaType/Media Type: PickOne
        *MediaType PLAIN/Plain Paper: ""
        *MediaType PHOTO/Photo Paper: ""
        *CloseUI: *MediaType
        *OpenUI *ColorModel/Color Model: PickOne
        *ColorModel Color/Color: ""
        *ColorModel Gray/Grayscale: ""
        *CloseUI: *ColorModel
        *End
        """

        let resolver = PrintPresetResolver(ppd: parser.parse(contents: contents))
        XCTAssertEqual(resolver.apply(.eco, to: [:]).options["PrintQuality"], "Draft")
        XCTAssertEqual(resolver.apply(.standard, to: [:]).options["PrintQuality"], "Normal")
        XCTAssertEqual(resolver.apply(.high, to: [:]).options["PrintQuality"], "Best")
        XCTAssertEqual(resolver.apply(.photo, to: [:]).options["PrintQuality"], "Photo")
    }

    // MARK: - Contract guarantees

    func testEveryAppliedValueIsARealPPDChoice() throws {
        let documents: [(PPDDocument, [String: String])] = [
            (try CompatibilityPresetFixtures.document("Epson-L1800.ppd"),
             ["PageSize": "A4", "Duplex": "None", "InputSlot": "Auto"]),
            (try CompatibilityPresetFixtures.document("Brother-HL-L2350DW.ppd"),
             ["PageSize": "Letter", "Duplex": "None", "InputSlot": "Tray1"]),
            (parser.parse(contents: Self.syntheticPPD),
             ["PageSize": "A4", "MediaType": "Matte", "ColorProfile": "sRGB"])
        ]

        for (ppd, base) in documents {
            let resolver = PrintPresetResolver(ppd: ppd)
            for preset in resolver.availablePresets {
                let application = resolver.apply(preset, to: base)
                let allowedKeywords = Set(ppd.options.map(\.keyword)).union(base.keys)

                for (keyword, value) in application.options {
                    XCTAssertTrue(
                        allowedKeywords.contains(keyword),
                        "\(preset.rawValue) invented keyword \(keyword)"
                    )

                    if let option = ppd.option(keyword: keyword) {
                        XCTAssertTrue(
                            option.choices.contains { $0.keyword == value },
                            "\(preset.rawValue) invented value \(value) for \(keyword)"
                        )
                    } else {
                        XCTAssertEqual(value, base[keyword], "Unrelated base value changed")
                    }
                }
            }
        }
    }

    func testMatchingPresetFindsUniquePresetsAndRejectsCustom() throws {
        let ppd = try CompatibilityPresetFixtures.document("Epson-L1800.ppd")
        let resolver = PrintPresetResolver(ppd: ppd)

        XCTAssertEqual(resolver.matchingPreset(for: resolver.apply(.eco, to: [:]).options), .eco)
        XCTAssertEqual(resolver.matchingPreset(for: resolver.apply(.standard, to: [:]).options), .standard)
        XCTAssertEqual(resolver.matchingPreset(for: resolver.apply(.high, to: [:]).options), .high)
        XCTAssertEqual(resolver.matchingPreset(for: resolver.apply(.photo, to: [:]).options), .photo)

        var custom = resolver.apply(.standard, to: [:]).options
        custom["Resolution"] = "1440dpi"
        XCTAssertNil(resolver.matchingPreset(for: custom))

        var withUnrelated = resolver.apply(.standard, to: [:]).options
        withUnrelated["PageSize"] = "Legal"
        withUnrelated["InputSlot"] = "Manual"
        XCTAssertEqual(resolver.matchingPreset(for: withUnrelated), .standard)

        XCTAssertNil(resolver.matchingPreset(for: [:]))
    }

    func testMatchingPresetIsCaseInsensitive() throws {
        let ppd = try CompatibilityPresetFixtures.document("Epson-L1800.ppd")
        let resolver = PrintPresetResolver(ppd: ppd)
        let application = resolver.apply(.standard, to: [:])

        let lowercased = Dictionary(uniqueKeysWithValues: application.options.map {
            ($0.key.lowercased(), $0.value.lowercased())
        })
        XCTAssertEqual(resolver.matchingPreset(for: lowercased), .standard)
    }

    func testBrotherMatchingIsNilWhenEcoAndStandardAreIdentical() throws {
        let ppd = try CompatibilityPresetFixtures.document("Brother-HL-L2350DW.ppd")
        let resolver = PrintPresetResolver(ppd: ppd)

        XCTAssertEqual(resolver.apply(.eco, to: [:]).options, resolver.apply(.standard, to: [:]).options)
        XCTAssertNil(resolver.matchingPreset(for: resolver.apply(.standard, to: [:]).options))
        XCTAssertEqual(resolver.matchingPreset(for: resolver.apply(.high, to: [:]).options), .high)
        XCTAssertEqual(resolver.matchingPreset(for: resolver.apply(.photo, to: [:]).options), .photo)
    }

    func testEmptyPPDHasNoPresetsAndIsIncomplete() {
        let ppd = parser.parse(contents: "# Empty PPD\n*PPD-Adobe: \"4.3\"\n*End\n")
        let resolver = PrintPresetResolver(ppd: ppd)

        XCTAssertTrue(resolver.availablePresets.isEmpty)
        XCTAssertNil(resolver.matchingPreset(for: [:]))

        let application = resolver.apply(.photo, to: ["PageSize": "A4"])
        XCTAssertEqual(application.options, ["PageSize": "A4"])
        XCTAssertTrue(application.appliedLabels.isEmpty)
        XCTAssertFalse(application.isComplete)
    }

    func testPPDWithOnlyPaperSizeHasNoQualityPresets() {
        let contents = """
        *PPD-Adobe: "4.3"
        *OpenUI *PageSize/Page Size: PickOne
        *DefaultPageSize: A4
        *PageSize A4/A4: ""
        *CloseUI: *PageSize
        *End
        """
        let resolver = PrintPresetResolver(ppd: parser.parse(contents: contents))
        XCTAssertTrue(resolver.availablePresets.isEmpty)
    }

    func testPPDWithoutMediaReportsIncomplete() {
        let contents = """
        *PPD-Adobe: "4.3"
        *OpenUI *Resolution/Resolution: PickOne
        *DefaultResolution: 300dpi
        *Resolution 300dpi/300 dpi: ""
        *Resolution 600dpi/600 dpi: ""
        *CloseUI: *Resolution
        *End
        """
        let resolver = PrintPresetResolver(ppd: parser.parse(contents: contents))
        let application = resolver.apply(.standard, to: [:])

        XCTAssertEqual(application.options["Resolution"], "300dpi")
        XCTAssertFalse(application.isComplete)
        XCTAssertEqual(application.appliedLabels, ["300 dpi"])
    }

    func testResolutionAlsoRequiresAPlainMediaChoiceForEcoAndStandard() {
        let contents = """
        *PPD-Adobe: "4.3"
        *OpenUI *Resolution/Resolution: PickOne
        *Resolution 600dpi/600 dpi: ""
        *Resolution 1200dpi/1200 dpi: ""
        *CloseUI: *Resolution
        *OpenUI *MediaType/Media Type: PickOne
        *MediaType PHOTO/Photo Paper: ""
        *MediaType GLOSSY/Glossy Photo Paper: ""
        *CloseUI: *MediaType
        *End
        """
        let resolver = PrintPresetResolver(ppd: parser.parse(contents: contents))

        let eco = resolver.apply(.eco, to: [:])
        XCTAssertNil(eco.options["MediaType"])
        XCTAssertFalse(eco.isComplete)

        let high = resolver.apply(.high, to: [:])
        XCTAssertEqual(high.options["MediaType"], "GLOSSY")
        XCTAssertTrue(high.isComplete)

        let photo = resolver.apply(.photo, to: [:])
        XCTAssertEqual(photo.options["MediaType"], "GLOSSY")
        XCTAssertTrue(photo.isComplete)
    }

    func testInputSlotIsUsedAsMediaFallbackWhenItActuallyDescribesMedia() {
        let mediaInSlot = """
        *PPD-Adobe: "4.3"
        *OpenUI *Resolution/Resolution: PickOne
        *Resolution 600dpi/600 dpi: ""
        *Resolution 1200dpi/1200 dpi: ""
        *CloseUI: *Resolution
        *OpenUI *InputSlot/Paper Source: PickOne
        *InputSlot PLAIN/Plain Paper: ""
        *InputSlot PHOTO/Photo Paper: ""
        *CloseUI: *InputSlot
        *End
        """
        let resolver = PrintPresetResolver(ppd: parser.parse(contents: mediaInSlot))
        XCTAssertEqual(resolver.apply(.eco, to: [:]).options["InputSlot"], "PLAIN")
        XCTAssertEqual(resolver.apply(.photo, to: [:]).options["InputSlot"], "PHOTO")

        let trayOnly = """
        *PPD-Adobe: "4.3"
        *OpenUI *Resolution/Resolution: PickOne
        *Resolution 600dpi/600 dpi: ""
        *CloseUI: *Resolution
        *OpenUI *InputSlot/Paper Source: PickOne
        *InputSlot Auto/Automatic: ""
        *InputSlot Manual/Manual Feed: ""
        *CloseUI: *InputSlot
        *End
        """
        let trayResolver = PrintPresetResolver(ppd: parser.parse(contents: trayOnly))
        let application = trayResolver.apply(.eco, to: [:])
        XCTAssertNil(application.options["InputSlot"])
        XCTAssertFalse(application.isComplete)
    }

    func testRepeatedApplicationsAreDeterministic() throws {
        let ppd = try CompatibilityPresetFixtures.document("Epson-L1800.ppd")
        let resolver = PrintPresetResolver(ppd: ppd)
        let second = PrintPresetResolver(ppd: ppd)
        let base = ["PageSize": "A4", "Duplex": "None"]

        for preset in PrintQualityPreset.allCases {
            let firstApplication = resolver.apply(preset, to: base)
            XCTAssertEqual(firstApplication, resolver.apply(preset, to: base))
            XCTAssertEqual(firstApplication, second.apply(preset, to: base))
            XCTAssertEqual(firstApplication.options, second.apply(preset, to: base).options)
            XCTAssertEqual(
                resolver.matchingPreset(for: firstApplication.options),
                second.matchingPreset(for: firstApplication.options)
            )
        }
    }

    // MARK: - Synthetic PPD

    private static let syntheticPPD = """
    *PPD-Adobe: "4.3"
    *FormatVersion: "4.3"
    *LanguageVersion: English
    *Manufacturer: "Acme"
    *ModelName: "Acme Photo 900"
    *NickName: "Acme Photo 900"

    *OpenUI *PageSize/Page Size: PickOne
    *DefaultPageSize: A4
    *PageSize A4/A4: ""
    *PageSize Letter/Letter: ""
    *CloseUI: *PageSize

    *OpenUI *Resolution/Resolution: PickOne
    *DefaultResolution: 1200dpi
    *Resolution 600dpi/Draft: ""
    *Resolution 1200dpi/Normal: ""
    *Resolution 2400dpi/High: ""
    *Resolution 4800dpi/Photo: ""
    *CloseUI: *Resolution

    *OpenUI *PrintQuality/Print Quality: PickOne
    *DefaultPrintQuality: Normal
    *PrintQuality Draft/Draft: ""
    *PrintQuality Normal/Normal: ""
    *PrintQuality High/High: ""
    *PrintQuality Best/Best: ""
    *PrintQuality Photo/Photo: ""
    *CloseUI: *PrintQuality

    *OpenUI *MediaType/Media Type: PickOne
    *DefaultMediaType: Plain
    *MediaType Plain/Plain Paper: ""
    *MediaType Photo/Photo Paper: ""
    *MediaType Glossy/Glossy Photo Paper: ""
    *MediaType Matte/Matte Paper: ""
    *CloseUI: *MediaType

    *OpenUI *ColorModel/Color Model: PickOne
    *DefaultColorModel: Color
    *ColorModel Color/Color: ""
    *ColorModel Gray/Grayscale: ""
    *CloseUI: *ColorModel

    *OpenUI *ColorProfile/Color Profile: PickOne
    *DefaultColorProfile: sRGB
    *ColorProfile sRGB/sRGB: ""
    *ColorProfile AdobeRGB/Adobe RGB: ""
    *ColorProfile ProPhoto/ProPhoto RGB: ""
    *CloseUI: *ColorProfile

    *End
    """
}
