import XCTest
@testable import FlipStackCore

/// Guards on `CUPSOptionBuilder`: fit-to-page and scaling are always both
/// emitted, and reserved request-owned keys can never leak in from
/// `driverOptions` — including with weird casing, underscores, or padding.
final class CUPSOptionBuilderScalingGuardTests: XCTestCase {
    private let fileURL = URL(fileURLWithPath: "/tmp/FlipStack Guard Test.pdf")

    private func request(
        fitToPage: Bool = false,
        scalePercent: Int = 100,
        driverOptions: [String: String] = [:]
    ) -> PrintRequest {
        PrintRequest(
            fileURL: fileURL,
            printerID: "EPSON_L1800_Series",
            title: "FlipStack Guard",
            pageSet: .all,
            pageRanges: [],
            copies: 1,
            numberUp: 1,
            orientation: .portrait,
            driverOptions: driverOptions,
            fitToPage: fitToPage,
            scalePercent: scalePercent
        )
    }

    private func pairs(_ request: PrintRequest) -> [(String, String)] {
        CUPSOptionBuilder.optionPairs(for: request)
    }

    private func pairStrings(_ request: PrintRequest) -> [String] {
        pairs(request).map { "\($0.0)=\($0.1)" }
    }

    // MARK: - fit-to-page and scaling are always both present

    func testFitToPageAndScalingAreBothPresentForEveryRequest() {
        // fitToPage on and off, with several scale percentages (including
        // values that the request itself clamps to 50/150).
        for fitToPage in [false, true] {
            for scalePercent in [50, 75, 100, 150, 10, 999] {
                let request = request(fitToPage: fitToPage, scalePercent: scalePercent)
                let emitted = pairs(request)

                let fitPairs = emitted.filter { $0.0 == "fit-to-page" }
                let scalingPairs = emitted.filter { $0.0 == "scaling" }
                XCTAssertEqual(fitPairs.count, 1, "fit-to-page missing for \(fitToPage)/\(scalePercent)")
                XCTAssertEqual(scalingPairs.count, 1, "scaling missing for \(fitToPage)/\(scalePercent)")
                XCTAssertEqual(fitPairs.first?.1, fitToPage ? "true" : "false")

                let expectedScaling: String
                if fitToPage {
                    // Fit wins: scaling is pinned to 100 so the two keys can
                    // never double-scale the job.
                    expectedScaling = "100"
                } else {
                    expectedScaling = String(min(max(scalePercent, 50), 150))
                }
                XCTAssertEqual(scalingPairs.first?.1, expectedScaling)

                // Both keys appear in every full argument list too.
                let arguments = CUPSOptionBuilder.arguments(for: request).joined(separator: " ")
                XCTAssertTrue(arguments.contains("fit-to-page=\(fitToPage ? "true" : "false")"))
                XCTAssertTrue(arguments.contains("scaling=\(expectedScaling)"))
            }
        }
    }

    func testFitToPageForcesScaling100EvenWhenScalePercentDiffers() {
        let request = request(fitToPage: true, scalePercent: 75)
        XCTAssertEqual(pairStrings(request), [
            "page-set=all",
            "number-up=1",
            "orientation-requested=3",
            "fit-to-page=true",
            "scaling=100"
        ])
    }

    func testScalingIsClampedToBoundsWhenFitIsOff() {
        XCTAssertEqual(
            pairs(request(fitToPage: false, scalePercent: 10)).first { $0.0 == "scaling" }?.1,
            "50"
        )
        XCTAssertEqual(
            pairs(request(fitToPage: false, scalePercent: 500)).first { $0.0 == "scaling" }?.1,
            "150"
        )
    }

    // MARK: - Reserved keys never pass through

    func testReservedKeysNeverPassThroughWithWeirdCasingUnderscoresAndPadding() {
        let driverOptions: [String: String] = [
            "PAGE_SET": "even",
            "page_set": "odd",
            "Page-Set": "EVIL",
            "page-ranges": "9-1",
            "Page_Ranges": "8-2",
            "PAGE-RANGES": "EVIL",
            "NUMBER-UP": "4",
            "number_up": "6",
            "Number_Up": "EVIL",
            "Orientation_Requested": "5",
            "ORIENTATION-REQUESTED": "EVIL",
            "OUTPUT-ORDER": "reverse",
            "output_order": "reverse",
            "OutputOrder": "EVIL",
            "Page_Order": "EVIL",
            "REVERSE_ORDER": "EVIL",
            "Reverse": "true",
            "page-reversal": "EVIL",
            "SCALING": "10",
            "Natural_Scaling": "50",
            "FIT_TO_PAGE": "true",
            "fit-to-page": "EVIL",
            "  scaling  ": "25",
            "PageSize": "A4"
        ]
        let request = request(driverOptions: driverOptions)

        XCTAssertEqual(pairStrings(request), [
            "page-set=all",
            "number-up=1",
            "orientation-requested=3",
            "fit-to-page=false",
            "scaling=100",
            "PageSize=A4"
        ])

        let arguments = CUPSOptionBuilder.arguments(for: request).joined(separator: " ")
        XCTAssertFalse(arguments.contains("EVIL"))
        XCTAssertFalse(arguments.contains("reverse"))
        XCTAssertFalse(arguments.contains("page_set"))
    }

    func testReservedKeysAreSuppressedEvenWhenFitToPageIsOn() {
        let request = request(
            fitToPage: true,
            driverOptions: [
                "scaling": "10",
                "SCALING": "EVIL",
                "fit_to_page": "false",
                "Fit-To-Page": "EVIL",
                "output-order": "reverse",
                "PageSize": "Letter"
            ]
        )
        XCTAssertEqual(pairStrings(request), [
            "page-set=all",
            "number-up=1",
            "orientation-requested=3",
            "fit-to-page=true",
            "scaling=100",
            "PageSize=Letter"
        ])
        XCTAssertFalse(CUPSOptionBuilder.arguments(for: request).joined().contains("EVIL"))
    }

    func testNoEmittedDriverOptionKeyNormalizesToAReservedKey() {
        let reserved: Set<String> = [
            "page-set", "pageset", "page-ranges", "pageranges",
            "number-up", "numberup", "orientation-requested", "orientationrequested",
            "output-order", "outputorder", "page-order", "pageorder",
            "reverse-order", "reverseorder", "page-reversal", "pagereversal", "reverse",
            "scaling", "natural-scaling", "fit-to-page"
        ]
        let driverOptions = (0..<50).map { index in
            ("K\(index)", "v\(index)")
        }.reduce(into: [String: String]()) { $0[$1.0] = $1.1 }
        .merging([
            "Page_Set": "x", "PAGERANGES": "x", "NumberUp": "x",
            "orientationrequested": "x", "OutputOrder": "x", "REVERSE": "x",
            "Scaling": "x", "natural_scaling": "x", "Fit-To-Page": "x"
        ]) { current, _ in current }

        for fitToPage in [false, true] {
            let emitted = pairs(request(fitToPage: fitToPage, driverOptions: driverOptions))
            for (key, _) in emitted {
                let normalized = key
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "_", with: "-")
                    .lowercased()
                // Request-owned keys are emitted by the builder itself.
                if ["page-set", "number-up", "orientation-requested", "fit-to-page", "scaling"].contains(normalized) {
                    continue
                }
                XCTAssertFalse(
                    reserved.contains(normalized),
                    "driver option key \(key) normalizes to reserved \(normalized)"
                )
            }
        }
    }
}
