import CoreGraphics
import Foundation

enum CameraShape: String, Codable, CaseIterable {
    case circle, square, roundedRectangle, verticalOval
}

struct CameraLayout: Codable, Equatable {
    var shape: CameraShape = .roundedRectangle
    var widthFraction: Double = 0.23
    var centerX: Double = 0.84
    var centerY: Double = 0.82
    var zoom: Double = 1
    static let `default` = CameraLayout()
    static let zoomRange = 1.0...3.0

    init(shape: CameraShape = .roundedRectangle, widthFraction: Double = 0.23,
         centerX: Double = 0.84, centerY: Double = 0.82, zoom: Double = 1) {
        self.shape = shape
        self.widthFraction = widthFraction
        self.centerX = centerX
        self.centerY = centerY
        self.zoom = zoom
    }

    private enum CodingKeys: String, CodingKey { case shape, widthFraction, centerX, centerY, zoom }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        shape = try values.decodeIfPresent(CameraShape.self, forKey: .shape) ?? .roundedRectangle
        widthFraction = try values.decodeIfPresent(Double.self, forKey: .widthFraction) ?? 0.23
        centerX = try values.decodeIfPresent(Double.self, forKey: .centerX) ?? 0.84
        centerY = try values.decodeIfPresent(Double.self, forKey: .centerY) ?? 0.82
        // Recordings and saved camera preferences from earlier versions have no zoom field.
        zoom = try values.decodeIfPresent(Double.self, forKey: .zoom) ?? 1
    }

    var effectiveZoom: Double {
        zoom.isFinite ? min(Self.zoomRange.upperBound, max(Self.zoomRange.lowerBound, zoom)) : 1
    }

    /// Centered aspect fill shared by the on-screen preview and the video compositor.
    /// Zoom changes the camera content, never the outer shape's size or position.
    func imageFrame(sourceSize: CGSize, in bounds: CGRect) -> CGRect {
        guard sourceSize.width > 0, sourceSize.height > 0,
              sourceSize.width.isFinite, sourceSize.height.isFinite,
              bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = max(bounds.width / sourceSize.width, bounds.height / sourceSize.height) * effectiveZoom
        let width = sourceSize.width * scale
        let height = sourceSize.height * scale
        return CGRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2, width: width, height: height)
    }

    /// Normalized center and returned rectangle both use top-left coordinates.
    func frame(in size: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return .zero }
        let fraction = widthFraction.isFinite ? min(0.45, max(0.12, widthFraction)) : 0.23
        let ratio: CGFloat
        switch shape {
        case .circle, .square: ratio = 1
        case .roundedRectangle: ratio = 4.0 / 3.0
        case .verticalOval: ratio = 3.0 / 4.0
        }
        let width = min(size.width * fraction, size.height * ratio)
        let height = width / ratio
        let cx = centerX.isFinite ? min(1, max(0, centerX)) : 0.84
        let cy = centerY.isFinite ? min(1, max(0, centerY)) : 0.82
        return CGRect(x: min(size.width - width, max(0, size.width * cx - width / 2)),
                      y: min(size.height - height, max(0, size.height * cy - height / 2)),
                      width: width, height: height)
    }
}
