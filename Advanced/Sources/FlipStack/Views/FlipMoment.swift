import FlipStackCore
import SwiftUI

@MainActor
struct FlipWaitingView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var orchestrator: DuplexOrchestrator
    let prompt: FlipPrompt

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isFlipped = false

    private var eyebrow: String {
        String(format: L("Your turn · %@"), FlipFormat.sheets(prompt.sheetCount))
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

            FlipHeroScene(
                sheetCount: prompt.sheetCount,
                axis: prompt.flipAxis,
                mode: prompt.mode,
                isFlipped: isFlipped,
                reduceMotion: reduceMotion,
                isLandscape: model.isLandscapeStack
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
                RoundedRectangle(cornerRadius: FlipMetrics.compactRadius, style: .continuous)
                    .fill(FlipColor.coral.opacity(0.07))
            )
            .overlay {
                RoundedRectangle(cornerRadius: FlipMetrics.compactRadius, style: .continuous)
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
            }

            if let footnote = prompt.footnote {
                FlipHintLine(
                    systemName: "doc.text",
                    text: footnote,
                    tint: FlipColor.tertiaryInk
                )
            }
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
            Text(L(title).uppercased())
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

}

// MARK: - The hero moment

/// The flip prompt is the one physical moment the app cannot do for the user.
/// This scene makes it feel like the printer is presenting the stack: a quiet
/// custom printer body behind the paper block, with the block floating in front
/// and turning as one object.
@MainActor
private struct FlipHeroScene: View {
    let sheetCount: Int
    let axis: FlipAxis
    let mode: FlipMode
    let isFlipped: Bool
    let reduceMotion: Bool
    let isLandscape: Bool

    @ScaledMetric(relativeTo: .body) private var sceneHeight: CGFloat = 218
    @State private var glow = false

    var body: some View {
        ZStack {
            // Scene-level shadows, drawn before the object. Nothing inside the
            // printer or the paper block casts its own competing shadow.
            Ellipse()
                .fill(FlipColor.paperShadow.opacity(0.16))
                .frame(width: 248, height: 19)
                .blur(radius: 10)
                .offset(y: 85)

            Ellipse()
                .fill(FlipColor.paperShadow.opacity(0.32))
                .frame(width: 176, height: 13)
                .blur(radius: 5)
                .offset(y: 80)

            Circle()
                .strokeBorder(
                    FlipColor.ink.opacity(0.055),
                    style: StrokeStyle(lineWidth: 1, dash: [2, 7])
                )
                .frame(width: 168, height: 168)
                .offset(y: -26)

            Circle()
                .trim(from: 0.05, to: 0.27)
                .stroke(
                    FlipColor.coral.opacity(glow ? 0.72 : 0.36),
                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
                )
                .frame(width: 168, height: 168)
                .rotationEffect(.degrees(-94))
                .offset(y: -26)

            PrinterObject(hasPaper: false, isActive: true)
                .offset(y: -4)

            // The paper block is the one moving object. It sits in the output
            // slot and turns as a single physical stack.
            FlipStackDiagram(
                sheetCount: sheetCount,
                axis: axis,
                mode: mode,
                isFlipped: isFlipped,
                reduceMotion: reduceMotion,
                isLandscape: isLandscape,
                showsLabels: false,
                showsGroundShadow: false,
                showsBadges: false
            )
            .scaleEffect(0.76)
            .offset(y: -30)
        }
        .frame(height: sceneHeight)
        .frame(maxWidth: .infinity)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 3.2).repeatForever(autoreverses: true)) {
                glow = true
            }
        }
        .accessibilityElement(children: .contain)
    }
}
