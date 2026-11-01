import Foundation
import XCTest
@testable import FlipStackCore

/// Ranking and selection behavior of `PrintPresetResolver` on synthetic PPDs:
/// mixed numeric dpi lists with an "Auto" label choice, pure semantic tier
/// labels, photo-specific filtering, photo media selection, color-option
/// independence, `matchingPreset` round-trips, and case-insensitive keyword
/// replacement in `setOption`.
final class PrintPresetEngineRankingTests: XCTestCase {
    private let parser = PPDParser()

    // MARK: - Mixed numeric dpi list plus an "Auto" label choice

    /// 180/300/366/600/1200 dpi plus an "Auto" choice. The "Auto" choice has
    /// no number, so it is ranked at the midpoint of the numeric range
    /// ((180 + 1200) / 2 = 690) and carries semantic tier 1.
    private static let mixedDpiPPD = """
    *PPD-Adobe: "4.3"
    *OpenUI *Resolution/Resolution: PickOne
    *DefaultResolution: 600dpi
    *Resolution 180dpi/180 dpi: ""
    *Resolution 300dpi/300 dpi: ""
    *Resolution 366dpi/366 dpi: ""
    *Resolution 600dpi/600 dpi: ""
    *Resolution 1200dpi/1200 dpi: ""
    *Resolution Auto/Auto: ""
    *CloseUI: *Resolution
    *OpenUI *MediaType/Media Type: PickOne
    *DefaultMediaType: PLAIN
    *MediaType PLAIN/Plain Paper: ""
    *MediaType PHOTO/Photo Paper: ""
    *CloseUI: *MediaType
    *OpenUI *ColorModel/Color Model: PickOne
    *DefaultColorModel: Color
    *ColorModel Color/Color: ""
    *ColorModel Gray/Grayscale: ""
    *CloseUI: *ColorModel
    *End
    """

    func testMixedDpiListPinsExactPresetSelection() {
        let resolver = PrintPresetResolver(ppd: parser.parse(contents: Self.mixedDpiPPD))
        XCTAssertEqual(resolver.availablePresets, PrintQualityPreset.allCases)

        // Eco: first choice at or above 300 dpi.
        XCTAssertEqual(resolver.apply(.eco, to: [:]).options["Resolution"], "300dpi")
        // Standard: first semantic tier-1 choice — the "Auto" label choice.
        XCTAssertEqual(resolver.apply(.standard, to: [:]).options["Resolution"], "Auto")
        // High: highest non-photo-specific numeric choice.
        XCTAssertEqual(resolver.apply(.high, to: [:]).options["Resolution"], "1200dpi")
        // Photo: no photo-specific quality choice exists, so the highest overall.
        XCTAssertEqual(resolver.apply(.photo, to: [:]).options["Resolution"], "1200dpi")

        for preset in PrintQualityPreset.allCases {
            XCTAssertTrue(resolver.apply(preset, to: [:]).isComplete, "\(preset)")
        }
    }

