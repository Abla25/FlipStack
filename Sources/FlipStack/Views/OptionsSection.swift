import FlipStackCore
import SwiftUI

// MARK: - Mode

@MainActor
struct ModeSection: View {
    @ObservedObject var model: AppModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isBusy: Bool { model.isPreparingPrint }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            FlipSectionHeader("Mode") {
                if model.mode == .booklet {
                    Text("LONG-EDGE FLIP")
                        .font(.system(size: 7.5, weight: .semibold))
                        .tracking(1.1)
                        .foregroundStyle(FlipColor.tertiaryInk)
                }
            }

            modeSwitch

            Group {
                if model.mode == .booklet {
                    bookletDetails
                } else if model.mode == .singleSided {
                    singleSidedDetails
                } else {
                    duplexDetails
                }
            }
            .transition(.opacity)
        }
        .animation(FlipMotion.standard(reduceMotion), value: model.mode)
    }

    private var singleSidedDetails: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                FlipMetaChip(systemName: "doc.text", text: "One side")
                FlipMetaChip(systemName: "arrow.turn.down.right", text: "No flip")
                Spacer(minLength: 0)
            }
            Text("Every selected page prints once. Use this for everyday documents, envelopes, and labels.")
                .font(FlipType.footnote)
                .foregroundStyle(FlipColor.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(1)
        }
    }

    private var modeSwitch: some View {
        FlipSegmentedPicker(
            labels: PrintMode.allCases.map(\.label),
            selectedIndex: Binding(
                get: { PrintMode.allCases.firstIndex(of: model.mode) ?? 0 },
                set: { _ in }
            ),
            height: 31,
            font: .system(.footnote, design: .default, weight: .semibold),
            accessibilityLabels: PrintMode.allCases.map(\.label),
            onChange: { index in
                guard !isBusy else { return }
                withAnimation(FlipMotion.standard(reduceMotion)) {
                    model.mode = PrintMode.allCases[index]
                }
            }
        )
        .disabled(isBusy)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("Mode"))
    }

    // MARK: Booklet

    private var bookletDetails: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text("Signature size")
                    .font(FlipType.captionStrong)
                    .foregroundStyle(FlipColor.secondaryInk)
                Spacer()
                Text(
                    model.bookletSignatureSheets == 0 && model.bookletPlan != nil
                    ? String(format: L("Auto · %lld sheets"), model.bookletPlan?.signatureSheetCount ?? 0)
                    : L("Sheets per signature")
                )
                .font(FlipType.caption)
                .foregroundStyle(FlipColor.secondaryInk)
                .lineLimit(1)
            }

            HStack(spacing: 5) {
                ForEach(SignatureChoice.all) { choice in
                    signatureChip(choice)
                }
            }

            if let plan = model.bookletPlan {
                planMetrics(plan)

                FlipHintLine(
                    systemName: "book.closed",
                    text: "\(plan.foldHint) \(plan.stapleHint)"
                )

                if plan.hasBlankPages {
                    FlipHintLine(
                        systemName: "doc.text",
                        text: String(
                            format: L("%@ don’t fill the last signature, so %lld blank pages will be added."),
                            FlipFormat.pages(plan.sourcePageCount),
                            blankCount(plan)
                        ),
                        tint: FlipColor.warning
                    )
                }
            } else if model.selectedDocument == nil {
                Text("Choose a document to see the imposition plan.")
                    .font(FlipType.footnote)
                    .foregroundStyle(FlipColor.secondaryInk)
            } else if model.isPreparingPrint {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text("Working out the signatures…")
                        .font(FlipType.footnote)
                        .foregroundStyle(FlipColor.secondaryInk)
                }
            } else {
                Text("The booklet plan will appear here.")
                    .font(FlipType.footnote)
                    .foregroundStyle(FlipColor.tertiaryInk)
            }
        }
    }

    private func signatureChip(_ choice: SignatureChoice) -> some View {
        let isSelected = model.bookletSignatureSheets == choice.value
        return Button {
            guard !isBusy, !isSelected else { return }
            withAnimation(FlipMotion.quick(reduceMotion)) {
                model.bookletSignatureSheets = choice.value
            }
        } label: {
            Text(choice.label)
                .font(.system(.footnote, design: .rounded, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(isSelected ? FlipColor.onCoral : FlipColor.secondaryInk)
                .frame(maxWidth: .infinity)
                .frame(height: 29)
                .background(
                    RoundedRectangle(cornerRadius: FlipMetrics.smallRadius, style: .continuous)
                        .fill(isSelected ? FlipColor.coral : FlipColor.tone)
                )
                .overlay {
                    if !isSelected {
                        RoundedRectangle(cornerRadius: FlipMetrics.smallRadius, style: .continuous)
                            .strokeBorder(FlipColor.hairline, lineWidth: 0.5)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .accessibilityLabel(choice.value == 0 ? "Automatic signature size" : "\(choice.value) sheets per signature")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint("Sets how many sheets are folded together in one signature.")
    }

    private func planMetrics(_ plan: BookletPlan) -> some View {
        HStack(spacing: 14) {
            FlipMetric(value: "\(plan.sheetCount)", label: "Sheets")
            metricDivider
            FlipMetric(value: "\(plan.signatureCount)", label: plan.signatureCount == 1 ? "Signature" : "Signatures")
            metricDivider
            FlipMetric(value: "\(blankCount(plan))", label: "Blanks")
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .contain)
    }

    private var metricDivider: some View {
        Rectangle()
            .fill(FlipColor.hairline)
            .frame(width: 0.5, height: 25)
    }

    private func blankCount(_ plan: BookletPlan) -> Int {
        max(0, plan.paddedPageCount - plan.sourcePageCount)
    }

    // MARK: Duplex

    private var duplexDetails: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                FlipMetaChip(
                    systemName: model.preferences.flipAxis.symbolName,
                    text: String(format: L("%@ flip"), model.preferences.flipAxis.label)
                )
                FlipMetaChip(
                    systemName: model.preferences.ejectsFaceDown ? "arrow.down" : "arrow.up",
                    text: model.preferences.ejectsFaceDown ? L("Face-down tray") : L("Face-up tray")
                )
                Spacer(minLength: 0)
                Button {
                    model.openFlipAxisSetup()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 8, weight: .semibold))
                        Text(model.preferences.hasConfiguredFlip ? L("Edit") : L("Set up"))
                    }
                }
                .buttonStyle(FlipTertiaryButtonStyle())
                .disabled(isBusy)
                .accessibilityLabel(model.preferences.hasConfiguredFlip ? "Edit flip setup" : "Set up flip")
                .accessibilityHint("Opens the flip axis and tray setup inline.")
            }

            if !model.isShowingQueue, !model.preferences.hasConfiguredFlip {
                Text("Tell FlipStack how this printer stacks pages before the first job.")
                    .font(FlipType.footnote)
                    .foregroundStyle(FlipColor.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(1)
            }
        }
    }
}

