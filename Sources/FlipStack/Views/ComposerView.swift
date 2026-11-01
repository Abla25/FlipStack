import FlipStackCore
import SwiftUI

/// The minimal composer. One short workflow, duplex at the center:
/// drop a file → quick one-tap options (paper / color / quality) →
/// Print fronts → flip the stack once → done.
@MainActor
struct ComposerView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DocumentSection(model: model)

            if model.selectedDocument != nil {
                sectionBreak

                DuplexHeroCard(model: model)

                sectionBreak

                QuickOptionsRow(model: model)

                MoreSettingsDisclosure(model: model)
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
            .padding(.vertical, 10)
    }
}

// MARK: - Duplex hero

/// The centerpiece, kept compact: what two-sided printing means here and the
/// one physical action it needs, with the calibration entry point.
@MainActor
private struct DuplexHeroCard: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            FlipIconMedallion(systemName: "arrow.triangle.2.circlepath", tint: FlipColor.coralDeep, size: 26)
            VStack(alignment: .leading, spacing: 4) {
                Text(L("Two-sided printing"))
                    .font(FlipType.bodyStrong)
                    .foregroundStyle(FlipColor.ink)
                HStack(spacing: 5) {
                    FlipMetaChip(
                        systemName: model.preferences.flipAxis.symbolName,
                        text: String(format: L("%@ flip"), model.preferences.flipAxis.label)
                    )
                    FlipMetaChip(
                        systemName: model.preferences.ejectsFaceDown ? "arrow.down" : "arrow.up",
                        text: model.preferences.ejectsFaceDown ? L("Face-down tray") : L("Face-up tray")
                    )
                }
            }
            Spacer(minLength: 0)
            Button {
                model.openFlipAxisSetup()
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(FlipIconButtonStyle(size: 28))
            .help(model.preferences.hasConfiguredFlip ? "Edit flip setup" : "Set up flip")
            .accessibilityLabel(model.preferences.hasConfiguredFlip ? "Edit flip setup" : "Set up flip")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(FlipGlassCard())
        .accessibilityElement(children: .contain)
    }
}

/// First job with a printer: one generic sheet, two answers, then duplex is
/// automatic. Calibration flow is shared with the advanced version.
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
                    Text(String(format: L("FlipStack prints a generic orientation sheet so it can learn how %@ stacks paper. Your document is not used."), printerName))
                        .font(FlipType.caption)
                        .foregroundStyle(FlipColor.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineSpacing(1)
                }
                Spacer(minLength: 0)
            }

            Button {
                model.beginGuidedSetup()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "printer")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Print setup sheet")
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(FlipPrimaryButtonStyle())
            .disabled(model.isCalibrating || !model.orchestrator.phase.isIdle)

            Button("Set up manually") {
                model.openFlipAxisSetup()
            }
            .buttonStyle(FlipTertiaryButtonStyle())
            .frame(minHeight: 36)
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
}

private struct FirstFlipGuide: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FlipSectionHeader("How it works")
            Text(L("Drop a file, print the fronts, flip the whole stack once, and the backs print in order. Nothing is shuffled or reversed."))
                .font(FlipType.footnote)
                .foregroundStyle(FlipColor.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(1)
        }
    }
}

// MARK: - Quick options (always visible, one tap)

/// The choices people actually change: paper, color, quality. Always visible,
/// segmented or chip — no digging.
@MainActor
private struct QuickOptionsRow: View {
    @ObservedObject var model: AppModel

    private var isBusy: Bool { model.isPreparingPrint }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            // Paper + media as menu chips
            HStack(spacing: 6) {
                if let option = model.paperSizeOption {
                    optionChip(label: L("Paper"), value: model.selectedPaperLabel.map(L) ?? L("System default"), option: option)
                }
                if let option = model.mediaTypeOption {
                    optionChip(label: L("Media"), value: model.selectedMediaLabel.map(L) ?? L("Driver default"), option: option)
                }
                Spacer(minLength: 0)
            }

            // Color as a segmented control
            if model.supportsColorModeToggle {
                HStack(spacing: 6) {
                    Image(systemName: "circle.lefthalf.filled")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(FlipColor.tertiaryInk)
                    FlipSegmentedPicker(
                        labels: [L("Color"), L("B&W")],
                        selectedIndex: Binding(
                            get: { model.isGrayscaleSelected ? 1 : 0 },
                            set: { _ in }
                        ),
                        accessibilityLabels: [L("Color"), L("Black and white")],
                        onChange: { index in model.setGrayscale(index == 1) }
                    )
                    .disabled(isBusy)
                    Spacer(minLength: 0)
                }
            }

