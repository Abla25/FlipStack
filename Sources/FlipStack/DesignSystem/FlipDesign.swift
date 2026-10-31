import AppKit
import FlipStackCore
import SwiftUI

// MARK: - Palette

/// FlipStack's visual language: warm paper, ink, and one deliberate coral.
/// Every color resolves against the current appearance so light and dark are
/// designed independently rather than tinted versions of each other.
enum FlipColor {
    static let coral = dynamic(light: 0xEB4F31, dark: 0xFF7A5E)
    static let coralDeep = dynamic(light: 0xB8331E, dark: 0xFF9A84)
    static let coralSoft = dynamic(light: 0xFFE9E2, dark: 0x40241D)
    static let onCoral = dynamic(light: 0x2A1008, dark: 0x211009)

    static let ink = Color(nsColor: .labelColor)
    static let secondaryInk = dynamic(light: 0x5B5651, dark: 0xC7C1BA)
    static let tertiaryInk = dynamic(light: 0x6E6862, dark: 0xAFA9A2)

    static let hairline = Color(nsColor: .separatorColor).opacity(0.5)
    static let border = Color(nsColor: .separatorColor).opacity(0.72)
    static let tone = Color.primary.opacity(0.042)
    static let toneStrong = Color.primary.opacity(0.072)
    static let pressedTone = Color.primary.opacity(0.1)

    static let paper = dynamic(light: 0xFFFCF7, dark: 0x302C28)
    static let paperEdge = dynamic(light: 0xE7DCD0, dark: 0x201D1A)
    static let paperLine = dynamic(light: 0x9B8C7E, dark: 0x8C8177)
    /// Physical paper stays warm and light in both appearances: it is an object,
    /// not a surface of the interface.
    static let printPaper = dynamic(light: 0xFFFCF7, dark: 0xF1E7DA)
    static let printPaperEdge = dynamic(light: 0xE7DCD0, dark: 0xCEBEAE)
    static let printLine = dynamic(light: 0x9B8C7E, dark: 0x7C6B5B)
    static let paperShadow = Color.black.opacity(0.18)
    static let printPaperShadow = Color.black.opacity(0.12)

    static let success = dynamic(light: 0x2C7A56, dark: 0x7FD2A8)
    static let warning = dynamic(light: 0x9A6200, dark: 0xF2BE62)
    static let danger = dynamic(light: 0xB5342A, dark: 0xFF9387)
    static let info = dynamic(light: 0x326D91, dark: 0x8FC7E8)

    static let cyan = dynamic(light: 0x168BA1, dark: 0x54CBDE)
    static let magenta = dynamic(light: 0xB63A71, dark: 0xF27CAF)
    static let yellow = dynamic(light: 0xB27B00, dark: 0xF0C54C)
    static let keyBlack = dynamic(light: 0x403B36, dark: 0xB8ADA1)
    static let neutralSupply = dynamic(light: 0x85786B, dark: 0xA29688)

    static func printerState(_ state: PrinterState) -> Color {
        switch state {
        case .idle: return success
        case .processing: return coral
        case .stopped: return danger
        case .unknown: return neutralSupply
        }
    }

    static func jobState(_ state: JobState) -> Color {
        switch state {
        case .completed: return success
        case .processing: return coral
        case .pending, .held: return yellow
        case .stopped, .canceled, .aborted: return danger
        case .unknown: return neutralSupply
        }
    }

