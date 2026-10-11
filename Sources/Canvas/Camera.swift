// Canvas camera: world -> screen mapping. screen = world * scale + offset.

import Foundation
import CoreGraphics
import QuartzCore

struct Camera: Equatable {
    var offset = CGPoint.zero
    var scale: CGFloat = 1.0

    // Clamp range from config (zoom-min / zoom-max), live-reloaded.
    static var minScale: CGFloat { GCTConfig.current.zoomMin }
    static var maxScale: CGFloat { GCTConfig.current.zoomMax }

    func worldToScreen(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x * scale + offset.x, y: p.y * scale + offset.y)
    }

    func screenToWorld(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - offset.x) / scale, y: (p.y - offset.y) / scale)
    }

    func worldToScreenDistance(_ d: CGFloat) -> CGFloat { d * scale }
    func screenToWorldDistance(_ d: CGFloat) -> CGFloat { d / max(scale, 0.0001) }

    // Zoom keeping the world point under `screenPoint` stationary.
    mutating func zoom(at screenPoint: CGPoint, factor: CGFloat) {
        let anchor = screenToWorld(screenPoint)
        scale = min(max(scale * factor, Camera.minScale), Camera.maxScale)
        offset = CGPoint(x: screenPoint.x - anchor.x * scale,
                         y: screenPoint.y - anchor.y * scale)
    }

    func transform() -> CATransform3D {
        let t = CGAffineTransform(translationX: offset.x, y: offset.y)
            .scaledBy(x: scale, y: scale)
        return CATransform3DMakeAffineTransform(t)
    }
}
