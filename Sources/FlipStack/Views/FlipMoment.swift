import FlipStackCore
import SwiftUI

@MainActor
struct FlipWaitingView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var orchestrator: DuplexOrchestrator
    let prompt: FlipPrompt

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isFlipped = false
    @State private var isConfirming = false

    private var primaryTitle: String {
        prompt.mode == .reinsertOnly ? "I reinserted the stack" : "I flipped the sheets"
    }

    private var eyebrow: String {
        "Your turn · \(FlipFormat.sheets(prompt.sheetCount))"
    }

    private var currentProgress: Double {
        min(max(orchestrator.progress, 0), 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    FlipEyebrow(eyebrow, color: FlipColor.coralDeep)
                    Text(prompt.title)
                        .font(FlipType.displayLarge)
                        .foregroundStyle(FlipColor.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text(prompt.detail)
                        .font(FlipType.footnote)
                        .foregroundStyle(FlipColor.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineSpacing(1)
                }

                Spacer(minLength: 2)
                passMeter
            }

            FlipStackDiagram(
                sheetCount: prompt.sheetCount,
                axis: prompt.flipAxis,
                mode: prompt.mode,
                isFlipped: isFlipped,
                reduceMotion: reduceMotion
            )
            .frame(maxWidth: .infinity)
            .padding(.top, 1)

            // The exact instruction from the engine, never shortened.
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(FlipColor.coralDeep)
                    .frame(width: 13, height: 14, alignment: .top)
                Text(prompt.message)
                    .font(FlipType.footnote)
                    .foregroundStyle(FlipColor.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(1)
                Spacer(minLength: 0)
            }
            .padding(9)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(FlipColor.coral.opacity(0.07))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(FlipColor.coral.opacity(0.18), lineWidth: 0.5)
            }
            .accessibilityElement(children: .combine)

            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.octagon.fill")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(FlipColor.warning)
                Text("Do not reorder or reverse the pages.")
                    .font(FlipType.captionStrong)
                    .foregroundStyle(FlipColor.secondaryInk)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button {
                    model.cancelFlow()
                } label: {
                    Text("Cancel")
                        .font(FlipType.caption)
                        .foregroundStyle(FlipColor.secondaryInk)
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isConfirming)
                .accessibilityLabel("Cancel printing")
                .accessibilityHint("Stops the duplex job after the first pass.")
            }

            if let footnote = prompt.footnote {
                FlipHintLine(
                    systemName: "doc.text",
                    text: footnote,
                    tint: FlipColor.tertiaryInk
                )
            }

            Button {
                confirmFlip()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: prompt.mode == .reinsertOnly ? "arrow.down" : "arrow.triangle.2.circlepath")
                        .font(.system(size: 12, weight: .semibold))
                    Text(primaryTitle)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Spacer(minLength: 2)
                    if isConfirming {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(FlipColor.onCoral)
                    }
                }
            }
            .buttonStyle(FlipPrimaryButtonStyle())
            .disabled(isConfirming)
            .accessibilityHint(
                prompt.mode == .reinsertOnly
                ? "Confirms the stack is back in the printer and starts the backs."
                : "Confirms the stack was flipped as one block and starts the backs."
            )
            .accessibilityValue(isConfirming ? "Confirmed" : "Waiting for you")
            .padding(.top, 2)
        }
        .onChange(of: orchestrator.flipAnimationNonce) { _ in
            withAnimation(FlipMotion.stack(reduceMotion)) {
                isFlipped = true
            }
        }
    }

    // MARK: Pass meter

    private var passMeter: some View {
        let fronts = min(max(currentProgress / 0.5, 0), 1)
        let backs = min(max((currentProgress - 0.5) / 0.5, 0), 1)

        return VStack(alignment: .leading, spacing: 3) {
            DuplexProgressArc(progress: currentProgress, activePass: nil, compact: true)
            VStack(alignment: .leading, spacing: 2) {
                meterLegend("Fronts", fraction: fronts, strong: true)
                meterLegend("Backs", fraction: backs, strong: false)
            }
        }
        .frame(width: 78, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Pass progress")
        .accessibilityValue(
            "Fronts \(Int((fronts * 100).rounded())) percent. Backs \(Int((backs * 100).rounded())) percent."
        )
    }

    private func meterLegend(_ title: String, fraction: Double, strong: Bool) -> some View {
        HStack(spacing: 3) {
            Circle()
                .fill(FlipColor.coral.opacity(fraction > 0 ? (strong ? 1 : 0.62) : 0.14))
                .frame(width: 3, height: 3)
            Text(title.uppercased())
                .font(.system(size: 6.5, weight: .semibold))
                .tracking(0.7)
                .foregroundStyle(FlipColor.tertiaryInk)
            Spacer(minLength: 0)
            Text(FlipFormat.percent(fraction))
                .font(.system(size: 6.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(FlipColor.tertiaryInk)
        }
    }

    // MARK: Confirm choreography

    private func confirmFlip() {
        guard !isConfirming else { return }
        isConfirming = true

        withAnimation(FlipMotion.stack(reduceMotion)) {
            isFlipped = true
        }

        if reduceMotion {
            model.confirmFlip()
            return
        }

        Task {
            try? await Task.sleep(nanoseconds: 520_000_000)
            model.confirmFlip()
        }
    }
}
