import AppKit
import FlipStackCore
import PDFKit
import SwiftUI

/// A compact, fully in-panel preview of the print file, drawn the way the
/// macOS print panel draws it: a fixed paper sheet with the page content
/// scaled, centered, and clipped inside the sheet. The sheet itself never
/// changes size — only the content inside it does, so an exact percentage
/// shows cropping at the sheet edges instead of zooming the page, and
/// "Fit" shows the page scaled down onto the paper exactly as CUPS
/// `fit-to-page` will print it. For booklets each imposed page is one 2-up
/// sheet side, so the sheet is the imposed page itself.
struct PDFPagePreview: View {
    let url: URL
    var twoUp: Bool = false
    var sheetSize: CGSize = CGSize(width: 595.28, height: 841.89)
    var contentSize: CGSize = CGSize(width: 595.28, height: 841.89)
    var contentScale: CGFloat = 1
    var contentRotation: Double = 0
    var imageableArea: CGRect?
    var isGrayscale: Bool = false
    var scaleBadge: String?

    @State private var pageCount = 0
    @State private var pageIndex = 0
    @State private var image: NSImage?
    @State private var pageSizes: [Int: CGSize] = [:]

    private let previewHeight: CGFloat = 150

    /// The sheet drawn in the preview. Booklet imposed pages are landscape
    /// sheets already, so the page's own box is the sheet.
    private var sheet: CGSize {
        if twoUp, let size = pageSizes[pageIndex] {
            return size
        }
        return sheetSize
    }

    private var content: CGSize {
        twoUp ? sheet : contentSize
    }

    private var scale: CGFloat {
        twoUp ? 1 : contentScale
    }

    private var rotation: Double {
        twoUp ? 0 : contentRotation
    }

    private var currentLabel: Int { pageIndex + 1 }

