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
                        LineItem(label: "Duplex", value: model.duplex ? "ON · \(model.duplexEdge.uppercased()) EDGE" : "OFF",
                                 hot: model.duplex, tappable: true) { model.duplex.toggle() }
                        LineItem(label: "Paper", value: model.paper, tappable: true) { model.popover = .paper }
                        LineItem(label: "Color", value: model.colorMode, tappable: true) { model.popover = .color }
                        LineItem(label: "Quality", value: qualityText, tappable: true) { model.popover = .quality }
                        LineItem(label: "Copies", value: "\(model.copies)", tappable: true) { model.popover = .copies }
                        DashedRule()
                        moreSection
                    }
                }
                .scrollIndicators(.hidden)
                totalLine
                printButton
                perforation
                Text("*** THANK YOU — DUPLEX DONE RIGHT ***")
                    .font(.system(size: 8.5, design: .monospaced)).foregroundStyle(muted)
                if let last = model.lastPrint {
                    Text("last: \(last)").font(.system(size: 8.5, design: .monospaced)).foregroundStyle(muted)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 20)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(ink)

            // overlays — settings is modal and exclusive so nothing can eat its clicks
            if model.settingsOpen {
                SettingsOverlay(model: model)
            } else {
                if let pop = model.popover { popoverOverlay(pop) }
                if model.printersOpen { printerMenu }
                if model.previewOpen { PreviewOverlay(model: model) }
                if model.calibOpen { CalibOverlay(model: model) }
            }
            if model.flowPhase != .idle { FlowBar(model: model) }
            if let t = model.toast { ToastView(msg: t).frame(maxHeight: .infinity, alignment: .top).padding(.top, 10).zIndex(60) }
        }
        .frame(width: ReceiptPanel.panelWidth, height: ReceiptPanel.panelHeight)
        .onDrop(of: [.fileURL], isTargeted: $dragOver) { providers in
            if let p = providers.first {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in model.chooseDoc(url) } }
                }
            }
            return true
        }
    }

    var qualityText: String {
        switch model.quality {
        case "draft": return "Draft · 180"
        case "normal": return "Normal · 366"
        default: return "High · 600"
        }
    }

    // Header: printer name (tap to switch) + live status + real ink levels below
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
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 2))
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(accent.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                }
                .buttonStyle(PressScale())
                .hoverTint()
                Spacer()
                iconButton("eye") { model.previewOpen = true }
                iconButton("gear") { model.popover = nil; model.printersOpen = false; model.previewOpen = false; model.settingsOpen = true }
            }
            HStack(spacing: 5) {
                let sev = model.statusSeverity(model.printerID)
                Circle().fill(sev == 2 ? Color.red : sev == 1 ? Color.orange : model.printerState == .idle ? Color.green : model.printerState == .processing ? Color.orange : .gray)
                    .frame(width: 7, height: 7)
                Text(model.statusLabel(model.printerID))
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(muted)
                if model.queuedJobs > 0 {
                    Text("· \(model.queuedJobs) job\(model.queuedJobs == 1 ? "" : "s") queued")
                        .font(.system(size: 9, design: .monospaced)).foregroundStyle(muted)
                }
                Spacer()
                Text(model.statusOrigin == .unavailable ? "" : "via \(model.statusOrigin.rawValue)")
                    .font(.system(size: 8, design: .monospaced)).foregroundStyle(muted.opacity(0.7))
            }
            SupplyBars(supplies: model.supplies)
        }
    }

    func iconButton(_ kind: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: kind == "eye" ? "eye" : "gearshape")
                .font(.system(size: 12)).foregroundStyle(ink)
                .frame(width: 26, height: 26)
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.black.opacity(0.14)))
        }
        .buttonStyle(PressScale())
        .hoverTint()
    }

    var docArea: some View {
        Group {
            if let name = model.docURL?.lastPathComponent {
                HStack(spacing: 8) {
                    Image(systemName: "doc").foregroundStyle(accent)
                        .frame(width: 26, height: 26)
                        .overlay(Rectangle().stroke(accent, lineWidth: 1.5).frame(width: 26, height: 26))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(name).font(.system(size: 11.5, weight: .semibold, design: .monospaced)).lineLimit(1)
                        Text("\(model.docPages) pages · \(String(format: "%.1f", model.docSizeMB)) MB")
                            .font(.system(size: 9, design: .monospaced)).foregroundStyle(muted)
                    }
                    Spacer()
                    Button { model.removeDoc() } label: { Image(systemName: "xmark").font(.system(size: 10)) }
                        .buttonStyle(.plain).foregroundStyle(muted).hoverTint()
                }
            } else {
                VStack(spacing: 5) {
                    Image(systemName: "doc.badge.plus").font(.system(size: 18)).foregroundStyle(accent)
                    Text("Drop a document").font(.system(size: 12, weight: .semibold, design: .monospaced))
                    Text("PDF · JPEG · HEIC · PNG · DOCX — lossless").font(.system(size: 9, design: .monospaced)).foregroundStyle(muted)
                    Button("Choose file") { chooseFile() }
                        .buttonStyle(PressScale())
                        .font(.system(size: 10.5, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(accent, in: RoundedRectangle(cornerRadius: 2))
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

    var moreSection: some View {
        VStack(spacing: 0) {
            Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { model.moreOpen.toggle() } } label: {
                HStack(spacing: 6) {
                    Text("More options").fontWeight(.bold)
                    DotLeader().frame(height: 10)
                    Text(model.moreOpen ? "▾ 8" : "▸ 8").foregroundStyle(accent).fontWeight(.bold)
                }
            }
            .buttonStyle(.plain).hoverTint()
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
                            .padding(.leading, 12).padding(.vertical, 4)
                        }
                        .buttonStyle(.plain).hoverTint()
                    }
                }
                .padding(.top, 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    var moreRows: [(String, String, PopoverKind)] {
        let pagesText = model.pagesSel == "all" ? "All"
            : model.pagesSel == "odd" ? "Odd only"
            : model.pagesSel == "even" ? "Even only"
            : "Custom: \(model.pageSpec.isEmpty ? "—" : model.pageSpec)"
        return [("Pages", "\(pagesText) (\(model.selectedPages))", .pages),
         ("Orientation", model.orientation, .orientation),
         ("Scale", "\(model.scale)%", .scale),
         ("Media", model.media, .media),
         ("Tray", model.tray == "auto" ? "Auto" : model.tray, .tray),
         ("Res. override", model.resOverride == "off" ? "Off" : "\(model.resOverride) dpi", .resOverride),
         ("Ink save", model.inkSave ? "On" : "Off", .inkSave),
         ("Duplex edge", "\(model.duplexEdge) edge", .duplexEdge)]
    }

    var totalLine: some View {
        HStack(spacing: 6) {
            Text("TOTAL").fontWeight(.bold)
            DotLeader().frame(height: 10)
            Text("\(model.sheets) SHEET\(model.sheets == 1 ? "" : "S") · \(model.dpi) DPI").fontWeight(.bold)
        }
    }

    var printButton: some View {
        Button {
            model.startPrint()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "printer.fill")
                Text("PRINT \(model.selectedPages) PAGE\(model.selectedPages == 1 ? "" : "S")")
            }
            .font(.system(size: 12.5, weight: .heavy, design: .monospaced))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(model.docURL == nil ? accent.opacity(0.4) : ctaHover ? accent.opacity(0.82) : accent, in: RoundedRectangle(cornerRadius: 2))
            .animation(.easeOut(duration: 0.15), value: ctaHover)
        }
        .buttonStyle(PressScale())
        .disabled(model.docURL == nil)
        .onHover { ctaHover = $0 }
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
        if kind == .pages { pagesPopover }
        else {
            let cfg: (title: String, options: [String], current: String) = {
                switch kind {
                case .paper: return ("Paper", ["A4", "A3", "Letter", "Photo 4×6"], model.paper)
                case .color: return ("Color", ["Color", "B&W"], model.colorMode)
                case .quality: return ("Quality", ["Draft · 180", "Normal · 366", "High · 600"], qualityText)
                case .copies: return ("Copies", (1...5).map(String.init), "\(model.copies)")
                case .duplexEdge: return ("Duplex edge", ["long edge", "short edge"], "\(model.duplexEdge) edge")
                case .orientation: return ("Orientation", ["auto", "portrait", "landscape"], model.orientation)
                case .scale: return ("Scale", ["50%", "75%", "100%", "125%", "150%"], "\(model.scale)%")
                case .media: return ("Media", ["Plain", "Glossy", "Photo", "Recycled"], model.media)
                case .tray: return ("Tray", ["auto", "tray1", "tray2"], model.tray)
                case .resOverride: return ("Resolution override", ["Off", "180 dpi", "366 dpi", "600 dpi"], model.resOverride == "off" ? "Off" : "\(model.resOverride) dpi")
                case .inkSave: return ("Ink save", ["Off", "On"], model.inkSave ? "On" : "Off")
                case .pages: return ("", [], "")
                }
            }()
            ZStack {
                Color.black.opacity(0.25).ignoresSafeArea().onTapGesture { model.popover = nil }
                PopMenu(title: cfg.title, options: cfg.options, current: cfg.current,
                        onPick: { pick(kind, $0) }, onClose: { model.popover = nil })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .zIndex(40)
            .transition(.scale(scale: 0.92).combined(with: .opacity))
        }
    }

    // Pages popover with custom range entry ("1-5, 8, 12-14")
    var pagesPopover: some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea().onTapGesture { model.popover = nil }
            VStack(alignment: .leading, spacing: 8) {
                Text("PAGES").font(.system(size: 9, weight: .heavy, design: .monospaced)).foregroundStyle(muted)
                HStack(spacing: 5) {
                    ForEach(["All", "Odd only", "Even only"], id: \.self) { o in
                        Button {
                            model.pagesSel = o == "All" ? "all" : o == "Odd only" ? "odd" : "even"
                            model.popover = nil
                        } label: {
                            Text(o).font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                                .padding(.horizontal, 8).padding(.vertical, 5)
                                .background(model.pagesSel == (o == "All" ? "all" : o == "Odd only" ? "odd" : "even") ? accent : Color.gray.opacity(0.15))
                                .foregroundStyle(model.pagesSel == (o == "All" ? "all" : o == "Odd only" ? "odd" : "even") ? .white : ink)
                                .clipShape(Capsule())
                        }.buttonStyle(PressScale())
                    }
                }
                Text("Custom (e.g. 1-5, 8, 12-14)").font(.system(size: 9, design: .monospaced)).foregroundStyle(muted)
                TextField("1-…", text: $model.customPagesDraft)
                    .font(.system(size: 12, design: .monospaced))
                    .textFieldStyle(.plain)
                    .padding(6).background(Color.gray.opacity(0.12)).clipShape(RoundedRectangle(cornerRadius: 6))
                Button {
                    let list = PrintMath.parsePageSpec(model.customPagesDraft, total: max(model.docPages, 1))
                    model.pageSpec = PrintMath.compressRange(list)
                    model.pagesSel = "custom"
                    model.popover = nil
                } label: {
                    Text("Apply \(PrintMath.parsePageSpec(model.customPagesDraft, total: max(model.docPages, 1)).count) pages")
                        .font(.system(size: 11, weight: .heavy)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                        .background(accent, in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(PressScale())
                Button("Cancel") { model.popover = nil }
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(muted)
            }
            .padding(12)
            .frame(width: 230)
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .shadow(color: .black.opacity(0.3), radius: 18, y: 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    // MARK: printer menu (real CUPS queues with live power/status)
    var printerMenu: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("PRINTERS").font(.system(size: 9, weight: .heavy, design: .monospaced)).foregroundStyle(muted).padding(8)
            ForEach(model.printers) { p in
                Button {
                    model.pickPrinter(p.id)
                } label: {
                    HStack(spacing: 8) {
                        let sev = model.statusSeverity(p.id)
                        Circle().fill(sev == 2 ? Color.red : sev == 1 ? Color.orange : (model.printerStates[p.id]?.state ?? p.state) == .idle ? Color.green : (model.printerStates[p.id]?.state ?? p.state) == .processing ? Color.orange : .gray).frame(width: 8, height: 8)
                        Text(p.name).font(.system(size: 12, weight: model.printerID == p.id ? .bold : .medium)).lineLimit(1)
                        Spacer()
                        Text(model.statusLabel(p.id)).font(.system(size: 9, design: .monospaced)).foregroundStyle(sev == 2 ? .red : sev == 1 ? .orange : muted)
                        if p.isDefault { Text("default").font(.system(size: 8.5, design: .monospaced)).foregroundStyle(muted) }
                        if model.printerID == p.id { Text("✓").foregroundStyle(accent) }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).hoverTint()
            }
        }
        .frame(width: 225)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.3), radius: 18, y: 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(.top, 56).padding(.trailing, 10)
        .zIndex(41)
        .transition(.scale(scale: 0.94).combined(with: .opacity))
    }
}
