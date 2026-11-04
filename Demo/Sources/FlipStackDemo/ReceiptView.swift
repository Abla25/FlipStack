import SwiftUI
import PDFKit
import AppKit
import UniformTypeIdentifiers
import FlipStackCore

struct ReceiptView: View {
    @ObservedObject var model: AppModel
    @State private var dragOver = false
    @State private var ctaHover = false

    var body: some View {
        ZStack {
            paper.ignoresSafeArea()
            VStack(spacing: 7) {
                headerRow
                DashedRule()
                ScrollView {
                    VStack(spacing: 7) {
                        docArea.transition(.opacity.combined(with: .scale(scale: 0.98)))
                        if model.docURL != nil { EmbeddedPreview(model: model).padding(.vertical, 2) }
                        DashedRule()
                        LineItem(label: T("receipt.duplex"), value: duplexDisplay,
                                 hot: model.duplex, tappable: true) { model.duplex.toggle() }
                        LineItem(label: T("receipt.paper"), value: optionLabel(.paper, model.paper), tappable: true) { model.popover = .paper }
                        LineItem(label: T("receipt.color"), value: colorDisplay, tappable: true) { model.popover = .color }
                        LineItem(label: T("receipt.quality"), value: qualityDisplay, tappable: true) { model.popover = .quality }
                        LineItem(label: T("receipt.copies"), value: "\(model.copies)", tappable: true) { model.popover = .copies }
                        DashedRule()
                        moreSection
                    }
                }
                .scrollIndicators(.hidden)
                totalLine
                printButton
                perforation
                Text(T("app.tagline"))
                    .font(.system(size: 8.5, design: .monospaced)).foregroundStyle(muted)
                if let last = model.lastPrint {
                    Text(T("receipt.lastPrint", last)).font(.system(size: 8.5, design: .monospaced)).foregroundStyle(muted)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 20)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(ink)

            // Overlays — layering (audit fix): settings stays visible while the printer
            // picker / calibration modal open ABOVE it (higher zIndex). Popover + preview
            // are hidden while settings is open. FlowBar sits BELOW settings (zIndex 20)
            // and is not rendered at all while settings is open, so it can never cover QUIT.
            if model.settingsOpen {
                SettingsOverlay(model: model)
            } else {
                if let pop = model.popover { popoverOverlay(pop) }
                if model.previewOpen { PreviewOverlay(model: model) }
            }
            if model.printersOpen { PrinterMenuView(model: model) }
            if model.calibOpen { CalibOverlay(model: model) }
            if model.flowPhase != .idle && !model.settingsOpen { FlowBar(model: model) }
            if let t = model.toast {
                ToastView(msg: t)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 10)
                    .zIndex(80)
            }
        }
        .frame(width: ReceiptPanel.panelWidth, height: ReceiptPanel.panelHeight)
        .preferredColorScheme(.light)   // audit fix: pin the light receipt look in dark mode
        .onDrop(of: [.fileURL], isTargeted: $dragOver) { providers in
            if let p = providers.first {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in model.chooseDoc(url) } }
                }
            }
            return true
        }
    }

    // MARK: localized display helpers (canonical model values stay untranslated)

    func edgeLabel(_ edge: String) -> String {
        T(edge == "long" ? "option.edge.long" : "option.edge.short")
    }

    var duplexDisplay: String {
        model.duplex
            ? T("receipt.duplexOn", edgeLabel(model.duplexEdge).uppercased())
            : T("receipt.duplexOff")
    }

    var colorDisplay: String {
        model.colorMode == "Color" ? T("option.color.color") : T("option.color.bw")
    }

    /// Canonical quality label (used to match the PopMenu current value + assignments).
    var qualityText: String {
        switch model.quality {
        case "draft": return "Draft · 180"
        case "normal": return "Normal · 366"
        default: return "High · 600"
        }
    }

    var qualityDisplay: String { optionLabel(.quality, qualityText) }

    /// Maps a canonical option value to its localized display label.
    func optionLabel(_ kind: PopoverKind, _ value: String) -> String {
        switch kind {
        case .paper:
            switch value {
            case "A4": return T("option.paper.a4")
            case "A3": return T("option.paper.a3")
            case "Letter": return T("option.paper.letter")
            case "Photo 4×6": return T("option.paper.photo4x6")
            default: return value
            }
        case .color:
            return value == "Color" ? T("option.color.color") : T("option.color.bw")
        case .quality:
            if value.hasPrefix("Draft") { return T("quality.draft") }
            if value.hasPrefix("Normal") { return T("quality.normal") }
            return T("quality.high")
        case .duplexEdge:
            return T("option.edge.value", edgeLabel(value.hasPrefix("long") ? "long" : "short"))
        case .orientation:
            switch value {
            case "auto": return T("option.orientation.auto")
            case "portrait": return T("option.orientation.portrait")
            case "landscape": return T("option.orientation.landscape")
            default: return value
            }
        case .scale:
            let n = Int(value.replacingOccurrences(of: "%", with: "")) ?? model.scale
            switch n {
            case 50: return T("option.scale.p50")
            case 75: return T("option.scale.p75")
            case 100: return T("option.scale.p100")
            case 125: return T("option.scale.p125")
            case 150: return T("option.scale.p150")
            default: return value
            }
        case .media:
            switch value {
            case "Plain": return T("option.media.plain")
            case "Glossy": return T("option.media.glossy")
            case "Photo": return T("option.media.photo")
            case "Recycled": return T("option.media.recycled")
            default: return value
            }
        case .tray:
            switch value {
            case "auto": return T("option.tray.auto")
            case "tray1": return T("option.tray.tray1")
            case "tray2": return T("option.tray.tray2")
            default: return value
            }
        case .resOverride:
            if value == "Off" { return T("option.res.off") }
            return T("option.res.dpi", value.replacingOccurrences(of: " dpi", with: ""))
        case .inkSave:
            return value == "On" ? T("common.on") : T("common.off")
        case .copies:
            return value
        case .pages:
            return value
        }
    }

    // MARK: header
    var headerRow: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Button { model.printersOpen.toggle() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "printer.fill").font(.system(size: 12)).foregroundStyle(accent)
                        Text(model.printerName)
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .lineLimit(1).minimumScaleFactor(0.72).truncationMode(.middle).foregroundStyle(ink)
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 7.5)).foregroundStyle(muted)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .frame(minHeight: 28)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 2))
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(accent.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressScale())
                .hoverTint()
                .accessibilityLabel(T("a11y.printerStatus", model.printerName))
                .accessibilityAddTraits(.isButton)
                .help(T("printer.change"))
                Spacer()
                iconButton("eye", a11y: T("a11y.previewDocument"), help: T("preview.openHelp")) {
                    model.previewOpen = true
                }
                iconButton("gear", a11y: T("a11y.settings"), help: T("a11y.settings")) {
                    model.popover = nil
                    model.printersOpen = false
                    model.previewOpen = false
                    model.settingsOpen = true
                }
            }
            HStack(spacing: 5) {
                let sev = model.statusSeverity(model.printerID)
                Circle().fill(sev == 2 ? Color.red : sev == 1 ? Color.orange : model.printerState == .idle ? Color.green : model.printerState == .processing ? Color.orange : .gray)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text(model.statusLabel(model.printerID))
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(muted)
                if model.queuedJobs > 0 {
                    Text(T("header.queuedJobs", Units.jobs(model.queuedJobs)))
                        .font(.system(size: 9, design: .monospaced)).foregroundStyle(muted)
                }
                Spacer()
                Text(model.statusOrigin == .unavailable ? "" : T("header.via", model.statusOrigin.rawValue))
                    .font(.system(size: 8, design: .monospaced)).foregroundStyle(muted.opacity(0.7))
            }
            SupplyBars(supplies: model.supplies)
        }
    }

    func iconButton(_ kind: String, a11y: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: kind == "eye" ? "eye" : "gearshape")
                .font(.system(size: 12)).foregroundStyle(ink)
                .frame(width: 28, height: 28)
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.black.opacity(0.14)))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .hoverTint()
        .accessibilityLabel(a11y)
        .help(help)
    }

    var docArea: some View {
        Group {
            if let name = model.docURL?.lastPathComponent {
                HStack(spacing: 8) {
                    Image(systemName: "doc").foregroundStyle(accent)
                        .frame(width: 26, height: 26)
                        .overlay(Rectangle().stroke(accent, lineWidth: 1.5).frame(width: 26, height: 26))
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 5) {
                            Text(model.documentTag)
                                .font(.system(size: 7.5, weight: .heavy, design: .monospaced))
                                .foregroundStyle(accent)
                                .padding(.horizontal, 3).padding(.vertical, 1)
                                .overlay(Rectangle().stroke(accent.opacity(0.5), lineWidth: 0.8))
                                .accessibilityHidden(true)
                            Text(name).font(.system(size: 11.5, weight: .semibold, design: .monospaced)).lineLimit(1)
                        }
                        Text(T("doc.meta", Units.pages(model.docPages), String(format: "%.1f", model.docSizeMB)))
                            .font(.system(size: 9, design: .monospaced)).foregroundStyle(muted)
                    }
                    Spacer()
                    Button { model.removeDoc() } label: {
                        Image(systemName: "xmark").font(.system(size: 10))
                            .foregroundStyle(muted)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .hoverTint()
                    .accessibilityLabel(T("doc.removeA11y"))
                    .help(T("doc.removeA11y"))
                }
            } else {
                VStack(spacing: 5) {
                    Image(systemName: "doc.badge.plus").font(.system(size: 18)).foregroundStyle(accent)
                    Text(T("doc.dropTitle")).font(.system(size: 12, weight: .semibold, design: .monospaced))
                    Text(T("doc.formats")).font(.system(size: 9, design: .monospaced)).foregroundStyle(muted)
                        .lineLimit(2).minimumScaleFactor(0.8).multilineTextAlignment(.center)
                    Button { chooseFile() } label: {
                        Text(T("doc.chooseFile"))
                            .font(.system(size: 10.5, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .frame(minHeight: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressScale())
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(accent, in: RoundedRectangle(cornerRadius: 2))
                    .accessibilityLabel(T("doc.chooseFile"))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(dragOver ? accent.opacity(0.12) : accent.opacity(0.04))
                .animation(.easeInOut(duration: 0.15), value: dragOver)
                .clipShape(RoundedRectangle(cornerRadius: 2))
                .overlay(RoundedRectangle(cornerRadius: 2).stroke(accent, style: StrokeStyle(lineWidth: 2, dash: [5, 4])))
            }
        }
    }

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.pdf, .image, .jpeg, .heic, .png, .tiff, .content]
        if panel.runModal() == .OK, let url = panel.url { model.chooseDoc(url) }
    }

    // MARK: more options (full-row hit targets — audit fix)
    var moreSection: some View {
        VStack(spacing: 0) {
            Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { model.moreOpen.toggle() } } label: {
                HStack(spacing: 6) {
                    Text(T("receipt.moreOptions")).fontWeight(.bold)
                    DotLeader().frame(height: 10)
                    Text(model.moreOpen ? T("receipt.moreOptionsExpanded", 8) : T("receipt.moreOptionsCollapsed", 8))
                        .foregroundStyle(accent).fontWeight(.bold)
                }
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverTint()
            .accessibilityLabel(T("a11y.moreOptions"))
            .accessibilityAddTraits(.isButton)
            .help(T("a11y.moreOptions"))
            if model.moreOpen {
                VStack(spacing: 0) {
                    ForEach(moreRows, id: \.0) { row in
                        Button { model.popover = row.2 } label: {
                            HStack(spacing: 6) {
                                Text(row.0).foregroundStyle(muted).font(.system(size: 10.5, design: .monospaced))
                                DotLeader().frame(height: 8)
                                HStack(spacing: 2) {
                                    Text(row.1).font(.system(size: 10.5, design: .monospaced))
                                    Image(systemName: "chevron.right").font(.system(size: 8)).foregroundStyle(muted)
                                }
                            }
                            .padding(.leading, 12)
                            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .hoverTint()
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(row.0), \(row.1)")
                        .accessibilityAddTraits(.isButton)
                        .help(row.0)
                    }
                }
                .padding(.top, 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    var moreRows: [(String, String, PopoverKind)] {
        let pagesText: String
        switch model.pagesSel {
        case "odd": pagesText = T("option.pages.odd")
        case "even": pagesText = T("option.pages.even")
        case "custom": pagesText = T("option.pages.customPrefix", model.pageSpec.isEmpty ? T("common.none") : model.pageSpec)
        default: pagesText = T("option.pages.all")
        }
        return [(T("options.pages"), "\(pagesText) (\(model.selectedPages))", .pages),
                (T("options.orientation"), optionLabel(.orientation, model.orientation), .orientation),
                (T("options.scale"), optionLabel(.scale, "\(model.scale)%"), .scale),
                (T("options.media"), optionLabel(.media, model.media), .media),
                (T("options.tray"), optionLabel(.tray, model.tray), .tray),
                (T("options.resOverride"), model.resOverride == "off" ? T("common.off") : T("option.res.dpi", model.resOverride), .resOverride),
                (T("options.inkSave"), model.inkSave ? T("common.on") : T("common.off"), .inkSave),
                (T("options.duplexEdge"), optionLabel(.duplexEdge, "\(model.duplexEdge) edge"), .duplexEdge)]
    }

    var totalLine: some View {
        HStack(spacing: 6) {
            Text(T("receipt.total")).fontWeight(.bold)
            DotLeader().frame(height: 10)
            Text(T("receipt.sheetsDpi", Units.sheets(model.sheets), String(model.dpi))).fontWeight(.bold)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
    }

    /// Why PRINT is unavailable, in priority order (nil = it is available).
    var printBlockReason: String? {
        if model.isPrinting { return nil }
        if model.docURL == nil || model.isPreparingDoc { return T("toast.dropDocumentFirst") }
        if model.printerID.isEmpty || model.printer == nil { return T("error.noPrinter") }
        if model.selectedPageList.isEmpty { return T("error.noPages") }
        return nil
    }

    var printButton: some View {
        VStack(spacing: 4) {
            Button {
                model.startPrint()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "printer.fill")
                    Text(T("receipt.printButton", Units.pages(model.selectedPages).uppercased()))
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
                .font(.system(size: 12.5, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(model.canPrint ? (ctaHover ? accent.opacity(0.82) : accent) : accent.opacity(0.4),
                            in: RoundedRectangle(cornerRadius: 2))
                .animation(.easeOut(duration: 0.15), value: ctaHover)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressScale())
            .disabled(!model.canPrint)
            .onHover { ctaHover = $0 }
            .accessibilityLabel(T("a11y.print"))
            .help(printBlockReason ?? T("a11y.print"))
            if let reason = printBlockReason {
                Text(reason)
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(muted)
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .accessibilityLabel(reason)
            }
        }
    }

    var perforation: some View {
        ZStack(alignment: .trailing) {
            DashedRule()
            Text("✂").font(.system(size: 11)).foregroundStyle(muted)
                .background(paper).padding(.trailing, 6).offset(y: -0.5)
        }.padding(.top, 6)
    }

    // MARK: popover
    @ViewBuilder
    func popoverOverlay(_ kind: PopoverKind) -> some View {
        if kind == .pages { PagesPopoverView(model: model) }
        else {
            let cfg: (title: String, options: [String], current: String) = {
                switch kind {
                case .paper: return (T("receipt.paper"), ["A4", "A3", "Letter", "Photo 4×6"], model.paper)
                case .color: return (T("receipt.color"), ["Color", "B&W"], model.colorMode)
                case .quality: return (T("receipt.quality"), ["Draft · 180", "Normal · 366", "High · 600"], qualityText)
                case .copies: return (T("receipt.copies"), (1...5).map(String.init), "\(model.copies)")
                case .duplexEdge: return (T("options.duplexEdge"), ["long edge", "short edge"], "\(model.duplexEdge) edge")
                case .orientation: return (T("options.orientation"), ["auto", "portrait", "landscape"], model.orientation)
                case .scale: return (T("options.scale"), ["50%", "75%", "100%", "125%", "150%"], "\(model.scale)%")
                case .media: return (T("options.media"), ["Plain", "Glossy", "Photo", "Recycled"], model.media)
                case .tray: return (T("options.tray"), ["auto", "tray1", "tray2"], model.tray)
                case .resOverride: return (T("options.resOverrideTitle"), ["Off", "180 dpi", "366 dpi", "600 dpi"],
                                           model.resOverride == "off" ? "Off" : "\(model.resOverride) dpi")
                case .inkSave: return (T("options.inkSave"), ["Off", "On"], model.inkSave ? "On" : "Off")
                case .pages: return ("", [], "")
                }
            }()
            ZStack {
                Color.black.opacity(0.25).ignoresSafeArea()
                    .onTapGesture { model.popover = nil }
                    .accessibilityHidden(true)
                PopMenu(title: cfg.title, options: cfg.options, current: cfg.current,
                        onPick: { pick(kind, $0) }, onClose: { model.popover = nil },
                        label: { optionLabel(kind, $0) })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .zIndex(40)
            .transition(.scale(scale: 0.92).combined(with: .opacity))
        }
    }

    func pick(_ kind: PopoverKind, _ v: String) {
        switch kind {
        case .paper: model.paper = v
        case .color: model.colorMode = v
        case .quality: model.quality = v.hasPrefix("Draft") ? "draft" : v.hasPrefix("Normal") ? "normal" : "high"
        case .copies: model.copies = Int(v) ?? 1
        case .duplexEdge: model.duplexEdge = v.hasPrefix("long") ? "long" : "short"
        case .orientation: model.orientation = v
        case .scale: model.scale = Int(v.dropLast()) ?? 100
        case .media: model.media = v
        case .tray: model.tray = v
        case .resOverride: model.resOverride = v == "Off" ? "off" : v.components(separatedBy: " ").first ?? "off"
        case .inkSave: model.inkSave = v == "On"
        case .pages: break
        }
        model.popover = nil
    }
}

// MARK: - Pages popover (no free-text field: keyboard is impossible in the nonactivating panel)
struct PagesPopoverView: View {
    @ObservedObject var model: AppModel
    @State private var from = 1
    @State private var to = 1
    @State private var initialized = false

    private var total: Int { max(model.docPages, 0) }
    private var count: Int { total > 0 && from >= 1 && to >= from && to <= total ? to - from + 1 : 0 }
    private var currentPreset: String {
        switch model.pagesSel {
        case "all", "odd", "even": return model.pagesSel
        default: return "custom"
        }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
                .onTapGesture { model.popover = nil }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text(T("pages.title"))
                    .font(.system(size: 9, weight: .heavy, design: .monospaced)).foregroundStyle(muted)
                HStack(spacing: 5) {
                    presetButton(T("option.pages.all"), "all")
                    presetButton(T("option.pages.odd"), "odd")
                    presetButton(T("option.pages.even"), "even")
                }
                if total > 0 {
                    stepperRow(T("pages.from"), value: $from) { newValue in
                        from = min(max(newValue, 1), total)
                        if to < from { to = from }
                    }
                    stepperRow(T("pages.to"), value: $to) { newValue in
                        to = min(max(newValue, 1), total)
                        if from > to { from = to }
                    }
                    if count == 0 {
                        Text(T("pages.invalidRange"))
                            .font(.system(size: 9, design: .monospaced)).foregroundStyle(accent)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text(T("error.documentNoPages"))
                        .font(.system(size: 9, design: .monospaced)).foregroundStyle(muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                applyButton
                Button { model.popover = nil } label: {
                    Text(T("common.cancel"))
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(muted)
                        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(T("common.cancel"))
            }
            .padding(12)
            .frame(width: 230)
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .shadow(color: .black.opacity(0.3), radius: 18, y: 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear { syncFromSelection() }
        }
        .zIndex(40)
        .transition(.scale(scale: 0.92).combined(with: .opacity))
    }

    /// Small extraction keeps the ViewBuilder type-checking fast.
    func presetButton(_ label: String, _ value: String) -> some View {
        Button {
            model.pagesSel = value
            model.pageSpec = ""
            model.popover = nil
        } label: {
            Text(label)
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .lineLimit(1).minimumScaleFactor(0.7)
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, minHeight: 28)
                .background(currentPreset == value ? accent : Color.gray.opacity(0.15))
                .foregroundStyle(currentPreset == value ? .white : ink)
                .clipShape(Capsule())
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .accessibilityLabel(label)
        .accessibilityAddTraits(currentPreset == value ? [.isButton, .isSelected] : .isButton)
        .help(label)
    }

    var applyButton: some View {
        Button {
            guard count > 0 else { return }
            model.applyPageRange(from: from, to: to)
            model.popover = nil
        } label: {
            Text(T("pages.apply", Units.pages(count)))
                .font(.system(size: 11, weight: .heavy)).foregroundStyle(.white)
                .lineLimit(1).minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity, minHeight: 34)
                .background(count > 0 ? accent : accent.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .disabled(count == 0)
        .accessibilityLabel(T("pages.apply", Units.pages(count)))
        .help(T("pages.apply", Units.pages(count)))
    }

    /// −/value/+ row; every control has a >= 28 pt hit target.
    func stepperRow(_ title: String, value: Binding<Int>, set: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(muted)
                .frame(width: 52, alignment: .leading)
                .lineLimit(1).minimumScaleFactor(0.75)
            stepButton("minus", a11y: T("a11y.decrease")) { set(value.wrappedValue - 1) }
            Text("\(value.wrappedValue)")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .frame(width: 34)
            stepButton("plus", a11y: T("a11y.increase")) { set(value.wrappedValue + 1) }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 28)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    func stepButton(_ kind: String, a11y: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: kind == "minus" ? "minus" : "plus")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(ink)
                .frame(width: 28, height: 28)
                .background(Color.gray.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .accessibilityLabel(a11y)
        .help(a11y)
    }

    private func syncFromSelection() {
        guard !initialized else { return }
        initialized = true
        if model.pagesSel == "custom" {
            let list = model.selectedPageList
            if let first = list.first, let last = list.last, total > 0 {
                from = min(max(first, 1), total)
                to = min(max(last, from), total)
                return
            }
        }
        from = 1
        to = max(total, 1)
    }
}

// MARK: - Printer picker (scrollable, loading/empty states, refresh)
struct PrinterMenuView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            header
            if model.printers.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(model.printers) { p in
                            printerRow(p)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(maxHeight: 360)
            }
        }
        .frame(width: 225)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.3), radius: 18, y: 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(.top, 56).padding(.trailing, 10)
        .preferredColorScheme(.light)
        .zIndex(60)   // above SettingsOverlay (30) — the settings row must show the picker on top
        .transition(.scale(scale: 0.94).combined(with: .opacity))
        .onAppear { if model.printers.isEmpty && !model.printersLoading { model.refreshPrinters() } }
    }

    var header: some View {
        HStack(spacing: 6) {
            Text(T("printer.menuTitle"))
                .font(.system(size: 9, weight: .heavy, design: .monospaced)).foregroundStyle(muted)
            Spacer()
            if model.printersLoading { ProgressView().controlSize(.small) }
            Button { model.refreshPrinters() } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(ink)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.printersLoading)
            .accessibilityLabel(T("printer.refreshA11y"))
            .help(T("printer.refreshA11y"))
            Button { model.printersOpen = false } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(muted)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(T("common.close"))
            .help(T("common.close"))
        }
        .padding(.horizontal, 8).padding(.top, 6)
    }

    var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.printersLoading ? T("printer.loading") : T("printer.none"))
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(muted)
                .fixedSize(horizontal: false, vertical: true)
            Text(T("printer.noneHint"))
                .font(.system(size: 9, design: .monospaced)).foregroundStyle(muted.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
            Button { model.refreshPrinters() } label: {
                Text(T("common.refresh"))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(accent)
                    .frame(maxWidth: .infinity, minHeight: 30)
                    .overlay(Rectangle().stroke(accent.opacity(0.5)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(T("printer.refreshA11y"))
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
    }

    /// Compact status for the 225 pt-wide picker (full label stays in a11y).
    func shortStatus(_ id: String) -> String {
        switch model.statusSeverity(id) {
        case 2: return T("status.offline")
        case 1: return T("status.checkPrinterShort")
        default:
            let state = model.printerStates[id]?.state ?? model.printers.first(where: { $0.id == id })?.state
            switch state {
            case .idle: return T("status.ready")
            case .processing: return T("status.printing")
            case .stopped: return T("status.stopped")
            case .unknown, .none: return T("status.unknown")
            }
        }
    }

    @ViewBuilder
    func printerRow(_ p: Printer) -> some View {
        Button { model.pickPrinter(p.id) } label: {
            HStack(spacing: 8) {
                let sev = model.statusSeverity(p.id)
                Circle().fill(sev == 2 ? Color.red : sev == 1 ? Color.orange : (model.printerStates[p.id]?.state ?? p.state) == .idle ? Color.green : (model.printerStates[p.id]?.state ?? p.state) == .processing ? Color.orange : .gray)
                    .frame(width: 8, height: 8)
                Text(p.name).font(.system(size: 12, weight: model.printerID == p.id ? .bold : .medium))
                    .lineLimit(1).minimumScaleFactor(0.75)
                Spacer(minLength: 4)
                Text(shortStatus(p.id))
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(sev == 2 ? .red : sev == 1 ? .orange : muted)
                    .lineLimit(1).minimumScaleFactor(0.7).layoutPriority(1)
                if p.isDefault {
                    Text(T("printer.defaultShort")).font(.system(size: 8, design: .monospaced)).foregroundStyle(muted)
                }
                if model.printerID == p.id { Text("✓").foregroundStyle(accent) }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverTint()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(p.name), \(model.statusLabel(p.id))")
        .accessibilityAddTraits(model.printerID == p.id ? [.isButton, .isSelected] : .isButton)
        .help(p.name)
    }

}
