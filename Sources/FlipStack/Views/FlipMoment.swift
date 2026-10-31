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
    @State private var floats = false

    private var stackOffset: CGFloat {
        -31 + (floats ? -2 : 2)
    }

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(
                    FlipColor.ink.opacity(0.075),
                    style: StrokeStyle(lineWidth: 1, dash: [2.5, 6])
                )
                .frame(width: 196, height: 196)
                .offset(y: 4)

            Circle()
                .trim(from: 0.04, to: 0.26)
                .stroke(
                    FlipColor.coral.opacity(glow ? 0.7 : 0.38),
                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
                )
                .frame(width: 196, height: 196)
                .rotationEffect(.degrees(-94))
                .offset(y: 4)

            Ellipse()
                .fill(FlipColor.paperShadow.opacity(0.45))
                .frame(width: 176, height: 15)
                .blur(radius: 8)
                .offset(y: 84)

            PrinterHeroBackdrop()
                .offset(y: 39)

            FlipStackDiagram(
                sheetCount: sheetCount,
                axis: axis,
                mode: mode,
                isFlipped: isFlipped,
                reduceMotion: reduceMotion,
                isLandscape: isLandscape,
                showsLabels: false
            )
            .scaleEffect(0.92)
            .offset(y: stackOffset)
        }
        .frame(height: sceneHeight)
        .frame(maxWidth: .infinity)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 2.8).repeatForever(autoreverses: true)) {
                glow = true
            }
            withAnimation(.easeInOut(duration: 3.4).repeatForever(autoreverses: true)) {
                floats = true
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// A small, deliberately flat printer with a subtle perspective tilt. It uses
/// the same paper, ink, and coral vocabulary as the app rather than an SF Symbol.
private struct PrinterHeroBackdrop: View {
    var body: some View {
        ZStack {
            // A soft side plane gives the flat illustration a little depth.
            RoundedRectangle(cornerRadius: FlipMetrics.cardRadius, style: .continuous)
                .fill(FlipColor.printPaperEdge.opacity(0.9))
                .frame(width: 194, height: 82)
                .offset(x: 5, y: 5)
                .opacity(0.8)

            // Two small feet keep the body grounded.
            HStack(spacing: 112) {
                Capsule().fill(FlipColor.ink.opacity(0.18)).frame(width: 22, height: 4)
                Capsule().fill(FlipColor.ink.opacity(0.18)).frame(width: 22, height: 4)
            }
            .offset(y: 44)

            // Top lid.
            RoundedRectangle(cornerRadius: FlipMetrics.smallRadius, style: .continuous)
                .fill(FlipColor.printPaperEdge)
                .overlay {
                    RoundedRectangle(cornerRadius: FlipMetrics.smallRadius, style: .continuous)
                        .strokeBorder(FlipColor.ink.opacity(0.18), lineWidth: 0.6)
                }
                .frame(width: 178, height: 17)
                .offset(y: -45)

            // Body.
            RoundedRectangle(cornerRadius: FlipMetrics.cardRadius, style: .continuous)
                .fill(FlipColor.printPaper)
                .overlay {
                    RoundedRectangle(cornerRadius: FlipMetrics.cardRadius, style: .continuous)
                        .strokeBorder(FlipColor.ink.opacity(0.18), lineWidth: 0.9)
                }
                .frame(width: 194, height: 82)
                .overlay(alignment: .top) {
                    RoundedRectangle(cornerRadius: FlipMetrics.smallRadius, style: .continuous)
                        .fill(FlipColor.printPaperEdge)
                        .overlay {
                            RoundedRectangle(cornerRadius: FlipMetrics.smallRadius, style: .continuous)
                                .strokeBorder(FlipColor.ink.opacity(0.2), lineWidth: 0.6)
                        }
                        .frame(width: 140, height: 15)
                        .offset(y: -8)
                }
                .overlay(alignment: .topLeading) {
                    // A small control window, like a real print queue.
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(FlipColor.tone)
                        .overlay(alignment: .leading) {
                            HStack(spacing: 3) {
                                Image(systemName: "printer.fill")
                                    .font(.system(size: 7, weight: .semibold))
                                    .foregroundStyle(FlipColor.coralDeep)
                                Capsule()
                                    .fill(FlipColor.printLine.opacity(0.38))
                                    .frame(width: 30, height: 1.2)
                            }
                            .padding(.leading, 6)
                        }
                        .frame(width: 52, height: 13)
                        .padding(.leading, 12)
                        .padding(.top, 12)
                }
                .overlay(alignment: .topTrailing) {
                    Circle()
                        .fill(FlipColor.coral)
                        .frame(width: 5, height: 5)
                        .padding(.trailing, 14)
                        .padding(.top, 16)
                }
                .overlay(alignment: .top) {
                    VStack(spacing: 5) {
                        Capsule()
                            .fill(FlipColor.ink.opacity(0.2))
                            .frame(width: 112, height: 3)
                        Capsule()
                            .fill(FlipColor.ink.opacity(0.09))
                            .frame(width: 72, height: 2)
                    }
                    .offset(y: 22)
                }
                .overlay(alignment: .bottom) {
                    // Output tray.
                    RoundedRectangle(cornerRadius: FlipMetrics.microRadius, style: .continuous)
                        .stroke(FlipColor.ink.opacity(0.2), lineWidth: 0.8)
                        .frame(width: 150, height: 19)
                        .offset(y: 10)
                }

            // Front paper lip, catching the light.
            Capsule()
                .fill(FlipColor.coral.opacity(0.82))
                .frame(width: 112, height: 2)
                .offset(y: 26)
        }
        .rotation3DEffect(
            .degrees(7),
            axis: (x: 1, y: 0, z: 0),
            perspective: 0.55
        )
        .rotation3DEffect(
            .degrees(-4),
            axis: (x: 0, y: 1, z: 0),
            perspective: 0.55
        )
        .shadow(color: FlipColor.paperShadow.opacity(0.7), radius: 12, x: 0, y: 12)
        .frame(width: 220, height: 150)
        .accessibilityHidden(true)
    }
}
