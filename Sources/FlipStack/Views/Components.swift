import AppKit
import FlipStackCore
import SwiftUI

// MARK: - Mark

/// Three offset sheets, the last one coral. Drawn rather than shipped as an
/// asset so it stays crisp at any scale and in either appearance.
struct FlipStackMark: View {
    var size: CGFloat = 22

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.12, style: .continuous)
                .stroke(FlipColor.ink.opacity(0.42), lineWidth: max(0.8, size * 0.055))
                .frame(width: size * 0.58, height: size * 0.76)
                .offset(x: -size * 0.17, y: size * 0.08)

            RoundedRectangle(cornerRadius: size * 0.12, style: .continuous)
                .fill(FlipColor.printPaper)
                .overlay {
                    RoundedRectangle(cornerRadius: size * 0.12, style: .continuous)
                        .strokeBorder(FlipColor.ink.opacity(0.28), lineWidth: max(0.7, size * 0.045))
                }
                .frame(width: size * 0.58, height: size * 0.76)
                .offset(x: -size * 0.02, y: 0)

            RoundedRectangle(cornerRadius: size * 0.12, style: .continuous)
                .fill(FlipColor.coral)
                .overlay(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: size * 0.1) {
                        Capsule().fill(FlipColor.onCoral.opacity(0.82))
                            .frame(width: size * 0.26, height: max(1, size * 0.07))
                        Capsule().fill(FlipColor.onCoral.opacity(0.46))
                            .frame(width: size * 0.2, height: max(1, size * 0.06))
                    }
                    .padding(.leading, size * 0.11)
                    .padding(.top, size * 0.16)
                }
                .frame(width: size * 0.58, height: size * 0.76)
                .offset(x: size * 0.15, y: -size * 0.08)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Status

struct FlipStatusDot: View {
    let state: PrinterState
    var size: CGFloat = 7
    var animates: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    private var color: Color { FlipColor.printerState(state) }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .overlay {
                if animates, state == .processing, !reduceMotion {
                    Circle()
                        .stroke(color.opacity(0.4), lineWidth: 1)
                        .scaleEffect(pulse ? 2.1 : 1)
                        .opacity(pulse ? 0 : 0.9)
                }
            }
            .onAppear {
                guard animates, state == .processing, !reduceMotion else { return }
                withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) {
                    pulse = true
                }
            }
            .accessibilityHidden(true)
    }
}

struct FlipStatePill: View {
    let label: String
    let color: Color
    var dotState: PrinterState?

    var body: some View {
        HStack(spacing: 5) {
            if let dotState {
                FlipStatusDot(state: dotState, size: 5.5)
            } else {
                Circle().fill(color).frame(width: 5.5, height: 5.5)
            }
            Text(label)
                .font(FlipType.captionStrong)
                .foregroundStyle(FlipColor.secondaryInk)
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(FlipColor.tone))
        .overlay(Capsule().strokeBorder(FlipColor.hairline, lineWidth: 0.5))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Small pieces

struct FlipMetaChip: View {
    let systemName: String
    let text: String
    var tint: Color = FlipColor.secondaryInk

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemName)
                .font(.system(size: 9, weight: .semibold))
            Text(text)
                .font(FlipType.caption)
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(FlipColor.tone))
        .overlay(Capsule().strokeBorder(FlipColor.hairline, lineWidth: 0.5))
        .accessibilityElement(children: .combine)
    }
}

struct FlipHintLine: View {
    let systemName: String
    let text: String
    var tint: Color = FlipColor.coral

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 13, height: 14, alignment: .top)
            Text(text)
                .font(FlipType.footnote)
                .foregroundStyle(FlipColor.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(1)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

struct FlipMetric: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(FlipType.numberSmall)
                .foregroundStyle(FlipColor.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            FlipEyebrow(label, color: FlipColor.tertiaryInk)
        }
        .accessibilityElement(children: .combine)
    }
}

struct FlipSupplyMeter: View {
    let supply: SupplyLevel
    var width: CGFloat = 58

