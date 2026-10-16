import Testing
import CoreGraphics
@testable import ArtShotCore

struct CaptureGeometryTests {
    @Test func testReverseDragProducesPositiveRectangle() {
        #expect(CaptureGeometry.rectangle(from: CGPoint(x: 80, y: 90), to: CGPoint(x: 10, y: 20)) ==
                       CGRect(x: 10, y: 20, width: 70, height: 70))
    }

    @Test func testSecondaryScreenWithNegativeOriginFlipsAgainstThatScreen() {
        let screen = CGRect(x: -1920, y: -300, width: 1920, height: 1080)
        let region = CGRect(x: -1900, y: -250, width: 300, height: 200)
        #expect(CaptureGeometry.sourceRect(for: region, screenFrame: screen) ==
                       CGRect(x: 20, y: 830, width: 300, height: 200))
        #expect(CaptureGeometry.globalRect(fromLocal: CGRect(x: 20, y: 50, width: 300, height: 200), screenFrame: screen) == region)
    }

    @Test func testCaptureClipsToChosenScreenOnly() {
        let screen = CGRect(x: 100, y: 200, width: 500, height: 300)
        #expect(CaptureGeometry.clippedRegion(CGRect(x: 50, y: 100, width: 200, height: 200), to: screen) ==
                       CGRect(x: 100, y: 200, width: 150, height: 100))
        #expect(CaptureGeometry.clippedRegion(CGRect(x: 600, y: 200, width: 10, height: 10), to: screen) == nil)
        #expect(CaptureGeometry.clippedRegion(CGRect(x: 100, y: 200, width: 0, height: 10), to: screen) == nil)
    }

    @Test func testRetinaAlignsOutwardWithoutLosingSelectedPixels() {
        let screen = CGRect(x: 0, y: 0, width: 100, height: 100)
        let source = CaptureGeometry.pixelAlignedSourceRect(for: CGRect(x: 10.2, y: 20.2, width: 30.1, height: 40.1), screenFrame: screen, scale: 2)
        #expect(source == CGRect(x: 10, y: 39.5, width: 30.5, height: 40.5))
        #expect(CaptureGeometry.pixelSize(for: source!.size, scale: 2) == CGSize(width: 61, height: 81))
    }

    @Test func testRetinaAlignmentStaysWithinDisplayEdges() {
        let screen = CGRect(x: 0, y: 0, width: 100, height: 100)
        #expect(CaptureGeometry.pixelAlignedSourceRect(for: CGRect(x: 99.8, y: 99.8, width: 3, height: 3), screenFrame: screen, scale: 2) ==
                       CGRect(x: 99.5, y: 0, width: 0.5, height: 0.5))
    }

    @Test func testRejectsNonFiniteGeometryAndInvalidScale() {
        let screen = CGRect(x: 0, y: 0, width: 100, height: 100)
        #expect(CaptureGeometry.clippedRegion(CGRect(x: CGFloat.nan, y: 0, width: 20, height: 20), to: screen) == nil)
        #expect(CaptureGeometry.pixelAlignedSourceRect(for: screen, screenFrame: screen, scale: 0) == nil)
        #expect(CaptureGeometry.pixelSize(for: CGSize(width: 20, height: 20), scale: .infinity) == nil)
    }
}
