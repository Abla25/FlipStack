import FlipStackCore
import SwiftUI

/// The one-sheet calibration flow. It is deliberately separate from the print
/// orchestrator: the document must not be sent until the user has confirmed
/// what came out of the tray.
@MainActor
struct FlipCalibrationView: View {
    @ObservedObject var model: AppModel

    private var calibration: FlipCalibration? { model.flipCalibration }

    var body: some View {
        Group {
            if let calibration {
                switch calibration.stage {
                case .printing:
                    printingView(calibration)
                case .questions:
                    questionsView(calibration)
                case .failed(let message):
                    failedView(message)
                }
            } else {
                EmptyView()
            }
        }
    }

    // MARK: Printing

    private func printingView(_ calibration: FlipCalibration) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            calibrationHeading(
                eyebrow: "Automatic calibration",
                title: "Printing one sheet.",
                subtitle: calibration.autoStartsPrint
                    ? "This printer’s first two-sided job starts with a generic orientation sheet. Your document has not been sent."
                    : "A generic orientation sheet is on its way. No document was sent."
            )

            HStack(alignment: .top, spacing: 14) {
                CalibrationSheetArt()
                    .frame(width: 108, height: 145)

                VStack(alignment: .leading, spacing: 7) {
                    Text(statusTitle)
                        .font(FlipType.bodyStrong)
                        .foregroundStyle(statusTint)
                    Text(statusDetail)
                        .font(FlipType.caption)
                        .foregroundStyle(FlipColor.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineSpacing(1)

                    if model.printerHealth != .offline {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.top, 2)
                            .accessibilityLabel("Printing the calibration sheet")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(11)
            .background(
                RoundedRectangle(cornerRadius: FlipMetrics.cardRadius, style: .continuous)
                    .fill(FlipColor.tone)
            )
            .overlay {
                RoundedRectangle(cornerRadius: FlipMetrics.cardRadius, style: .continuous)
                    .strokeBorder(FlipColor.hairline, lineWidth: 0.5)
            }

            FlipHintLine(
                systemName: "lock",
                text: "This sheet uses the printer’s current paper and media, and contains no document content. FlipStack waits for the printer to finish the sheet.",
                tint: FlipColor.tertiaryInk
            )
        }
    }

    private var statusTitle: String {
        switch model.printerHealth {
        case .offline:
            return "Waiting for the printer"
        case .attention:
            return "The printer needs attention"
        case .unknown:
            return "Checking the queue"
        default:
            return "Printing the calibration sheet"
        }
    }

    private var statusDetail: String {
        switch model.printerHealth {
        case .offline:
            return "CUPS reports the printer offline. The sheet is queued and FlipStack will wait up to ten minutes for it to print."
        case .attention:
            return "Finish the printer’s request, then FlipStack will continue with the sheet."
        case .unknown:
            return "Checking the printer."
        default:
            return "Keep the sheet as it lands. You will confirm the result in the next step."
        }
    }

    private var statusTint: Color {
        switch model.printerHealth {
        case .offline: return FlipColor.warning
        case .attention: return FlipColor.danger
        default: return FlipColor.ink
        }
    }

    // MARK: Questions

    private func questionsView(_ calibration: FlipCalibration) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            calibrationHeading(
                eyebrow: "Check the sheet",
                title: "Take the sheet out. Don't turn it yet.",
                subtitle: "Look at which side is facing up, then confirm the turn FlipStack should use for the stack."
            )

            HStack(alignment: .top, spacing: 13) {
                CalibrationSheetArt()
                    .frame(width: 92, height: 126)

                VStack(alignment: .leading, spacing: 8) {
                    trayQuestion(calibration)
                    axisQuestion(calibration)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            calibrationResult(calibration)

            if calibration.autoStartsPrint {
                HStack(spacing: 7) {
                    Image(systemName: "printer")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(FlipColor.coralDeep)
                    Text("Your PDF is still waiting. It prints after you save this setup.")
                        .font(FlipType.caption)
                        .foregroundStyle(FlipColor.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: FlipMetrics.smallRadius, style: .continuous)
                        .fill(FlipColor.coral.opacity(0.065))
                )
                .accessibilityElement(children: .combine)
            }

        }
    }

    private func trayQuestion(_ calibration: FlipCalibration) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            calibrationQuestionLabel("1", "Which side is facing up?")
            HStack(spacing: 6) {
                calibrationChoice(
                    title: "Printed side up",
                    subtitle: "I can see the print",
                    systemName: "doc.text",
                    selected: calibration.hasConfirmedTray && !calibration.ejectsFaceDown
                ) {
                    model.setFlipCalibrationEjectsFaceDown(false)
                }
                calibrationChoice(
                    title: "Blank side up",
                    subtitle: "I only see paper",
                    systemName: "rectangle",
                    selected: calibration.hasConfirmedTray && calibration.ejectsFaceDown
                ) {
                    model.setFlipCalibrationEjectsFaceDown(true)
                }
            }
        }
    }

    @ViewBuilder
    private func axisQuestion(_ calibration: FlipCalibration) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            calibrationQuestionLabel("2", "Turn direction")
            if model.mode == .booklet {
                Text("Booklets always use the long-edge turn. No second answer is needed.")
                    .font(FlipType.caption)
                    .foregroundStyle(FlipColor.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 5)
                    .accessibilityElement(children: .combine)
            } else {
                Text("Recommended: \(calibration.recommendedAxis.label.lowercased()). Confirm or change it.")
                    .font(FlipType.caption)
                    .foregroundStyle(FlipColor.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    calibrationChoice(
                        title: "Long edge",
                        subtitle: "Book turn",
                        systemName: "book.closed",
                        selected: calibration.hasConfirmedAxis && calibration.axis == .longEdge
                    ) {
                        model.setFlipCalibrationAxis(.longEdge)
                    }
                    calibrationChoice(
                        title: "Short edge",
                        subtitle: "Calendar turn",
                        systemName: "calendar",
                        selected: calibration.hasConfirmedAxis && calibration.axis == .shortEdge
                    ) {
                        model.setFlipCalibrationAxis(.shortEdge)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func calibrationResult(_ calibration: FlipCalibration) -> some View {
        if !calibration.isAnswered {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "checklist")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(FlipColor.secondaryInk)
                    .frame(width: 16, height: 16, alignment: .top)
                VStack(alignment: .leading, spacing: 2) {
                    Text(calibration.hasConfirmedTray || calibration.hasConfirmedAxis
                         ? "One answer left"
                         : "Two answers needed")
                        .font(FlipType.bodyStrong)
                        .foregroundStyle(FlipColor.ink)
                    Text(missingAnswerText(calibration))
                        .font(FlipType.caption)
                        .foregroundStyle(FlipColor.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: FlipMetrics.compactRadius, style: .continuous)
                    .fill(FlipColor.tone)
            )
            .overlay {
                RoundedRectangle(cornerRadius: FlipMetrics.compactRadius, style: .continuous)
                    .strokeBorder(FlipColor.hairline, lineWidth: 0.5)
            }
            .accessibilityElement(children: .combine)
        } else {
            HStack(alignment: .top, spacing: 10) {
                FlipAxisDiagram(axis: calibration.axis, isSelected: true, size: 46)
                    .frame(width: 48, height: 48)

                VStack(alignment: .leading, spacing: 3) {
                    Text("\(calibration.axis.label) · print lands \(calibration.ejectsFaceDown ? "down" : "up")")
                        .font(FlipType.bodyStrong)
                        .foregroundStyle(FlipColor.ink)
                    Text(resultDetail(calibration))
                        .font(FlipType.caption)
                        .foregroundStyle(FlipColor.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineSpacing(1)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: FlipMetrics.compactRadius, style: .continuous)
                    .fill(FlipColor.coral.opacity(0.06))
            )
            .overlay {
                RoundedRectangle(cornerRadius: FlipMetrics.compactRadius, style: .continuous)
                    .strokeBorder(FlipColor.coral.opacity(0.3), lineWidth: 0.75)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func missingAnswerText(_ calibration: FlipCalibration) -> String {
        if !calibration.hasConfirmedTray {
            return "Confirm which side of the sheet landed facing up."
        }
        return "Confirm the long-edge or short-edge turn."
    }

    private func resultDetail(_ calibration: FlipCalibration) -> String {
        if calibration.ejectsFaceDown {
            return "Your tray already lands the printed side down. Reinsert the stack without flipping; the backs print in order."
        }
        return "\(calibration.axis.flipInstruction) Then reinsert the stack for the backs."
    }

    // MARK: Failure

    private func failedView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            calibrationHeading(
                eyebrow: "Automatic calibration",
                title: "The sheet did not finish.",
                subtitle: "No document pages were sent. You can try the sheet again or set the flip up manually."
            )

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(FlipColor.warning)
                Text(message)
                    .font(FlipType.footnote)
                    .foregroundStyle(FlipColor.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(11)
            .background(
                RoundedRectangle(cornerRadius: FlipMetrics.compactRadius, style: .continuous)
                    .fill(FlipColor.warning.opacity(0.06))
            )
            .overlay {
                RoundedRectangle(cornerRadius: FlipMetrics.compactRadius, style: .continuous)
                    .strokeBorder(FlipColor.warning.opacity(0.28), lineWidth: 0.75)
            }
        }
    }

    // MARK: Common pieces

    private func calibrationHeading(
        eyebrow: String,
        title: String,
        subtitle: String
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            FlowHeading(
                eyebrow: eyebrow,
                tint: FlipColor.coralDeep,
                title: title,
                subtitle: subtitle
            )
            Spacer(minLength: 0)
            Button("Cancel setup") {
                model.dismissFlipAxisSetup()
            }
            .buttonStyle(FlipTertiaryButtonStyle())
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityHint("Cancels calibration and closes flip setup. The document is not printed.")
        }
    }

    private func calibrationQuestionLabel(_ number: String, _ text: String) -> some View {
        HStack(spacing: 5) {
            Text(number)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(FlipColor.onCoral)
                .frame(width: 15, height: 15)
                .background(Circle().fill(FlipColor.coral))
            Text(text)
                .font(FlipType.captionStrong)
                .foregroundStyle(FlipColor.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func calibrationChoice(
        title: String,
        subtitle: String,
        systemName: String,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: systemName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(selected ? FlipColor.coralDeep : FlipColor.tertiaryInk)
                    .frame(width: 13, height: 14, alignment: .top)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(FlipType.captionStrong)
                        .foregroundStyle(FlipColor.ink)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(subtitle)
                        .font(FlipType.caption)
                        .foregroundStyle(FlipColor.secondaryInk)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(selected ? FlipColor.coralDeep : FlipColor.tertiaryInk)
                    .frame(width: 13, height: 14, alignment: .top)
            }
            .padding(7)
            .frame(maxWidth: .infinity, minHeight: 58, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: FlipMetrics.smallRadius, style: .continuous)
                    .fill(selected ? FlipColor.coral.opacity(0.09) : FlipColor.tone)
            )
            .overlay {
                RoundedRectangle(cornerRadius: FlipMetrics.smallRadius, style: .continuous)
                    .strokeBorder(
                        selected ? FlipColor.coral : FlipColor.hairline,
                        lineWidth: selected ? 1.1 : 0.5
                    )
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(subtitle)")
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint("Choose this calibration result.")
    }
}

// MARK: - Sticky confirmation

@MainActor
struct FlipCalibrationActionBar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            FlipHairline()
            if let calibration = model.flipCalibration {
                VStack(spacing: 7) {
                    switch calibration.stage {
                    case .questions:
                        questionsActions(calibration)
                    case .printing:
                        Button("Cancel and set up manually") {
                            model.cancelFlipCalibration()
                        }
                        .buttonStyle(FlipSecondaryButtonStyle())
                        .accessibilityHint("Cancels the sheet and returns to manual flip setup.")
                    case .failed:
                        Button {
                            model.retryFlipCalibration()
                        } label: {
                            HStack(spacing: 8) {
                                Text("Try the calibration sheet again")
                                Spacer(minLength: 4)
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 11, weight: .semibold))
                                    .opacity(0.7)
                            }
                        }
                        .buttonStyle(FlipPrimaryButtonStyle())
                        HStack {
                            Button("Set up manually") {
                                model.returnToFlipSetup()
                            }
                            .buttonStyle(FlipTertiaryButtonStyle())
                            .frame(minWidth: 44, minHeight: 44)
                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(.horizontal, FlipMetrics.gutter)
                .padding(.vertical, 9)
            }
        }
        .background {
            ZStack {
                Rectangle().fill(.thickMaterial)
                Rectangle().fill(Color.primary.opacity(0.012))
            }
        }
    }

    @ViewBuilder
    private func questionsActions(_ calibration: FlipCalibration) -> some View {
        Text(calibration.isAnswered
             ? "\(calibration.axis.label) · print lands \(calibration.ejectsFaceDown ? "down" : "up")"
             : missingAnswerText(calibration))
            .font(calibration.isAnswered ? FlipType.captionStrong : FlipType.caption)
            .foregroundStyle(calibration.isAnswered ? FlipColor.ink : FlipColor.secondaryInk)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)

        HStack(spacing: 8) {
            Button {
                model.applyFlipCalibration()
            } label: {
                HStack(spacing: 8) {
                    Text(calibration.autoStartsPrint ? "Save and print" : "Use this setup")
                    Spacer(minLength: 4)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 11, weight: .semibold))
                        .opacity(0.7)
                }
            }
            .buttonStyle(FlipPrimaryButtonStyle())
            .disabled(!calibration.isAnswered)
            .keyboardShortcut(.defaultAction)
            .accessibilityHint(
                calibration.autoStartsPrint
                ? "Saves the calibrated flip setup and starts the waiting document."
                : "Saves the calibrated flip setup for this printer."
            )

            Button("Manual setup") {
                model.returnToFlipSetup()
            }
            .buttonStyle(FlipTertiaryButtonStyle())
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityHint("Leaves calibration and opens manual flip setup.")
        }
    }

    private func missingAnswerText(_ calibration: FlipCalibration) -> String {
        if !calibration.hasConfirmedTray {
            return "Confirm which side landed up."
        }
        return "Confirm the turn direction."
    }
}