            // Quality as a segmented control
            if !model.qualityPresets.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "speedometer")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(FlipColor.tertiaryInk)
                    FlipSegmentedPicker(
                        labels: model.qualityPresets.map(\.title),
                        selectedIndex: Binding(
                            get: {
                                guard let active = model.activeQualityPreset else { return -1 }
                                return model.qualityPresets.firstIndex { $0 == active } ?? -1
                            },
                            set: { _ in }
                        ),
                        onChange: { index in
                            guard index >= 0, index < model.qualityPresets.count else { return }
                            model.applyQualityPreset(model.qualityPresets[index])
                        }
                    )
                    .disabled(isBusy)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func optionChip(label: String, value: String, option: PPDOption) -> some View {
        Menu {
            ForEach(option.choices) { choice in
                Button {
                    model.setValue(choice.keyword, for: option)
                } label: {
                    if choice.keyword == model.selectedValue(for: option) {
                        Label(L(choice.displayLabel), systemImage: "checkmark")
                    } else {
                        Text(L(choice.displayLabel))
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(label)
                    .font(.system(size: 8, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(FlipColor.tertiaryInk)
                Text(value)
                    .font(.system(.caption2, design: .default, weight: .semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 6.5, weight: .bold))
                    .foregroundStyle(FlipColor.tertiaryInk)
            }
            .foregroundStyle(FlipColor.secondaryInk)
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(Capsule().fill(FlipColor.tone))
            .overlay(Capsule().strokeBorder(FlipColor.hairline, lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .disabled(isBusy)
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }
}

// MARK: - More settings (secondary, collapsed)

@MainActor
private struct MoreSettingsDisclosure: View {
    @ObservedObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = false
    @FocusState private var isPageRangeFocused: Bool

    private var isBusy: Bool { model.isPreparingPrint }

    private var summary: String {
        let selection = model.pageSelectionInfo
        var parts: [String] = [selection.isValid ? selection.summary : L("Check the page range")]
        parts.append(model.pageOrientation.label)
        parts.append(model.fitToPage ? L("Fit to page") : "\(model.scalePercent)%")
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                guard !isBusy else { return }
                withAnimation(FlipMotion.quick(reduceMotion)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(FlipColor.tertiaryInk)
                    Text(L("More settings"))
                        .font(.system(.caption2, design: .default, weight: .semibold))
                        .foregroundStyle(FlipColor.secondaryInk)
                    Text(summary)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(FlipColor.tertiaryInk)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 6.5, weight: .bold))
                        .foregroundStyle(FlipColor.tertiaryInk)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .padding(.horizontal, 9)
                .frame(height: 26)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isBusy)
            .accessibilityLabel("More settings")
            .accessibilityValue(summary)

            if isExpanded {
                VStack(alignment: .leading, spacing: 9) {
                    pageSelectionRow
                    orientationScaleRow
                    if !model.extraDriverOptions.isEmpty {
                        extraDriverOptions
                    }
                }
                .padding(.top, 8)
                .transition(.opacity)
            }
        }
        .animation(FlipMotion.quick(reduceMotion), value: isExpanded)
    }

    private var pageSelectionRow: some View {
        let selection = model.pageSelectionInfo
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(L("Pages"))
                    .font(FlipType.captionStrong)
                    .foregroundStyle(FlipColor.secondaryInk)
                Spacer(minLength: 4)
                FlipSegmentedPicker(
                    labels: PageSelectionMode.allCases.map(\.label),
                    selectedIndex: Binding(
                        get: { model.pageSelectionMode == .all ? 0 : 1 },
                        set: { _ in }
                    ),
                    accessibilityLabels: [L("All pages"), L("Selected pages")],
                    onChange: { index in
                        model.pageSelectionMode = PageSelectionMode.allCases[index]
                        if PageSelectionMode.allCases[index] == .range {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                                isPageRangeFocused = true
                            }
                        }
                    }
                )
                .disabled(isBusy)
                Text(selection.summary)
                    .font(.system(.caption, design: .rounded, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(selection.isValid ? FlipColor.secondaryInk : FlipColor.danger)
                    .lineLimit(1)
            }

            if model.pageSelectionMode == .range {
                HStack(spacing: 7) {
                    Image(systemName: "number")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(FlipColor.tertiaryInk)
                    TextField(L("For example 1–4, 7"), text: $model.pageRangeText)
                        .textFieldStyle(.plain)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(FlipColor.ink)
                        .focused($isPageRangeFocused)
                        .disabled(isBusy)
                        .onSubmit { isPageRangeFocused = false }
                        .accessibilityLabel("Page range")
                }
                .padding(.horizontal, 9)
                .frame(height: 29)
                .background(
                    RoundedRectangle(cornerRadius: FlipMetrics.smallRadius, style: .continuous)
                        .fill(FlipColor.tone)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: FlipMetrics.smallRadius, style: .continuous)
                        .strokeBorder(
                            selection.isValid ? (isPageRangeFocused ? FlipColor.coral : FlipColor.hairline)
                                : FlipColor.danger.opacity(0.7),
                            lineWidth: isPageRangeFocused ? 1 : 0.5
                        )
                }

                if let message = selection.message, !selection.isValid {
                    Text(message)
                        .font(FlipType.caption)
                        .foregroundStyle(FlipColor.danger)
                }
            }
        }
    }

    private var orientationScaleRow: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(L("Orientation"))
                    .font(FlipType.captionStrong)
                    .foregroundStyle(FlipColor.secondaryInk)
                Spacer(minLength: 4)
                FlipSegmentedPicker(
                    labels: PageOrientationChoice.allCases.map(\.label),
                    selectedIndex: Binding(
                        get: { PageOrientationChoice.allCases.firstIndex(of: model.pageOrientation) ?? 0 },
                        set: { _ in }
                    ),
                    height: 23,
                    font: .system(size: 9, weight: .semibold),
                    onChange: { index in
                        model.pageOrientation = PageOrientationChoice.allCases[index]
                    }
                )
                .disabled(isBusy)
            }

            HStack(spacing: 8) {
                Text(L("Scale"))
                    .font(FlipType.captionStrong)
                    .foregroundStyle(FlipColor.secondaryInk)
                Spacer(minLength: 4)
                FlipScaleStepper(model: model)
                    .disabled(isBusy)
            }
        }
    }

    private var extraDriverOptions: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(model.extraDriverOptions) { option in
                HStack(spacing: 6) {
                    Text(option.displayLabel)
                        .font(FlipType.captionStrong)
                        .foregroundStyle(FlipColor.secondaryInk)
                    Spacer(minLength: 4)
                    Menu {
                        ForEach(option.choices) { choice in
                            Button {
                                model.setValue(choice.keyword, for: option)
                            } label: {
                                if choice.keyword == model.selectedValue(for: option) {
                                    Label(L(choice.displayLabel), systemImage: "checkmark")
                                } else {
                                    Text(L(choice.displayLabel))
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(option.choice(keyword: model.selectedValue(for: option))?.displayLabel ?? L("Driver default"))
                                .font(.system(.caption2, design: .default, weight: .semibold))
                                .lineLimit(1)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 6.5, weight: .bold))
                        }
                        .foregroundStyle(FlipColor.secondaryInk)
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .background(Capsule().fill(FlipColor.tone))
                        .overlay(Capsule().strokeBorder(FlipColor.hairline, lineWidth: 0.5))
                        .contentShape(Capsule())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .disabled(isBusy)
                }
            }
        }
    }
}