private struct SignatureChoice: Identifiable {
    let id: Int
    let value: Int
    let label: String

    static let all: [SignatureChoice] = [
        SignatureChoice(id: 0, value: 0, label: "Auto"),
        SignatureChoice(id: 2, value: 2, label: "2"),
        SignatureChoice(id: 3, value: 3, label: "3"),
        SignatureChoice(id: 4, value: 4, label: "4")
    ]
}

// MARK: - Driver options

@MainActor
struct OutputSection: View {
    @ObservedObject var model: AppModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expandedOptionKeyword: String?
    @State private var isOptionsExpanded = false
    @State private var expandedSetupPicker: SetupPicker?
    @FocusState private var isPageRangeFocused: Bool

    /// Which in-panel popover list is open inside the page-setup card.
    private enum SetupPicker: Equatable {
        case paper
        case media
        case profile(String)
    }

    private func setupOption(for picker: SetupPicker) -> PPDOption? {
        switch picker {
        case .paper:
            return model.paperSizeOption
        case .media:
            return model.mediaTypeOption
        case .profile(let keyword):
            return model.colorProfileOptions.first { $0.keyword == keyword }
        }
    }

    private func toggleSetupPicker(_ picker: SetupPicker) {
        guard !isBusy else { return }
        withAnimation(FlipMotion.quick(reduceMotion)) {
            expandedSetupPicker = expandedSetupPicker == picker ? nil : picker
        }
    }

