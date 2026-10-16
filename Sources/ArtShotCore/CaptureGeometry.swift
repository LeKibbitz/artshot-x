import Foundation
import CoreGraphics

/// Public capture rectangles use AppKit global points, with a bottom-left origin.
/// ScreenCaptureKit source rectangles use display-local points, with a top-left origin.
public enum CaptureGeometry {
    public static func rectangle(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
               width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    public static func clippedRegion(_ region: CGRect, to screenFrame: CGRect) -> CGRect? {
        guard isFinite(region), isFinite(screenFrame), !region.isNull, !screenFrame.isNull else { return nil }
        let clipped = region.standardized.intersection(screenFrame.standardized)
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return nil }
        return clipped
    }

    public static func globalRect(fromLocal rect: CGRect, screenFrame: CGRect) -> CGRect {
        rect.offsetBy(dx: screenFrame.minX, dy: screenFrame.minY)
    }

    public static func sourceRect(for region: CGRect, screenFrame: CGRect) -> CGRect? {
        guard let clipped = clippedRegion(region, to: screenFrame) else { return nil }
        return CGRect(x: clipped.minX - screenFrame.minX, y: screenFrame.maxY - clipped.maxY,
                      width: clipped.width, height: clipped.height)
    }

    /// Expands fractional edges to whole device pixels, without crossing the chosen display.
    public static func pixelAlignedSourceRect(for region: CGRect, screenFrame: CGRect, scale: CGFloat) -> CGRect? {
        guard scale.isFinite, scale > 0,
              let source = sourceRect(for: region, screenFrame: screenFrame) else { return nil }
        let left = max(0, floor(source.minX * scale) / scale)
        let top = max(0, floor(source.minY * scale) / scale)
        let right = min(screenFrame.width, ceil(source.maxX * scale) / scale)
        let bottom = min(screenFrame.height, ceil(source.maxY * scale) / scale)
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    public static func pixelSize(for pointSize: CGSize, scale: CGFloat) -> CGSize? {
        guard pointSize.width.isFinite, pointSize.height.isFinite, scale.isFinite,
              pointSize.width > 0, pointSize.height > 0, scale > 0 else { return nil }
        let width = (pointSize.width * scale).rounded()
        let height = (pointSize.height * scale).rounded()
        guard width.isFinite, height.isFinite, width >= 1, height >= 1 else { return nil }
        return CGSize(width: width, height: height)
    }

    private static func isFinite(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite && rect.width.isFinite && rect.height.isFinite
    }
}
