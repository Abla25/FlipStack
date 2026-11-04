import AppKit
import QuartzCore

/// A transparent, non-activating panel whose content is clipped to a
/// "receipt" silhouette: rectangle with a zigzag torn bottom edge.
final class ReceiptPanel: NSPanel {
    static let panelWidth: CGFloat = 320
    static let panelHeight: CGFloat = 680
    private let teeth = 14
    private let depth: CGFloat = 10

    static func make() -> ReceiptPanel {
        let rect = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)
        let panel = ReceiptPanel(contentRect: rect,
                                 styleMask: [.nonactivatingPanel, .fullSizeContentView, .utilityWindow],
                                 backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.contentView?.wantsLayer = true
        panel.applyReceiptMask()
        return panel
    }

    func applyReceiptMask() {
        guard let layer = contentView?.layer else { return }
        let path = CGMutablePath()
        let w = contentView?.bounds.width ?? ReceiptPanel.panelWidth
        let h = contentView?.bounds.height ?? ReceiptPanel.panelHeight
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: w, y: 0))
        path.addLine(to: CGPoint(x: w, y: h - depth))
        let step = w / CGFloat(teeth)
        for i in stride(from: teeth, through: 0, by: -1) {
            let x = CGFloat(i) * step
            path.addLine(to: CGPoint(x: x, y: i % 2 == 1 ? h : h - depth))
        }
        path.closeSubpath()
        let mask = CAShapeLayer()
        mask.path = path
        layer.mask = mask
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = 0.45
        layer.shadowRadius = 30
        layer.shadowOffset = CGSize(width: 0, height: 12)
        layer.masksToBounds = false
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(frameRect, display: flag)
        applyReceiptMask()
    }
}
