import FlipStackCore
import SwiftUI

@MainActor
struct FlipAxisSetupView: View {
    @ObservedObject var model: AppModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var diagramSize: CGFloat = 54
    @State private var selectedAxis: FlipAxis = .longEdge
    @State private var ejectsFaceDown = false
    @State private var didLoadDefaults = false

    private var printerName: String {
        model.selectedPrinter?.displayName ?? "this printer"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                FlipEyebrow("Flip setup", color: FlipColor.coralDeep)
                Spacer()
                Button {
                    model.dismissFlipAxisSetup()
                } label: {
                    Text("Cancel")
                }
                .buttonStyle(FlipTertiaryButtonStyle())
                .accessibilityHint("Closes setup without saving changes.")
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("How should the stack turn?")
                    .font(FlipType.displayLarge)
                    .foregroundStyle(FlipColor.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text("Saved for \(printerName). It tells FlipStack which way to turn the block between passes.")
                    .font(FlipType.footnote)
                    .foregroundStyle(FlipColor.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(1)
            }

            HStack(spacing: 8) {
                axisCard(.longEdge)
                axisCard(.shortEdge)
            }

            faceDownSetting

            Text("Pages are never reordered. The physical turn restores their order.")
                .font(FlipType.caption)
                .foregroundStyle(FlipColor.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)

            if model.flipAxisSetup?.autoStartsPrint == true {
                HStack(spacing: 7) {
                    Image(systemName: "printer")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(FlipColor.coralDeep)
                    Text("Printing starts as soon as you continue.")
                        .font(FlipType.caption)
                        .foregroundStyle(FlipColor.secondaryInk)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(FlipColor.coral.opacity(0.07))
                )
                .accessibilityElement(children: .combine)
            }

            Button {
                model.completeFlipAxisSetup(
                    flipAxis: selectedAxis,
                    ejectsFaceDown: ejectsFaceDown
                )
            } label: {
                HStack(spacing: 8) {
                    Text("Continue")
                    Spacer(minLength: 4)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 11, weight: .semibold))
                        .opacity(0.7)
                }
            }
            .buttonStyle(FlipPrimaryButtonStyle())
            .accessibilityHint(
                model.flipAxisSetup?.autoStartsPrint == true
                ? "Saves the setup and starts printing the fronts."
                : "Saves the flip axis and tray for this printer."
            )
            .padding(.top, 2)
        }
        .onAppear {
            guard !didLoadDefaults else { return }
            didLoadDefaults = true
            selectedAxis = model.preferences.flipAxis
            ejectsFaceDown = model.preferences.ejectsFaceDown
        }
    }

    // MARK: Axis cards

    private func axisCard(_ axis: FlipAxis) -> some View {
        let isSelected = selectedAxis == axis
        return Button {
            withAnimation(FlipMotion.standard(reduceMotion)) {
                selectedAxis = axis
            }
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .top) {
                    FlipAxisDiagram(
                        axis: axis,
                        isSelected: isSelected,
                        size: min(diagramSize, 58)
                    )
                    Spacer(minLength: 2)
                    Image(systemName: isSelected ? "checkmark" : "circle")
                        .font(.system(size: isSelected ? 9 : 12, weight: .bold))
                        .foregroundStyle(isSelected ? FlipColor.onCoral : FlipColor.tertiaryInk)
                        .frame(width: 18, height: 18)
                        .background(
                            Circle().fill(isSelected ? FlipColor.coral : Color.clear)
                        )
                        .overlay {
                            if !isSelected {
                                Circle().strokeBorder(FlipColor.border, lineWidth: 0.75)
                            }
                        }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(axis.label)
                        .font(.system(.headline, design: .serif, weight: .semibold))
                        .foregroundStyle(FlipColor.ink)
                    Text(axis.shortLabel.uppercased())
                        .font(.system(size: 7.5, weight: .semibold))
                        .tracking(1.15)
                        .foregroundStyle(FlipColor.tertiaryInk)
                }

                Text(axis == .longEdge
                     ? "Turn the block like a book page."
                     : "Turn the block like a calendar.")
                    .font(FlipType.caption)
                    .foregroundStyle(FlipColor.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(1)
            }
            .padding(9)
            .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(isSelected ? FlipColor.coral.opacity(0.08) : FlipColor.tone)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(
                        isSelected ? FlipColor.coral : FlipColor.hairline,
                        lineWidth: isSelected ? 1.2 : 0.5
                    )
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(axis.label), \(axis.shortLabel) style")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint(axis.detail)
    }

    // MARK: Face-down

    private var faceDownSetting: some View {
        Toggle(isOn: $ejectsFaceDown) {
            VStack(alignment: .leading, spacing: 1) {
                Text("My tray ejects pages face-down")
                    .font(FlipType.bodyStrong)
                    .foregroundStyle(FlipColor.ink)
                Text("Only reinsert the stack; pages are never reordered.")
                    .font(FlipType.caption)
                    .foregroundStyle(FlipColor.tertiaryInk)
            }
        }
        .toggleStyle(.switch)
        .tint(FlipColor.coral)
        .accessibilityHint("Turn this on if the printed side already faces down when the pages land in the tray.")
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(FlipColor.tone)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(FlipColor.hairline, lineWidth: 0.5)
        }
    }
}

