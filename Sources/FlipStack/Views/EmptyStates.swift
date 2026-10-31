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

            Text(model.discoveredPrinters.isEmpty ? "No print queue yet." : "Printers detected.")
                .font(FlipType.displayLarge)
                .foregroundStyle(FlipColor.ink)
                .accessibilityAddTraits(.isHeader)

            Text(
                model.discoveredPrinters.isEmpty
                ? "Add a printer in Printers & Scanners, then let FlipStack find it again."
                : "A printer was found nearby. Add it in Printers & Scanners to create a print queue."
            )
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
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
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
                    Text(model.isRefreshing ? "Looking again…" : "Refresh")
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

private struct FlipPrinterArt: View {
    let hasPaper: Bool
    let showsAccent: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var artWidth: CGFloat = 164
    @State private var breathe = false

    private var height: CGFloat { artWidth * 0.78 }

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(
                    FlipColor.ink.opacity(0.09),
                    style: StrokeStyle(lineWidth: 1, dash: [2.5, 5])
                )
                .frame(width: artWidth * 0.94, height: artWidth * 0.94)

            if showsAccent {
                Circle()
                    .trim(from: 0.05, to: 0.3)
                    .stroke(FlipColor.coral.opacity(0.65), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
                    .frame(width: artWidth * 0.94, height: artWidth * 0.94)
                    .rotationEffect(.degrees(-90))
            }

            // Paper ready to feed.
            RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                .fill(hasPaper ? FlipColor.printPaper : FlipColor.tone)
                .overlay {
                    RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                        .strokeBorder(FlipColor.ink.opacity(0.24), lineWidth: 1)
                }
                .frame(width: artWidth * 0.42, height: artWidth * 0.3)
                .offset(y: -height * 0.37)

            // Body.
            RoundedRectangle(cornerRadius: artWidth * 0.09, style: .continuous)
                .fill(FlipColor.printPaper)
                .overlay {
                    RoundedRectangle(cornerRadius: artWidth * 0.09, style: .continuous)
                        .strokeBorder(FlipColor.ink.opacity(0.5), lineWidth: 1.4)
                }
                .frame(width: artWidth * 0.78, height: height * 0.57)
                .offset(y: height * 0.08)

            // Feed slot.
            Capsule()
                .fill(FlipColor.ink.opacity(0.2))
                .frame(width: artWidth * 0.48, height: 2.5)
                .offset(y: -height * 0.1)

            // Output tray.
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .stroke(FlipColor.ink.opacity(0.35), lineWidth: 1.1)
                .frame(width: artWidth * 0.6, height: height * 0.13)
                .offset(y: height * 0.34)

            if hasPaper {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(FlipColor.coral.opacity(0.88))
                    .frame(width: artWidth * 0.34, height: 2)
                    .offset(y: height * 0.31)
            }

            // A quiet status light.
            Circle()
                .fill(showsAccent ? FlipColor.coral : FlipColor.success)
                .frame(width: 6, height: 6)
                .overlay {
                    if !reduceMotion {
                        Circle()
                            .stroke(FlipColor.coral.opacity(0.3), lineWidth: 1)
                            .scaleEffect(breathe ? 2.4 : 1)
                            .opacity(breathe ? 0 : 0.8)
                    }
                }
                .offset(x: artWidth * 0.27, y: height * 0.16)
        }
        .frame(width: artWidth, height: artWidth * 0.86)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 1.9).repeatForever(autoreverses: false)) {
                breathe = true
            }
        }
        .accessibilityHidden(true)
    }
}
