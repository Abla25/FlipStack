import FlipStackCore
import SwiftUI

// MARK: - Shared heading

struct FlowHeading: View {
    let eyebrow: String
    let tint: Color
    let title: String
    let subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            FlipEyebrow(eyebrow, color: tint)
            Text(L(title))
                .font(FlipType.displayLarge)
                .foregroundStyle(FlipColor.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if let subtitle {
                Text(L(subtitle))
                    .font(FlipType.footnote)
                    .foregroundStyle(FlipColor.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(2)
            }
        }
    }
}

// MARK: - Preparing

@MainActor
struct PreparingSurface: View {
    @ObservedObject var model: AppModel

    private var title: String {
        switch model.activePrintMode {
        case .singleSided: return L("Preparing the document.")
        case .manualDuplex: return L("Lining up the passes.")
        case .booklet: return L("Building the booklet.")
        }
    }

    private var subtitle: String {
        switch model.activePrintMode {
        case .singleSided:
            return L("FlipStack is getting the job ready on this Mac. Nothing is sent until it is.")
        case .manualDuplex:
            return L("FlipStack is preparing the job on this Mac. Nothing is sent until both passes are ready.")
        case .booklet:
            return L("FlipStack is arranging the pages into signatures on this Mac. Nothing is sent yet.")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            FlowHeading(
                eyebrow: "Preparing",
                tint: FlipColor.coralDeep,
                title: title,
                subtitle: subtitle
            )

            PreparingArt()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 2)

            HStack(spacing: 7) {
                ProgressView()
                    .controlSize(.small)
                    .tint(FlipColor.coral)
                Text(L("Preparing the print job…"))
                    .font(FlipType.caption)
                    .foregroundStyle(FlipColor.secondaryInk)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .accessibilityElement(children: .combine)

        }
    }
}

