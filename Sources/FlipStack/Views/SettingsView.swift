import FlipStackCore
import SwiftUI

@MainActor
struct SettingsView: View {
    @ObservedObject var model: AppModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    FlipEyebrow("Settings", color: FlipColor.coralDeep)
                    Text("Make FlipStack yours.")
                        .font(FlipType.displayLarge)
                        .foregroundStyle(FlipColor.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                }

                Spacer(minLength: 4)

                Button("Done") {
                    model.closeSettings()
                }
                .buttonStyle(FlipSecondaryButtonStyle())
                .frame(width: 86)
                .accessibilityHint("Closes settings and returns to the document.")
            }
            .padding(.bottom, 15)

            languageSection

            sectionBreak

            printerSection

            sectionBreak

            aboutSection
        }
        .padding(.bottom, 10)
    }

    // MARK: Language

    private var languageSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                FlipIconMedallion(systemName: "globe", tint: FlipColor.coralDeep, size: 25)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Language")
                        .font(FlipType.bodyStrong)
                        .foregroundStyle(FlipColor.ink)
                    Text("The app updates immediately. Your system language is the default.")
                        .font(FlipType.caption)
                        .foregroundStyle(FlipColor.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                spacing: 8
            ) {
                ForEach(AppLanguage.allCases) { language in
                    languageButton(language)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func languageButton(_ language: AppLanguage) -> some View {
        let selected = model.language == language
        return Button {
            withAnimation(FlipMotion.quick(reduceMotion)) {
                model.language = language
            }
        } label: {
            HStack(spacing: 8) {
                Text(language.shortCode)
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(selected ? FlipColor.onCoral : FlipColor.tertiaryInk)
                    .frame(width: 24, height: 20)
                    .background(
                        Capsule().fill(selected ? FlipColor.onCoral.opacity(0.14) : FlipColor.tone)
                    )

                Text(language.displayName)
                    .font(FlipType.footnoteStrong)
                    .foregroundStyle(selected ? FlipColor.onCoral : FlipColor.ink)
                    .lineLimit(1)

                Spacer(minLength: 0)

                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(FlipColor.onCoral)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 38)
            .background(
                RoundedRectangle(cornerRadius: FlipMetrics.smallRadius, style: .continuous)
                    .fill(selected ? FlipColor.coral : FlipColor.tone)
            )
            .overlay {
                RoundedRectangle(cornerRadius: FlipMetrics.smallRadius, style: .continuous)
                    .strokeBorder(selected ? Color.clear : FlipColor.hairline, lineWidth: 0.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(language.displayName)
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: Printer

    private var printerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                FlipIconMedallion(systemName: "slider.horizontal.3", tint: FlipColor.coralDeep, size: 25)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Printer quality presets")
                        .font(FlipType.bodyStrong)
                        .foregroundStyle(FlipColor.ink)
                    Text(
                        model.selectedPrinter.map {
                            String(format: L("Customize Eco, Standard, High, and Photo for %@."), $0.displayName)
                        } ?? L("Select a printer to customize its quality presets.")
                    )
                    .font(FlipType.caption)
                    .foregroundStyle(FlipColor.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            if model.selectedPrinter == nil {
                Text("No printer selected.")
                    .font(FlipType.footnote)
                    .foregroundStyle(FlipColor.tertiaryInk)
            } else if model.qualityTunableOptions.isEmpty {
                Text("This queue does not expose adjustable quality or media choices.")
                    .font(FlipType.footnote)
                    .foregroundStyle(FlipColor.tertiaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 9) {
                    ForEach(PrintQualityPreset.allCases) { preset in
                        qualityPresetCard(preset)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func qualityPresetCard(_ preset: PrintQualityPreset) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Text(preset.title)
                    .font(FlipType.bodyStrong)
                    .foregroundStyle(FlipColor.ink)
                if model.hasQualityOverride(preset) {
                    Text("CUSTOM")
                        .font(.system(size: 7, weight: .semibold))
                        .tracking(0.8)
                        .foregroundStyle(FlipColor.coralDeep)
                }
                Spacer(minLength: 4)
                if model.hasQualityOverride(preset) {
                    Button("Reset") {
                        withAnimation(FlipMotion.quick(reduceMotion)) {
                            model.resetQualityOverride(preset)
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(FlipColor.coralDeep)
                    .accessibilityHint(String(format: L("Restores the driver-based default for %@."), preset.title))
                }
            }

            ForEach(model.qualityTunableOptions) { option in
                qualityChoiceRow(preset: preset, option: option)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: FlipMetrics.compactRadius, style: .continuous)
                .fill(FlipColor.tone)
        )
        .overlay {
            RoundedRectangle(cornerRadius: FlipMetrics.compactRadius, style: .continuous)
                .strokeBorder(FlipColor.hairline, lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
    }

    private func qualityChoiceRow(preset: PrintQualityPreset, option: PPDOption) -> some View {
        let selected = model.effectiveQualityValue(for: preset, option: option)
        let label = option.choice(keyword: selected).map { L($0.displayLabel) } ?? L("Driver default")
        return HStack(spacing: 6) {
            Text(L(option.displayLabel))
                .font(FlipType.caption)
                .foregroundStyle(FlipColor.secondaryInk)
                .lineLimit(1)
            Spacer(minLength: 4)
            Menu {
                ForEach(option.choices) { choice in
                    Button {
                        model.setQualityOverride(choice.keyword, for: preset, option: option)
                    } label: {
                        if choice.keyword == selected {
                            Label(L(choice.displayLabel), systemImage: "checkmark")
                        } else {
                            Text(L(choice.displayLabel))
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(label)
                        .font(.system(.caption2, design: .default, weight: .semibold))
                        .foregroundStyle(FlipColor.secondaryInk)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 6.5, weight: .bold))
                        .foregroundStyle(FlipColor.tertiaryInk)
                }
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(
                    RoundedRectangle(cornerRadius: FlipMetrics.smallRadius, style: .continuous)
                        .fill(FlipColor.paper.opacity(0.55))
                )
                .overlay {
                    RoundedRectangle(cornerRadius: FlipMetrics.smallRadius, style: .continuous)
                        .strokeBorder(FlipColor.hairline, lineWidth: 0.5)
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(maxWidth: 190, alignment: .trailing)
            .accessibilityLabel("\(preset.title) \(option.displayLabel)")
            .accessibilityValue(label)
            .accessibilityHint(String(format: L("Choose a real value from this printer driver for the %@ preset."), preset.title))
        }
    }

    // MARK: About

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("About FlipStack")
                .font(FlipType.bodyStrong)
                .foregroundStyle(FlipColor.ink)
            Text("Manual duplex for simplex printers. Everything stays on this Mac.")
                .font(FlipType.caption)
                .foregroundStyle(FlipColor.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 5) {
                Text("Version")
                    .font(FlipType.caption)
                    .foregroundStyle(FlipColor.tertiaryInk)
                Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0")
                    .font(.system(.caption, design: .rounded, weight: .medium))
                    .foregroundStyle(FlipColor.secondaryInk)
            }
            .padding(.top, 2)
        }
        .accessibilityElement(children: .contain)
    }

    private var sectionBreak: some View {
        FlipHairline()
            .padding(.vertical, 15)
    }
}
