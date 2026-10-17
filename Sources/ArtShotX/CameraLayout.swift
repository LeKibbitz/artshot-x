import CoreGraphics
import Foundation

enum CameraShape: String, Codable, CaseIterable {
    case circle, square, roundedRectangle
}

struct CameraLayout: Codable, Equatable {
    var shape: CameraShape = .roundedRectangle
    var widthFraction: Double = 0.23
    var centerX: Double = 0.84
    var centerY: Double = 0.82
    static let `default` = CameraLayout()

    /// Normalized center and returned rectangle both use top-left coordinates.
    func frame(in size: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return .zero }
        let fraction = widthFraction.isFinite ? min(0.45, max(0.12, widthFraction)) : 0.23
        let ratio: CGFloat = shape == .roundedRectangle ? 4.0 / 3.0 : 1
        let width = min(size.width * fraction, size.height * ratio)
        let height = width / ratio
        let cx = centerX.isFinite ? min(1, max(0, centerX)) : 0.84
        let cy = centerY.isFinite ? min(1, max(0, centerY)) : 0.82
        return CGRect(x: min(size.width - width, max(0, size.width * cx - width / 2)),
                      y: min(size.height - height, max(0, size.height * cy - height / 2)),
                      width: width, height: height)
    }
}
