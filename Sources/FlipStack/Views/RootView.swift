import FlipStackCore
import SwiftUI

/// The minimal FlipStack panel: one workflow — drop a file, (optionally)
/// adjust print settings, print fronts, flip the stack, done. Duplex is the
/// centerpiece; everything else is secondary.
@MainActor
struct RootView: View {
    @ObservedObject private var model: AppModel
    @ObservedObject private var orchestrator: DuplexOrchestrator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: AppModel, orchestrator: DuplexOrchestrator) {
        _model = ObservedObject(wrappedValue: model)
        _orchestrator = ObservedObject(wrappedValue: orchestrator)
    }

    private var isFlowActive: Bool {
        orchestrator.phase.isActive
    }

    private var surfaceKey: String {
        if model.isPreparingPrint { return "preparing" }
        if model.flipCalibration != nil, !isFlowActive { return "calibration" }
        if model.flipAxisSetup != nil, !isFlowActive { return "setup" }
        switch orchestrator.phase {
        case .idle: return "idle"
        case .preparing: return "preparing"
        case .printing(let pass, _): return "printing-\(pass.rawValue)"
        case .awaitingFlip(let prompt): return "flip-\(prompt.title)-\(prompt.mode.rawValue)"
        case .completed: return "completed"
        case .failed(let failure): return "failed-\(failure.title)"
        case .cancelled: return "cancelled"
        }
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                HeaderView(model: model, orchestrator: orchestrator)

                ScrollView(.vertical, showsIndicators: true) {
                    VStack(spacing: 0) {
                        if let banner = model.banner {
                            FlipBanner(banner: banner, reduceMotion: reduceMotion) {
                                model.dismissBanner()
                            }
                            .padding(.horizontal, 16)
                            .padding(.top, 12)
                        }

                        Group {
                            content
                        }
                        .padding(.horizontal, FlipMetrics.gutter)
                        .padding(.top, 13)
                        .padding(.bottom, 20)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
                    }
                    .frame(maxWidth: .infinity)
                }

                if model.flipCalibration != nil {
                    FlipCalibrationActionBar(model: model)
                        .transition(.opacity)
                } else if showsFlowActionBar {
                    FlowActionBar(model: model, orchestrator: orchestrator)
                        .transition(.opacity)
                } else if showsComposerAction {
                    ComposerActionBar(model: model)
                        .transition(.opacity)
                }

                FooterBar(model: model)
            }

            if model.isShowingSettings {
                settingsOverlay
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
        .tint(FlipColor.coral)
        .environment(\.locale, model.language.locale)
        .clipped()
        .animation(FlipMotion.standard(reduceMotion), value: model.banner?.id)
        .animation(FlipMotion.surface(reduceMotion), value: surfaceKey)
    }

    private var settingsOverlay: some View {
        ZStack {
            Color.black.opacity(0.24)
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(FlipMotion.surface(reduceMotion)) {
                        model.closeSettings()
                    }
                }

            ScrollView(.vertical, showsIndicators: true) {
                SettingsView(model: model)
                    .padding(14)
                    .frame(maxWidth: 460)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(10)
            .background {
                RoundedRectangle(cornerRadius: FlipMetrics.panelRadius - 4, style: .continuous)
                    .fill(.regularMaterial)
                    .shadow(color: Color.black.opacity(0.35), radius: 30, x: 0, y: 14)
            }
            .overlay {
                RoundedRectangle(cornerRadius: FlipMetrics.panelRadius - 4, style: .continuous)
                    .strokeBorder(FlipColor.border, lineWidth: 0.75)
            }
            .padding(10)
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
        }
        .transition(.opacity)
        .accessibilityAddTraits(.isModal)
    }

    private var showsFlowActionBar: Bool {
        if model.isShowingSettings { return false }
        if model.flipCalibration != nil { return false }
        return model.isPreparingPrint || !orchestrator.phase.isIdle
    }

    private var showsComposerAction: Bool {
        guard !model.isShowingSettings,
              !showsFlowActionBar,
              orchestrator.phase.isIdle,
              model.flipAxisSetup == nil,
              model.flipCalibration == nil,
              !model.isPreparingPrint,
              model.selectedDocument != nil,
              model.selectedPrinter != nil else {
            return false
        }
        return true
    }

    @ViewBuilder
    private var content: some View {
        if model.isPreparingPrint {
            PreparingSurface(model: model)
        } else if let _ = model.flipCalibration, !isFlowActive {
            FlipCalibrationView(model: model)
        } else if let _ = model.flipAxisSetup, !isFlowActive, model.selectedPrinter != nil {
            FlipAxisSetupView(model: model)
        } else {
            switch orchestrator.phase {
            case .idle:
                idleContent
            case .preparing:
                PreparingSurface(model: model)
            case .printing(let pass, let job):
                PrintingSurface(model: model, orchestrator: orchestrator, pass: pass, job: job)
            case .awaitingFlip(let prompt):
                FlipWaitingView(model: model, orchestrator: orchestrator, prompt: prompt)
            case .completed(let result):
                CompletedSurface(model: model, result: result)
            case .failed(let failure):
                FailedSurface(model: model, failure: failure)
            case .cancelled(let pass):
                CancelledSurface(model: model, pass: pass)
            }
        }
    }

    @ViewBuilder
    private var idleContent: some View {
        if model.isLoadingPrinters && model.printers.isEmpty {
            LoadingPrintersState()
        } else if model.printers.isEmpty || model.selectedPrinter == nil {
            NoPrinterState(model: model)
        } else {
            ComposerView(model: model)
        }
    }
}
