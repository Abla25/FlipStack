import SwiftUI

/// A single, reusable product-shot printer. It is drawn in a 300 x 180 design
/// space and scaled by the caller, so the flip hero and the empty states share
/// one material language instead of two competing illustrations.
struct PrinterObject: View {
    var hasPaper: Bool = false
    var isActive: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var ledPulse = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            // A sheet waiting in the input tray, behind the body.
            if hasPaper {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(FlipColor.printPaper)
                    .overlay {
                        VStack(alignment: .leading, spacing: 4) {
                            Capsule().fill(FlipColor.coral.opacity(0.9))
                                .frame(width: 36, height: 2)
                            Capsule().fill(FlipColor.printLine.opacity(0.35))
                                .frame(width: 56, height: 1.3)
                            Capsule().fill(FlipColor.printLine.opacity(0.25))
                                .frame(width: 42, height: 1.3)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 13)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .strokeBorder(FlipColor.ink.opacity(0.12), lineWidth: 0.6)
                    }
                    .frame(width: 132, height: 54)
                    .offset(x: 82, y: 19)
                    .rotationEffect(.degrees(-1.1))
            }

            // Right side of the chassis, visible behind the front face.
            PrinterSideFace()
                .fill(
                    LinearGradient(
                        colors: [FlipColor.deviceSide, FlipColor.deviceSide.opacity(0.78)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 300, height: 180)
                .overlay {
                    PrinterSideFace()
                        .stroke(FlipColor.deviceEdge, lineWidth: 0.6)
                }

            // The shallow top deck. One continuous face, not a detached lid.
            PrinterTopFace()
                .fill(
                    LinearGradient(
                        colors: [FlipColor.deviceTop, FlipColor.deviceFrontTop],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 300, height: 180)
                .overlay {
                    PrinterTopFace()
                        .stroke(FlipColor.deviceHighlight, lineWidth: 0.6)
                }

            // Recessed seam on the deck.
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(FlipColor.deviceEdge)
                .frame(width: 154, height: 1.2)
                .offset(x: 91, y: 50)
                .opacity(0.55)

            // Front face.
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [FlipColor.deviceFrontTop, FlipColor.deviceFrontBottom],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 246, height: 92)
                .overlay {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(FlipColor.deviceHighlight, lineWidth: 0.55)
                        .padding(0.5)
                }
                .offset(x: 27, y: 58)

            // Output slot: a dark physical opening with a highlight underneath.
            RoundedRectangle(cornerRadius: 2.2, style: .continuous)
                .fill(FlipColor.deviceWell)
                .frame(width: 156, height: 5)
                .offset(x: 72, y: 108)
            Capsule()
                .fill(FlipColor.deviceHighlight.opacity(0.65))
                .frame(width: 142, height: 0.8)
                .offset(x: 79, y: 114)

            // A shallow output shelf catches the light below the slot.
            PrinterOutputShelf()
                .fill(
                    LinearGradient(
                        colors: [FlipColor.deviceFrontBottom.opacity(0.72), FlipColor.deviceSide.opacity(0.35)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 188, height: 17)
                .offset(x: 56, y: 117)

            // Three restrained vents keep the front from becoming a blank slab.
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { _ in
                    Capsule()
                        .fill(FlipColor.deviceWell.opacity(0.38))
                        .frame(width: 24, height: 1.4)
                }
            }
            .offset(x: 45, y: 87)

            // A single recessed status LED. It breathes; the printer never
            // floats or wobbles continuously.
            Circle()
                .fill(isActive ? FlipColor.coral : FlipColor.success)
                .frame(width: 4.5, height: 4.5)
                .overlay {
                    if isActive, !reduceMotion {
                        Circle()
                            .stroke((isActive ? FlipColor.coral : FlipColor.success).opacity(0.36), lineWidth: 1)
                            .scaleEffect(ledPulse ? 2.2 : 1)
                            .opacity(ledPulse ? 0 : 0.8)
                    }
                }
                .offset(x: 247, y: 73)

            // Base plinth and its contact lip.
            RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                .fill(FlipColor.deviceSide)
                .frame(width: 252, height: 11)
                .offset(x: 24, y: 145)
            Capsule()
                .fill(FlipColor.deviceHighlight.opacity(0.32))
                .frame(width: 214, height: 0.8)
                .offset(x: 43, y: 158)
        }
        .frame(width: 300, height: 180)
        .onAppear {
            guard isActive, !reduceMotion else { return }
            withAnimation(.easeOut(duration: 2.2).repeatForever(autoreverses: false)) {
                ledPulse = true
            }
        }
        .onChange(of: isActive) { _ in
            ledPulse = false
            guard isActive, !reduceMotion else { return }
            withAnimation(.easeOut(duration: 2.2).repeatForever(autoreverses: false)) {
                ledPulse = true
            }
        }
        .accessibilityHidden(true)
    }
}

/// The top deck is a shallow perspective plane. Its front edge is wider than
/// its back edge, which gives the object a believable product-shot angle
/// without rotating a flat rectangle in 3D.
private struct PrinterTopFace: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 48, y: 58))
        path.addLine(to: CGPoint(x: 70, y: 30))
        path.addLine(to: CGPoint(x: 278, y: 30))
        path.addLine(to: CGPoint(x: 262, y: 58))
        path.closeSubpath()
        return path
    }
}

private struct PrinterSideFace: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 272, y: 58))
        path.addLine(to: CGPoint(x: 292, y: 46))
        path.addLine(to: CGPoint(x: 292, y: 136))
        path.addLine(to: CGPoint(x: 272, y: 148))
        path.closeSubpath()
        return path
    }
}

private struct PrinterOutputShelf: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 9, y: 2))
        path.addLine(to: CGPoint(x: 179, y: 2))
        path.addLine(to: CGPoint(x: 188, y: 17))
        path.addLine(to: CGPoint(x: 0, y: 17))
        path.closeSubpath()
        return path
    }
}

/// A friendly, single printer illustration for the empty and loading states.
/// The geometry comes from the same design as the flip hero.
struct FlipPrinterArt: View {
    let hasPaper: Bool
    let showsAccent: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var halo = false

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(
                    FlipColor.ink.opacity(0.07),
                    style: StrokeStyle(lineWidth: 1, dash: [2.5, 6])
                )
                .frame(width: 166, height: 166)

            if showsAccent {
                Circle()
                    .trim(from: 0.06, to: 0.29)
                    .stroke(
                        FlipColor.coral.opacity(halo ? 0.72 : 0.42),
                        style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
                    )
                    .frame(width: 166, height: 166)
                    .rotationEffect(.degrees(-92))
            }

            Ellipse()
                .fill(FlipColor.paperShadow.opacity(0.28))
                .frame(width: 168, height: 15)
                .blur(radius: 8)
                .offset(y: 61)

            PrinterObject(hasPaper: hasPaper, isActive: showsAccent)
                .scaleEffect(0.56)
                .frame(width: 174, height: 104)
                .offset(y: 9)
        }
        .frame(width: 196, height: 164)
        .onAppear {
            guard !reduceMotion, showsAccent else { return }
            withAnimation(.easeInOut(duration: 2.8).repeatForever(autoreverses: true)) {
                halo = true
            }
        }
    }
}
