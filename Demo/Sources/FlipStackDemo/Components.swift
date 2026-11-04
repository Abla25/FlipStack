import SwiftUI
import PDFKit
import AppKit
import FlipStackCore

let accent = Color(red: 235 / 255, green: 79 / 255, blue: 49 / 255)
let ink = Color(red: 27 / 255, green: 27 / 255, blue: 31 / 255)
let muted = Color(red: 138 / 255, green: 138 / 255, blue: 147 / 255)
let paper = Color(red: 247 / 255, green: 247 / 255, blue: 249 / 255)

/// press → scale microinteraction
struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.955 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// hover → accent tint microinteraction
struct HoverTint: ViewModifier {
    @State private var hover = false
    func body(content: Content) -> some View {
        content
            .background(hover ? accent.opacity(0.08) : Color.clear)
            .onHover { hover = $0 }
            .animation(.easeOut(duration: 0.15), value: hover)
    }
}
extension View { func hoverTint() -> some View { modifier(HoverTint()) } }

/// dashed receipt separator (flush to both edges)
struct DashedRule: View {
    var body: some View {
        GeometryReader { g in
            Path { p in
                let w = g.size.width
                var x: CGFloat = 0
                while x < w { p.addRect(CGRect(x: x, y: 0, width: min(3, w - x), height: 1)); x += 6 }
            }
            .fill(Color.gray.opacity(0.45))
        }
        .frame(height: 1)
    }
}

/// dot leader between label and value, resting on the text baseline
struct DotLeader: View {
    var body: some View {
        GeometryReader { g in
            Path { p in
                let w = g.size.width, y = g.size.height - 2.4
                var x: CGFloat = 1
                while x < w - 1 { p.addEllipse(in: CGRect(x: x, y: y - 0.8, width: 1.6, height: 1.6)); x += 4.5 }
            }
            .fill(Color.gray.opacity(0.55))
        }
    }
}

struct LineItem: View {
    let label: String
    let value: String
    var hot: Bool = false
    var tappable: Bool = false
    var action: (() -> Void)? = nil
    @State private var flash = false

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
            DotLeader().frame(height: 10)
            Text(value)
                .fontWeight(.bold)
                .foregroundStyle(hot ? accent : ink)
        }
        .padding(.horizontal, 4)
        .background(flash ? accent.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .hoverTint()
        .onTapGesture {
            if tappable {
                action?()
                withAnimation(.easeOut(duration: 0.25)) { flash = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    withAnimation(.easeOut(duration: 0.3)) { flash = false }
                }
            }
        }
        .animation(.easeOut(duration: 0.15), value: value)
    }
}

/// Real supply levels (any number of colors — L1800 has 6+, etc.)
struct SupplyBars: View {
    let supplies: [SupplyLevel]
    static func color(for s: SupplyLevel) -> Color {
        let t = (s.colorName ?? s.name).lowercased()
        if t.contains("00ffff") { return Color(red: 0, green: 162/255, blue: 232/255) }
        if t.contains("cyan") && !t.contains("light") { return Color(red: 0, green: 162/255, blue: 232/255) }
        if t.contains("light cyan") || t.contains("lc") { return Color(red: 140/255, green: 220/255, blue: 250/255) }
        if t.contains("magenta") && !t.contains("light") { return Color(red: 229/255, green: 72/255, blue: 140/255) }
        if t.contains("light magenta") || t.contains("lm") { return Color(red: 245/255, green: 150/255, blue: 200/255) }
        if t.contains("yellow") { return Color(red: 232/255, green: 179/255, blue: 12/255) }
        if t.contains("black") || t.contains("grey") || t.contains("gray") { return Color(red: 58/255, green: 58/255, blue: 66/255) }
        if t.contains("red") { return .red }
        if t.contains("green") { return .green }
        if t.contains("blue") { return .blue }
        return .gray
    }
    static func short(_ s: SupplyLevel) -> String {
        let d = s.displayName
        let map = ["Cyan":"C","Magenta":"M","Yellow":"Y","Black":"K","Light Cyan":"Lc","Light Magenta":"Lm",
                   "Matte Black":"MB","Photo Black":"PK","Photo Cyan":"Pc","Photo Magenta":"Pm",
                   "Vivid Magenta":"VM","Vivid Light Magenta":"VLM","Vivid Light Cyan":"VLC","Light Black":"Lk"]
        return map[d] ?? String(d.prefix(2))
    }
    var body: some View {
        if supplies.isEmpty {
            HStack(spacing: 6) {
                Text("INK").font(.system(size: 9, weight: .heavy, design: .monospaced)).foregroundStyle(muted)
                Text("levels unavailable").font(.system(size: 8.5, design: .monospaced)).foregroundStyle(muted)
            }
        } else {
            HStack(spacing: 7) {
                Text("INK").font(.system(size: 9, weight: .heavy, design: .monospaced)).foregroundStyle(muted)
                ForEach(supplies.prefix(8)) { s in
                    VStack(spacing: 2) {
                        Text("\(Self.short(s)) \(s.levelPercent.map { "\($0)%" } ?? "—")")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundStyle(s.isCritical ? .red : s.isLow ? .orange : Self.color(for: s))
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.gray.opacity(0.18))
                                if let f = s.fraction {
                                    Capsule().fill(s.isCritical ? Color.red : s.isLow ? Color.orange : Self.color(for: s))
                                        .frame(width: g.size.width * CGFloat(f))
                                        .animation(.spring(response: 0.5), value: f)
                                }
                            }
                        }.frame(height: 4)
                    }.frame(maxWidth: .infinity)
                }
            }
        }
    }
}

