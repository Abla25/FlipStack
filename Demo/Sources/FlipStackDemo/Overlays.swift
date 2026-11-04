import SwiftUI
import PDFKit
import AppKit

// MARK: - Live preview (fixed sheet, content scales inside — never zooms the page)
struct PreviewOverlay: View {
    @ObservedObject var model: AppModel
    private let sheetW: CGFloat = 200
    private let sheetH: CGFloat = 283

    var body: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
                .onTapGesture { model.previewOpen = false }
                .accessibilityHidden(true)
            VStack(spacing: 10) {
                HStack(spacing: 6) {
                    Text(T("preview.title")).foregroundStyle(.white).fontWeight(.bold)
                    Text(T("preview.meta", model.docName, Units.pages(model.selectedPages), model.paper))
                        .foregroundStyle(.white.opacity(0.7)).font(.system(size: 11))
                        .lineLimit(1).minimumScaleFactor(0.7)
                    Spacer(minLength: 4)
                    Button { model.previewOpen = false } label: {
                        Image(systemName: "xmark").foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(.white.opacity(0.14), in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(PressScale())
                    .accessibilityLabel(T("a11y.closePreview"))
                    .help(T("common.close"))
                }
                // Fixed 200x283 sheet: the BACK badge lives INSIDE this frame (audit fix).
                ZStack(alignment: .topTrailing) {
                    Rectangle().fill(.white)
                        .shadow(color: .black.opacity(0.5), radius: 20)
                    if let pdf = model.previewDoc {
                        PDFKitView(pdf: pdf, page: $model.previewPage, zoom: $model.previewZoom)
                            .frame(width: sheetW, height: sheetH)
                            .clipped()
                    }
                    if model.duplex && model.previewPage % 2 == 0 {
                        Text(T("preview.back")).font(.system(size: 8, weight: .heavy)).foregroundStyle(.white)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(accent, in: Capsule())
                            .padding(8)
                            .accessibilityLabel(T("preview.back"))
                    }
                }
                .frame(width: sheetW, height: sheetH)
                .clipped()

                HStack(spacing: 8) {
                    previewButton("chevron.left", T("pages.previousA11y"), enabled: model.previewPage > 1) {
                        model.previewPage = max(1, model.previewPage - 1)
                    }
                    Text("\(model.previewPage) / \(max(model.selectedPages, 1))")
                        .foregroundStyle(.white).font(.system(size: 12, weight: .semibold))
                        .frame(width: 46).lineLimit(1).minimumScaleFactor(0.75)
                    previewButton("chevron.right", T("pages.nextA11y"), enabled: model.previewPage < model.selectedPages) {
                        model.previewPage = min(max(model.selectedPages, 1), model.previewPage + 1)
                    }
                    Divider().frame(height: 18)
                    previewButton(nil, T("preview.zoomOut"), enabled: model.previewZoom > 0.5, text: "−") {
                        model.previewZoom = max(0.5, model.previewZoom - 0.1)
                    }
                    Text("\(Int(model.previewZoom * 100))%").foregroundStyle(.white).font(.system(size: 12, weight: .semibold)).frame(width: 40)
                    previewButton(nil, T("preview.zoomIn"), enabled: model.previewZoom < 2.0, text: "+") {
                        model.previewZoom = min(2.0, model.previewZoom + 0.1)
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .frame(height: 30)
                .background(.white.opacity(0.12), in: Capsule())
            }
            .padding(14)
        }
        .transition(.opacity)
        .zIndex(40)
        .onAppear {
            model.previewZoom = 1.0   // always open fit-to-sheet
            if model.previewPage > model.selectedPages { model.previewPage = model.selectedPages }
        }
    }

    /// 28x28 minimum hit target for the small preview controls (audit fix).
    @ViewBuilder
    func previewButton(_ systemName: String?, _ a11y: String, enabled: Bool, text: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if let systemName {
                    Image(systemName: systemName).font(.system(size: 11, weight: .bold))
                } else {
                    Text(text ?? "").font(.system(size: 13, weight: .bold))
                }
            }
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .accessibilityLabel(a11y)
        .help(a11y)
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

    private var language: String { model.settings.language.shortCode }

    var body: some View {
        ZStack {
            paper.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(T("settings.title"))
                        .font(.system(size: 13, weight: .heavy, design: .monospaced)).tracking(3)
                    Spacer()
                    Button { model.settingsOpen = false } label: {
                        Image(systemName: "xmark").foregroundStyle(muted)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                            .overlay(Rectangle().stroke(Color.black.opacity(0.14)).frame(width: 28, height: 28))
                    }
                    .buttonStyle(PressScale())
                    .accessibilityLabel(T("settings.closeA11y"))
                    .help(T("common.close"))
                }
                DashedRule()
                sectionTitle(T("settings.language"))
                segRow(options: ["EN", "IT"], current: language) { lang in
                    model.settings.language = (lang == "IT" ? .it : .en)
                }
                .accessibilityLabel(T("settings.languageA11y", model.settings.language.displayName))
                DashedRule()
                sectionTitle(T("settings.defaultQuality"))
                segRow(options: qualityOptions, current: qualityCurrent) { picked in
                    if picked == T("quality.draft") { model.settings.defaultQuality = "draft" }
                    else if picked == T("quality.normal") { model.settings.defaultQuality = "normal" }
                    else { model.settings.defaultQuality = "high" }
                }
                DashedRule()
                sectionTitle(T("settings.printerCalibration"))
                settingRow(T("settings.defaultPrinter"), model.printerName) {
                    model.printersOpen = true
                }
                settingRow(T("settings.calibrationSheet"), T("common.run")) {
                    model.calibOpen = true
                }
                DashedRule()
                sectionTitle(T("settings.about"))
                Text(versionLabel)
                    .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(muted)
                    .lineLimit(2).minimumScaleFactor(0.8)
                Spacer()
                Button {
                    NSApp.terminate(nil)
                } label: {
                    Text(T("settings.quit"))
                        .font(.system(size: 12, weight: .heavy, design: .monospaced)).tracking(1)
                        .foregroundStyle(accent)
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity, minHeight: 30)
                        .padding(.vertical, 9)
                        .overlay(Rectangle().stroke(accent, lineWidth: 1.5).frame(maxWidth: .infinity))
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressScale())
                .hoverTint()
                .accessibilityLabel(T("settings.quit"))
                .help(T("settings.quit"))
            }
            .padding(16)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(ink)
        }
        .preferredColorScheme(.light)
        .zIndex(30)
    }

    private var qualityOptions: [String] {
        [T("quality.draft"), T("quality.normal"), T("quality.high")]
    }
    private var qualityCurrent: String {
        switch model.settings.defaultQuality {
        case "draft": return T("quality.draft")
        case "normal": return T("quality.normal")
        default: return T("quality.high")
        }
    }

    private var versionLabel: String {
        guard let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String else {
            return T("settings.versionDev")
        }
        return T("settings.version", version, build)
    }

    func sectionTitle(_ t: String) -> some View {
        Text(t).font(.system(size: 9, weight: .heavy, design: .monospaced)).foregroundStyle(muted).tracking(1.5)
    }

    func segRow(options: [String], current: String, onPick: @escaping (String) -> Void) -> some View {
        HStack(spacing: 5) {
            ForEach(options, id: \.self) { o in
                Button { onPick(o) } label: {
                    Text(o).font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity, minHeight: 28)
                        .padding(.vertical, 6)
                        .background(o == current ? accent : .white)
                        .foregroundStyle(o == current ? .white : ink)
                        .overlay(Rectangle().stroke(o == current ? accent : Color.black.opacity(0.15), lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressScale())
                .hoverTint()
                .accessibilityLabel(o)
                .accessibilityAddTraits(o == current ? [.isButton, .isSelected] : .isButton)
            }
        }
    }

    /// Key/value setting row: full-width clickable (contentShape + min 28 pt) so blank
    /// space between the label and the value responds — audit fix A1b.
    func settingRow(_ k: String, _ v: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(k).foregroundStyle(muted).lineLimit(1).minimumScaleFactor(0.75)
                DotLeader().frame(height: 8)
                HStack(spacing: 3) {
                    Text(v).fontWeight(.bold).lineLimit(1).minimumScaleFactor(0.75)
                    Image(systemName: "chevron.right").font(.system(size: 8)).foregroundStyle(muted)
                }
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverTint()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(k), \(v)")
        .accessibilityAddTraits(.isButton)
        .help(k)
    }
}