    private var color: Color { FlipColor.supply(supply) }
    private var fraction: Double { supply.fraction ?? 0 }
    private var levelText: String {
        guard let level = supply.levelPercent else { return "—" }
        return "\(level)%"
    }
    private var shortName: String {
        let name = (supply.colorName?.isEmpty == false ? supply.colorName! : supply.name)
        let trimmed = name
            .replacingOccurrences(of: " Ink", with: "")
            .replacingOccurrences(of: " Toner", with: "")
            .trimmingCharacters(in: .whitespaces)
        return trimmed.count > 10 ? String(trimmed.prefix(9)) + "…" : trimmed
    }
    private var accessibilityLevel: String {
        guard let level = supply.levelPercent else { return "level not reported" }
        let estimate = supply.isEstimated ? ", estimated" : ""
        return "\(level) percent\(estimate)\(supply.isLow ? ", low" : "")"
    }
    private var barWidth: CGFloat { width * 0.45 }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(shortName)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(FlipColor.secondaryInk)
                .lineLimit(1)
            HStack(spacing: 4) {
                Capsule()
                    .fill(color.opacity(0.16))
                    .frame(width: barWidth, height: 3)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(color)
                            .frame(width: max(1.5, barWidth * fraction), height: 3)
                    }
                Text(levelText)
                    .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(supply.isLow ? FlipColor.warning : FlipColor.tertiaryInk)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
        }
        .frame(width: width, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(supply.kind.label), \(supply.name)")
        .accessibilityValue(accessibilityLevel)
    }
}

struct FlipFileGlyph: View {
    var size: CGFloat = 42

    private var width: CGFloat { size * 0.78 }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: size * 0.13, style: .continuous)
                .fill(FlipColor.printPaper)
                .overlay {
                    RoundedRectangle(cornerRadius: size * 0.13, style: .continuous)
                        .strokeBorder(FlipColor.ink.opacity(0.2), lineWidth: 0.7)
                }

            VStack(alignment: .leading, spacing: size * 0.075) {
                Capsule().fill(FlipColor.coral)
                    .frame(width: width * 0.48, height: max(1.5, size * 0.045))
                Capsule().fill(FlipColor.printLine.opacity(0.48))
                    .frame(width: width * 0.58, height: max(1, size * 0.035))
                Capsule().fill(FlipColor.printLine.opacity(0.38))
                    .frame(width: width * 0.44, height: max(1, size * 0.035))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.leading, size * 0.14)
            .padding(.top, size * 0.2)

            Text("PDF")
                .font(.system(size: size * 0.16, weight: .bold))
                .tracking(0.7)
                .foregroundStyle(FlipColor.coralDeep)
                .padding(.leading, size * 0.14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(.bottom, size * 0.12)

            FoldedCorner()
                .fill(FlipColor.printPaperEdge)
                .frame(width: size * 0.24, height: size * 0.24)
                .overlay {
                    FoldedCorner()
                        .stroke(FlipColor.ink.opacity(0.18), lineWidth: 0.6)
                }
        }
        .frame(width: width, height: size)
        .accessibilityHidden(true)
    }
}

private struct FoldedCorner: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Buttons

struct FlipPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.callout, design: .default, weight: .semibold))
            .foregroundStyle(isEnabled ? FlipColor.onCoral : FlipColor.tertiaryInk)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, minHeight: FlipMetrics.primaryHeight)
            .background {
                Capsule(style: .continuous)
                    .fill(isEnabled ? FlipColor.coral : FlipColor.toneStrong)
            }
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(isEnabled ? Color.clear : FlipColor.hairline, lineWidth: 0.5)
            }
            .shadow(color: isEnabled ? FlipColor.coral.opacity(0.22) : .clear, radius: 12, x: 0, y: 6)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.95 : 1)
            .animation(FlipMotion.quick(reduceMotion), value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

struct FlipSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(FlipType.bodyStrong)
            .foregroundStyle(isEnabled ? FlipColor.ink : FlipColor.tertiaryInk)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 42)
            .background {
                Capsule(style: .continuous)
                    .fill(configuration.isPressed ? FlipColor.toneStrong : FlipColor.tone)
            }
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(FlipColor.border, lineWidth: 0.75)
            }
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.99 : 1)
            .animation(FlipMotion.quick(reduceMotion), value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

struct FlipSmallPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(FlipType.footnoteStrong)
            .foregroundStyle(isEnabled ? FlipColor.onCoral : FlipColor.tertiaryInk)
            .padding(.horizontal, 15)
            .frame(minHeight: 34)
            .background(
                Capsule(style: .continuous)
                    .fill(isEnabled ? FlipColor.coral : FlipColor.toneStrong)
            )
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.94 : 1)
            .animation(FlipMotion.quick(reduceMotion), value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

struct FlipTertiaryButtonStyle: ButtonStyle {    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(FlipType.footnoteStrong)
            .foregroundStyle(isEnabled ? FlipColor.coralDeep : FlipColor.tertiaryInk)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.62 : 1)
            .animation(FlipMotion.quick(reduceMotion), value: configuration.isPressed)
    }
}