    /// A paper/media/profile value button that opens the in-panel choice list
    /// instead of a system menu, keeping the popover feel consistent.
    private func setupPickerButton(
        label: String,
        font: Font,
        tint: Color = FlipColor.ink,
        isExpanded: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(label)
                    .font(font)
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(FlipColor.tertiaryInk)
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
    }

    private var isBusy: Bool { model.isPreparingPrint }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            FlipSectionHeader("Output") {
                if model.isLoadingPPD {
                    ProgressView()
                        .controlSize(.mini)
                        .accessibilityLabel("Reading driver options")
                }
                if model.mode.isTwoPass {
                    Text("1 copy at a time")
                        .font(FlipType.caption)
                        .foregroundStyle(FlipColor.secondaryInk)
                        .lineLimit(1)
                        .help("Two-sided jobs print one copy at a time so every back stays aligned.")
                        .accessibilityLabel("Copies")
                        .accessibilityValue("1. Two-sided jobs print one copy at a time.")
                } else {
                    copiesStepper
                }
            }

            pageSetupCard

            pageSelectionControl

            if model.supportsColorModeToggle {
                colorModeControl
            }

            if !model.qualityPresets.isEmpty {
                qualityPresetControl
            }

            if !model.colorProfileOptions.isEmpty {
                ForEach(model.colorProfileOptions) { profileOption in
                    colorProfileControl(profileOption)
                }
            }

            if !model.extraDriverOptions.isEmpty {
                driverOptionsSummary

                if isOptionsExpanded {
                    VStack(spacing: 6) {
                        ForEach(model.extraDriverOptions) { option in
                            DriverOptionChip(
                                option: option,
                                selectedKeyword: model.selectedValue(for: option),
                                isExpanded: expandedOptionKeyword == option.keyword
                            ) {
                                toggleExpanded(option)
                            }

                            if expandedOptionKeyword == option.keyword {
                                DriverChoiceList(
                                    option: option,
                                    selectedKeyword: model.selectedValue(for: option),
                                    onSelect: { model.setValue($0, for: option) },
                                    onClose: { toggleExpanded(option) }
                                )
                            }
                        }
                    }
                    .transition(.opacity)
                }
            }

