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
            } else if !model.preferences.hasConfiguredFlip {
                FirstRunSetupCard(model: model)
                    .padding(.top, 14)
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

/// The first job is the only time the app needs a physical lesson. Keep this
/// card concrete: one sheet, two answers, then every duplex job is automatic.
@MainActor
private struct FirstRunSetupCard: View {
    @ObservedObject var model: AppModel

    private var printerName: String {
        model.selectedPrinter?.displayName ?? "this printer"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 9) {
                FlipIconMedallion(systemName: "viewfinder", tint: FlipColor.coralDeep, size: 28)
                VStack(alignment: .leading, spacing: 3) {
                    FlipEyebrow("First time with this printer", color: FlipColor.coralDeep)
                    Text("One sheet. Two answers. Then it just works.")
                        .font(FlipType.bodyStrong)
                        .foregroundStyle(FlipColor.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(String(format: L("FlipStack prints a generic orientation sheet so it can learn how %@ stacks paper. Your PDF is not used."), printerName))
                        .font(FlipType.caption)
                        .foregroundStyle(FlipColor.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineSpacing(1)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 6) {
                setupStep("1", "Print sheet")
                setupChevron
                setupStep("2", "Check result")
                setupChevron
                setupStep("3", "Ready")
            }
            .padding(.vertical, 1)

            HStack(spacing: 8) {
                Button {
                    model.beginGuidedSetup()
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "printer")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Print setup sheet")
                        Spacer(minLength: 0)
                    }
                }
                .buttonStyle(FlipPrimaryButtonStyle())
                .disabled(model.isCalibrating || !model.orchestrator.phase.isIdle)
                .help("Prints one generic orientation sheet. No document content is sent.")
                .accessibilityHint("Prints one setup sheet, then asks two questions about how it landed.")

                Button("Set up manually") {
                    model.openFlipAxisSetup()
                }
                .buttonStyle(FlipTertiaryButtonStyle())
                .disabled(model.isCalibrating || !model.orchestrator.phase.isIdle)
                .frame(minHeight: 44)
                .accessibilityHint("Skips the calibration sheet and chooses the turn and output face yourself.")
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: FlipMetrics.cardRadius, style: .continuous)
                .fill(FlipColor.coral.opacity(0.055))
        )
        .overlay {
            RoundedRectangle(cornerRadius: FlipMetrics.cardRadius, style: .continuous)
                .strokeBorder(FlipColor.coral.opacity(0.28), lineWidth: 0.75)
        }
        .accessibilityElement(children: .contain)
    }

    private func setupStep(_ number: String, _ title: String) -> some View {
        HStack(spacing: 4) {
            Text(number)
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(FlipColor.onCoral)
                .frame(width: 15, height: 15)
                .background(Circle().fill(FlipColor.coral))
            Text(L(title))
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(FlipColor.secondaryInk)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    private var setupChevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 6.5, weight: .bold))
            .foregroundStyle(FlipColor.tertiaryInk.opacity(0.6))
            .accessibilityHidden(true)
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
                        Text(L(step.1))
                            .font(FlipType.captionStrong)
                            .foregroundStyle(FlipColor.ink)
                            .lineLimit(2)
                        Text(L(step.2))
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
        .accessibilityLabel(L("How a flip works. Drop a PDF, print the fronts, then flip the whole stack once and print the backs. Single-sided prints skip the flip."))
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
        if needsCalibration { return L("Set up flip and print") }
        switch model.mode {
        case .singleSided: return L("Print document")
        case .manualDuplex:
            return model.pageSelectionInfo.pageCount == 1 ? L("Print page") : L("Print fronts")
        case .booklet: return L("Print booklet")
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
            return L("Preparing the document. This stays on your Mac.")
        }
        if model.isMaintenanceBusy {
            return L("A maintenance page is being prepared.")
        }
        if model.selectedPrinter == nil {
            return L("Connect a printer to start printing.")
        }
        if model.selectedDocument == nil {
            return L("Choose a PDF to continue.")
        }
        if !model.pageSelectionInfo.isValid {
            return model.pageSelectionInfo.message ?? "Choose at least one page."
        }
        if model.isLoadingPPD {
            return L("Reading the printer driver…")
        }
        if printerIsStopped {
            return L("The printer is stopped. Resume its queue, then try again.")
        }
        if !model.canPrint {
            return L("A print flow is already running.")
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
            return L("One setup sheet first. Answer two questions, then your PDF prints.")
        }
        guard let sheets = sheetCount else { return nil }
        let copyPrefix = model.copies > 1
            ? String(format: L("%lld copies · "), model.copies)
            : ""
        let selectedPrefix: String
        if model.pageSelectionMode == .range {
            selectedPrefix = "\(model.pageSelectionInfo.summary) · "
        } else {
            selectedPrefix = ""
        }
        switch model.mode {
        case .singleSided:
            return String(format: L("%@%@%@ · one side."), selectedPrefix, copyPrefix, FlipFormat.sheets(sheets))
        case .booklet:
            return String(format: L("%@%@%@ · fold and flip between passes."), selectedPrefix, copyPrefix, FlipFormat.sheets(sheets))
        case .manualDuplex:
            if model.pageSelectionInfo.pageCount == 1 {
                return String(format: L("%@1 sheet · one page, so no flip is needed."), selectedPrefix)
            }
            return String(format: L("%@%@%@ · fronts first, then the flip."), selectedPrefix, copyPrefix, FlipFormat.sheets(sheets))
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
