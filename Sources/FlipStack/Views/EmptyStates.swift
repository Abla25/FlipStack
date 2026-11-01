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

            Text(L("Add a printer to begin."))
                .font(FlipType.displayLarge)
                .foregroundStyle(FlipColor.ink)
                .accessibilityAddTraits(.isHeader)

            Text(L("FlipStack prints through macOS print queues. Add yours in Printers & Scanners; it appears here automatically."))
                .font(FlipType.footnote)
                .foregroundStyle(FlipColor.secondaryInk)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 7)
                .padding(.horizontal, 18)

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
                ProgressView().controlSize(.small).tint(FlipColor.coral)
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
