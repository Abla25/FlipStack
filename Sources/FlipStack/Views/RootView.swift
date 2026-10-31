import FlipStackCore
import SwiftUI

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
        if model.isPreparingPrint {
            return "preparing"
        }
        if model.flipAxisSetup != nil, !isFlowActive {
            return "setup"
        }
        switch orchestrator.phase {
        case .idle:
            return "idle"
        case .preparing:
            return "preparing"
        case .printing(let pass, _):
            return "printing-\(pass.rawValue)"
        case .awaitingFlip(let prompt):
            return "flip-\(prompt.title)-\(prompt.mode.rawValue)"
        case .completed:
            return "completed"
        case .failed(let failure):
            return "failed-\(failure.title)"
        case .cancelled:
            return "cancelled"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HeaderView(model: model, orchestrator: orchestrator)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    if let banner = model.banner {
                        FlipBanner(banner: banner, reduceMotion: reduceMotion) {
                            model.dismissBanner()
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                    }

                    if showsInkLowStrip, !model.lowSupplies.isEmpty {
                        FlipInkLowStrip(supplies: model.lowSupplies)
                            .padding(.horizontal, 16)
                            .padding(.top, model.banner == nil ? 12 : 8)
                    }

                    Group {
                        content
                    }
                    .padding(.horizontal, FlipMetrics.gutter)
                    .padding(.top, 13)
                    .padding(.bottom, 20)
                    .transition(.opacity)
                }
                .frame(maxWidth: .infinity)
            }

            if showsComposerActionBar {
                PrimaryActionBar(model: model)
                    .transition(.opacity)
            }

            FooterBar(model: model)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
        .tint(FlipColor.coral)
        .clipped()
        .animation(FlipMotion.standard(reduceMotion), value: model.banner?.id)
        .animation(FlipMotion.surface(reduceMotion), value: surfaceKey)
        .animation(FlipMotion.standard(reduceMotion), value: showsComposerActionBar)
    }

    private var showsComposerActionBar: Bool {
        guard orchestrator.phase.isIdle,
              model.flipAxisSetup == nil,
              !model.isShowingQueue,
              !model.isLoadingPrinters,
              !model.isPreparingPrint,
              !model.isShowingPreview,
              !model.isPreparingPreview,
              model.selectedDocument != nil,
              !model.printers.isEmpty else {
            return false
        }
        return model.selectedPrinter != nil
    }

    private var showsInkLowStrip: Bool {
        orchestrator.phase.isIdle && model.flipAxisSetup == nil && !model.isPreparingPrint
    }

    @ViewBuilder
    private var content: some View {
        if model.isPreparingPrint {
            PreparingSurface(model: model)
        } else if let _ = model.flipAxisSetup, !isFlowActive, model.selectedPrinter != nil {
            FlipAxisSetupView(model: model)
        } else {
            switch orchestrator.phase {
            case .idle:
                idleContent
            case .preparing:
                PreparingSurface(model: model)
            case .printing(let pass, let job):
                PrintingSurface(
                    model: model,
                    orchestrator: orchestrator,
                    pass: pass,
                    job: job
                )
            case .awaitingFlip(let prompt):
                FlipWaitingView(
                    model: model,
                    orchestrator: orchestrator,
                    prompt: prompt
                )
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