            if model.ppd == nil, !model.isLoadingPPD {
                driverNote
            } else if model.isLoadingPPD {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text("Reading the printer driver…")
                        .font(FlipType.footnote)
                        .foregroundStyle(FlipColor.secondaryInk)
                }
            }
        }
        .onChange(of: model.selectedPrinter?.id) { _ in
            expandedOptionKeyword = nil
            isOptionsExpanded = false
            expandedSetupPicker = nil
        }
    }

    private var driverOptionsSummary: some View {
        Button {
            guard !isBusy else { return }
            withAnimation(FlipMotion.quick(reduceMotion)) {
                isOptionsExpanded.toggle()
                if !isOptionsExpanded { expandedOptionKeyword = nil }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(FlipColor.tertiaryInk)
                Text(driverOptionSummaryText)
                    .font(FlipType.caption)
                    .foregroundStyle(FlipColor.secondaryInk)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(FlipColor.tertiaryInk)
                    .rotationEffect(.degrees(isOptionsExpanded ? 180 : 0))
            }
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: FlipMetrics.smallRadius, style: .continuous)
                    .fill(FlipColor.tone)
            )
            .overlay {
                RoundedRectangle(cornerRadius: FlipMetrics.smallRadius, style: .continuous)
                    .strokeBorder(FlipColor.hairline, lineWidth: 0.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .accessibilityLabel("Driver options")
        .accessibilityValue(driverOptionSummaryText)
        .accessibilityHint(isOptionsExpanded ? "Collapses the driver option pickers." : "Shows color, paper, media, and quality options from the printer driver.")
    }

    private var driverOptionSummaryText: String {
        let values = model.extraDriverOptions.compactMap { option -> String? in
            let keyword = model.selectedValue(for: option)
            guard !keyword.isEmpty else { return nil }
            return option.choice(keyword: keyword)?.displayLabel ?? keyword
        }
        return values.isEmpty
            ? L("Driver defaults")
            : "\(model.extraDriverOptions.count) · " + values.joined(separator: " · ")
    }

    private var expandedOption: PPDOption? {
        guard let keyword = expandedOptionKeyword else { return nil }
        return model.driverOptions.first(where: { $0.keyword == keyword })
    }

    private func toggleExpanded(_ option: PPDOption) {
        guard !isBusy else { return }
        withAnimation(FlipMotion.standard(reduceMotion)) {
            expandedOptionKeyword = expandedOptionKeyword == option.keyword ? nil : option.keyword
        }
    }

    private var driverNote: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(FlipColor.tertiaryInk)
                .frame(width: 13, height: 14, alignment: .top)
            Text(
                model.ppdNote
                ?? (model.ppd == nil
                    ? "No driver options are reported for this queue. System defaults will be used."
                    : "This driver reports no adjustable color, paper, media or quality options.")
            )
            .font(FlipType.footnote)
            .foregroundStyle(FlipColor.secondaryInk)
            .fixedSize(horizontal: false, vertical: true)
            .lineSpacing(1)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Copies

    private var pageSelectionControl: some View {
        let selection = model.pageSelectionInfo
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Pages")
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
                        let option = PageSelectionMode.allCases[index]
                        guard !isBusy else { return }
                        model.pageSelectionMode = option
                        if option == .range {
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
                    .frame(minWidth: 74, alignment: .trailing)
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
                        .accessibilityHint("Enter page numbers and ranges separated by commas.")
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
                        .padding(.leading, 2)
                        .accessibilityLabel("Page range error, \(message)")
                }
            }
        }
        .animation(FlipMotion.quick(reduceMotion), value: model.pageSelectionMode)
    }

    private var qualityPresetControl: some View {
        let items = model.qualityPresetItems
        return HStack(spacing: 5) {
            Text("Quality")
                .font(FlipType.captionStrong)
                .foregroundStyle(FlipColor.secondaryInk)
                .lineLimit(1)

            if model.activePresetItem == nil {
                Text("Custom")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(FlipColor.tertiaryInk)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            FlipSegmentedPicker(
                labels: items.map(\.title),
                selectedIndex: Binding(
                    get: {
                        guard let active = model.activePresetItem else { return -1 }
                        return items.firstIndex { $0.id == active.id } ?? -1
                    },
                    set: { _ in }
                ),
                onChange: { index in
                    guard index >= 0, index < items.count else { return }
                    withAnimation(FlipMotion.quick(reduceMotion)) {
                        model.applyQualityPresetItem(items[index])
                    }
                }
            )
            .help(model.qualityPresets.map(\.detail).joined(separator: "\n"))
        }
        .disabled(isBusy)
        .help("Quality is independent of Color / B&W. Choosing a quality preset never switches the print back to color.")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Print quality")
        .accessibilityValue(model.activeQualityPreset?.title ?? "Custom driver settings")
    }

    private var colorModeControl: some View {
        HStack(spacing: 8) {
            Text("Color")
                .font(FlipType.captionStrong)
                .foregroundStyle(FlipColor.secondaryInk)

            Spacer(minLength: 4)

            FlipSegmentedPicker(
                labels: [L("Color"), L("B&W")],
                selectedIndex: Binding(
                    get: { model.isGrayscaleSelected ? 1 : 0 },
                    set: { _ in }
                ),
                accessibilityLabels: [L("Color"), L("Black and white")],
                onChange: { index in
                    guard !isBusy else { return }
                    withAnimation(FlipMotion.quick(reduceMotion)) {
                        model.setGrayscale(index == 1)
                    }
                }
            )
            .help(L("Sets the color mode exposed by this printer driver."))
        }
        .disabled(isBusy)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Color mode")
        .accessibilityValue(model.isGrayscaleSelected ? "Black and white" : "Color")
    }

    private func colorProfileControl(_ option: PPDOption) -> some View {
        let selected = model.selectedValue(for: option)
        let selectedLabel = option.choice(keyword: selected)?.displayLabel ?? L("Driver default")
        let isExpanded = expandedSetupPicker == .profile(option.keyword)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(option.displayLabel)
                    .font(FlipType.captionStrong)
                    .foregroundStyle(FlipColor.secondaryInk)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 4)

                Button {
                    toggleSetupPicker(.profile(option.keyword))
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "circle.lefthalf.filled")
                            .font(.system(size: 8, weight: .semibold))
                        Text(selectedLabel)
                            .font(.system(.caption2, design: .default, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 6.5, weight: .bold))
                            .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    }
                    .foregroundStyle(FlipColor.secondaryInk)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(Capsule().fill(FlipColor.tone))
                    .overlay(Capsule().strokeBorder(FlipColor.hairline, lineWidth: 0.5))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isBusy)
                .help("Color profile exposed by this printer driver.")
                .accessibilityLabel("\(option.displayLabel) color profile")
                .accessibilityValue(selectedLabel)
                .accessibilityHint("Chooses the color profile provided by this printer driver.")
            }

            if isExpanded {
                DriverChoiceList(
                    option: option,
                    selectedKeyword: selected,
                    onSelect: { model.setValue($0, for: option) },
                    onClose: { expandedSetupPicker = nil }
                )
                .transition(.opacity)
            }
        }
    }

    /// The page facts come first, like a print panel: the PDF's own size, the
    /// paper the queue will feed, then orientation, scale, and media.
    private var pageSetupCard: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                if model.mode != .booklet {
                    FlipSheetDiagram(
                        sheetSize: model.previewSheetSize,
                        contentSize: model.previewContentSize,
                        contentScale: model.previewContentScale,
                        contentRotation: model.previewContentRotation,
                        imageableArea: model.selectedImageableArea,
                        height: 56
                    )
                    .frame(width: 44)
                    .help("The paper sheet with your page scaled inside it, exactly as it will print.")
                }

                VStack(alignment: .leading, spacing: 3) {
                    FlipEyebrow("PDF page", color: FlipColor.tertiaryInk)
                    Text(model.documentPageSizeText ?? L("No document"))
                        .font(FlipType.footnoteStrong)
                        .foregroundStyle(FlipColor.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    if let document = model.selectedDocument {
                        Text("\(document.isLandscape ? L("Landscape") : L("Portrait")) · \(document.formattedPageCount)")
                            .font(FlipType.caption)
                            .foregroundStyle(FlipColor.tertiaryInk)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    "PDF page, \(model.documentPageSizeText ?? "no document"), \(model.selectedDocument?.isLandscape == true ? "landscape" : "portrait")"
                )

                Image(systemName: "arrow.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(FlipColor.tertiaryInk)
                    .padding(.top, 16)
                    .accessibilityHidden(true)

                VStack(alignment: .trailing, spacing: 3) {
                    FlipEyebrow("Paper", color: FlipColor.tertiaryInk)
                    if model.paperSizeOption != nil {
                        setupPickerButton(
                            label: model.selectedPaperLabel.map(L) ?? L("System default"),
                            font: FlipType.footnoteStrong,
                            isExpanded: expandedSetupPicker == .paper
                        ) {
                            toggleSetupPicker(.paper)
                        }
                        .help("Paper size reported by this printer driver.")
                        .accessibilityLabel("Paper size")
                        .accessibilityValue(model.selectedPaperLabel ?? "System default")
                    } else {
                        Text("System default")
                            .font(FlipType.footnoteStrong)
                            .foregroundStyle(FlipColor.ink)
                            .lineLimit(1)
                    }
                    if model.mediaTypeOption != nil {
                        setupPickerButton(
                            label: model.selectedMediaLabel.map(L) ?? L("Driver default"),
                            font: FlipType.caption,
                            tint: FlipColor.tertiaryInk,
                            isExpanded: expandedSetupPicker == .media
                        ) {
                            toggleSetupPicker(.media)
                        }
                        .help("Media type reported by this printer driver.")
                        .accessibilityLabel("Media type")
                        .accessibilityValue(model.selectedMediaLabel ?? "Driver default")
                    } else if let media = model.selectedMediaLabel {
                        Text(L(media))
                            .font(FlipType.caption)
                            .foregroundStyle(FlipColor.tertiaryInk)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.horizontal, 11)
            .padding(.top, 10)

            if let picker = expandedSetupPicker, let option = setupOption(for: picker) {
                DriverChoiceList(
                    option: option,
                    selectedKeyword: model.selectedValue(for: option),
                    onSelect: { model.setValue($0, for: option) },
                    onClose: { expandedSetupPicker = nil }
                )
                .padding(.horizontal, 11)
                .padding(.top, 8)
                .transition(.opacity)
            }

            FlipHairline()
                .padding(.top, 9)

            if model.mode == .booklet {
                HStack(spacing: 6) {
                    Image(systemName: "book.closed")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(FlipColor.coralDeep)
                    Text("Imposed 2-up on landscape sheets. Fold and flip between passes.")
                        .font(FlipType.caption)
                        .foregroundStyle(FlipColor.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 11)
                .padding(.top, 9)
                .padding(.bottom, 10)
                .accessibilityElement(children: .combine)
            } else {
                HStack(spacing: 8) {
                    Text("Scale")
                        .font(FlipType.captionStrong)
                        .foregroundStyle(FlipColor.secondaryInk)
                    Spacer(minLength: 4)
                    FlipScaleStepper(model: model)
                }
                .padding(.horizontal, 11)
                .padding(.top, 9)

                HStack(spacing: 5) {
                    Text("Orientation")
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
                            withAnimation(FlipMotion.quick(reduceMotion)) {
                                model.pageOrientation = PageOrientationChoice.allCases[index]
                            }
                        }
                    )
                    .help(L("Rotates pages on the paper. Match PDF uses each page's own orientation."))
                }
                .padding(.horizontal, 11)
                .padding(.top, 7)
                .padding(.bottom, 10)
            }
        }
        .background(FlipGlassCard(radius: FlipMetrics.compactRadius))
        .disabled(isBusy)
        .accessibilityElement(children: .contain)
    }

    private var copiesStepper: some View {
        let allowsMultipleCopies = model.mode == .singleSided
        return HStack(spacing: 5) {
            Text("Copies")
                .font(FlipType.caption)
                .foregroundStyle(FlipColor.tertiaryInk)

            HStack(spacing: 0) {
                Button {
                    withAnimation(FlipMotion.quick(reduceMotion)) {
                        model.copies = max(1, model.copies - 1)
                    }
                } label: {
                    Image(systemName: "minus")
                        .font(.system(size: 8, weight: .bold))
                        .frame(width: 23, height: 23)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(model.copies > 1 ? FlipColor.secondaryInk : FlipColor.tertiaryInk)
                .disabled(model.copies <= 1 || isBusy || !allowsMultipleCopies)
                .accessibilityLabel("Decrease copies")

                Text("\(model.copies)")
                    .font(.system(.caption, design: .rounded, weight: .semibold))
                    .foregroundStyle(FlipColor.ink)
                    .monospacedDigit()
                    .frame(minWidth: 21)

                Button {
                    withAnimation(FlipMotion.quick(reduceMotion)) {
                        model.copies = min(20, model.copies + 1)
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 8, weight: .bold))
                        .frame(width: 23, height: 23)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(model.copies < 20 ? FlipColor.secondaryInk : FlipColor.tertiaryInk)
                .disabled(model.copies >= 20 || isBusy || !allowsMultipleCopies)
                .accessibilityLabel("Increase copies")
            }
            .padding(1)
            .background(Capsule(style: .continuous).fill(FlipColor.tone))
            .overlay(Capsule(style: .continuous).strokeBorder(FlipColor.hairline, lineWidth: 0.5))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Copies")
            .accessibilityValue("\(model.copies)")
            .accessibilityHint(
                allowsMultipleCopies
                ? "Adjust from 1 to 20 copies."
                : "Two-sided jobs print one copy at a time to keep the sheet order correct."
            )
            .accessibilityAdjustableAction { direction in
                guard !isBusy, allowsMultipleCopies else { return }
                switch direction {
                case .increment:
                    model.copies = min(20, model.copies + 1)
                case .decrement:
                    model.copies = max(1, model.copies - 1)
                @unknown default:
                    break
                }
            }
            .help(allowsMultipleCopies ? "Number of copies" : "Two-sided jobs print one copy at a time so every back stays aligned.")
        }
    }
}

private struct DriverOptionChip: View {
    let option: PPDOption
    let selectedKeyword: String
    let isExpanded: Bool
    let action: () -> Void

    private var selectedLabel: String {
        option.choice(keyword: selectedKeyword)?.displayLabel
        ?? option.selectedDefault.flatMap { option.choice(keyword: $0)?.displayLabel }
        ?? "Default"
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Text(option.group.title.uppercased())
                    .font(.system(size: 8, weight: .semibold))
                    .tracking(1.05)
                    .foregroundStyle(FlipColor.tertiaryInk)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(selectedLabel)
                        .font(FlipType.footnoteStrong)
                        .foregroundStyle(FlipColor.ink)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 2)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7.5, weight: .semibold))
                        .foregroundStyle(isExpanded ? FlipColor.coralDeep : FlipColor.tertiaryInk)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: FlipMetrics.controlRadius, style: .continuous)
                    .fill(isExpanded ? FlipColor.coral.opacity(0.06) : FlipColor.tone)
            )
            .overlay {
                RoundedRectangle(cornerRadius: FlipMetrics.controlRadius, style: .continuous)
                    .strokeBorder(
                        isExpanded ? FlipColor.coral.opacity(0.35) : FlipColor.hairline,
                        lineWidth: isExpanded ? 0.8 : 0.5
                    )
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(option.group.title) driver option")
        .accessibilityValue("\(selectedLabel)\(isExpanded ? ", expanded" : "")")
        .accessibilityHint("Shows the values reported by this printer’s driver.")
    }
}