    func testPureNumericDpiListPinsExactPresetSelection() {
        let contents = """
        *PPD-Adobe: "4.3"
        *OpenUI *Resolution/Resolution: PickOne
        *Resolution 180dpi/180 dpi: ""
        *Resolution 300dpi/300 dpi: ""
        *Resolution 366dpi/366 dpi: ""
        *Resolution 600dpi/600 dpi: ""
        *Resolution 1200dpi/1200 dpi: ""
        *CloseUI: *Resolution
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

        XCTAssertEqual(resolver.apply(.eco, to: [:]).options["Resolution"], "300dpi")
        // No semantic tier-1 choice: Standard falls back to the median rank,
        // which is 366 dpi in a five-choice list.
        XCTAssertEqual(resolver.apply(.standard, to: [:]).options["Resolution"], "366dpi")
        XCTAssertEqual(resolver.apply(.high, to: [:]).options["Resolution"], "1200dpi")
        XCTAssertEqual(resolver.apply(.photo, to: [:]).options["Resolution"], "1200dpi")
    }

    // MARK: - Semantic tiers (Draft/Normal/High/Best)

    private static let semanticTierPPD = """
    *PPD-Adobe: "4.3"
    *OpenUI *PrintQuality/Print Quality: PickOne
    *DefaultPrintQuality: Normal
    *PrintQuality Draft/Draft: ""
    *PrintQuality Normal/Normal: ""
    *PrintQuality High/High: ""
    *PrintQuality Best/Best: ""
    *PrintQuality Photo/Photo: ""
    *CloseUI: *PrintQuality
    *OpenUI *MediaType/Media Type: PickOne
    *MediaType PLAIN/Plain Paper: ""
    *CloseUI: *MediaType
    *OpenUI *ColorModel/Color Model: PickOne
    *ColorModel Color/Color: ""
    *CloseUI: *ColorModel
    *End
    """

    func testSemanticTierLabelsPinExactPresetSelection() {
        let resolver = PrintPresetResolver(ppd: parser.parse(contents: Self.semanticTierPPD))

        XCTAssertEqual(resolver.apply(.eco, to: [:]).options["PrintQuality"], "Draft")
        XCTAssertEqual(resolver.apply(.standard, to: [:]).options["PrintQuality"], "Normal")
        // High excludes photo-specific choices, so "Best" wins over "Photo".
        XCTAssertEqual(resolver.apply(.high, to: [:]).options["PrintQuality"], "Best")
        XCTAssertEqual(resolver.apply(.photo, to: [:]).options["PrintQuality"], "Photo")
    }

    // MARK: - Photo-specific filtering

    func testHighSkipsPhotoSpecificDpiChoiceButPhotoSelectsIt() {
        let contents = """
        *PPD-Adobe: "4.3"
        *OpenUI *Resolution/Resolution: PickOne
        *Resolution 600dpi/600 dpi: ""
        *Resolution 1200dpi/1200 dpi: ""
        *Resolution 2880dpi/Photo: ""
        *CloseUI: *Resolution
        *OpenUI *MediaType/Media Type: PickOne
        *MediaType PLAIN/Plain Paper: ""
        *MediaType PHOTO/Photo Paper: ""
        *CloseUI: *MediaType
        *OpenUI *ColorModel/Color Model: PickOne
        *ColorModel Color/Color: ""
        *CloseUI: *ColorModel
        *End
        """
        let resolver = PrintPresetResolver(ppd: parser.parse(contents: contents))

        XCTAssertEqual(resolver.apply(.eco, to: [:]).options["Resolution"], "600dpi")
        XCTAssertEqual(resolver.apply(.standard, to: [:]).options["Resolution"], "1200dpi")
        // 2880 dpi is photo-specific: High must not take it.
        XCTAssertEqual(resolver.apply(.high, to: [:]).options["Resolution"], "1200dpi")
        // Photo takes the photo-specific choice.
        XCTAssertEqual(resolver.apply(.photo, to: [:]).options["Resolution"], "2880dpi")
    }

    // MARK: - Media selection for the photo preset

    func testPhotoPresetSelectsGlossyPhotoMediaWhenAvailable() {
        let contents = """
        *PPD-Adobe: "4.3"
        *OpenUI *Resolution/Resolution: PickOne
        *Resolution 600dpi/600 dpi: ""
        *Resolution 1200dpi/1200 dpi: ""
        *CloseUI: *Resolution
        *OpenUI *MediaType/Media Type: PickOne
        *MediaType PLAIN/Plain Paper: ""
        *MediaType MATTE/Matte Photo Paper: ""
        *MediaType GLOSSY/Glossy Photo Paper: ""
        *CloseUI: *MediaType
        *OpenUI *ColorModel/Color Model: PickOne
        *ColorModel Color/Color: ""
        *CloseUI: *ColorModel
        *End
        """
        let resolver = PrintPresetResolver(ppd: parser.parse(contents: contents))

        XCTAssertEqual(resolver.apply(.photo, to: [:]).options["MediaType"], "GLOSSY")
        XCTAssertEqual(resolver.apply(.eco, to: [:]).options["MediaType"], "PLAIN")
        XCTAssertEqual(resolver.apply(.standard, to: [:]).options["MediaType"], "PLAIN")
        XCTAssertEqual(resolver.apply(.high, to: [:]).options["MediaType"], "PLAIN")
    }

    func testPhotoPresetFallsBackToPlainPhotoWhenNoGlossyExists() {
        let resolver = PrintPresetResolver(ppd: parser.parse(contents: Self.mixedDpiPPD))
        XCTAssertEqual(resolver.apply(.photo, to: [:]).options["MediaType"], "PHOTO")
    }

    // MARK: - Color option independence

    func testEveryPresetAppliesTheColorChoiceAndMatchingIgnoresColor() {
        let resolver = PrintPresetResolver(ppd: parser.parse(contents: Self.mixedDpiPPD))

        // The color option is controlled uniformly: every preset selects the
        // best color choice, regardless of the preset.
        for preset in PrintQualityPreset.allCases {
            XCTAssertEqual(
                resolver.apply(preset, to: [:]).options["ColorModel"],
                "Color",
                "\(preset) changed color handling"
            )
        }

        // Color mode is not a quality dimension: swapping it must not change
        // which preset the options match.
        for preset in PrintQualityPreset.allCases {
            var options = resolver.apply(preset, to: [:]).options
            options["ColorModel"] = "Gray"
            XCTAssertEqual(resolver.matchingPreset(for: options), preset)
        }
    }

    // MARK: - matchingPreset round-trips

    func testMatchingPresetRoundTripsEveryPresetOnMixedDpiPPD() {
        let resolver = PrintPresetResolver(ppd: parser.parse(contents: Self.mixedDpiPPD))
        let base = ["PageSize": "A4", "Duplex": "None"]

        for preset in PrintQualityPreset.allCases {
            let application = resolver.apply(preset, to: base)
            XCTAssertEqual(
                resolver.matchingPreset(for: application.options),
                preset,
                "\(preset) did not round-trip"
            )
        }

        // Unrelated options are ignored by the match.
        var withUnrelated = resolver.apply(.photo, to: base).options
        withUnrelated["InputSlot"] = "Manual"
        withUnrelated["PageSize"] = "Legal"
        XCTAssertEqual(resolver.matchingPreset(for: withUnrelated), .photo)

        // A custom resolution matches nothing.
        var custom = resolver.apply(.standard, to: base).options
        custom["Resolution"] = "366dpi"
        XCTAssertNil(resolver.matchingPreset(for: custom))

        XCTAssertNil(resolver.matchingPreset(for: [:]))
    }

    // MARK: - setOption case-insensitive keyword replacement

    func testSetOptionReplacesAllCaseVariantsOfControlledKeywords() {
        let resolver = PrintPresetResolver(ppd: parser.parse(contents: Self.mixedDpiPPD))
        let base: [String: String] = [
            "RESOLUTION": "1200dpi",
            "resolution": "600dpi",
            "ReSoLuTiOn": "180dpi",
            "mediaTYPE": "PHOTO",
            "PageSize": "A4"
        ]

        let application = resolver.apply(.eco, to: base)

        XCTAssertEqual(application.options["Resolution"], "300dpi")
        XCTAssertEqual(
            application.options.keys.filter {
                $0.caseInsensitiveCompare("Resolution") == .orderedSame
            }.count,
            1,
            "case variants of Resolution must collapse into one key"
        )
        XCTAssertEqual(application.options["MediaType"], "PLAIN")
        XCTAssertEqual(
            application.options.keys.filter {
                $0.caseInsensitiveCompare("MediaType") == .orderedSame
            }.count,
            1,
            "case variants of MediaType must collapse into one key"
        )
        // Uncontrolled options are preserved untouched.
        XCTAssertEqual(application.options["PageSize"], "A4")
        XCTAssertEqual(application.options.count, 4)
    }
}
