import Foundation

/// Pure, unit-tested print math shared by the model and the print engine.
///
/// Extracted from `Model.swift` in v1.0.2 so the print flow can be tested
/// without a UI. This is also where the v1.0.2 correctness fixes live:
/// - `parsePageSpec` can never trap on out-of-range/illegal ranges
///   (the old `for i in a...min(b, total)` crashed with
///   "Fatal error: Range requires lowerBound <= upperBound" whenever the
///   range start was past the end of the document);
/// - paper names map to real CUPS media names (A3 / Photo used to print as
///   Letter);
/// - oversized pages and photos get a computed scale that actually fits the
///   chosen media instead of being clipped;
/// - long/short edge manual duplex passes are planned consistently.
enum PrintMath {
    // MARK: - Page math

    /// Number of pages selected out of `total` for a page mode.
    static func selectedPages(total: Int, pages: String) -> Int {
        switch pages {
        case "odd": return (total + 1) / 2
        case "even": return total / 2
        default: return total
        }
    }

    /// Sheets consumed by one copy. `pages` is the number of selected pages.
    static func sheets(pages: Int, duplex: Bool, copies: Int) -> Int {
        let perCopy = duplex ? (pages + 1) / 2 : pages
        return perCopy * max(copies, 0)
    }

    /// Explicit alias used by the v1.0.2 flow planner.
    static func totalSheets(pages: Int, copies: Int, duplex: Bool) -> Int {
        sheets(pages: pages, duplex: duplex, copies: copies)
    }

    static func dpi(quality: String, resOverride: String) -> Int {
        if let v = Int(resOverride), v > 0 { return v }
        switch quality {
        case "draft": return 180
        case "normal": return 366
        default: return 600
        }
    }

    static func qualityLevel(forDPI dpi: Int) -> Int {
        dpi <= 180 ? 3 : dpi <= 366 ? 4 : 5
    }

    static func qualityLevel(_ q: String) -> Int {
        switch q {
        case "draft": return 3
        case "normal": return 4
        default: return 5
        }
    }

    static func pageRange(pages: Int, side: String) -> String {
        var nums: [Int] = []
        var i = side == "odd" ? 1 : 2
        while i <= pages {
            nums.append(i)
            i += 2
        }
        return compressRange(nums)
    }

    /// Compress sorted page numbers into "1-3,5,7-9" form.
    static func compressRange(_ pages: [Int]) -> String {
        let sorted = Array(Set(pages)).sorted()
        guard !sorted.isEmpty else { return "" }
        var parts: [String] = []
        var start = sorted[0]
        var prev = sorted[0]
        for p in sorted.dropFirst() {
            if p == prev + 1 {
                prev = p
                continue
            }
            parts.append(start == prev ? "\(start)" : "\(start)-\(prev)")
            start = p
            prev = p
        }
        parts.append(start == prev ? "\(start)" : "\(start)-\(prev)")
        return parts.joined(separator: ",")
    }

    /// Parse a user page spec like "1-5, 8, 12-14" against a total page count.
    ///
    /// Never traps. Ranges are intersected with `1...total`; single numbers
    /// outside the document are ignored. Returns an empty array when nothing
    /// valid was requested (callers must treat that as "no pages selected",
    /// not as "all pages").
    static func parsePageSpec(_ spec: String, total: Int) -> [Int] {
        guard total > 0 else { return [] }
        var result = Set<Int>()
        for part in spec.split(separator: ",") {
            let p = part.trimmingCharacters(in: .whitespaces)
            guard !p.isEmpty else { continue }
            if let dash = p.firstIndex(of: "-") {
                let a = Int(p[..<dash].trimmingCharacters(in: .whitespaces)) ?? 0
                let b = Int(p[p.index(after: dash)...].trimmingCharacters(in: .whitespaces)) ?? 0
                guard a > 0, b >= a else { continue }
                let lo = max(1, a)
                let hi = min(total, b)
                if lo <= hi { result.formUnion(lo...hi) }
            } else if let n = Int(p) {
                if n >= 1, n <= total { result.insert(n) }
            }
        }
        return result.sorted()
    }

    /// Whether a page spec selects at least one page.
    static func isValidPageSpec(_ spec: String, total: Int) -> Bool {
        !parsePageSpec(spec, total: total).isEmpty
    }

