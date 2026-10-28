import AppKit
import QuartzCore
import YTMGlowCore

/// Draws the edge light with Core Animation layers: a two-color gradient
/// masked by four edge fades. The content is static while music plays; the
/// pulse is the window's alpha, which WindowServer applies while compositing,
/// so beats cost no re-rendering in the app.
///
/// Each display is covered by four thin strip windows rather than one
/// full-screen window, so WindowServer only blends the edges. Every strip
/// renders the whole display's glow, offset so the strips line up seamlessly.
final class GlowView: NSView {
    private let container = CALayer()
    private let colorLayer = CAGradientLayer()
    private let mask = CALayer()
    private let edges: [CAGradientLayer] = (0..<4).map { _ in CAGradientLayer() }

    /// Size of the whole display, in points.
    private var screenSize: CGSize
    /// This strip's rectangle within the display, in points.
    private var stripRect: CGRect
    private var thickness: CGFloat = 38

    init(screenSize: CGSize, stripRect: CGRect) {
        self.screenSize = screenSize
        self.stripRect = stripRect
        super.init(frame: CGRect(origin: .zero, size: stripRect.size))
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = .clear
        layer?.masksToBounds = true

        colorLayer.startPoint = CGPoint(x: 0, y: 1)
        colorLayer.endPoint = CGPoint(x: 1, y: 0)
        colorLayer.colors = [CGColor(srgbRed: 1, green: 0.36, blue: 0.78, alpha: 1), CGColor(srgbRed: 0.35, green: 0.78, blue: 1, alpha: 1)]
        colorLayer.mask = mask

        let opaque = CGColor(gray: 1, alpha: 1)
        let fadeMid = CGColor(gray: 1, alpha: 0.35)
        let clear = CGColor(gray: 1, alpha: 0)
        for edge in edges {
            edge.colors = [opaque, fadeMid, clear]
            edge.locations = [0, 0.35, 1]
            mask.addSublayer(edge)
        }
        // Edge order: bottom, top, left, right. Gradients run from the edge inward.
        edges[0].startPoint = CGPoint(x: 0.5, y: 0); edges[0].endPoint = CGPoint(x: 0.5, y: 1)
        edges[1].startPoint = CGPoint(x: 0.5, y: 1); edges[1].endPoint = CGPoint(x: 0.5, y: 0)
        edges[2].startPoint = CGPoint(x: 0, y: 0.5); edges[2].endPoint = CGPoint(x: 1, y: 0.5)
        edges[3].startPoint = CGPoint(x: 1, y: 0.5); edges[3].endPoint = CGPoint(x: 0, y: 0.5)

        container.addSublayer(colorLayer)
        layer?.addSublayer(container)
        layoutLayers()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let backingScale = window?.backingScaleFactor ?? 2
        for layer in [container, colorLayer, mask] + edges { layer.contentsScale = backingScale }
    }

    func setGeometry(screenSize: CGSize, stripRect: CGRect, thickness: CGFloat) {
        guard screenSize != self.screenSize || stripRect != self.stripRect || thickness != self.thickness else { return }
        self.screenSize = screenSize
        self.stripRect = stripRect
        self.thickness = thickness
        layoutLayers()
    }

    func setColors(_ a: SRGBColor, _ b: SRGBColor, animated: Bool) {
        transaction(duration: animated ? 0.9 : 0) {
            colorLayer.colors = [a.cgColor, b.cgColor]
        }
    }

    private func layoutLayers() {
        transaction(duration: 0) {
            container.frame = CGRect(x: -stripRect.minX, y: -stripRect.minY, width: screenSize.width, height: screenSize.height)
            colorLayer.frame = CGRect(origin: .zero, size: screenSize)
            mask.frame = colorLayer.bounds
            layoutEdges()
        }
    }

    private func layoutEdges() {
        let depth = min(thickness, min(screenSize.width, screenSize.height) / 2)
        let size = screenSize
        edges[0].frame = CGRect(x: 0, y: 0, width: size.width, height: depth)
        edges[1].frame = CGRect(x: 0, y: size.height - depth, width: size.width, height: depth)
        edges[2].frame = CGRect(x: 0, y: 0, width: depth, height: size.height)
        edges[3].frame = CGRect(x: size.width - depth, y: 0, width: depth, height: size.height)
    }

    private func transaction(duration: CFTimeInterval, _ changes: () -> Void) {
        CATransaction.begin()
        if duration > 0 {
            CATransaction.setAnimationDuration(duration)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        } else {
            CATransaction.setDisableActions(true)
        }
        changes()
        CATransaction.commit()
    }
}

/// The four edge strips of a display, in display-local points.
enum GlowStrips {
    static func rects(screenSize size: CGSize, thickness: CGFloat) -> [CGRect] {
        let depth = ceil(min(thickness, min(size.width, size.height) / 2))
        return [
            CGRect(x: 0, y: 0, width: size.width, height: depth), // bottom
            CGRect(x: 0, y: size.height - depth, width: size.width, height: depth), // top
            CGRect(x: 0, y: depth, width: depth, height: max(1, size.height - 2 * depth)), // left
            CGRect(x: size.width - depth, y: depth, width: depth, height: max(1, size.height - 2 * depth)), // right
        ]
    }
}
