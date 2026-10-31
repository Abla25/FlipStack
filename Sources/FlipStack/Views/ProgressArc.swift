import FlipStackCore
import SwiftUI

/// A two-segment pass arc. Fronts occupy the left sweep and backs the right,
/// with a quiet gap at the top and bottom. It stays visible from the flip
/// prompt through the second pass.
struct DuplexProgressArc: View {
    let progress: Double
    let activePass: DuplexPass?
    var compact: Bool = false
    var singleSided: Bool = false
    var indeterminate: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var baseDiameter: CGFloat = 136
    @State private var spinning = false

    private var diameter: CGFloat {
        compact ? min(baseDiameter * 0.44, 60) : min(baseDiameter, 142)
    }
    private var lineWidth: CGFloat { compact ? 5 : 8 }
    private var clamped: Double { min(max(progress, 0), 1) }
    private var frontFraction: Double { min(max(clamped / 0.5, 0), 1) }
    private var backFraction: Double { min(max((clamped - 0.5) / 0.5, 0), 1) }
    private var activeAnimation: Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.24)
    }

    var body: some View {
        VStack(spacing: compact ? 0 : 5) {
            ZStack {
                if indeterminate {
                    if singleSided {
                        Circle()
                            .stroke(FlipColor.ink.opacity(0.085), style: strokeStyle)
                    } else {
                        ArcSegment(startAngle: 135, endAngle: 255)
                            .stroke(FlipColor.ink.opacity(0.085), style: strokeStyle)
                        ArcSegment(startAngle: 285, endAngle: 405)
                            .stroke(FlipColor.ink.opacity(0.085), style: strokeStyle)
                    }
                    Circle()
                        .trim(from: 0, to: 0.17)
                        .stroke(FlipColor.coral, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                        .rotationEffect(.degrees(spinning ? 360 : 0))
                } else if singleSided {
                    Circle()
                        .stroke(FlipColor.ink.opacity(0.085), style: strokeStyle)
                    Circle()
                        .trim(from: 0, to: clamped)
                        .stroke(FlipColor.coral, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(activeAnimation, value: clamped)
                } else {
                    ArcSegment(startAngle: 135, endAngle: 255)
                        .stroke(FlipColor.ink.opacity(0.085), style: strokeStyle)

                    ArcSegment(startAngle: 285, endAngle: 405)
                        .stroke(FlipColor.ink.opacity(0.085), style: strokeStyle)

                    ArcSegment(startAngle: 135, endAngle: 135 + 120 * frontFraction)
                        .stroke(FlipColor.coral, style: strokeStyle)
                        .animation(activeAnimation, value: frontFraction)

                    ArcSegment(startAngle: 285, endAngle: 285 + 120 * backFraction)
                        .stroke(FlipColor.coral.opacity(0.62), style: strokeStyle)
                        .animation(activeAnimation, value: backFraction)
                }

                VStack(spacing: compact ? 0 : 1) {
                    if indeterminate {
                        Text("WORKING")
                            .font(.system(size: diameter * 0.13, weight: .semibold))
                            .tracking(1.2)
                            .foregroundStyle(FlipColor.ink)
                            .minimumScaleFactor(0.7)
                            .lineLimit(1)
                    } else {
                        Text(FlipFormat.percent(clamped))
                            .font(compact
                                  ? .system(size: diameter * 0.25, weight: .semibold, design: .rounded)
                                  : FlipType.numberLarge)
                            .monospacedDigit()
                            .foregroundStyle(FlipColor.ink)
                            .minimumScaleFactor(0.7)
                            .lineLimit(1)
                    }
                    if !compact {
                        Text(indeterminate ? "PRINTING" : (singleSided ? "PRINTED" : "OVERALL"))
                            .font(.system(size: 7.5, weight: .semibold))
                            .tracking(1.1)
                            .foregroundStyle(FlipColor.tertiaryInk)
                    }
                }
            }
            .frame(width: diameter, height: diameter)

            if !compact && !singleSided {
                HStack(spacing: 12) {
                    legend(title: "Fronts", fraction: frontFraction, isActive: activePass == .fronts)
                    legend(title: "Backs", fraction: backFraction, isActive: activePass == .backs)
                }
                .padding(.top, 1)
            } else if !compact {
                Text("One side · no flip")
                    .font(.system(size: 8, weight: .semibold))
                    .tracking(0.9)
                    .foregroundStyle(FlipColor.tertiaryInk)
                    .padding(.top, 1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(singleSided ? "Print progress" : "Duplex progress")
        .accessibilityValue(accessibilityProgress)
        .onAppear {
            guard indeterminate, !reduceMotion else { return }
            withAnimation(.linear(duration: 1.35).repeatForever(autoreverses: false)) {
                spinning = true
            }
        }
    }

    private var strokeStyle: StrokeStyle {
        StrokeStyle(lineWidth: lineWidth, lineCap: .round)
    }

    private func legend(title: String, fraction: Double, isActive: Bool) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(fraction > 0 ? FlipColor.coral.opacity(isActive ? 1 : 0.7) : FlipColor.ink.opacity(0.14))
                .frame(width: 4, height: 4)
            Text(title.uppercased())
                .font(.system(size: 7.5, weight: .semibold))
                .tracking(0.9)
                .foregroundStyle(isActive ? FlipColor.ink : FlipColor.secondaryInk)
            Text(FlipFormat.percent(fraction))
                .font(.system(size: 7.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(FlipColor.tertiaryInk)
        }
    }

    private var accessibilityProgress: String {
        if indeterminate {
            return "The printer is working. This queue does not report page-level progress."
        }
        if singleSided {
            return "Printing \(Int((clamped * 100).rounded())) percent complete."
        }
        let fronts = Int((frontFraction * 100).rounded())
        let backs = Int((backFraction * 100).rounded())
        let state: String
        switch activePass {
        case .some(.fronts): state = "Printing fronts."
        case .some(.backs): state = "Printing backs."
        case .none: state = clamped >= 0.5 ? "Fronts complete. Backs next." : "Preparing the first pass."
        }
        return "Fronts \(fronts) percent, backs \(backs) percent. \(state)"
    }
}

private struct ArcSegment: Shape {
    var startAngle: Double
    var endAngle: Double

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(startAngle, endAngle) }
        set {
            startAngle = newValue.first
            endAngle = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let radius = max(1, min(rect.width, rect.height) / 2 - 4)
        var path = Path()
        path.addArc(
            center: CGPoint(x: rect.midX, y: rect.midY),
            radius: radius,
            startAngle: .degrees(startAngle),
            endAngle: .degrees(endAngle),
            clockwise: false
        )
        return path
    }
}
