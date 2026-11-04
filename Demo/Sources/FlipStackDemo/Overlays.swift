import SwiftUI
import PDFKit
import AppKit

// MARK: - Live preview (fixed sheet, content scales inside — never zooms the page)
struct PreviewOverlay: View {
    @ObservedObject var model: AppModel
    var body: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
                .onTapGesture { model.previewOpen = false }
            VStack(spacing: 10) {
                HStack {
                    Text("Preview").foregroundStyle(.white).fontWeight(.bold)
                    Text("\(model.docName) · \(model.selectedPages) pages · \(model.paper)")
                        .foregroundStyle(.white.opacity(0.7)).font(.system(size: 11))
                    Spacer()
                    Button { model.previewOpen = false } label: {
                        Image(systemName: "xmark").foregroundStyle(.white)
                            .frame(width: 26, height: 26).background(.white.opacity(0.14), in: Circle())
                    }.buttonStyle(PressScale())
                }
                ZStack {
                    Rectangle().fill(.white).frame(width: 200, height: 283)
                        .shadow(color: .black.opacity(0.5), radius: 20)
                    if let pdf = model.previewDoc {
                        PDFKitView(pdf: pdf, page: $model.previewPage, zoom: $model.previewZoom)
                            .frame(width: 200, height: 283)
                            .clipped()
                    }
                    if model.duplex && model.previewPage % 2 == 0 {
                        Text("BACK").font(.system(size: 8, weight: .heavy)).foregroundStyle(.white)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(accent, in: Capsule())
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                            .padding(8)
                    }
                }
                HStack(spacing: 12) {
                    Button { model.previewPage = max(1, model.previewPage - 1) } label: { Image(systemName: "chevron.left") }
                        .disabled(model.previewPage <= 1)
                    Text("\(model.previewPage) / \(model.selectedPages)").foregroundStyle(.white).font(.system(size: 12, weight: .semibold)).frame(width: 52)
                    Button { model.previewPage = min(model.selectedPages, model.previewPage + 1) } label: { Image(systemName: "chevron.right") }
                        .disabled(model.previewPage >= model.selectedPages)
                    Divider().frame(height: 18)
                    Button { model.previewZoom = max(0.5, model.previewZoom - 0.1) } label: { Text("−") }
                    Text("\(Int(model.previewZoom * 100))%").foregroundStyle(.white).font(.system(size: 12, weight: .semibold)).frame(width: 42)
                    Button { model.previewZoom = min(2.0, model.previewZoom + 0.1) } label: { Text("+") }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .frame(height: 30)
                .background(.white.opacity(0.12), in: Capsule())
            }
            .padding(14)
        }
        .transition(.opacity)
        .zIndex(30)
        .onAppear {
            model.previewZoom = 1.0   // always open fit-to-sheet
            if model.previewPage > model.selectedPages { model.previewPage = model.selectedPages }
        }
    }
}

struct PDFKitView: NSViewRepresentable {
    let pdf: PDFDocument
    @Binding var page: Int
    @Binding var zoom: CGFloat
    func makeNSView(context: Context) -> PDFView {
        let v = PDFView()
        v.document = pdf
        v.displayMode = .singlePage
        v.autoScales = false
        v.backgroundColor = .white
        return v
    }
    func updateNSView(_ v: PDFView, context: Context) {
        if v.document !== pdf { v.document = pdf }
        if let cur = v.currentPage {
            let b = cur.bounds(for: .mediaBox)
            let fit = PrintMath.fitScale(sheetW: 200, sheetH: 283, pageW: Double(b.width), pageH: Double(b.height))
            v.scaleFactor = fit * zoom   // zoom=1.0 → always fit inside the fixed sheet
        }
        let idx = min(max(page - 1, 0), (v.document?.pageCount ?? 1) - 1)
        if let p = v.document?.page(at: idx) { v.go(to: p) }
    }
}

// MARK: - Settings (receipt-coherent: mono, dashed rules, dot leaders, quit)
struct SettingsOverlay: View {
    @ObservedObject var model: AppModel
    var body: some View {
        ZStack {
            paper.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("SETTINGS")
                        .font(.system(size: 13, weight: .heavy, design: .monospaced)).tracking(3)
                    Spacer()
                    Button { model.settingsOpen = false } label: {
                        Image(systemName: "xmark").foregroundStyle(muted)
                            .frame(width: 26, height: 26)
                            .overlay(Rectangle().stroke(Color.black.opacity(0.14)).frame(width: 26, height: 26))
                    }.buttonStyle(PressScale())
                }
                DashedRule()
                sectionTitle("LANGUAGE")
                segRow(options: ["EN", "IT", "ES", "FR"], current: model.settings.lang) { model.settings.lang = $0 }
                DashedRule()
                sectionTitle("DEFAULT QUALITY")
                segRow(options: ["Draft · 180", "Normal · 366", "High · 600"],
                       current: model.settings.defQuality == "draft" ? "Draft · 180" : model.settings.defQuality == "normal" ? "Normal · 366" : "High · 600") {
                    model.settings.defQuality = $0.hasPrefix("Draft") ? "draft" : $0.hasPrefix("Normal") ? "normal" : "high"
                }
                DashedRule()
                sectionTitle("PRINTER & CALIBRATION")
                settingRow("Default printer", model.printerName) { model.printersOpen = true }
                settingRow("Calibration sheet", "Run…") { model.calibOpen = true }
                DashedRule()
                sectionTitle("ABOUT")
                Text("FlipStack \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0") (build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?")) — receipt UI")
                    .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(muted)
                Spacer()
                Button {
                    NSApp.terminate(nil)
                } label: {
                    Text("QUIT FLIPSTACK")
                        .font(.system(size: 12, weight: .heavy, design: .monospaced)).tracking(1)
                        .foregroundStyle(accent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .overlay(Rectangle().stroke(accent, lineWidth: 1.5).frame(maxWidth: .infinity))
                }
                .buttonStyle(PressScale())
                .hoverTint()
            }
            .padding(16)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(ink)
        }
        .zIndex(31)
    }

    func sectionTitle(_ t: String) -> some View {
        Text(t).font(.system(size: 9, weight: .heavy, design: .monospaced)).foregroundStyle(muted).tracking(1.5)
    }

    func segRow(options: [String], current: String, onPick: @escaping (String) -> Void) -> some View {
        HStack(spacing: 5) {
            ForEach(options, id: \.self) { o in
                Button { onPick(o) } label: {
                    Text(o).font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .frame(maxWidth: .infinity).padding(.vertical, 7)
                        .background(o == current ? accent : .white)
                        .foregroundStyle(o == current ? .white : ink)
                        .overlay(Rectangle().stroke(o == current ? accent : Color.black.opacity(0.15), lineWidth: 1))
                }
                .buttonStyle(PressScale())
                .hoverTint()
            }
        }
    }

    func settingRow(_ k: String, _ v: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(k).foregroundStyle(muted)
                DotLeader().frame(height: 8)
                HStack(spacing: 3) {
                    Text(v).fontWeight(.bold)
                    Image(systemName: "chevron.right").font(.system(size: 8)).foregroundStyle(muted)
                }
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain).hoverTint()
    }
}