private struct PreparingArt: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var artWidth: CGFloat = 122
    @State private var scanning = false

    private var height: CGFloat { artWidth * 0.82 }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: FlipMetrics.microRadius, style: .continuous)
                .fill(FlipColor.printPaperEdge)
                .overlay {
                    RoundedRectangle(cornerRadius: FlipMetrics.microRadius, style: .continuous)
                        .strokeBorder(FlipColor.ink.opacity(0.1), lineWidth: 0.5)
                }
                .frame(width: artWidth * 0.66, height: height * 0.84)
                .offset(x: 7, y: 6)

            RoundedRectangle(cornerRadius: FlipMetrics.microRadius, style: .continuous)
                .fill(FlipColor.printPaper)
                .overlay {
                    VStack(alignment: .leading, spacing: height * 0.06) {
                        Capsule().fill(FlipColor.coral)
                            .frame(width: artWidth * 0.2, height: 2)
                        ForEach(0..<4, id: \.self) { index in
                            Capsule()
                                .fill(FlipColor.printLine.opacity(0.3))
                                .frame(
                                    width: artWidth * (index == 3 ? 0.2 : 0.34),
                                    height: 1.4
                                )
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 13)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: FlipMetrics.microRadius, style: .continuous)
                        .strokeBorder(FlipColor.ink.opacity(0.18), lineWidth: 0.6)
                }
                .frame(width: artWidth * 0.7, height: height * 0.9)

            Capsule()
                .fill(FlipColor.coral.opacity(0.7))
                .frame(width: artWidth * 0.54, height: 1.4)
                .offset(y: scanning ? height * 0.27 : -height * 0.27)
                .opacity(scanning ? 0.55 : 0.95)
        }
        .frame(width: artWidth, height: height)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.35).repeatForever(autoreverses: true)) {
                scanning = true
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Printing

@MainActor
struct PrintingSurface: View {
    @ObservedObject var model: AppModel
    @ObservedObject var orchestrator: DuplexOrchestrator
    let pass: DuplexPass
    let job: PrintJob

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isSingleSided: Bool {
        model.activePrintMode == .singleSided
    }

    private var isWaitingForPrinter: Bool {
        model.isWaitingForPrinter
    }

    private var eyebrow: String {
        if isWaitingForPrinter { return L("Waiting for printer") }
        if isSingleSided { return L("Single-sided") }
        return pass == .fronts ? L("Pass 1 of 2 · Fronts") : L("Pass 2 of 2 · Backs")
    }

    private var title: String {
        if isWaitingForPrinter { return L("The printer is offline.") }
        if isSingleSided { return L("Printing.") }
        return pass == .fronts ? L("Printing fronts.") : L("Printing backs.")
    }

    private var subtitle: String {
        if isWaitingForPrinter {
            return L("The job is queued. FlipStack keeps watching; wake or reconnect the printer, or cancel the job here.")
        }
        if isSingleSided {
            return L("The printer is working through the document one side at a time.")
        }
        return pass == .fronts
        ? L("The printer is working through the first pass. FlipStack will pause before the backs.")
        : L("The stack is in place. The printer is working through the second pass now.")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            FlowHeading(
                eyebrow: eyebrow,
                tint: isWaitingForPrinter ? FlipColor.warning : FlipColor.coralDeep,
                title: title,
                subtitle: subtitle
            )

            DuplexProgressArc(
                progress: orchestrator.progress,
                activePass: pass,
                singleSided: isSingleSided,
                indeterminate: isWaitingForPrinter || job.progress == nil
            )
            .frame(maxWidth: .infinity)

            jobCard

            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(FlipColor.tertiaryInk)
                    .frame(width: 11, height: 12, alignment: .top)
                Text(
                    isSingleSided
                    ? L("You can close this panel. FlipStack keeps watching the job in the menu bar.")
                    : L("You can close this panel. FlipStack keeps watching and brings the flip prompt back.")
                )
                .font(FlipType.caption)
                .foregroundStyle(FlipColor.tertiaryInk)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(1)
            }
            .padding(.horizontal, 3)
            .accessibilityElement(children: .combine)
        }
    }

    private var jobCard: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(model.jobDisplayTitle(job))
                    .font(FlipType.footnoteStrong)
                    .foregroundStyle(FlipColor.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Text(job.displayState)
                    .font(FlipType.captionStrong)
                    .foregroundStyle(FlipColor.secondaryInk)
                    .lineLimit(1)
            }

            HStack(spacing: 5) {
                Text(String(format: L("Job %lld"), job.id))
                    .font(FlipType.caption)
                    .foregroundStyle(FlipColor.tertiaryInk)
                Circle()
                    .fill(FlipColor.tertiaryInk)
                    .frame(width: 2.5, height: 2.5)
                Text(
                    isSingleSided
                    ? L("Single-sided")
                    : (pass == .fronts ? L("First pass") : L("Second pass"))
                )
                    .font(FlipType.caption)
                    .foregroundStyle(FlipColor.tertiaryInk)
                Spacer(minLength: 0)
            }

            if let progress = job.progress {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(FlipColor.ink.opacity(0.08))
                        Capsule()
                            .fill(FlipColor.coral)
                            .frame(width: max(3, proxy.size.width * progress))
                    }
                }
                .frame(height: 3)
                .padding(.top, 2)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.28), value: progress)
            }
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: FlipMetrics.compactRadius, style: .continuous)
                .fill(FlipColor.tone)
        )
        .overlay {
            RoundedRectangle(cornerRadius: FlipMetrics.compactRadius, style: .continuous)
                .strokeBorder(FlipColor.hairline, lineWidth: 0.5)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(format: L("Job %lld, %@"), job.id, model.jobDisplayTitle(job)))
        .accessibilityValue(
            "\(job.displayState). " + (isSingleSided
                ? L("Single-sided.")
                : (pass == .fronts ? L("First pass, fronts.") : L("Second pass, backs.")))
        )
    }
}

// MARK: - Completed

@MainActor
struct CompletedSurface: View {
    @ObservedObject var model: AppModel
    let result: DuplexResult

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            FlowHeading(
                eyebrow: "Complete",
                tint: FlipColor.success,
                title: "All done.",
                subtitle: result.isSingleSided || result.sourcePageCount <= 1
                    ? String(format: L("%@ finished your document."), result.printerName)
                    : String(format: L("%@ finished both passes."), result.printerName)
            )