// MARK: - Sheet art

private struct CalibrationSheetArt: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: FlipMetrics.paperRadius, style: .continuous)
                .fill(FlipColor.printPaper)
                .overlay {
                    RoundedRectangle(cornerRadius: FlipMetrics.paperRadius, style: .continuous)
                        .strokeBorder(FlipColor.printPaperEdge, lineWidth: 0.7)
                }
                .shadow(color: FlipColor.paperShadow, radius: 7, x: 0, y: 4)

            VStack(spacing: 4) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(FlipColor.coral)
                Text("TOP")
                    .font(.system(size: 7, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(FlipColor.printLine)
                Spacer(minLength: 2)
                Text("FLIP")
                    .font(.system(size: 10, weight: .bold, design: .serif))
                    .foregroundStyle(FlipColor.printLine)
                Text("CALIBRATION")
                    .font(.system(size: 5.5, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(FlipColor.printLine)
                Text("PRINTED SIDE")
                    .font(.system(size: 6.5, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(FlipColor.coralDeep)
                Spacer(minLength: 2)
                Text("SHORT EDGE")
                    .font(.system(size: 5.5, weight: .medium))
                    .foregroundStyle(FlipColor.printLine)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 5)

            HStack {
                Text("LONG")
                    .font(.system(size: 5.5, weight: .bold))
                    .foregroundStyle(FlipColor.coralDeep)
                    .rotationEffect(.degrees(-90))
                Spacer()
                Text("LONG")
                    .font(.system(size: 5.5, weight: .bold))
                    .foregroundStyle(FlipColor.coralDeep)
                    .rotationEffect(.degrees(90))
            }
            .padding(.horizontal, 3)
        }
        .accessibilityHidden(true)
    }
}
