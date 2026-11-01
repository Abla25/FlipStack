import FlipStackCore
import SwiftUI

/// Minimal settings: just the interface language. Everything about the
/// print itself lives in the composer's Print settings disclosure.
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
                .keyboardShortcut(.defaultAction)
                .accessibilityHint("Closes settings and returns to the document.")
            }
            .padding(.bottom, 15)

            languageSection

            sectionBreak

            aboutSection
        }
        .padding(.bottom, 10)
    }

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
                    .background(Capsule().fill(selected ? FlipColor.onCoral.opacity(0.14) : FlipColor.tone))

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

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("About FlipStack")
                .font(FlipType.bodyStrong)
                .foregroundStyle(FlipColor.ink)
            Text("Guided two-sided printing for printers that can't turn a page themselves. Everything stays on this Mac.")
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