/// generic popover menu for receipt line items
struct PopMenu: View {
    let title: String
    let options: [String]
    let current: String
    let onPick: (String) -> Void
    let onClose: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .heavy, design: .monospaced))
                .foregroundStyle(muted).padding(.horizontal, 10).padding(.top, 8)
            ForEach(options, id: \.self) { o in
                Button {
                    onPick(o)
                } label: {
                    HStack {
                        Text(o).font(.system(size: 12, design: .monospaced))
                        if o == current { Spacer(); Text("✓").foregroundStyle(accent) }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverTint()
            }
            Divider()
            Button("Cancel", role: .cancel) { onClose() }
                .buttonStyle(.plain).padding(.horizontal, 10).padding(.vertical, 6)
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(muted)
        }
        .frame(width: 190)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.3), radius: 18, y: 8)
        .transition(.scale(scale: 0.92).combined(with: .opacity))
    }
}

struct ToastView: View {
    let msg: String
    var body: some View {
        Text(msg)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Color.black.opacity(0.88), in: Capsule())
            .transition(.move(edge: .top).combined(with: .opacity))
    }
}

/// Embedded live preview inside the receipt: current page (fit to the space)
/// + horizontal filmstrip of all pages — tap a page to view it, "Select" mode
/// toggles pages in/out of the print set (like the macOS print dialog).
/// Caches page thumbnails per document so re-renders never re-rasterize.
final class ThumbCache: ObservableObject {
    static let shared = ThumbCache()
    private let cache = NSCache<NSNumber, NSImage>()
    private var docKey: String = ""
    func image(for page: Int, pdf: PDFDocument?) -> NSImage? {
        guard let pdf, let p = pdf.page(at: min(page - 1, pdf.pageCount - 1)) else { return nil }
        let key = NSNumber(value: page)
        let docID = "\(pdf.documentURL?.path ?? "")#\(pdf.pageCount)"
        if docID != docKey { cache.removeAllObjects(); docKey = docID }
        if let img = cache.object(forKey: key) { return img }
        let img = p.thumbnail(of: CGSize(width: 34, height: 48), for: .mediaBox)
        cache.setObject(img, forKey: key)
        return img
    }
}

struct EmbeddedPreview: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(spacing: 5) {
            ZStack(alignment: .topTrailing) {
                Rectangle().fill(.white)
                    .overlay(Rectangle().stroke(Color.black.opacity(0.14)))
                    .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
                if let pdf = model.previewDoc, let page = pdf.page(at: min(model.previewPage - 1, pdf.pageCount - 1)) {
                    FitPDFView(page: page, zoom: $model.previewZoom)
                        .padding(6)
                } else {
                    Rectangle().fill(LinearGradient(colors: [.orange, accent, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .padding(6)
                }
                Text("\(model.previewPage)/\(model.docPages)")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white).padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Color.black.opacity(0.55), in: Capsule())
                    .padding(10)
            }
            .frame(height: 148)
            .clipped()
            .onTapGesture { model.previewOpen = true }

            HStack(spacing: 6) {
                Text("PAGES").font(.system(size: 8.5, weight: .heavy, design: .monospaced)).foregroundStyle(muted)
                Text("\(model.selectedPages) selected").font(.system(size: 8.5, design: .monospaced)).foregroundStyle(muted)
                Spacer()
                Button {
                    withAnimation(.spring(response: 0.3)) { model.selectMode.toggle() }
                } label: {
                    Text(model.selectMode ? "✓ Selecting" : "Select…")
                        .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(model.selectMode ? .white : accent)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(model.selectMode ? accent : accent.opacity(0.1), in: Capsule())
                }.buttonStyle(PressScale())
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(Array(1...max(model.docPages, 1)), id: \.self) { p in
                        let included = model.includedSet.contains(p)
                        let current = p == model.previewPage
                        Button {
                            if model.selectMode { model.togglePageIncluded(p) }
                            else { model.previewPage = p }
                        } label: {
                            ZStack(alignment: .topTrailing) {
                                if let img = ThumbCache.shared.image(for: p, pdf: model.previewDoc) {
                                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                                } else {
                                    Rectangle().fill(Color.gray.opacity(0.2))
                                }
                                if model.selectMode {
                                    Image(systemName: included ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 11))
                                        .foregroundStyle(included ? accent : .gray)
                                        .background(Circle().fill(.white))
                                }
                            }
                            .frame(width: 34, height: 48)
                            .background(.white)
                            .overlay(Rectangle().stroke(current ? accent : Color.black.opacity(0.15),
                                                        lineWidth: current ? 2 : 1))
                            .opacity(included || !model.selectMode ? 1 : 0.45)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                        }
                        .buttonStyle(PressScale())
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(height: 54)
        }
    }
}

/// PDF page scaled to FIT a fixed frame (zoom multiplies the fit).
struct FitPDFView: NSViewRepresentable {
    let page: PDFPage
    @Binding var zoom: CGFloat
    func makeNSView(context: Context) -> PDFView {
        let v = PDFView()
        v.displayMode = .singlePage
        v.autoScales = false
        v.backgroundColor = .clear
        v.document = PDFDocument()
        v.document?.insert(page, at: 0)
        return v
    }
    func updateNSView(_ v: PDFView, context: Context) {
        let b = page.bounds(for: .mediaBox)
        let fit = PrintMath.fitScale(sheetW: 272, sheetH: 136, pageW: Double(b.width), pageH: Double(b.height))
        v.scaleFactor = fit * zoom
        v.go(to: page)
    }
}