// MARK: - Axis illustration

private struct FlipAxisDiagram: View {
    let axis: FlipAxis
    let isSelected: Bool
    let size: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var tint: Color { isSelected ? FlipColor.coral : FlipColor.secondaryInk.opacity(0.62) }

    private var pageWidth: CGFloat { size * 0.46 }
    private var pageHeight: CGFloat { size * 0.62 }
    private var pageCenter: CGPoint { CGPoint(x: size * 0.61, y: size * 0.43) }

    var body: some View {
        ZStack {
            // Back sheet, for depth.
            RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                .stroke(FlipColor.ink.opacity(0.18), lineWidth: 0.8)
                .frame(width: pageWidth, height: pageHeight)
                .position(x: pageCenter.x + 2.2, y: pageCenter.y + 2.2)

            // Front sheet.
            RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                .fill(FlipColor.printPaper)
                .overlay {
                    VStack(alignment: .leading, spacing: size * 0.055) {
                        Capsule().fill(FlipColor.coral)
                            .frame(width: pageWidth * 0.38, height: max(1.2, size * 0.033))
                        Capsule().fill(FlipColor.printLine.opacity(0.4))
                            .frame(width: pageWidth * 0.5, height: max(0.8, size * 0.025))
                        Capsule().fill(FlipColor.printLine.opacity(0.3))
                            .frame(width: pageWidth * 0.36, height: max(0.8, size * 0.025))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.horizontal, size * 0.075)
                    .padding(.vertical, size * 0.09)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                        .strokeBorder(FlipColor.ink.opacity(0.2), lineWidth: 0.7)
                }
                .frame(width: pageWidth, height: pageHeight)
                .position(pageCenter)

            axisGuide
            turnArrow
        }
        .frame(width: size, height: size)
        .animation(FlipMotion.standard(reduceMotion), value: isSelected)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var axisGuide: some View {
        if axis == .longEdge {
            Path { path in
                path.move(to: CGPoint(x: size * 0.25, y: size * 0.09))
                path.addLine(to: CGPoint(x: size * 0.25, y: size * 0.88))
            }
            .stroke(tint.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [2.4, 3]))
        } else {
            Path { path in
                path.move(to: CGPoint(x: size * 0.14, y: size * 0.81))
                path.addLine(to: CGPoint(x: size * 0.91, y: size * 0.81))
            }
            .stroke(tint.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [2.4, 3]))
        }
    }

    @ViewBuilder
    private var turnArrow: some View {
        if axis == .longEdge {
            let center = CGPoint(x: size * 0.25, y: size * 0.45)
            let radius = size * 0.18
            Path { path in
                path.addArc(
                    center: center,
                    radius: radius,
                    startAngle: .degrees(112),
                    endAngle: .degrees(250),
                    clockwise: false
                )
            }
            .stroke(tint, style: StrokeStyle(lineWidth: 1.35, lineCap: .round))

            ArrowHead()
                .fill(tint)
                .frame(width: size * 0.12, height: size * 0.11)
                .rotationEffect(.degrees(70))
                .position(
                    x: center.x + radius * CGFloat(cos(250 * Double.pi / 180)),
                    y: center.y + radius * CGFloat(sin(250 * Double.pi / 180))
                )
        } else {
            let center = CGPoint(x: pageCenter.x, y: size * 0.81)
            let radius = size * 0.16
            Path { path in
                path.addArc(
                    center: center,
                    radius: radius,
                    startAngle: .degrees(20),
                    endAngle: .degrees(160),
                    clockwise: false
                )
            }
            .stroke(tint, style: StrokeStyle(lineWidth: 1.35, lineCap: .round))

            ArrowHead()
                .fill(tint)
                .frame(width: size * 0.12, height: size * 0.11)
                .rotationEffect(.degrees(-20))
                .position(
                    x: center.x + radius * CGFloat(cos(160 * Double.pi / 180)),
                    y: center.y + radius * CGFloat(sin(160 * Double.pi / 180))
                )
        }
    }
}

private struct ArrowHead: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