            CompletedArt()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 2)

            HStack(spacing: 14) {
                FlipMetric(value: "\(result.sheetCount)", label: "Sheets")
                metricDivider
                FlipMetric(value: "\(result.sourcePageCount)", label: "Pages")
                metricDivider
                FlipMetric(value: FlipFormat.duration(result.elapsed), label: "Time")
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .contain)

            VStack(alignment: .leading, spacing: 7) {
                if result.isBooklet {
                    FlipHintLine(
                        systemName: "book.closed",
                        text: "The booklet is printed. Fold the signatures in half, then staple twice along the fold."
                    )
                }
                if result.hadBlankFinalBack {
                    FlipHintLine(
                        systemName: "doc.text",
                        text: "The last sheet’s back is blank because the document has an odd page count.",
                        tint: FlipColor.tertiaryInk
                    )
                }
            }
        }
    }

    private var metricDivider: some View {
        Rectangle()
            .fill(FlipColor.hairline)
            .frame(width: 0.5, height: 25)
    }
}

private struct CompletedArt: View {
    @ScaledMetric(relativeTo: .body) private var artWidth: CGFloat = 100

    private var height: CGFloat { artWidth * 0.78 }

    var body: some View {
        ZStack {
            Circle()
                .stroke(FlipColor.success.opacity(0.16), lineWidth: 1)
                .frame(width: artWidth * 0.92, height: artWidth * 0.92)

            Circle()
                .trim(from: 0.03, to: 0.24)
                .stroke(FlipColor.success.opacity(0.55), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
                .frame(width: artWidth * 0.92, height: artWidth * 0.92)
                .rotationEffect(.degrees(-70))

            RoundedRectangle(cornerRadius: FlipMetrics.paperRadius, style: .continuous)
                .fill(FlipColor.printPaperEdge)
                .overlay {
                    RoundedRectangle(cornerRadius: FlipMetrics.paperRadius, style: .continuous)
                        .strokeBorder(FlipColor.ink.opacity(0.1), lineWidth: 0.5)
                }
                .frame(width: artWidth * 0.46, height: height * 0.6)
                .offset(x: 6, y: 5)

            RoundedRectangle(cornerRadius: FlipMetrics.paperRadius, style: .continuous)
                .fill(FlipColor.printPaper)
                .overlay {
                    VStack(alignment: .leading, spacing: height * 0.055) {
                        Capsule().fill(FlipColor.coral)
                            .frame(width: artWidth * 0.16, height: 1.8)
                        Capsule().fill(FlipColor.printLine.opacity(0.35))
                            .frame(width: artWidth * 0.19, height: 1.2)
                        Capsule().fill(FlipColor.printLine.opacity(0.27))
                            .frame(width: artWidth * 0.14, height: 1.2)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: FlipMetrics.paperRadius, style: .continuous)
                        .strokeBorder(FlipColor.ink.opacity(0.16), lineWidth: 0.6)
                }
                .frame(width: artWidth * 0.49, height: height * 0.65)

            Circle()
                .fill(FlipColor.success)
                .frame(width: artWidth * 0.3, height: artWidth * 0.3)
                .overlay {
                    Image(systemName: "checkmark")
                        .font(.system(size: artWidth * 0.13, weight: .bold))
                        .foregroundStyle(Color(nsColor: .white))
                }
                .shadow(color: FlipColor.success.opacity(0.25), radius: 6, x: 0, y: 3)
                .offset(x: artWidth * 0.28, y: height * 0.26)
        }
        .frame(width: artWidth, height: height)
        .accessibilityHidden(true)
    }
}

// MARK: - Failed

@MainActor
struct FailedSurface: View {
    @ObservedObject var model: AppModel
    let failure: DuplexFailure

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            FlowHeading(
                eyebrow: "Needs attention",
                tint: FlipColor.danger,
                title: failure.title,
                subtitle: nil
            )

            FailedArt()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 2)

            Text(failure.message)
                .font(FlipType.footnote)
                .foregroundStyle(FlipColor.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: FlipMetrics.controlRadius, style: .continuous)
                        .fill(FlipColor.danger.opacity(0.07))
                )
                .accessibilityElement(children: .combine)

            FlipHintLine(
                systemName: "wrench.and.screwdriver",
                text: failure.recoverySuggestion,
                tint: FlipColor.danger
            )

            // Actions are hosted by the sticky FlowActionBar.

        }
    }
}

private struct FailedArt: View {
    @ScaledMetric(relativeTo: .body) private var artWidth: CGFloat = 90

