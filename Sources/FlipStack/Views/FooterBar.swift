import AppKit
import FlipStackCore
import SwiftUI

/// Minimal footer: maintenance sheets, flip calibration, settings, quit.
@MainActor
struct FooterBar: View {
    @ObservedObject var model: AppModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            FlipHairline()
            HStack(spacing: 8) {
                Spacer(minLength: 6)

                if model.isMaintenanceBusy {
                    Text(L("Preparing…"))
                        .font(FlipType.caption)
                        .foregroundStyle(FlipColor.tertiaryInk)
                        .accessibilityLabel(L("Maintenance task in progress"))
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
    }

    private var maintenanceMenu: some View {
        Menu {
            Button {
                Task { await model.printTestPage() }
            } label: {
                Label("Print test page", systemImage: "doc.text")
            }
            .disabled(
                model.selectedPrinter == nil
                    || model.isMaintenanceBusy
                    || model.isCalibrating
                    || !model.orchestrator.phase.isIdle
            )

            Button {
                Task { await model.printAlignmentPage() }
            } label: {
                Label("Head alignment sheet", systemImage: "scope")
            }
            .disabled(
                model.selectedPrinter == nil
                    || model.isMaintenanceBusy
                    || model.isCalibrating
                    || !model.orchestrator.phase.isIdle
            )

            Button {
                model.openFlipAxisSetup()
            } label: {
                Label("Flip calibration…", systemImage: "viewfinder")
            }
            .disabled(
                model.selectedPrinter == nil
                    || model.isMaintenanceBusy
                    || model.isCalibrating
                    || !model.orchestrator.phase.isIdle
            )

            Divider()

            Button {
                model.openSettings()
            } label: {
                Label("Settings…", systemImage: "gearshape")
            }
            .disabled(
                !model.orchestrator.phase.isIdle
                    || model.isPreparingPrint
                    || model.isMaintenanceBusy
                    || model.flipCalibration != nil
                    || model.flipAxisSetup != nil
            )

            Button {
                openPrinterSettings()
            } label: {
                Label("Printers & Scanners…", systemImage: "printer")
            }

            Divider()

            Button {
                NSApp.terminate(nil)
            } label: {
                Label("Quit FlipStack", systemImage: "power")
            }
        } label: {
            HStack(spacing: 0) {
                if model.isMaintenanceBusy {
                    ProgressView().controlSize(.mini)
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
        .accessibilityLabel(L("Maintenance and app menu"))
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
}