// MARK: - Calibration modal
struct CalibOverlay: View {
    @ObservedObject var model: AppModel
    var body: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
                .onTapGesture { model.calibOpen = false }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(T("calibration.title")).foregroundStyle(.white).fontWeight(.bold)
                    Spacer()
                    Button { model.calibOpen = false } label: {
                        Image(systemName: "xmark").foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressScale())
                    .accessibilityLabel(T("calibration.closeA11y"))
                    .help(T("common.close"))
                }
                Text(T("calibration.instructions"))
                    .foregroundStyle(.white.opacity(0.9)).font(.system(size: 12)).lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    model.calibOpen = false
                    model.printCalibration()   // model owns the print + toast feedback
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "printer.fill")
                        Text(T("calibration.printSheet")).lineLimit(1).minimumScaleFactor(0.7)
                    }
                    .font(.system(size: 12.5, weight: .heavy)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .background(accent, in: RoundedRectangle(cornerRadius: 10))
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressScale())
                .accessibilityLabel(T("calibration.printSheet"))
                .help(T("calibration.printSheet"))
            }
            .padding(16)
            .background(Color(red: 30 / 255, green: 30 / 255, blue: 36 / 255).opacity(0.95), in: RoundedRectangle(cornerRadius: 14))
            .padding(18)
        }
        .preferredColorScheme(.light)
        .zIndex(70)
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
                    // v1.0.2: no Retry while printing — failures stop the flow with a toast;
                    // the PRINT button is the retry path (Lead decision).
                    flowButton(T("common.cancel"), sec: true) { model.cancelFlow() }
                }
            case .flip:
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 24)).foregroundStyle(accent)
                    .scaleEffect(pulse ? 1.15 : 1)
                    .onAppear {
                        withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) { pulse = true }
                    }
                Text(T("flow.flipTitle")).font(.system(size: 12.5, weight: .heavy, design: .monospaced)).foregroundStyle(ink)
                Text(T("flow.flipInstructions", T(model.duplexEdge == "long" ? "option.edge.long" : "option.edge.short")))
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(muted).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    flowButton(T("common.cancel"), sec: true) { model.cancelFlow() }
                    flowButton(T("flow.reinserted"), sec: false) { model.confirmFlip() }
                }
            case .done:
                Text(T("flow.printed")).font(.system(size: 12.5, weight: .heavy, design: .monospaced)).foregroundStyle(ink)
                Text(model.lastPrint ?? "").font(.system(size: 10, design: .monospaced)).foregroundStyle(muted)
                HStack(spacing: 8) { flowButton(T("common.close"), sec: false) { model.flowPhase = .idle } }
            case .idle: EmptyView()
            }
        }
        .padding(12)
        .background(Color.white)                 // opaque: never ghosts the receipt/settings behind it
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
        .padding(.horizontal, 10).padding(.bottom, 26)   // keep clear of the torn zigzag edge
        .frame(maxHeight: .infinity, alignment: .bottom)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .preferredColorScheme(.light)
        .zIndex(20)
    }
    func flowButton(_ label: String, sec: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.system(size: 12, weight: .heavy))
                .lineLimit(1).minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, minHeight: 32)
                .background(sec ? Color.gray.opacity(0.15) : accent)
                .foregroundStyle(sec ? ink : .white)
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .contentShape(Rectangle())
        }
        .accessibilityLabel(label)
        .buttonStyle(PressScale())
    }
}