    var body: some View {
        VStack(spacing: 7) {
            ZStack {
                RoundedRectangle(cornerRadius: FlipMetrics.smallRadius, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))

                if image == nil {
                    VStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Rendering preview…")
                            .font(FlipType.caption)
                            .foregroundStyle(FlipColor.secondaryInk)
                    }
                } else {
                    GeometryReader { geometry in
                        let available = CGSize(
                            width: max(60, geometry.size.width - 6),
                            height: previewHeight - 6
                        )
                        let k = min(available.width / sheet.width, available.height / sheet.height)
                        let sheetW = sheet.width * k
                        let sheetH = sheet.height * k

                        ZStack {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(FlipColor.printPaper)
                                .frame(width: sheetW, height: sheetH)
                                .shadow(color: FlipColor.paperShadow, radius: 4, x: 0, y: 2)

                            sheetContent(k: k)
                                .frame(width: sheetW, height: sheetH)
                                .clipped()
                                .overlay {
                                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                                        .strokeBorder(FlipColor.printPaperEdge, lineWidth: 0.75)
                                }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .frame(height: previewHeight)
            .overlay {
                RoundedRectangle(cornerRadius: FlipMetrics.smallRadius, style: .continuous)
                    .strokeBorder(FlipColor.hairline, lineWidth: 0.5)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(twoUp ? L("Booklet sheet preview") : L("Page preview"))
            .accessibilityValue(
                image == nil
                ? "Rendering"
                : "\(twoUp ? "Sheet" : "Page") \(currentLabel) of \(pageCount), paper \(Int(sheet.width)) by \(Int(sheet.height)) points, content \(Int(scale * 100)) percent"
            )

            HStack(spacing: 8) {
                Button {
                    pageIndex = max(0, pageIndex - 1)
                    updateImage()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(FlipIconButtonStyle())
                .disabled(pageIndex == 0)
                .accessibilityLabel(String(format: L("Previous %@"), twoUp ? L("sheet") : L("page")))

                Text(
                    twoUp
                    ? String(format: L("Sheet %lld of %lld"), currentLabel, max(1, pageCount))
                    : String(format: L("Page %lld of %lld"), currentLabel, max(1, pageCount))
                )
                    .font(.system(.caption, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(FlipColor.secondaryInk)
                    .frame(minWidth: 96)

                Button {
                    pageIndex = min(max(0, pageCount - 1), pageIndex + 1)
                    updateImage()
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(FlipIconButtonStyle())
                .disabled(pageIndex + 1 >= pageCount)
                .accessibilityLabel(String(format: L("Next %@"), twoUp ? L("sheet") : L("page")))

                Spacer(minLength: 2)

                if let scaleBadge {
                    Text(scaleBadge)
                        .font(.system(size: 8, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(FlipColor.coralDeep)
                        .padding(.horizontal, 6)
                        .frame(height: 16)
                        .background(Capsule().fill(FlipColor.coralSoft))
                } else if twoUp {
                    Text("2-up")
                        .font(.system(size: 8, weight: .semibold))
                        .tracking(0.9)
                        .foregroundStyle(FlipColor.tertiaryInk)
                }
            }
        }
        .task(id: url) {
            pageIndex = 0
            loadDocument()
        }
    }

    /// The page content drawn on the sheet: scaled by `scale`, rotated by
    /// `rotation`, centered, and clipped to the sheet by the caller.
    private func sheetContent(k: CGFloat) -> some View {
        ZStack {
            if let area = imageableArea, !twoUp, area.width > 0, area.height > 0 {
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .strokeBorder(
                        FlipColor.printLine.opacity(0.6),
                        style: StrokeStyle(lineWidth: 0.6, dash: [3, 2.5])
                    )
                    .frame(width: area.width * k, height: area.height * k)
                    .offset(
                        x: (area.midX - sheet.width / 2) * k,
                        y: (sheet.height / 2 - area.midY) * k
                    )
                    .accessibilityHidden(true)
            }

            if let image {
                let w = content.width * scale * k
                let h = content.height * scale * k
                let swaps = rotation.truncatingRemainder(dividingBy: 180) != 0
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: swaps ? h : w, height: swaps ? w : h)
                    .rotationEffect(.degrees(rotation))
                    .saturation(isGrayscale ? 0 : 1)
            }
        }
    }

    private func loadDocument() {
        guard let document = PDFDocument(url: url) else {
            pageCount = 0
            pageIndex = 0
            image = nil
            pageSizes = [:]
            return
        }
        pageCount = document.pageCount
        pageIndex = min(pageIndex, max(0, pageCount - 1))
        var sizes: [Int: CGSize] = [:]
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            sizes[index] = CGSize(width: bounds.width, height: bounds.height)
        }
        pageSizes = sizes
        updateImage(document: document)
    }

    private func updateImage(document: PDFDocument? = nil) {
        guard let document = document ?? PDFDocument(url: url),
              let page = document.page(at: pageIndex) else {
            image = nil
            return
        }
        let bounds = page.bounds(for: .mediaBox)
        let longest = max(bounds.width, bounds.height, 1)
        let thumb = min(longest, 640) / longest
        image = page.thumbnail(
            of: NSSize(width: bounds.width * thumb, height: bounds.height * thumb),
            for: .mediaBox
        )
    }
}

/// A small live diagram of the sheet and the scaled content inside it, the
/// same geometry the big preview uses, for the page-setup card — like the
/// thumbnail in the macOS print panel.
struct FlipSheetDiagram: View {
    let sheetSize: CGSize
    let contentSize: CGSize
    let contentScale: CGFloat
    let contentRotation: Double
    var imageableArea: CGRect?
    var height: CGFloat = 64

    var body: some View {
        GeometryReader { geometry in
            let available = CGSize(width: geometry.size.width, height: height)
            let k = min(available.width / sheetSize.width, available.height / sheetSize.height)
            let sheetW = sheetSize.width * k
            let sheetH = sheetSize.height * k

            ZStack {
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .fill(FlipColor.printPaper)
                    .frame(width: sheetW, height: sheetH)
                    .shadow(color: FlipColor.paperShadow, radius: 2.5, x: 0, y: 1.5)

                ZStack {
                    if let area = imageableArea, area.width > 0, area.height > 0 {
                        RoundedRectangle(cornerRadius: 1, style: .continuous)
                            .strokeBorder(
                                FlipColor.printLine.opacity(0.6),
                                style: StrokeStyle(lineWidth: 0.5, dash: [2.5, 2])
                            )
                            .frame(width: area.width * k, height: area.height * k)
                            .offset(
                                x: (area.midX - sheetSize.width / 2) * k,
                                y: (sheetSize.height / 2 - area.midY) * k
                            )
                    }

                    let w = contentSize.width * contentScale * k
                    let h = contentSize.height * contentScale * k
                    let swaps = contentRotation.truncatingRemainder(dividingBy: 180) != 0
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(FlipColor.coral.opacity(0.14))
                        .overlay {
                            VStack(alignment: .leading, spacing: max(1, h * 0.09)) {
                                Capsule().fill(FlipColor.coral.opacity(0.75))
                                    .frame(width: w * 0.42, height: max(1, h * 0.045))
                                Capsule().fill(FlipColor.coral.opacity(0.4))
                                    .frame(width: w * 0.62, height: max(0.8, h * 0.032))
                                Capsule().fill(FlipColor.coral.opacity(0.28))
                                    .frame(width: w * 0.5, height: max(0.8, h * 0.032))
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .padding(.leading, w * 0.09)
                            .padding(.top, h * 0.1)
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 1, style: .continuous)
                                .strokeBorder(FlipColor.coral.opacity(0.65), lineWidth: 0.8)
                        }
                        .frame(width: swaps ? h : w, height: swaps ? w : h)
                        .rotationEffect(.degrees(contentRotation))
                }
                .frame(width: sheetW, height: sheetH)
                .clipped()
                .overlay {
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .strokeBorder(FlipColor.printPaperEdge, lineWidth: 0.6)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// A compact macOS Preview-style page rail. The checkmark is the print
/// selection, not just a navigation cursor; the preview stays open while the
/// selected-page PDF is regenerated.
@MainActor
private struct PageSelectionSidebar: View {
    @ObservedObject var model: AppModel
    let documentURL: URL

    @State private var thumbnails: [Int: NSImage] = [:]
    @State private var pageCount = 0

    private var selectedCount: Int {
        model.selectedPageNumbers.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                FlipEyebrow("Pages", color: FlipColor.tertiaryInk)
                Spacer(minLength: 0)
                Button("All") {
                    model.selectAllPages()
                }
                .font(.system(size: 8, weight: .semibold))
                .buttonStyle(.plain)
                .foregroundStyle(selectedCount == pageCount ? FlipColor.tertiaryInk : FlipColor.coralDeep)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
                .disabled(selectedCount == pageCount)
                .help("Select every page")
                .accessibilityLabel("Select all pages")
            }

            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(spacing: 7) {
                    ForEach(1...max(1, pageCount), id: \.self) { page in
                        pageThumbnail(page)
                    }
                }
                .padding(.bottom, 2)
            }
            .frame(maxHeight: 166)
        }
        .task(id: documentURL) {
            loadThumbnails()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Page selection")
    }

    private func pageThumbnail(_ page: Int) -> some View {
        let selected = model.isPageSelected(page)
        return Button {
            model.togglePageSelection(page)
        } label: {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let image = thumbnails[page] {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                    } else {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(FlipColor.toneStrong)
                    }
                }
                .frame(width: 58, height: 75)
                .background(Color.white)
                .overlay {
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .strokeBorder(
                            selected ? FlipColor.coral : FlipColor.hairline,
                            lineWidth: selected ? 1.3 : 0.5
                        )
                }
                .opacity(selected ? 1 : 0.48)
                .shadow(color: .black.opacity(0.08), radius: 1.5, x: 0, y: 1)

                Circle()
                    .fill(selected ? FlipColor.coral : FlipColor.printPaper)
                    .frame(width: 15, height: 15)
                    .overlay {
                        Image(systemName: selected ? "checkmark" : "plus")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(selected ? FlipColor.onCoral : FlipColor.tertiaryInk)
                    }
                    .overlay(Circle().strokeBorder(FlipColor.hairline, lineWidth: 0.5))
                    .offset(x: 4, y: -4)

                Text("\(page)")
                    .font(.system(size: 8, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(selected ? FlipColor.secondaryInk : FlipColor.tertiaryInk)
                    .padding(.horizontal, 4)
                    .frame(height: 13)
                    .background(Capsule().fill(FlipColor.paper.opacity(0.9)))
                    .overlay(Capsule().strokeBorder(FlipColor.hairline, lineWidth: 0.5))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 3)
            }
            .frame(width: 78, height: 79, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(format: L("Page %lld"), page))
        .accessibilityValue(selected ? L("Included in print") : L("Not included"))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(
            selected
            ? String(format: L("Remove page %lld from the print"), page)
            : String(format: L("Include page %lld in the print"), page)
        )
    }

    private func loadThumbnails() {
        guard let document = PDFDocument(url: documentURL) else {
            pageCount = 0
            thumbnails = [:]
            return
        }
        pageCount = document.pageCount
        var loaded: [Int: NSImage] = [:]
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            loaded[index + 1] = page.thumbnail(of: NSSize(width: 116, height: 150), for: .mediaBox)
        }
        thumbnails = loaded
    }
}

@MainActor
struct DocumentPreviewPanel: View {
    @ObservedObject var model: AppModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var activeURL: URL? {
        if model.previewShowsBacks, let backs = model.previewBacksURL {
            return backs
        }
        return model.previewURL
    }

    private var pageCount: Int {
        guard let activeURL else { return 0 }
        return PDFDocument(url: activeURL)?.pageCount ?? 0
    }

    private var previewAdjustments: some View {
        HStack(spacing: 7) {
            if model.previewBacksURL != nil, model.isShowingPreview {
                HStack(spacing: 2) {
                    sideChip("Fronts", backs: false)
                    sideChip("Backs", backs: true)
                }
                .padding(2)
                .background(Capsule().fill(FlipColor.tone))
                .overlay(Capsule().strokeBorder(FlipColor.hairline, lineWidth: 0.5))
            }

            if model.mode != .booklet {
                Text("Scale")
                    .font(FlipType.captionStrong)
                    .foregroundStyle(FlipColor.secondaryInk)
                    .fixedSize(horizontal: true, vertical: false)

                FlipScaleStepper(model: model, compact: true)
                    .disabled(model.isPreparingPrint)
                    .accessibilityLabel("Preview print scale")
            } else {
                Text("2-up booklet")
                    .font(FlipType.captionStrong)
                    .foregroundStyle(FlipColor.secondaryInk)
            }

            Spacer(minLength: 0)

            if model.supportsColorModeToggle {
                Button {
                    withAnimation(FlipMotion.quick(reduceMotion)) {
                        model.setGrayscale(!model.isGrayscaleSelected)
                    }
                } label: {
                    Text(model.isGrayscaleSelected ? L("B&W") : L("Color"))
                        .font(.system(.caption2, design: .default, weight: .semibold))
                        .foregroundStyle(FlipColor.secondaryInk)
                        .padding(.horizontal, 7)
                        .frame(height: 22)
                        .background(Capsule().fill(FlipColor.tone))
                        .overlay(Capsule().strokeBorder(FlipColor.hairline, lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .help(model.isGrayscaleSelected ? "Switch preview and print to color." : "Switch preview and print to black and white.")
                .accessibilityLabel("Color mode")
                .accessibilityValue(model.isGrayscaleSelected ? "Black and white" : "Color")
            }
        }
        .accessibilityElement(children: .contain)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FlipSectionHeader("Print preview") {
                Button {
                    model.togglePreview()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8.5, weight: .bold))
                }
                .buttonStyle(FlipIconButtonStyle(size: 26))
                .help("Close preview")
                .accessibilityLabel("Close print preview")
            }

            if model.isPreparingPreview {
                VStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(FlipColor.coral)
                    Text("Preparing the print preview…")
                        .font(FlipType.caption)
                        .foregroundStyle(FlipColor.secondaryInk)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 190)
                .background(
                    RoundedRectangle(cornerRadius: FlipMetrics.controlRadius, style: .continuous)
                        .fill(FlipColor.tone)
                )
                .accessibilityElement(children: .combine)
            } else if let activeURL {
                HStack(alignment: .top, spacing: 9) {
                    if model.mode != .booklet, let document = model.selectedDocument {
                        PageSelectionSidebar(model: model, documentURL: document.url)
                            .frame(width: 82)
                    }

                    PDFPagePreview(
                        url: activeURL,
                        twoUp: model.mode == .booklet,
                        sheetSize: model.previewSheetSize,
                        contentSize: model.previewContentSize,
                        contentScale: model.previewContentScale,
                        contentRotation: model.previewContentRotation,
                        imageableArea: model.selectedImageableArea,
                        isGrayscale: model.isGrayscaleSelected,
                        scaleBadge: model.mode == .booklet
                            ? nil
                            : (model.fitToPage ? L("Fit") : "\(model.scalePercent)%")
                    )
                }

                previewAdjustments
            } else {
                Text("No preview is available for this document.")
                    .font(FlipType.footnote)
                    .foregroundStyle(FlipColor.secondaryInk)
                    .frame(height: 80)
            }
        }
        .padding(11)
        .background(FlipGlassCard())
        .accessibilityElement(children: .contain)
    }

    private func sideChip(_ title: String, backs: Bool) -> some View {
        let isSelected = model.previewShowsBacks == backs
        return Button {
            withAnimation(FlipMotion.quick(reduceMotion)) {
                model.showPreviewBacks(backs)
            }
        } label: {
            Text(L(title))
                .font(.system(.caption2, design: .default, weight: .semibold))
                .foregroundStyle(isSelected ? FlipColor.onCoral : FlipColor.secondaryInk)
                .padding(.horizontal, 8)
                .frame(height: 21)
                .background(Capsule().fill(isSelected ? FlipColor.coral : Color.clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) preview")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
