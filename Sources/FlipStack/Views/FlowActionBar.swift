import FlipStackCore
import SwiftUI

/// One sticky action surface for every active or terminal flow. Keeping these
/// actions outside the scroll view means they stay reachable on a 560 pt
/// screen, just like the composer's print button.
@MainActor
struct FlowActionBar: View {
    @ObservedObject var model: AppModel
    @ObservedObject var orchestrator: DuplexOrchestrator

    private var phase: DuplexPhase { orchestrator.phase }

    var body: some View {
        VStack(spacing: 0) {
            FlipHairline()
            Group {
                if model.isPreparingPrint {
                    cancelBar(title: L("Cancel preparation"))
                } else {
                    switch phase {
                    case .idle:
                        EmptyView()
                    case .preparing:
                        cancelBar(title: L("Cancel"))
                    case .printing:
                        cancelBar(title: L("Cancel print"))
                            .keyboardShortcut(.cancelAction)
                    case .awaitingFlip(let prompt):
                        flipBar(prompt)
                    case .completed:
                        primaryBar(
                            title: L("Print another"),
                            systemName: "arrow.right",
                            shortcut: .defaultAction
                        ) {
                            model.resetFlow()
                        }
                    case .failed(let failure):
                        failureBar(failure)
                    case .cancelled:
                        cancelledBar
                    }
                }
            }
            .padding(.horizontal, FlipMetrics.gutter)
            .padding(.vertical, 10)
        }
        .background {
            ZStack {
                Rectangle().fill(.thickMaterial)
                Rectangle().fill(Color.primary.opacity(0.012))
            }
        }
    }

    private func flipBar(_ prompt: FlipPrompt) -> some View {
        VStack(spacing: 7) {
            Button {
                model.confirmFlip()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: prompt.mode == .reinsertOnly ? "arrow.down" : "arrow.triangle.2.circlepath")
                        .font(.system(size: 12, weight: .semibold))
                    Text(prompt.mode == .reinsertOnly ? L("I reinserted the stack") : L("I flipped the sheets"))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Spacer(minLength: 2)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 11, weight: .semibold))
                        .opacity(0.72)
                }
            }
            .buttonStyle(FlipPrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
            .accessibilityHint(
                prompt.mode == .reinsertOnly
                ? L("Confirms the stack is back in the printer and starts the backs.")
                : L("Confirms the stack was flipped as one block and starts the backs.")
            )

            Button(L("Cancel printing")) {
                model.cancelFlow()
            }
            .buttonStyle(FlipTertiaryButtonStyle())
            .frame(minWidth: 44, minHeight: 32)
            .accessibilityHint(L("Stops the duplex job after the first pass."))
        }
    }

    private func failureBar(_ failure: DuplexFailure) -> some View {
        VStack(spacing: 7) {
            if failure.canRetryBacks {
                primaryBar(
                    title: L("Retry backs"),
                    systemName: "arrow.clockwise",
                    shortcut: .defaultAction
                ) {
                    model.retryBacks()
                }
            } else {
                primaryBar(
                    title: L("Start over"),
                    systemName: "arrow.clockwise",
                    shortcut: .defaultAction
                ) {
                    model.startOver()
                }
            }

            HStack(spacing: 10) {
                if failure.canRetryBacks {
                    Button(L("Start over")) { model.startOver() }
                        .buttonStyle(FlipTertiaryButtonStyle())
                        .frame(minWidth: 44, minHeight: 32)
                }
                Button(L("Dismiss")) { model.resetFlow() }
                    .buttonStyle(FlipTertiaryButtonStyle())
                    .frame(minWidth: 44, minHeight: 32)
                Spacer(minLength: 0)
            }
        }
    }

    private var cancelledBar: some View {
        VStack(spacing: 7) {
            primaryBar(
                title: L("Start over"),
                systemName: "arrow.clockwise",
                shortcut: .defaultAction
            ) {
                model.startOver()
            }
            HStack {
                Button(L("Back to document")) { model.resetFlow() }
                    .buttonStyle(FlipTertiaryButtonStyle())
                    .frame(minWidth: 44, minHeight: 32)
                Spacer(minLength: 0)
            }
        }
    }

    private func cancelBar(title: String) -> some View {
        Button(title) {
            model.cancelFlow()
        }
        .buttonStyle(FlipSecondaryButtonStyle())
    }

    private func primaryBar(
        title: String,
        systemName: String,
        shortcut: KeyboardShortcut,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemName)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 4)
            }
        }
        .buttonStyle(FlipPrimaryButtonStyle())
        .keyboardShortcut(shortcut)
    }
}