    static func supply(_ supply: SupplyLevel) -> Color {
        let token = "\(supply.colorName ?? "") \(supply.name)".lowercased()
        if token.contains("cyan") { return cyan }
        if token.contains("magenta") { return magenta }
        if token.contains("yellow") { return yellow }
        if token.contains("black") || token.contains("photo") || token.contains("gray") {
            return keyBlack
        }
        if token.contains("waste") { return neutralSupply }
        switch supply.kind {
        case .ink: return info
        case .toner: return keyBlack
        case .drum: return magenta
        case .waste: return neutralSupply
        case .maintenance: return info
        case .other: return neutralSupply
        }
    }

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return nsColor(hex: isDark ? dark : light)
        })
    }

    private static func nsColor(hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

// MARK: - Type

enum FlipType {
    static let eyebrow = Font.system(.caption2, design: .default, weight: .semibold)
    static let micro = Font.system(.caption2, design: .default, weight: .medium)
    static let caption = Font.system(.caption, design: .default)
    static let captionStrong = Font.system(.caption, design: .default, weight: .medium)
    static let footnote = Font.system(.footnote, design: .default)
    static let footnoteStrong = Font.system(.footnote, design: .default, weight: .semibold)
    static let body = Font.system(.callout, design: .default)
    static let bodyStrong = Font.system(.callout, design: .default, weight: .semibold)
    static let headline = Font.system(.headline, design: .default, weight: .semibold)

    static let display = Font.system(.title2, design: .serif, weight: .semibold)
    static let displayLarge = Font.system(.title, design: .serif, weight: .semibold)
    static let displaySmall = Font.system(.title3, design: .serif, weight: .semibold)
    static let serifLabel = Font.system(.headline, design: .serif, weight: .semibold)
    static let serifItalic = Font.system(.callout, design: .serif, weight: .regular).italic()

    static let number = Font.system(.title3, design: .rounded, weight: .semibold).monospacedDigit()
    static let numberLarge = Font.system(.title2, design: .rounded, weight: .semibold).monospacedDigit()
    static let numberSmall = Font.system(.callout, design: .rounded, weight: .semibold).monospacedDigit()
}

// MARK: - Metrics

enum FlipMetrics {
    static let panelWidth: CGFloat = 388
    static let panelHeight: CGFloat = 680
    static let gutter: CGFloat = 20
    static let sectionSpacing: CGFloat = 21
    static let cardRadius: CGFloat = 14
    static let controlRadius: CGFloat = 10
    static let primaryHeight: CGFloat = 50
    static let footerHeight: CGFloat = 46
}

// MARK: - Motion

/// Motion is one vocabulary, not a per-view decision. Reduce Motion turns
/// movement into crossfades or instant state changes.
enum FlipMotion {
    static func quick(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .spring(response: 0.23, dampingFraction: 0.86)
    }

    static func standard(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.84)
    }

    static func surface(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? .easeInOut(duration: 0.18) : .spring(response: 0.4, dampingFraction: 0.9)
    }

    static func stack(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.76)
    }

    static func crossfade(_ reduceMotion: Bool) -> Animation {
        .easeInOut(duration: reduceMotion ? 0.16 : 0.22)
    }
}

// MARK: - Formatting

enum FlipFormat {
    static func sheets(_ count: Int) -> String {
        count == 1 ? "1 sheet" : "\(count) sheets"
    }

    static func pages(_ count: Int) -> String {
        count == 1 ? "1 page" : "\(count) pages"
    }

    static func jobs(_ count: Int) -> String {
        count == 1 ? "1 job" : "\(count) jobs"
    }

    static func percent(_ value: Double) -> String {
        "\(Int((min(max(value, 0), 1) * 100).rounded()))%"
    }

    static func duration(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded()))
        if total < 60 { return "\(total)s" }
        let minutes = total / 60
        let seconds = total % 60
        return seconds == 0 ? "\(minutes)m" : "\(minutes)m \(seconds)s"
    }
}

// MARK: - Shared primitives

struct FlipHairline: View {
    var body: some View {
        Rectangle()
            .fill(FlipColor.hairline)
            .frame(height: 0.5)
    }
}

struct FlipEyebrow: View {
    private let text: String
    private let color: Color

    init(_ text: String, color: Color = FlipColor.secondaryInk) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text.uppercased())
            .font(FlipType.eyebrow)
            .tracking(1.25)
            .foregroundStyle(color)
            .lineLimit(1)
            .accessibilityAddTraits(.isHeader)
    }
}

struct FlipToneLayer: View {
    var radius: CGFloat = FlipMetrics.cardRadius
    var strong: Bool = false
    var bordered: Bool = true

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(strong ? FlipColor.toneStrong : FlipColor.tone)
            .overlay {
                if bordered {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(FlipColor.hairline, lineWidth: 0.5)
                }
            }
    }
}

struct FlipIconMedallion: View {
    let systemName: String
    var tint: Color = FlipColor.coral
    var size: CGFloat = 26

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: max(9, size * 0.42), weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(Circle().fill(tint.opacity(0.12)))
            .accessibilityHidden(true)
    }
}