    /// The actual pages to print, given the mode ("all"/"odd"/"even"/"custom")
    /// and spec. A custom mode with an empty/invalid spec selects NO pages
    /// (v1.0.2 fix: it used to silently print the whole document).
    static func selectedPageList(total: Int, pages: String, spec: String) -> [Int] {
        switch pages {
        case "odd":
            return total > 0 ? stride(from: 1, through: total, by: 2).map { $0 } : []
        case "even":
            return total > 0 ? stride(from: 2, through: total, by: 2).map { $0 } : []
        case "custom":
            return parsePageSpec(spec, total: total)
        default:
            return total > 0 ? Array(1...total) : []
        }
    }

    /// Scale factor so a page fits inside a fixed sheet (zoom=1.0 → fit).
    static func fitScale(sheetW: Double, sheetH: Double, pageW: Double, pageH: Double) -> Double {
        guard pageW > 0, pageH > 0 else { return 1 }
        return min(sheetW / pageW, sheetH / pageH)
    }

    static func isPhoto(_ name: String) -> Bool {
        let exts = ["jpg", "jpeg", "heic", "heif", "png", "tiff", "tif", "bmp", "gif", "webp"]
        return exts.contains((name as NSString).pathExtension.lowercased())
    }

    // MARK: - Manual duplex pass planning (v1.0.2)

    /// Split the ordered selection into the front and back pass page lists.
    /// Positions 0, 2, 4… go on the first pass (fronts), 1, 3, 5… on the
    /// second (backs). This is independent of long/short edge: the edge only
    /// changes the rotation of the second pass and the instructions to the user.
    static func frontsAndBacks(_ pages: [Int]) -> (fronts: [Int], backs: [Int]) {
        var fronts: [Int] = []
        var backs: [Int] = []
        for (index, page) in pages.enumerated() {
            if index % 2 == 0 { fronts.append(page) } else { backs.append(page) }
        }
        return (fronts, backs)
    }

    // MARK: - Paper / media (v1.0.2: all four advertised sizes are real)

    static func paperMediaName(_ paper: String) -> String {
        switch paper {
        case "A4": return "iso_a4_210x297mm"
        case "A3": return "iso_a3_297x420mm"
        case "Letter": return "na_letter_8.5x11in"
        case "Photo 4×6", "Photo 4x6": return "na_index-4x6_4x6in"
        default: return "iso_a4_210x297mm"
        }
    }

    struct Size: Equatable {
        var width: Double
        var height: Double
        static let zero = Size(width: 0, height: 0)
    }

    /// Media size in PostScript points (72 dpi), used for fit calculations.
    static func paperSizePoints(_ paper: String) -> Size {
        switch paper {
        case "A4": return Size(width: 595, height: 842)
        case "A3": return Size(width: 842, height: 1191)
        case "Letter": return Size(width: 612, height: 792)
        case "Photo 4×6", "Photo 4x6": return Size(width: 288, height: 432)
        default: return Size(width: 595, height: 842)
        }
    }

    /// Orientation inferred from a page's media box.
    static func detectedOrientation(pageSize: Size) -> String {
        pageSize.width > pageSize.height ? "landscape" : "portrait"
    }

    /// CUPS `orientation-requested` value: 3 portrait, 4 landscape.
    /// `nil` means "let the driver decide" (only for auto with unknown page size).
    static func orientationRequested(orientation: String, pageSize: Size?) -> Int? {
        switch orientation {
        case "portrait": return 3
        case "landscape": return 4
        default:
            guard let pageSize, pageSize.width > 0, pageSize.height > 0 else { return nil }
            return detectedOrientation(pageSize: pageSize) == "landscape" ? 4 : 3
        }
    }

    /// The second pass of a manual short-edge duplex job must be rotated 180°
    /// relative to the first. Long-edge keeps the same orientation.
    static func backsOrientationRequested(fronts: Int?, shortEdge: Bool) -> Int? {
        guard shortEdge else { return fronts }
        switch fronts {
        case 3: return 5   // portrait → reverse portrait
        case 4: return 6   // landscape → reverse landscape
        case 5: return 3
        case 6: return 4
        default: return 5  // unknown: best-effort reverse portrait
        }
    }

    /// Scale percentage that fits `pageSize` inside the chosen media while
    /// never exceeding the user's requested scale. Photos embedded at pixel
    /// size and oversized PDFs therefore print whole instead of clipped.
    static func effectiveScale(paper: String, pageSize: Size?, userScale: Int) -> Int {
        let requested = min(max(userScale, 1), 200)
        guard let pageSize, pageSize.width > 0, pageSize.height > 0 else { return requested }
        let media = paperSizePoints(paper)
        guard media.width > 0, media.height > 0 else { return requested }
        let fit = min(media.width / pageSize.width, media.height / pageSize.height)
        let fitPercent = Int(floor(fit * 100.0))
        guard fitPercent > 0 else { return 1 }
        return min(requested, fitPercent)
    }
}