// MARK: - Calibration modal
struct CalibOverlay: View {
    @ObservedObject var model: AppModel
    var body: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Calibration").foregroundStyle(.white).fontWeight(.bold)
                    Spacer()
                    Button { model.calibOpen = false } label: { Image(systemName: "xmark").foregroundStyle(.white) }.buttonStyle(PressScale())
                }
                Text("1. Print the calibration sheet on plain A4.\n2. Mark the sharpest line block and the aligned pair.\n3. FlipStack stores the offsets for duplex registration.")
                    .foregroundStyle(.white.opacity(0.9)).font(.system(size: 12)).lineSpacing(4)
                Button {
                    model.calibOpen = false
                    if let pdf = Printing.calibrationPDF() {
                        if model.simulate {
                            model.showToast("Calibration sheet printed (simulated)")
                        } else {
                            _ = Printing.print(file: pdf, printer: model.printerID, pageRange: nil,
                                               targetDPI: 600, color: false, copies: 1, media: "Plain", paper: "A4",
                                               duplexEdge: model.duplexEdge, title: "FlipStack — calibration")
                            model.showToast("Calibration sheet sent to \(model.printerName)")
                        }
                    }
                } label: {
                    HStack { Image(systemName: "printer.fill"); Text("Print calibration sheet") }
                        .font(.system(size: 12.5, weight: .heavy)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity).padding(.vertical, 11)
                        .background(accent, in: RoundedRectangle(cornerRadius: 10))
                }.buttonStyle(PressScale())
            }
            .padding(16)
            .background(Color(red: 30 / 255, green: 30 / 255, blue: 36 / 255).opacity(0.95), in: RoundedRectangle(cornerRadius: 14))
            .padding(18)
        }
        .zIndex(32)
    }
}

// MARK: - Print flow bar (progress / flip / done) — kept clear of the torn edge
struct FlowBar: View {
    @ObservedObject var model: AppModel
    @State private var pulse = false
    var body: some View {
        VStack(spacing: 8) {
            switch model.flowPhase {
            case .printing:
                Text(model.flowLabel).font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundStyle(ink)
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.gray.opacity(0.2))
                        Capsule().fill(accent).frame(width: g.size.width * model.flowProgress)
                            .animation(.linear(duration: 0.1), value: model.flowProgress)
                    }
                }.frame(height: 6)
                HStack(spacing: 8) {
                    flowButton("Cancel", sec: true) { model.cancelFlow() }
                    flowButton("Retry", sec: true) { model.retryPhase() }
                }
            case .flip:
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 24)).foregroundStyle(accent)
                    .scaleEffect(pulse ? 1.15 : 1)
                    .onAppear {
                        withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) { pulse = true }
                    }
                Text("Flip the stack").font(.system(size: 12.5, weight: .heavy, design: .monospaced)).foregroundStyle(ink)
                Text("Turn the printed pages over on the \(model.duplexEdge) edge, keep the same tray, then confirm.")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(muted).multilineTextAlignment(.center)
                HStack(spacing: 8) {
                    flowButton("Cancel", sec: true) { model.cancelFlow() }
                    flowButton("Reinserted ✓", sec: false) { model.confirmFlip() }
                }
            case .done:
                Text("Printed ✓").font(.system(size: 12.5, weight: .heavy, design: .monospaced)).foregroundStyle(ink)
                Text(model.lastPrint ?? "").font(.system(size: 10, design: .monospaced)).foregroundStyle(muted)
                HStack(spacing: 8) { flowButton("Close", sec: false) { model.flowPhase = .idle } }
            case .idle: EmptyView()
            }
        }
        .padding(12)
        .background(.white.opacity(0.97))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
        .padding(.horizontal, 10).padding(.bottom, 26)   // keep clear of the torn zigzag edge
        .frame(maxHeight: .infinity, alignment: .bottom)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .zIndex(50)
    }
    func flowButton(_ label: String, sec: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.system(size: 12, weight: .heavy))
                .frame(maxWidth: .infinity).padding(.vertical, 9)
                .background(sec ? Color.gray.opacity(0.15) : accent)
                .foregroundStyle(sec ? ink : .white)
                .clipShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(PressScale())
    }
}
