import FlipStackCore
import SwiftUI

/// The signature moment, drawn as one physical block: layered sheet edges,
/// printed faces, a coral fold mark, and a bracket that says it must stay
/// together. The whole block rotates, never individual sheets.
struct FlipStackDiagram: View {
    let sheetCount: Int
    let axis: FlipAxis
    let mode: FlipMode
    let isFlipped: Bool
    let reduceMotion: Bool
    var isLandscape: Bool = false
    var showsLabels: Bool = true
    var showsGroundShadow: Bool = true
    var showsBadges: Bool = true

    @ScaledMetric(relativeTo: .body) private var scaledWidth: CGFloat = 128
    @ScaledMetric(relativeTo: .body) private var scaledHeight: CGFloat = 84

    private var width: CGFloat {
        isLandscape ? min(scaledWidth, 146) : min(scaledWidth * 0.72, 108)
    }

    private var height: CGFloat {
        isLandscape ? min(scaledHeight, 96) : min(scaledHeight * 1.48, 136)
    }
    private var edgeCount: Int { min(max(sheetCount, 1), 5) - 1 }

    private var stateText: String {
        if isFlipped {
            return mode == .reinsertOnly ? "Stack reinserted, order unchanged" : "Flipped as one block"
        }
        return mode == .reinsertOnly ? "Ready to reinsert" : "Ready to flip"
    }

    private var rotationAxis: (x: CGFloat, y: CGFloat, z: CGFloat) {
        axis == .longEdge ? (x: 0, y: 1, z: 0) : (x: 1, y: 0, z: 0)
    }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                if showsGroundShadow {
                    Ellipse()
                        .fill(FlipColor.printPaperShadow)
                        .frame(width: width * 0.7, height: 11)
                        .blur(radius: 5)
                        .offset(y: height * 0.57)
                }

                physicalBlock

                if showsBadges, !isFlipped {
                    directionBadge
                        .offset(x: width * 0.5 + 1, y: -height * 0.44)
                }