    private var height: CGFloat { artWidth * 0.74 }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(FlipColor.printPaper)
                .overlay {
                    VStack(alignment: .leading, spacing: height * 0.06) {
                        Capsule().fill(FlipColor.printLine.opacity(0.32))
                            .frame(width: artWidth * 0.32, height: 1.5)
                        Capsule().fill(FlipColor.printLine.opacity(0.24))
                            .frame(width: artWidth * 0.24, height: 1.5)
                        Capsule().fill(FlipColor.printLine.opacity(0.18))
                            .frame(width: artWidth * 0.29, height: 1.5)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(FlipColor.ink.opacity(0.18), lineWidth: 0.6)
                }
                .frame(width: artWidth * 0.58, height: height * 0.78)

            Path { path in
                path.move(to: CGPoint(x: artWidth * 0.37, y: height * 0.38))
                path.addLine(to: CGPoint(x: artWidth * 0.44, y: height * 0.55))
                path.addLine(to: CGPoint(x: artWidth * 0.37, y: height * 0.7))
            }
            .stroke(FlipColor.danger.opacity(0.6), style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [2, 2]))

            Circle()
                .fill(FlipColor.danger)
                .frame(width: artWidth * 0.3, height: artWidth * 0.3)
                .overlay {
                    Text(L("!"))
                        .font(.system(size: artWidth * 0.17, weight: .bold, design: .rounded))
                        .foregroundStyle(Color(nsColor: .white))
                }
                .shadow(color: FlipColor.danger.opacity(0.22), radius: 5, x: 0, y: 2)
                .offset(x: artWidth * 0.24, y: -height * 0.2)
        }
        .frame(width: artWidth, height: height)
        .accessibilityHidden(true)
    }
}

// MARK: - Cancelled

@MainActor
struct CancelledSurface: View {
    @ObservedObject var model: AppModel
    let pass: DuplexPass?

    private var subtitle: String {
        if model.activePrintMode == .singleSided {
            return L("The single-sided job stopped. No more pages will be printed.")
        }
        switch pass {
        case .some(.fronts):
            return L("The job stopped during the fronts. No backs will be printed.")
        case .some(.backs):
            return L("The fronts finished. Some backs may have printed; check the tray before starting over.")
        case .none:
            return L("No more pages will be printed.")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            FlowHeading(
                eyebrow: "Canceled",
                tint: FlipColor.tertiaryInk,
                title: "Printing canceled.",
                subtitle: subtitle
            )

            CancelledArt()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)

            if pass != nil {
                FlipHintLine(
                    systemName: "tray",
                    text: model.activePrintMode == .singleSided
                        ? "Check the printer and the tray before starting over."
                        : L("Remove any sheets from the tray before starting over."),
                    tint: FlipColor.tertiaryInk
                )
            }

            // Actions are hosted by the sticky FlowActionBar.
        }
    }
}

private struct CancelledArt: View {
    @ScaledMetric(relativeTo: .body) private var artWidth: CGFloat = 92

    private var height: CGFloat { artWidth * 0.72 }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(FlipColor.ink.opacity(0.16), lineWidth: 0.8)
                .frame(width: artWidth * 0.55, height: height * 0.68)
                .offset(x: 8, y: 5)

            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(FlipColor.printPaper)
                .overlay {
                    VStack(alignment: .leading, spacing: height * 0.055) {
                        Capsule().fill(FlipColor.printLine.opacity(0.3))
                            .frame(width: artWidth * 0.28, height: 1.5)
                        Capsule().fill(FlipColor.printLine.opacity(0.22))
                            .frame(width: artWidth * 0.21, height: 1.5)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(FlipColor.ink.opacity(0.16), lineWidth: 0.6)
                }
                .frame(width: artWidth * 0.58, height: height * 0.74)
                .rotationEffect(.degrees(-4))

            Circle()
                .fill(FlipColor.toneStrong)
                .frame(width: artWidth * 0.32, height: artWidth * 0.32)
                .overlay {
                    Image(systemName: "pause.fill")
                        .font(.system(size: artWidth * 0.12, weight: .bold))
                        .foregroundStyle(FlipColor.secondaryInk)
                }
                .overlay(Circle().strokeBorder(FlipColor.hairline, lineWidth: 0.5))
                .offset(x: artWidth * 0.26, y: height * 0.22)
        }
        .frame(width: artWidth, height: height)
        .accessibilityHidden(true)
    }
}
