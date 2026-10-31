import FlipStackCore
import SwiftUI

@MainActor
struct QueueSection: View {
    @ObservedObject var model: AppModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var emptyArtWidth: CGFloat = 52
    @State private var isRefreshing = false
    @State private var cancellingJobID: Int?

    private var rowHeight: CGFloat { 38 }

    var body: some View {
        VStack(spacing: 0) {
            header

            if let error = model.queueError {
                queueErrorRow(error)
            }

            if model.queue.isEmpty {
                emptyState
            } else {
                rows
            }
        }
        .background(Color.primary.opacity(0.028))
        .transition(
            reduceMotion
            ? .opacity
            : .move(edge: .bottom).combined(with: .opacity)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Print queue")
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 7) {
            FlipEyebrow("Print queue")
            Text("· \(model.queue.count)")
                .font(.system(.caption2, design: .rounded, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(FlipColor.tertiaryInk)
            Spacer(minLength: 4)
            if hasActiveJob {
                Text("LIVE")
                    .font(.system(size: 7, weight: .semibold))
                    .tracking(1)
                    .foregroundStyle(FlipColor.coralDeep)
            }
            Button {
                refresh()
            } label: {
                if isRefreshing {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(FlipIconButtonStyle())
            .disabled(isRefreshing || model.selectedPrinter == nil)
            .help("Refresh queue")
            .accessibilityLabel("Refresh print queue")

            Button {
                withAnimation(FlipMotion.quick(reduceMotion)) {
                    model.isShowingQueue = false
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(FlipIconButtonStyle())
            .help("Close queue")
            .accessibilityLabel("Close print queue")
        }
        .padding(.horizontal, 16)
        .frame(height: 34)
    }

    private var hasActiveJob: Bool {
        model.queue.contains(where: { $0.isActive })
    }

    // MARK: Rows

    private var rows: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 0) {
                ForEach(Array(model.queue.enumerated()), id: \.element.id) { index, job in
                    jobRow(job)
                    if index < model.queue.count - 1 {
                        FlipHairline()
                            .padding(.leading, 17)
                            .padding(.trailing, 16)
                    }
                }
            }
            .padding(.bottom, 4)
        }
        .frame(height: min(CGFloat(model.queue.count) * rowHeight + 4, 198))
    }

    private func jobRow(_ job: PrintJob) -> some View {
        let isCancelling = cancellingJobID == job.id
        return HStack(spacing: 9) {
            Circle()
                .fill(FlipColor.jobState(job.state))
                .frame(width: 6, height: 6)

            VStack(alignment: .leading, spacing: 1) {
                Text(model.jobDisplayTitle(job))
                    .font(FlipType.captionStrong)
                    .foregroundStyle(FlipColor.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 4) {
                    Text("Job \(job.id)")
                        .font(FlipType.caption)
                        .foregroundStyle(FlipColor.tertiaryInk)
                    Text("·")
                        .font(FlipType.caption)
                        .foregroundStyle(FlipColor.tertiaryInk)
                    Text(job.displayState)
                        .font(FlipType.caption)
                        .foregroundStyle(
                            job.state.isFailure ? FlipColor.danger : FlipColor.secondaryInk
                        )
                }
                .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Job \(job.id), \(model.jobDisplayTitle(job)), \(job.displayState)")

            Spacer(minLength: 2)

            if job.isActive {
                Button {
                    cancellingJobID = job.id
                    Task {
                        await model.cancelQueuedJob(job)
                        cancellingJobID = nil
                    }
                } label: {
                    if isCancelling {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                    }
                }
                .frame(width: 22, height: 22)
                .background(Circle().fill(FlipColor.tone))
                .overlay(Circle().strokeBorder(FlipColor.hairline, lineWidth: 0.5))
                .buttonStyle(.plain)
                .foregroundStyle(FlipColor.secondaryInk)
                .disabled(isCancelling)
                .accessibilityLabel("Cancel job \(job.id), \(model.jobDisplayTitle(job))")
                .accessibilityHint("Removes this job from the print queue.")
            }
        }
        .padding(.leading, 17)
        .padding(.trailing, 14)
        .frame(minHeight: rowHeight)
        .accessibilityElement(children: .contain)
    }

    // MARK: Empty and error

    private var emptyState: some View {
        VStack(spacing: 5) {
            EmptyQueueArt(size: min(emptyArtWidth, 56))
                .padding(.bottom, 1)

            Text(model.selectedPrinter == nil ? "No printer selected" : "The queue is quiet")
                .font(.system(.subheadline, design: .serif, weight: .semibold))
                .foregroundStyle(FlipColor.ink)

            Text(
                model.selectedPrinter == nil
                ? "Choose a printer to see its jobs."
                : "Active and recent jobs will appear here."
            )
            .font(FlipType.caption)
            .foregroundStyle(FlipColor.tertiaryInk)
            .multilineTextAlignment(.center)

            if model.selectedPrinter != nil {
                Button {
                    refresh()
                } label: {
                    Text("Refresh")
                }
                .buttonStyle(FlipTertiaryButtonStyle())
                .disabled(isRefreshing)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .accessibilityElement(children: .contain)
    }

    private func queueErrorRow(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(FlipColor.warning)
                .frame(width: 12, height: 12, alignment: .top)
            Text(message)
                .font(FlipType.caption)
                .foregroundStyle(FlipColor.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(1)
            Spacer(minLength: 4)
            Button {
                refresh()
            } label: {
                Text("Try again")
            }
            .buttonStyle(FlipTertiaryButtonStyle())
            .disabled(isRefreshing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(FlipColor.warning.opacity(0.06))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Queue error")
        .accessibilityValue(message)
    }

    // MARK: Refresh

    private func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task {
            await model.refreshQueue()
            isRefreshing = false
        }
    }
}

private struct EmptyQueueArt: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(FlipColor.ink.opacity(0.16), style: StrokeStyle(lineWidth: 0.8, dash: [3, 3]))
                .frame(width: size * 0.7, height: size * 0.2)
                .offset(y: size * 0.3)

            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(FlipColor.printPaper)
                .overlay {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(FlipColor.ink.opacity(0.18), lineWidth: 0.6)
                }
                .frame(width: size * 0.56, height: size * 0.64)
                .offset(y: -size * 0.05)

            Capsule()
                .fill(FlipColor.coral.opacity(0.85))
                .frame(width: size * 0.22, height: 1.5)
                .offset(y: -size * 0.18)

            Capsule()
                .fill(FlipColor.printLine.opacity(0.28))
                .frame(width: size * 0.3, height: 1.2)
                .offset(y: -size * 0.04)

            Capsule()
                .fill(FlipColor.printLine.opacity(0.2))
                .frame(width: size * 0.24, height: 1.2)
                .offset(y: size * 0.08)
        }
        .frame(width: size, height: size * 0.9)
        .accessibilityHidden(true)
    }
}