                if showsBadges, isFlipped {
                    checkBadge
                        .offset(x: width * 0.5 + 1, y: -height * 0.44)
                        .transition(.opacity)
                }
            }
            .frame(width: width + 34, height: height + 24)

            if showsLabels {
                blockBracket

                HStack(spacing: 5) {
                    Circle()
                        .fill(isFlipped ? FlipColor.coral : FlipColor.tertiaryInk.opacity(0.55))
                        .frame(width: 4, height: 4)
                    Text(stateText)
                        .font(FlipType.caption)
                        .foregroundStyle(FlipColor.secondaryInk)
                }
                .animation(FlipMotion.standard(reduceMotion), value: isFlipped)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Paper stack, \(FlipFormat.sheets(sheetCount)), one physical block")
        .accessibilityValue("\(stateText). \(axis.flipInstruction)")
    }

    // MARK: The block

    @ViewBuilder
    private var physicalBlock: some View {
        if reduceMotion {
            ZStack {
                block
                    .frame(width: width, height: height)
                    .opacity(isFlipped ? 0 : 1)

                block
                    .frame(width: width, height: height)
                    .overlay {
                        RoundedRectangle(cornerRadius: FlipMetrics.microRadius, style: .continuous)
                            .fill(FlipColor.coral.opacity(0.07))
                    }
                    .opacity(isFlipped ? 1 : 0)
            }
            .animation(.easeInOut(duration: 0.22), value: isFlipped)
            .shadow(color: FlipColor.printPaperShadow, radius: 7, x: 3, y: 5)
        } else if mode == .reinsertOnly {
            block
                .frame(width: width, height: height)
                .scaleEffect(isFlipped ? 0.965 : 1)
                .offset(y: isFlipped ? -7 : 0)
                .opacity(isFlipped ? 0.92 : 1)
                .shadow(color: FlipColor.printPaperShadow, radius: isFlipped ? 11 : 7, x: 3, y: 5)
                .animation(FlipMotion.stack(reduceMotion), value: isFlipped)
        } else {
            block
                .frame(width: width, height: height)
                .rotation3DEffect(
                    .degrees(isFlipped ? (axis == .longEdge ? -180 : 180) : 0),
                    axis: rotationAxis,
                    anchor: .center,
                    perspective: 0.55
                )
                .shadow(color: FlipColor.printPaperShadow, radius: isFlipped ? 12 : 7, x: 3, y: 5)
                .animation(FlipMotion.stack(reduceMotion), value: isFlipped)
        }
    }

    private var block: some View {
        ZStack {
            if edgeCount > 0 {
                ForEach(Array(stride(from: edgeCount, through: 1, by: -1)), id: \.self) { edge in
                    RoundedRectangle(cornerRadius: FlipMetrics.microRadius, style: .continuous)
                        .fill(edge.isMultiple(of: 2) ? FlipColor.printPaperEdge : FlipColor.printPaper)
                        .overlay {
                            RoundedRectangle(cornerRadius: FlipMetrics.microRadius, style: .continuous)
                                .strokeBorder(FlipColor.ink.opacity(0.16), lineWidth: 0.5)
                        }
                        .frame(width: width, height: height)
                        .offset(x: CGFloat(edge) * 2.3, y: CGFloat(edge) * 1.9)
                }
            }

            RoundedRectangle(cornerRadius: FlipMetrics.microRadius, style: .continuous)
                .fill(FlipColor.printPaper)
                .overlay {
                    pageFace
                        .opacity(isFlipped ? 0 : 1)
                }
                .overlay {
                    blankFace
                        .opacity(isFlipped ? 1 : 0)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: FlipMetrics.microRadius, style: .continuous)
                        .strokeBorder(FlipColor.ink.opacity(0.22), lineWidth: 0.7)
                }
                .overlay(alignment: axis == .longEdge ? .leading : .top) {
                    if axis == .longEdge {
                        Capsule()
                            .fill(FlipColor.coral)
                            .frame(width: 3, height: height * 0.42)
                            .padding(.leading, 6)
                    } else {
                        Capsule()
                            .fill(FlipColor.coral)
                            .frame(width: width * 0.3, height: 3)
                            .padding(.top, 6)
                    }
                }
                .frame(width: width, height: height)
        }
    }

    private var pageFace: some View {
        VStack(alignment: .leading, spacing: max(4, height * 0.055)) {
            Capsule()
                .fill(FlipColor.coral.opacity(0.9))
                .frame(width: width * 0.26, height: 2)
            Capsule()
                .fill(FlipColor.printLine.opacity(0.42))
                .frame(width: width * 0.38, height: 1.5)
            Capsule()
                .fill(FlipColor.printLine.opacity(0.34))
                .frame(width: width * 0.31, height: 1.5)
            Capsule()
                .fill(FlipColor.printLine.opacity(0.26))
                .frame(width: width * 0.35, height: 1.5)
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Capsule()
                    .fill(FlipColor.printLine.opacity(0.2))
                    .frame(width: width * 0.08, height: 1.5)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 12)
        .animation(FlipMotion.standard(reduceMotion), value: isFlipped)
    }

    /// The stack lands printed-side down after the flip.
    private var blankFace: some View {
        VStack(alignment: .leading, spacing: max(5, height * 0.07)) {
            Spacer(minLength: 0)
            Capsule()
                .fill(FlipColor.printLine.opacity(0.12))
                .frame(width: width * 0.22, height: 1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .animation(FlipMotion.standard(reduceMotion), value: isFlipped)
    }

    // MARK: Labels

    private var blockBracket: some View {
        HStack(spacing: 5) {
            Rectangle()
                .fill(FlipColor.hairline)
                .frame(width: 1, height: 7)
            Rectangle()
                .fill(FlipColor.hairline)
                .frame(width: 22, height: 0.5)
            Text("ONE STACK · \(sheetCount) \(sheetCount == 1 ? "SHEET" : "SHEETS")")
                .font(.system(size: 7.5, weight: .semibold))
                .tracking(1.05)
                .foregroundStyle(FlipColor.tertiaryInk)
                .lineLimit(1)
            Rectangle()
                .fill(FlipColor.hairline)
                .frame(width: 22, height: 0.5)
            Rectangle()
                .fill(FlipColor.hairline)
                .frame(width: 1, height: 7)
        }
        .accessibilityHidden(true)
    }

    private var directionBadge: some View {
        Image(systemName: mode == .reinsertOnly ? "arrow.down" : "arrow.triangle.2.circlepath")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(FlipColor.coralDeep)
            .rotationEffect(.degrees(mode == .flipBlock && axis == .shortEdge ? 90 : 0))
            .frame(width: 25, height: 25)
            .background(Circle().fill(FlipColor.printPaper))
            .overlay(Circle().strokeBorder(FlipColor.hairline, lineWidth: 0.5))
            .shadow(color: FlipColor.printPaperShadow.opacity(0.45), radius: 3, x: 1, y: 2)
            .accessibilityHidden(true)
    }

    private var checkBadge: some View {
        Image(systemName: "checkmark")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(FlipColor.onCoral)
            .frame(width: 25, height: 25)
            .background(Circle().fill(FlipColor.coral))
            .overlay(Circle().strokeBorder(FlipColor.onCoral.opacity(0.12), lineWidth: 0.5))
            .shadow(color: FlipColor.coral.opacity(0.25), radius: 5, x: 0, y: 2)
            .accessibilityHidden(true)
    }
}