private struct DriverChoiceList: View {
    let option: PPDOption
    let selectedKeyword: String
    let onSelect: (String) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                FlipEyebrow(option.group.title)
                Text("· \(option.choices.count) \(option.choices.count == 1 ? "choice" : "choices")")
                    .font(FlipType.caption)
                    .foregroundStyle(FlipColor.tertiaryInk)
                Spacer(minLength: 4)
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(FlipColor.tertiaryInk)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
                .accessibilityLabel("Close \(option.group.title) choices")
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 4)

            VStack(spacing: 0) {
                ForEach(Array(option.choices.enumerated()), id: \.element.id) { index, choice in
                    let isSelected = choice.keyword == selectedKeyword
                    Button {
                        onSelect(choice.keyword)
                    } label: {
                        HStack(spacing: 6) {
                            Text(choice.displayLabel)
                                .font(isSelected ? FlipType.footnoteStrong : FlipType.footnote)
                                .foregroundStyle(FlipColor.ink)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            if isSelected {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(FlipColor.coralDeep)
                            }
                        }
                        .padding(.horizontal, 10)
                        .frame(minHeight: 27)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(choice.displayLabel)
                    .accessibilityValue(isSelected ? "Selected" : "Not selected")
                    .accessibilityAddTraits(isSelected ? .isSelected : [])

                    if index < option.choices.count - 1 {
                        FlipHairline()
                            .padding(.leading, 10)
                    }
                }
            }
            .padding(.bottom, 5)
        }
        .background(
            RoundedRectangle(cornerRadius: FlipMetrics.compactRadius, style: .continuous)
                .fill(FlipColor.paper.opacity(0.44))
        )
        .overlay {
            RoundedRectangle(cornerRadius: FlipMetrics.compactRadius, style: .continuous)
                .strokeBorder(FlipColor.hairline, lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
    }
}