struct FlipIconButtonStyle: ButtonStyle {
    var tint: Color = FlipColor.secondaryInk

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(isEnabled ? tint : FlipColor.tertiaryInk)
            .frame(width: 27, height: 27)
            .background(Circle().fill(configuration.isPressed ? FlipColor.toneStrong : FlipColor.tone))
            .overlay(Circle().strokeBorder(FlipColor.hairline, lineWidth: 0.5))
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
            .animation(FlipMotion.quick(reduceMotion), value: configuration.isPressed)
            .contentShape(Circle())
    }
}

// MARK: - Banner and supplies

struct FlipBanner: View {
    let banner: AppBanner
    let reduceMotion: Bool
    let onDismiss: () -> Void

    private var tone: Color {
        switch banner.kind {
        case .info: return FlipColor.info
        case .success: return FlipColor.success
        case .warning: return FlipColor.warning
        case .error: return FlipColor.danger
        }
    }

    private var symbol: String {
        switch banner.kind {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            FlipIconMedallion(systemName: symbol, tint: tone, size: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(banner.title)
                    .font(FlipType.footnoteStrong)
                    .foregroundStyle(FlipColor.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let message = banner.message, !message.isEmpty {
                    Text(message)
                        .font(FlipType.caption)
                        .foregroundStyle(FlipColor.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineSpacing(1)
                }
            }
            .accessibilityElement(children: .combine)

            Spacer(minLength: 2)

            Button {
                withAnimation(FlipMotion.standard(reduceMotion)) {
                    onDismiss()
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(FlipColor.tertiaryInk)
            .accessibilityLabel("Dismiss message")
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(tone.opacity(0.075)))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(tone.opacity(0.2), lineWidth: 0.5)
        }
    }
}

struct FlipInkLowStrip: View {
    let supplies: [SupplyLevel]

    private var summary: String {
        supplies.prefix(3).map { supply in
            if let level = supply.levelPercent {
                return "\(supply.name) \(level)%"
            }
            return supply.name
        }.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(FlipColor.warning)
                .frame(width: 5, height: 5)
            FlipEyebrow("Supply low", color: FlipColor.warning)
            Text("·")
                .font(FlipType.caption)
                .foregroundStyle(FlipColor.tertiaryInk)
            Text(summary)
                .font(FlipType.caption)
                .foregroundStyle(FlipColor.secondaryInk)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(FlipColor.warning.opacity(0.055))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(FlipColor.warning.opacity(0.14), lineWidth: 0.5)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Low supplies")
        .accessibilityValue(
            supplies.map { supply in
                let level = supply.levelPercent.map { "\($0) percent" } ?? "level not reported"
                return "\(supply.name), \(level)"
            }.joined(separator: "; ")
        )
    }
}

// MARK: - Discovered devices

extension PrinterTransport {
    var title: String {
        switch self {
        case .wifi: return "Wi-Fi"
        case .ethernet: return "Ethernet"
        case .usb: return "USB"
        case .network: return "Network"
        case .unknown: return "Device"
        }
    }

    var symbolName: String {
        switch self {
        case .wifi: return "wifi"
        case .ethernet: return "network"
        case .usb: return "cable.connector"
        case .network: return "network"
        case .unknown: return "printer"
        }
    }
}

enum PrinterSetup {
    static func openSystemSettings() {
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

struct DiscoveredPrinterRow: View {
    let device: DiscoveredPrinter
    var compact: Bool = false

    var body: some View {
        Button {
            PrinterSetup.openSystemSettings()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: device.transport.symbolName)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(FlipColor.tertiaryInk)
                    .frame(width: 14)

                VStack(alignment: .leading, spacing: 1) {
                    Text(device.name)
                        .font(FlipType.captionStrong)
                        .foregroundStyle(FlipColor.ink)
                        .lineLimit(1)
                    Text(device.model ?? device.transport.title)
                        .font(FlipType.caption)
                        .foregroundStyle(FlipColor.tertiaryInk)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Text("Set up")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(FlipColor.coralDeep)
            }
            .padding(.horizontal, compact ? 8 : 10)
            .padding(.vertical, compact ? 6 : 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Add this printer in Printers & Scanners.")
        .accessibilityLabel("\(device.name), \(device.transport.title), detected")
        .accessibilityHint("Opens Printers & Scanners to add this printer queue.")
    }
}
