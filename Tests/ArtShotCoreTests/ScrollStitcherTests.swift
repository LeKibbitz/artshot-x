import Testing
@testable import ArtShotCore

struct ScrollStitcherTests {
    private func frame(offset: Int = 0, height: Int = 180, header: Int = 0, footer: Int = 0) -> ScrollFrame {
        let width = 48
        let pixels: [UInt8] = (0..<height).flatMap { y in
            (0..<width).map { x in
                let row = y < header || y >= height - footer ? y : y + offset
                let hash = (row &* 1_664_525 &+ x &* 1_013_904_223) ^ (row &* x &* 7_919)
                return UInt8(truncatingIfNeeded: hash >> 7)
            }
        }
        return ScrollFrame(width: width, height: height, pixels: pixels)
    }

    @Test func registersDownwardScrollAtNativeVerticalResolution() {
        #expect(ScrollStitcher.align(previous: frame(), next: frame(offset: 37)) == .shifted(pixels: 37))
        #expect(ScrollStitcher.align(previous: frame(), next: frame(offset: 1)) == .shifted(pixels: 1))
        #expect(ScrollStitcher.align(previous: frame(), next: frame(offset: 90)) == .shifted(pixels: 90))
    }

    @Test func stationaryFramesDoNotAddRows() {
        #expect(ScrollStitcher.align(previous: frame(), next: frame()) == .duplicate)
        #expect(ScrollStitcher.isStable(frame(), frame()))
        #expect(!ScrollStitcher.isStable(frame(), frame(offset: 2)))
    }

    @Test func toleratesFixedHeading() {
        #expect(ScrollStitcher.align(previous: frame(header: 35), next: frame(offset: 41, header: 35)) == .shifted(pixels: 41))
    }

    @Test func rejectsFixedFooterInsteadOfRepeatingIt() {
        #expect(ScrollStitcher.align(previous: frame(footer: 15), next: frame(offset: 30, footer: 15)) == .unalignable)
    }

    @Test func rejectsUpwardMovementOrMissingOverlap() {
        #expect(ScrollStitcher.align(previous: frame(offset: 40), next: frame()) == .unalignable)
        #expect(ScrollStitcher.align(previous: frame(), next: frame(offset: 240)) == .unalignable)
    }

    @Test func rejectsAmbiguousRepeatedPattern() {
        func repeating(offset: Int) -> ScrollFrame {
            ScrollFrame(width: 48, height: 180, pixels: (0..<180).flatMap { y in
                (0..<48).map { x in UInt8(((y + offset) % 12 * 19 + x * 7) % 255) }
            })
        }
        #expect(ScrollStitcher.align(previous: repeating(offset: 0), next: repeating(offset: 5)) == .unalignable)
    }

    @Test func rejectsMalformedAndResizedFrames() {
        let invalid = ScrollFrame(width: Int.max, height: 2, pixels: [])
        #expect(ScrollStitcher.align(previous: invalid, next: frame()) == .unalignable)
        #expect(!ScrollStitcher.isStable(invalid, invalid))
        #expect(ScrollStitcher.align(previous: frame(), next: frame(height: 181)) == .unalignable)
    }

    @Test func smallLocalChangeIsNotMistakenForNoMovement() {
        let previous = frame()
        var pixels = previous.pixels
        pixels[100] = previous.pixels[100] > 127 ? 0 : 255
        let next = ScrollFrame(width: previous.width, height: previous.height, pixels: pixels)
        #expect(!ScrollStitcher.isStable(previous, next))
        #expect(ScrollStitcher.align(previous: previous, next: next) != .duplicate)
    }

    @Test func registersSparseTextWithWideBlankMarginsAndStickyHeader() {
        func document(offset: Int) -> ScrollFrame {
            let width = 160
            let height = 720
            let pixels: [UInt8] = (0..<height).flatMap { y in
                (0..<width).map { x -> UInt8 in
                    if y < 90 { return x > 12 && x < 130 && y % 19 < 5 ? 50 : 240 }
                    if x < 10 || x > 148 { return 255 }
                    let row = y + offset
                    let line = row / 23
                    let word = (x / 5 + line * 7) % 13
                    return row % 23 < 6 && word < (line % 8 + 3) ? 30 : 255
                }
            }
            return ScrollFrame(width: width, height: height, pixels: pixels)
        }
        for offset in [1, 8, 41, 120, 260, 350] {
            #expect(ScrollStitcher.align(previous: document(offset: 0), next: document(offset: offset)) == .shifted(pixels: offset))
        }
    }

    @Test func blankChangedSurfaceDoesNotInventOffset() {
        let white = ScrollFrame(width: 48, height: 180, pixels: Array(repeating: 255, count: 48 * 180))
        let gray = ScrollFrame(width: 48, height: 180, pixels: Array(repeating: 230, count: 48 * 180))
        #expect(ScrollStitcher.align(previous: white, next: gray) == .unalignable)
    }
}
