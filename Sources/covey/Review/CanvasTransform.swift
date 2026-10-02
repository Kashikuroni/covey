import Foundation
import CoreGraphics

/// Screen space kept free when fitting: the title block sits top-left and
/// the toolbar bottom-left.
struct CanvasInsets: Equatable {
    var top: CGFloat
    var left: CGFloat
    var bottom: CGFloat
    var right: CGFloat

    static let canvas = CanvasInsets(top: 150, left: 40, bottom: 90, right: 40)
}

/// World → screen: `screen = world * zoom + pan`.
struct CanvasTransform: Equatable {
    static let zoomRange: ClosedRange<CGFloat> = 0.2...2

    var zoom: CGFloat = 1
    var pan: CGSize = .zero

    func toScreen(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x * zoom + pan.width, y: p.y * zoom + pan.height)
    }

    func toWorld(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - pan.width) / zoom, y: (p.y - pan.height) / zoom)
    }

    /// Zooms keeping the world point under `anchor` (screen) where it is.
    func zoomed(by factor: CGFloat, around anchor: CGPoint) -> CanvasTransform {
        let world = toWorld(anchor)
        let z = Self.clamp(zoom * factor)
        return CanvasTransform(zoom: z, pan: CGSize(width: anchor.x - world.x * z,
                                                    height: anchor.y - world.y * z))
    }

    func panned(by delta: CGSize) -> CanvasTransform {
        CanvasTransform(zoom: zoom, pan: CGSize(width: pan.width + delta.width,
                                                height: pan.height + delta.height))
    }

    func centered(on rect: CGRect, in viewport: CGSize) -> CanvasTransform {
        CanvasTransform(zoom: zoom, pan: CGSize(width: viewport.width / 2 - rect.midX * zoom,
                                                height: viewport.height / 2 - rect.midY * zoom))
    }

    /// Fits `content` inside the viewport minus `insets`: centered
    /// horizontally, top-aligned under the title, never above 100%.
    static func fit(_ content: CGRect?, in viewport: CGSize,
                    insets: CanvasInsets = .canvas) -> CanvasTransform {
        let width = viewport.width - insets.left - insets.right
        let height = viewport.height - insets.top - insets.bottom
        guard let content, content.width > 0, content.height > 0, width > 0, height > 0 else {
            return CanvasTransform()
        }
        let z = clamp(min(width / content.width, height / content.height, 1))
        return CanvasTransform(zoom: z, pan: CGSize(
            width: insets.left + (width - content.width * z) / 2 - content.minX * z,
            height: insets.top - content.minY * z))
    }

    private static func clamp(_ z: CGFloat) -> CGFloat {
        min(max(z, zoomRange.lowerBound), zoomRange.upperBound)
    }
}