// MARK: - Sticky action bar

@MainActor
struct ComposerActionBar: View {
    @ObservedObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var needsCalibration: Bool {
        guard model.selectedDocument != nil,
              !model.preferences.hasConfiguredFlip else { return false }
        return model.pageSelectionInfo.pageCount > 1
    }

    private var actionTitle: String {
        if needsCalibration { return L("Set up flip and print") }
        return model.pageSelectionInfo.pageCount == 1 ? L("Print page") : L("Print fronts")
    }

    private var sheetCount: Int? {
        guard model.selectedDocument != nil else { return nil }
        let pages = model.pageSelectionInfo.pageCount
        guard pages > 0 else { return nil }
        return Int(ceil(Double(pages) / 2.0))
    }

    private var detailLine: String? {
        if needsCalibration {
            return L("One setup sheet first. Answer two questions, then your document prints.")
        }
        guard let sheets = sheetCount else { return nil }
        let selectedPrefix = model.pageSelectionMode == .range
            ? "\(model.pageSelectionInfo.summary) · "
            : ""
        if model.pageSelectionInfo.pageCount == 1 {
            return String(format: L("%@1 sheet · one page, so no flip is needed."), selectedPrefix)
        }
        return String(format: L("%@%@ · fronts first, flip the stack once, then the backs."), selectedPrefix, FlipFormat.sheets(sheets))
    }

    var body: some View {
        VStack(spacing: 0) {
            FlipHairline()
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
                            Image(systemName: "printer")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        Text(model.isPreparingPrint ? L("Preparing…") : actionTitle)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        if model.canPrint {
                            Image(systemName: "arrow.right")
                                .font(.system(size: 11, weight: .semibold))
                                .opacity(0.7)
                        }
                    }
                }
                .buttonStyle(FlipPrimaryButtonStyle())
                .disabled(!model.canPrint)
                .keyboardShortcut(.defaultAction)
                .accessibilityLabel(model.isPreparingPrint ? "Preparing print job" : actionTitle)
                .accessibilityHint(detailLine ?? "Starts printing. Command-P also works.")

                if let detailLine {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "arrow.triangle.2.circlepath")
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
            .padding(.horizontal, FlipMetrics.gutter)
            .padding(.top, 10)
            .padding(.bottom, 10)
        }
        .background {
            ZStack {
                Rectangle().fill(.thickMaterial)
                Rectangle().fill(Color.primary.opacity(0.012))
            }
        }
        .animation(FlipMotion.standard(reduceMotion), value: model.isPreparingPrint)
    }
}
