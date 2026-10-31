import FlipStackCore
import SwiftUI

@MainActor
struct HeaderView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var orchestrator: DuplexOrchestrator

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .title2) private var printerNameSize: CGFloat = 25
    @State private var isPickerOpen = false
    @State private var hoveredPrinterID: String?

    private var printer: Printer? { model.selectedPrinter }

    private var isLocked: Bool {
        !orchestrator.phase.isIdle
            || model.isPreparingPrint
            || model.flipAxisSetup != nil
            || model.flipCalibration != nil
    }

    private var modelLine: String {
        if model.isLoadingPPD { return "Reading driver options…" }
        if let name = printer?.modelName, !name.isEmpty,
           name.caseInsensitiveCompare(printer?.displayName ?? "") != .orderedSame {
            return name
        }
        if let name = model.ppd?.displayName, !name.isEmpty,
           name.caseInsensitiveCompare(printer?.displayName ?? "") != .orderedSame {
            return name
        }
        if let uri = printer?.deviceURI?.lowercased() {
            if uri.hasPrefix("usb://") || uri.hasPrefix("hp:/") {
                return "USB printer"
            }
            if uri.hasPrefix("dnssd://") || uri.hasPrefix("ipp://")
                || uri.hasPrefix("ipps://") || uri.hasPrefix("socket://")
                || uri.hasPrefix("lpd://") {
                return "Network printer"
            }
        }
        guard let printer else { return "No printer selected" }
        return "Print queue · \(printer.id)"
    }

    private var stateReasons: [String] {
        Array(model.activeStateReasons.prefix(3))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            brandRow
                .padding(.horizontal, FlipMetrics.gutter)
                .padding(.top, 13)
                .padding(.bottom, 9)

            identityRow
                .padding(.horizontal, FlipMetrics.gutter)

            if !stateReasons.isEmpty {
                noticeRow
                    .padding(.horizontal, FlipMetrics.gutter)
                    .padding(.top, 7)
            } else if let healthNote = model.printerHealthNote,
                      model.printerHealth == .offline
                        || model.printerHealth == .unknown
                        || model.printerHealth == .attention {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: model.printerHealth == .offline ? "exclamationmark.triangle" : "info.circle")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(model.printerHealth == .offline ? FlipColor.warning : FlipColor.tertiaryInk)
                    Text(healthNote)
                        .font(FlipType.caption)
                        .foregroundStyle(FlipColor.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineSpacing(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, FlipMetrics.gutter)
                .padding(.top, 7)
                .accessibilityElement(children: .combine)
            }

            if let printer,
               model.flipAxisSetup == nil,
               model.flipCalibration == nil {
                supplySection(for: printer)
            }

            if isPickerOpen {
                printerPicker
                    .padding(.horizontal, FlipMetrics.gutter)
                    .padding(.top, 10)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
            }

            Rectangle()
                .fill(FlipColor.hairline)
                .frame(height: 0.5)
                .padding(.top, 11)
        }
        .background {
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                Rectangle().fill(Color.primary.opacity(0.012))
            }
        }
        .onChange(of: isLocked) { locked in
            if locked, isPickerOpen {
                withAnimation(FlipMotion.quick(reduceMotion)) {
                    isPickerOpen = false
                }
            }
        }
    }

    // MARK: Brand row

    private var brandRow: some View {
        HStack(spacing: 8) {
            FlipStackMark(size: 20)
            Text("FLIPSTACK")
                .font(.system(size: 9.5, weight: .bold))
                .tracking(1.85)
                .foregroundStyle(FlipColor.ink.opacity(0.72))
            Rectangle()
                .fill(FlipColor.hairline)
                .frame(width: 1, height: 9)
            Text("PRINT STUDIO")
                .font(.system(size: 8.5, weight: .medium))
                .tracking(1.2)
                .foregroundStyle(FlipColor.tertiaryInk)
            Spacer(minLength: 6)

            Button {
                guard !isLocked, !model.isLoadingPrinters, !model.isRefreshing else { return }
                Task { await model.refreshAll() }
            } label: {
                if model.isLoadingPrinters || model.isRefreshing {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(FlipIconButtonStyle())
            .disabled(isLocked || model.isLoadingPrinters || model.isRefreshing)
            .opacity(isLocked ? 0.45 : 1)
            .help(isLocked ? "Refresh is unavailable while a print is in progress" : "Refresh printers, status and queue")
            .accessibilityLabel("Refresh printers and status")
            .accessibilityValue(isLocked ? "Unavailable while printing" : "Available")
            .accessibilityHint("Checks the print system and the selected printer again.")
        }
        .frame(height: 26)
    }

    // MARK: Identity

    private var identityRow: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                if let printer {
                    Button {
                        togglePicker()
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(printer.displayName)
                                .font(.system(
                                    size: min(printerNameSize, 29),
                                    weight: .semibold,
                                    design: .serif
                                ))
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .minimumScaleFactor(0.82)
                            if isLocked {
                                Image(systemName: "lock.fill")
                                    .font(.system(size: 7.5, weight: .semibold))
                                    .foregroundStyle(FlipColor.tertiaryInk)
                                    .offset(y: -1)
                            } else if model.printers.count > 1 {
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 8.5, weight: .bold))
                                    .rotationEffect(.degrees(isPickerOpen ? 180 : 0))
                                    .foregroundStyle(FlipColor.tertiaryInk)
                                    .offset(y: -1)
                            }
                        }
                        .foregroundStyle(FlipColor.ink)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isLocked)
                    .allowsHitTesting(!isLocked && model.printers.count > 1)
                    .help(isLocked ? "Printer switching is unavailable during a print" : "Switch printer")
                    .accessibilityLabel("Printer, \(printer.displayName)")
                    .accessibilityValue(isPickerOpen ? "Expanded" : "Collapsed")
                    .accessibilityHint(
                        isLocked
                        ? "Printer switching is unavailable while a print is in progress."
                        : (model.printers.count > 1
                           ? "Shows the other printers on this Mac."
                           : "This is the only printer on this Mac.")
                    )

                    Text(modelLine)
                        .font(FlipType.caption)
                        .foregroundStyle(FlipColor.tertiaryInk)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text(model.isLoadingPrinters ? "Finding a printer" : "No printer")
                        .font(.system(size: min(printerNameSize, 29), weight: .semibold, design: .serif))
                        .foregroundStyle(FlipColor.ink)
                        .lineLimit(1)
                        .accessibilityAddTraits(.isHeader)
                    Text(model.isLoadingPrinters ? "Checking this Mac" : "Nothing connected yet")
                        .font(FlipType.caption)
                        .foregroundStyle(FlipColor.tertiaryInk)
                }
            }

            Spacer(minLength: 4)

            if let printer {
                VStack(alignment: .trailing, spacing: 5) {
                    HStack(spacing: 5) {
                        FlipHealthDot(
                            health: model.printerHealth,
                            size: 6.5,
                            animates: true
                        )
        Text(model.printerHealth.label)
                            .font(FlipType.captionStrong)
                            .foregroundStyle(
                                model.printerHealth == .offline
                                ? FlipColor.warning
                                : (model.printerHealth == .waiting || model.printerHealth == .preparing)
                                    ? FlipColor.coralDeep
                                    : FlipColor.secondaryInk
                            )
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Printer state")
                    .accessibilityValue(
                        stateReasons.isEmpty
                        ? model.printerHealth.label
                        : "\(model.printerHealth.label), \(stateReasons.joined(separator: ", "))"
                    )

                    if printer.isDefault {
                        Text("DEFAULT")
                            .font(.system(size: 7.5, weight: .semibold))
                            .tracking(1.1)
                            .foregroundStyle(FlipColor.tertiaryInk)
                    }
                }
                .padding(.top, 5)
            }
        }
    }

    // MARK: Notices and supplies

    private var noticeRow: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(FlipColor.warning)
            Text(stateReasons.joined(separator: " · "))
                .font(FlipType.caption)
                .foregroundStyle(FlipColor.secondaryInk)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .help(stateReasons.joined(separator: "\n"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Printer notice")
        .accessibilityValue(stateReasons.joined(separator: ", "))
    }

    @ViewBuilder
    private func supplySection(for printer: Printer) -> some View {
        if let supplies = model.displayStatus?.supplies, !supplies.isEmpty {
            supplyRow(for: printer, supplies: supplies)
                .padding(.horizontal, FlipMetrics.gutter)
                .padding(.top, 10)
        } else if let note = model.supplyFallbackNote {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "drop.triangle")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(FlipColor.secondaryInk)
                    .frame(width: 11, height: 12, alignment: .top)
                Text(note)
                    .font(FlipType.caption)
                    .foregroundStyle(FlipColor.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, FlipMetrics.gutter)
            .padding(.top, 8)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Supply levels. \(note)")
        }
    }

    private func supplyRow(for printer: Printer, supplies: [SupplyLevel]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(stride(from: 0, to: supplies.count, by: 6)), id: \.self) { start in
                let end = min(start + 6, supplies.count)
                let row = Array(supplies[start..<end])
                let width = supplyWidth(for: row.count)
                HStack(alignment: .top, spacing: 6) {
                    ForEach(row) { supply in
                        FlipSupplyMeter(supply: supply, width: width)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Supply levels for \(printer.displayName)")
    }

    private func supplyWidth(for count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        let available = FlipMetrics.panelWidth - FlipMetrics.gutter * 2
        return min(84, max(42, (available - CGFloat(count - 1) * 6) / CGFloat(count)))
    }

    // MARK: Picker

    private func togglePicker() {
        guard !isLocked, model.printers.count > 1 else { return }
        let opening = !isPickerOpen
        withAnimation(FlipMotion.standard(reduceMotion)) {
            isPickerOpen.toggle()
        }
        if opening {
            Task { await model.refreshDiscovery() }
        }
    }

    private var printerPicker: some View {
        VStack(spacing: 0) {
            HStack {
                FlipEyebrow("Choose a printer")
                Spacer()
                if model.isLoadingPrinters || model.isDiscoveringPrinters {
                    ProgressView().controlSize(.mini)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 4)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 1) {
                    ForEach(model.printers) { candidate in
                        printerRow(candidate)
                    }

                    if !model.discoveredPrinters.isEmpty {
                        HStack(spacing: 5) {
                            Image(systemName: "dot.radiowaves.left.and.right")
                                .font(.system(size: 8, weight: .semibold))
                            FlipEyebrow("Detected nearby")
                            Spacer()
                            Text("\(model.discoveredPrinters.count)")
                                .font(.system(size: 8, weight: .semibold, design: .rounded))
                                .foregroundStyle(FlipColor.tertiaryInk)
                        }
                        .padding(.horizontal, 8)
                        .padding(.top, 8)
                        .padding(.bottom, 3)
                        .accessibilityElement(children: .combine)

                        ForEach(Array(model.discoveredPrinters.prefix(6))) { device in
                            DiscoveredPrinterRow(device: device, compact: true)
                        }
                    }

                    if let note = model.discoveryNote {
                        Text(note)
                            .font(FlipType.caption)
                            .foregroundStyle(FlipColor.tertiaryInk)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .accessibilityLabel("Printer detection notice, \(note)")
                    }
                }
                .padding(.horizontal, 5)
                .padding(.bottom, 5)
            }
            .frame(maxHeight: 172)
        }
        .background(
            RoundedRectangle(cornerRadius: FlipMetrics.compactRadius, style: .continuous)
                .fill(FlipColor.paper.opacity(0.52))
        )
        .overlay {
            RoundedRectangle(cornerRadius: FlipMetrics.compactRadius, style: .continuous)
                .strokeBorder(FlipColor.hairline, lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
    }

    private func printerRow(_ candidate: Printer) -> some View {
        let isSelected = candidate.id == model.selectedPrinter?.id
        let isHovered = candidate.id == hoveredPrinterID
        let health = health(for: candidate)

        return Button {
            guard !isLocked else { return }
            withAnimation(FlipMotion.quick(reduceMotion)) {
                isPickerOpen = false
            }
            Task { await model.selectPrinter(candidate) }
        } label: {
            HStack(spacing: 8) {
                FlipHealthDot(health: health, size: 6)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(candidate.displayName)
                            .font(FlipType.bodyStrong)
                            .foregroundStyle(FlipColor.ink)
                            .lineLimit(1)
                        if candidate.isDefault {
                            Text("DEFAULT")
                                .font(.system(size: 7, weight: .semibold))
                                .tracking(0.8)
                                .foregroundStyle(FlipColor.tertiaryInk)
                        }
                    }
                    Text(candidate.modelName ?? "Print queue · \(candidate.id)")
                        .font(FlipType.caption)
                        .foregroundStyle(FlipColor.tertiaryInk)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(FlipColor.coralDeep)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: FlipMetrics.smallRadius, style: .continuous)
                    .fill(isHovered ? FlipColor.tone : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredPrinterID = hovering ? candidate.id : (hoveredPrinterID == candidate.id ? nil : hoveredPrinterID)
        }
        .disabled(isLocked)
        .accessibilityLabel("\(candidate.displayName), \(health.label)")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint("Switches FlipStack to this printer.")
    }

    private func health(for candidate: Printer) -> PrinterHealth {
        if candidate.state == .stopped || !candidate.acceptsJobs {
            return .attention
        }
        if candidate.stateReasons.contains("offline-report") {
            return .offline
        }
        if candidate.state == .processing {
            return .printing
        }
        if candidate.state == .idle {
            return .ready
        }
        return .unknown
    }
}
