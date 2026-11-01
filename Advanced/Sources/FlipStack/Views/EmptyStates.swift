import AppKit
import FlipStackCore
import SwiftUI

@MainActor
struct NoPrinterState: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 26)
            FlipPrinterArt(hasPaper: false, showsAccent: true)
                .padding(.bottom, 20)

            Text(model.discoveredPrinters.isEmpty ? L("Add a printer to begin.") : L("A printer is nearby."))
                .font(FlipType.displayLarge)
                .foregroundStyle(FlipColor.ink)
                .accessibilityAddTraits(.isHeader)

            Text(
                model.discoveredPrinters.isEmpty
                ? L("FlipStack prints through macOS print queues. Add yours in Printers & Scanners; it appears here automatically.")
                : L("Add it in Printers & Scanners to create a queue. FlipStack will find it when you come back.")
            )
                .font(FlipType.footnote)
                .foregroundStyle(FlipColor.secondaryInk)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 7)
                .padding(.horizontal, 18)

            HStack(spacing: 6) {
                setupStep("1", "Add", active: true)
                setupChevron
                setupStep("2", "Setup", active: false)
                setupChevron
                setupStep("3", "Print", active: false)
            }
            .padding(.top, 14)
            .padding(.horizontal, 8)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Setup: add a printer in System Settings, print one setup sheet, then print.")

            Button {
                PrinterSetup.openSystemSettings()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Open Printers & Scanners")
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(FlipPrimaryButtonStyle())
            .padding(.top, 22)

            if !model.discoveredPrinters.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(.system(size: 8, weight: .semibold))
                        FlipEyebrow("Detected nearby")
                        Spacer()
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 6)

                    ForEach(Array(model.discoveredPrinters.prefix(3))) { device in
                        DiscoveredPrinterRow(device: device, compact: true)
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 2)
                .background(
                    RoundedRectangle(cornerRadius: FlipMetrics.compactRadius, style: .continuous)
                        .fill(FlipColor.tone)
                )
                .padding(.top, 10)
            } else if model.isDiscoveringPrinters {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Looking for nearby printers…")
                        .font(FlipType.caption)
                        .foregroundStyle(FlipColor.tertiaryInk)
                }
                .padding(.top, 12)
            }

            Button {
                Task { await model.refreshAll() }
            } label: {
                HStack(spacing: 6) {
                    if model.isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    Text(model.isRefreshing ? L("Looking again…") : L("Check again"))
                }
            }
            .buttonStyle(FlipTertiaryButtonStyle())
            .disabled(model.isRefreshing)
            .padding(.top, 6)

            Spacer(minLength: 26)
        }
        .frame(maxWidth: .infinity, minHeight: 438)
        .accessibilityElement(children: .contain)
    }

    private func setupStep(_ number: String, _ title: String, active: Bool) -> some View {
        HStack(spacing: 4) {
            Text(number)
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(active ? FlipColor.onCoral : FlipColor.secondaryInk)
                .frame(width: 16, height: 16)
                .background(Circle().fill(active ? FlipColor.coral : FlipColor.toneStrong))
            Text(L(title))
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(active ? FlipColor.ink : FlipColor.secondaryInk)
                .lineLimit(1)
        }
    }

    private var setupChevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 6.5, weight: .bold))
            .foregroundStyle(FlipColor.tertiaryInk.opacity(0.6))
            .accessibilityHidden(true)
    }
}

@MainActor
struct LoadingPrintersState: View {
    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 36)
            FlipPrinterArt(hasPaper: true, showsAccent: false)
                .padding(.bottom, 20)

            Text("Looking for printers")
                .font(FlipType.displayLarge)
                .foregroundStyle(FlipColor.ink)
                .accessibilityAddTraits(.isHeader)

            Text("Checking the print queues on this Mac.")
                .font(FlipType.footnote)
                .foregroundStyle(FlipColor.secondaryInk)
                .padding(.top, 7)

            HStack(spacing: 7) {
                ProgressView()
                    .controlSize(.small)
                    .tint(FlipColor.coral)
                Text("This only takes a moment")
                    .font(FlipType.caption)
                    .foregroundStyle(FlipColor.tertiaryInk)
            }
            .padding(.top, 18)

            Spacer(minLength: 36)
        }
        .frame(maxWidth: .infinity, minHeight: 438)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Looking for printers. Checking the print queues on this Mac.")
    }
}
