import FlipStackCore
import SwiftUI

@MainActor
struct ComposerView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DocumentSection(model: model)

            if model.selectedDocument != nil {
                if model.isShowingPreview || model.isPreparingPreview {
                    DocumentPreviewPanel(model: model)
                        .padding(.top, 12)
                }

                sectionBreak

                ModeSection(model: model)

                sectionBreak

                OutputSection(model: model)
            } else {
                FirstFlipGuide()
                    .padding(.top, 18)
            }
        }
    }

    private var sectionBreak: some View {
        FlipHairline()
            .padding(.vertical, 12)
    }
}

/// The empty composer is intentionally quiet, but it still explains the one
/// physical action that makes the whole feature work.
private struct FirstFlipGuide: View {
    private var steps: [(String, String, String)] = [
        ("01", "Drop a PDF", "Choose any document from this Mac."),
        ("02", "Print the fronts", "FlipStack sends the odd pages first."),
        ("03", "Flip once", "Turn the whole block; the backs follow.")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 7) {
                Rectangle()
                    .fill(FlipColor.coral)
                    .frame(width: 18, height: 2)
                Text("HOW A FLIP WORKS")
                    .font(.system(size: 8, weight: .semibold))
                    .tracking(1.3)
                    .foregroundStyle(FlipColor.tertiaryInk)
            }

            HStack(alignment: .top, spacing: 12) {
                ForEach(Array(steps.enumerated()), id: \.offset) { item in
                    let step = item.element
                    VStack(alignment: .leading, spacing: 3) {
                        Text(step.0)
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(FlipColor.coralDeep)
                        Text(step.1)
                            .font(FlipType.captionStrong)
                            .foregroundStyle(FlipColor.ink)
                            .lineLimit(2)
                        Text(step.2)
                            .font(.system(size: 10))
                            .foregroundStyle(FlipColor.secondaryInk)
                            .fixedSize(horizontal: false, vertical: true)
                            .lineSpacing(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Text("Single-sided prints skip the flip. Duplex and booklet use it to keep every back in order.")
                .font(FlipType.caption)
                .foregroundStyle(FlipColor.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(1)
                .padding(.top, 2)
        }
        .padding(.top, 13)
        .overlay(alignment: .top) {
            FlipHairline()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("How a flip works. Drop a PDF, print the fronts, then flip the whole stack once and print the backs. Single-sided prints skip the flip.")
    }
}

@MainActor
struct PrimaryActionBar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            FlipHairline()
            PrimaryActionSection(model: model)
                .padding(.horizontal, FlipMetrics.gutter)
                .padding(.top, 10)
                .padding(.bottom, 10)
        }
        .background {
            ZStack {
                // A thick material keeps scrolling content from showing through
                // sliced at the action bar edge while preserving the glass feel.
                Rectangle().fill(.thickMaterial)
                Rectangle().fill(Color.primary.opacity(0.012))
            }
        }
    }
}

@MainActor
struct PrimaryActionSection: View {
    @ObservedObject var model: AppModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var needsCalibration: Bool {
        guard model.selectedDocument != nil,
              !model.preferences.hasConfiguredFlip else { return false }
        switch model.mode {
        case .singleSided: return false
        case .manualDuplex: return model.pageSelectionInfo.pageCount > 1
        case .booklet: return true
        }
    }

    private var actionTitle: String {
        if needsCalibration { return "Calibrate and print" }
        switch model.mode {
        case .singleSided: return "Print document"
        case .manualDuplex:
            return model.pageSelectionInfo.pageCount == 1 ? "Print page" : "Print fronts"
        case .booklet: return "Print booklet"
        }
    }

    private var printerIsStopped: Bool {
        model.printerState == .stopped
    }

    private var canStart: Bool {
        model.canPrint && !printerIsStopped
    }

    private var disabledReason: String? {
        if model.isPreparingPrint {
            return "Preparing the document. This stays on your Mac."
        }
        if model.isMaintenanceBusy {
            return "A maintenance page is being prepared."
        }
        if model.selectedPrinter == nil {
            return "Connect a printer to start printing."
        }
        if model.selectedDocument == nil {
            return "Choose a PDF to continue."
        }
        if !model.pageSelectionInfo.isValid {
            return model.pageSelectionInfo.message ?? "Choose at least one page."
        }
        if model.isLoadingPPD {
            return "Reading the printer driver…"
        }
        if printerIsStopped {
            return "The printer is stopped. Resume its queue, then try again."
        }
        if !model.canPrint {
            return "A print flow is already running."
        }
        return nil
    }

    private var sheetCount: Int? {
        guard model.selectedDocument != nil else { return nil }
        let pages = model.pageSelectionInfo.pageCount
        guard pages > 0 else { return nil }
        switch model.mode {
        case .singleSided:
            return pages
        case .booklet:
            return model.bookletPlan?.sheetCount
        case .manualDuplex:
            return Int(ceil(Double(pages) / 2.0))
        }
    }

    private var detailLine: String? {
        if let reason = disabledReason { return reason }
        if needsCalibration {
            return "One orientation sheet on the current paper prints first; your PDF waits."
        }
        guard let sheets = sheetCount else { return nil }
        let copyPrefix = model.copies > 1
            ? "\(model.copies) copies · "
            : ""
        let selectedPrefix: String
        if model.pageSelectionMode == .range {
            selectedPrefix = "\(model.pageSelectionInfo.summary) · "
        } else {
            selectedPrefix = ""
        }
        switch model.mode {
        case .singleSided:
            return "\(selectedPrefix)\(copyPrefix)\(FlipFormat.sheets(sheets)) · one side."
        case .booklet:
            return "\(selectedPrefix)\(copyPrefix)\(FlipFormat.sheets(sheets)) per copy · fold and flip between passes."
        case .manualDuplex:
            if model.pageSelectionInfo.pageCount == 1 {
                return "\(selectedPrefix)1 sheet · one page, so no flip is needed."
            }
            return "\(selectedPrefix)\(copyPrefix)\(FlipFormat.sheets(sheets)) per copy · fronts first, then the flip."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                model.requestPrint()
            } label: {
                HStack(spacing: 9) {
                    if model.isPreparingPrint {
                        ProgressView()
                            .controlSize(.small)
                            .tint(FlipColor.coralDeep)
                    } else {
                        Image(systemName: model.mode == .booklet ? "book.closed" : "printer")
                            .font(.system(size: 12, weight: .semibold))
                    }

                    Text(model.isPreparingPrint ? "Preparing…" : actionTitle)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    if canStart {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 11, weight: .semibold))
                            .opacity(0.7)
                    }
                }
            }
            .buttonStyle(FlipPrimaryButtonStyle())
            .disabled(!canStart)
            .help(disabledReason ?? detailLine ?? actionTitle)
            .accessibilityLabel(model.isPreparingPrint ? "Preparing print job" : actionTitle)
            .accessibilityHint(disabledReason ?? detailLine ?? "Starts printing. Command-P also works.")

            if let detailLine {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: disabledReason == nil ? "arrow.triangle.2.circlepath" : "info.circle")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(FlipColor.tertiaryInk)
                        .frame(width: 11, height: 12, alignment: .top)
                    Text(detailLine)
                        .font(FlipType.caption)
                        .foregroundStyle(FlipColor.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineSpacing(1)
                }
                .padding(.horizontal, 3)
                .accessibilityElement(children: .combine)
            }
        }
        .animation(FlipMotion.standard(reduceMotion), value: disabledReason)
        .animation(FlipMotion.quick(reduceMotion), value: model.isPreparingPrint)
    }
}
