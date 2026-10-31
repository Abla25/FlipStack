import AppKit
import FlipStackCore
import PDFKit
import SwiftUI

/// A compact, fully in-panel preview of the print file. For booklets it pairs
/// the imposed PDF pages back into the 2-up sheet sides CUPS will produce.
struct PDFPagePreview: View {
    let url: URL
    var twoUp: Bool = false

    @State private var pageCount = 0
    @State private var pageIndex = 0
    @State private var images: [NSImage] = []

    private var pageStep: Int { twoUp ? 2 : 1 }

    private var sheetCount: Int {
        twoUp ? Int(ceil(Double(pageCount) / 2.0)) : pageCount
    }

    private var currentSheet: Int {
        min(sheetCount, pageIndex / pageStep + 1)
    }

    var body: some View {
        VStack(spacing: 7) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))

                if images.isEmpty {
                    VStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Rendering preview…")
                            .font(FlipType.caption)
                            .foregroundStyle(FlipColor.secondaryInk)
                    }
                } else if twoUp {
                    HStack(spacing: 7) {
                        ForEach(Array(images.enumerated()), id: \.offset) { _, image in
                            Image(nsImage: image)
                                .resizable()
                                .interpolation(.high)
                                .aspectRatio(contentMode: .fit)
                        }
                    }
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.white)
                    )
                    .shadow(color: .black.opacity(0.18), radius: 4, x: 0, y: 2)
                    .padding(10)
                } else {
                    HStack(spacing: 0) {
                        ForEach(Array(images.enumerated()), id: \.offset) { _, image in
                            Image(nsImage: image)
                                .resizable()
                                .interpolation(.high)
                                .aspectRatio(contentMode: .fit)
                                .background(Color.white)
                                .shadow(color: .black.opacity(0.16), radius: 3, x: 0, y: 2)
                        }
                    }
                    .padding(10)
                }
            }
            .frame(height: 214)
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(FlipColor.hairline, lineWidth: 0.5)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(twoUp ? "Booklet sheet preview" : "Page preview")
            .accessibilityValue(
                images.isEmpty
                ? "Rendering"
                : "\(twoUp ? "Sheet" : "Page") \(currentSheet) of \(sheetCount), \(pageCount) source pages"
            )

            HStack(spacing: 8) {
                Button {
                    pageIndex = max(0, pageIndex - pageStep)
                    updateImages()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(FlipIconButtonStyle())
                .disabled(pageIndex == 0)
                .accessibilityLabel("Previous \(twoUp ? "sheet" : "page")")

                Text(twoUp ? "Sheet \(currentSheet) of \(sheetCount)" : "Page \(max(1, currentSheet)) of \(sheetCount)")
                    .font(.system(.caption, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(FlipColor.secondaryInk)
                    .frame(minWidth: 96)

                Button {
                    pageIndex = min(max(0, pageCount - 1), pageIndex + pageStep)
                    updateImages()
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(FlipIconButtonStyle())
                .disabled(pageIndex + pageStep >= pageCount)
                .accessibilityLabel("Next \(twoUp ? "sheet" : "page")")

                Spacer(minLength: 2)

                if twoUp {
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

    private func loadDocument() {
        guard let document = PDFDocument(url: url) else {
            pageCount = 0
            pageIndex = 0
            images = []
            return
        }
        pageCount = document.pageCount
        pageIndex = min(pageIndex, max(0, pageCount - 1))
        updateImages(document: document)
    }

    private func updateImages(document: PDFDocument? = nil) {
        guard let document = document ?? PDFDocument(url: url) else { return }
        let pages = twoUp
            ? Array(pageIndex..<min(pageCount, pageIndex + 2))
            : [pageIndex]
        images = pages.compactMap { index in
            guard let page = document.page(at: index) else { return nil }
            return page.thumbnail(of: NSSize(width: 420, height: 560), for: .mediaBox)
        }
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

    private var countLabel: String {
        if model.mode == .booklet {
            let sheets = Int(ceil(Double(pageCount) / 2.0))
            return "\(sheets) \(sheets == 1 ? "sheet" : "sheets") · \(pageCount) pages"
        }
        return pageCount == 1 ? "1 page" : "\(pageCount) pages"
    }

    private var previewSubtitle: String {
        if model.mode == .booklet {
            return model.previewShowsBacks
                ? "Backs · sheet sides after the flip"
                : "Fronts · sheet sides before the flip"
        }
        if model.pageSelectionMode == .range {
            return "\(model.pageSelectionInfo.summary) · in print order"
        }
        return "All \(model.selectedDocument?.pageCount ?? 0) pages · in print order"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                FlipEyebrow("Print preview")
                Spacer(minLength: 4)

                if model.previewBacksURL != nil, model.isShowingPreview {
                    HStack(spacing: 2) {
                        sideChip("Fronts", backs: false)
                        sideChip("Backs", backs: true)
                    }
                    .padding(2)
                    .background(Capsule().fill(FlipColor.tone))
                    .overlay(Capsule().strokeBorder(FlipColor.hairline, lineWidth: 0.5))
                }

                Button {
                    model.togglePreview()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8.5, weight: .bold))
                }
                .buttonStyle(FlipIconButtonStyle())
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
                .frame(height: 246)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(FlipColor.tone)
                )
                .accessibilityElement(children: .combine)
            } else if let activeURL {
                PDFPagePreview(url: activeURL, twoUp: model.mode == .booklet)

                HStack(alignment: .top, spacing: 5) {
                    Text(previewSubtitle)
                        .font(FlipType.caption)
                        .foregroundStyle(FlipColor.secondaryInk)
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    Text(countLabel)
                        .font(.system(.caption, design: .rounded, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(FlipColor.tertiaryInk)                }
            } else {
                Text("No preview is available for this document.")
                    .font(FlipType.footnote)
                    .foregroundStyle(FlipColor.secondaryInk)
                    .frame(height: 80)
            }
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(FlipColor.tone)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(FlipColor.hairline, lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
    }

    private func sideChip(_ title: String, backs: Bool) -> some View {
        let isSelected = model.previewShowsBacks == backs
        return Button {
            withAnimation(FlipMotion.quick(reduceMotion)) {
                model.showPreviewBacks(backs)
            }
        } label: {
            Text(title)
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
