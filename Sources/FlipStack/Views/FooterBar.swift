import AppKit
import FlipStackCore
import SwiftUI

@MainActor
struct FooterBar: View {
    @ObservedObject var model: AppModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var appVersion: String {
        guard let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              !version.isEmpty else {
            return "1.0.0"
        }
        return version
    }

    private var hasActiveJob: Bool {
        model.queue.contains(where: { $0.isActive })
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.isShowingQueue {
                FlipHairline()
                QueueSection(model: model)
            }

            FlipHairline()

            HStack(spacing: 8) {
                queueButton
                Spacer(minLength: 6)

                if model.isMaintenanceBusy {
                    Text("Preparing…")
                        .font(FlipType.caption)
                        .foregroundStyle(FlipColor.tertiaryInk)
                        .accessibilityLabel("Maintenance task in progress")
                }

                maintenanceMenu
            }
            .padding(.horizontal, 13)
            .frame(height: FlipMetrics.footerHeight)
        }
        .background {
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                Rectangle().fill(Color.primary.opacity(0.012))
            }
        }
        .animation(FlipMotion.standard(reduceMotion), value: model.isShowingQueue)
    }

    // MARK: Queue row

    private var queueButton: some View {
        Button {
            let opening = !model.isShowingQueue
            withAnimation(FlipMotion.standard(reduceMotion)) {
                model.isShowingQueue = opening
            }
            if opening {
                Task { await model.refreshQueue() }
            }
        } label: {
            HStack(spacing: 6) {
                if hasActiveJob {
                    Circle()
                        .fill(FlipColor.coral)
                        .frame(width: 4.5, height: 4.5)
                }
                Text("Queue")
                    .font(.system(.caption, design: .default, weight: .medium))
                    .foregroundStyle(FlipColor.ink)
                Text("· \(model.queue.count)")
                    .font(.system(.caption, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(FlipColor.secondaryInk)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundStyle(FlipColor.tertiaryInk)
                    .rotationEffect(.degrees(model.isShowingQueue ? 180 : 0))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(model.isShowingQueue ? FlipColor.tone : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Queue")
        .accessibilityValue(
            "\(FlipFormat.jobs(model.queue.count)), \(model.isShowingQueue ? "expanded" : "collapsed")"
        )
        .accessibilityHint("Shows or hides the print queue.")
    }

    // MARK: Maintenance

    private var maintenanceMenu: some View {
        Menu {
            Button {
                Task { await model.printTestPage() }
            } label: {
                Label("Print test page", systemImage: "doc.text")
            }
            .disabled(model.selectedPrinter == nil || model.isMaintenanceBusy || !model.orchestrator.phase.isIdle)

            Button {
                Task { await model.printAlignmentPage() }
            } label: {
                Label("Head alignment sheet", systemImage: "scope")
            }
            .disabled(model.selectedPrinter == nil || model.isMaintenanceBusy || !model.orchestrator.phase.isIdle)

            Divider()

            Button {
                openPrinterSettings()
            } label: {
                Label("Printers & Scanners…", systemImage: "printer")
            }

            Button {
                openCUPSQueue()
            } label: {
                Label("Open CUPS queue", systemImage: "safari")
            }
            .disabled(model.selectedPrinter == nil)

            Divider()

            Button {
            } label: {
                Label("FlipStack \(appVersion)", systemImage: "info.circle")
            }
            .disabled(true)

            Divider()

            Button {
                NSApp.terminate(nil)
            } label: {
                Label("Quit FlipStack", systemImage: "power")
            }
        } label: {
            HStack(spacing: 0) {
                if model.isMaintenanceBusy {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(FlipColor.secondaryInk)
                }
            }
            .frame(width: 27, height: 27)
            .background(Circle().fill(FlipColor.tone))
            .overlay(Circle().strokeBorder(FlipColor.hairline, lineWidth: 0.5))
            .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("Maintenance and app menu")
        .accessibilityLabel("Maintenance and app menu")
        .accessibilityValue(model.isMaintenanceBusy ? "Working" : "Ready")
        .accessibilityHint("Print a test page, print a head alignment sheet, open printer settings, or quit FlipStack.")
    }

    private func openPrinterSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.Print-Scan-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.printfax"
        ]
        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    private func openCUPSQueue() {
        guard let id = model.selectedPrinter?.id,
              let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "http://localhost:631/printers/\(encoded)") else { return }
        NSWorkspace.shared.open(url)
    }
}
