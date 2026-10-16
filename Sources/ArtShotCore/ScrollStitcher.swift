import Foundation

/// Images are row-major grayscale samples, with a top-left origin. Keep native
/// vertical resolution; callers may reduce the horizontal resolution.
public struct ScrollFrame: Sendable {
    public let width: Int
    public let height: Int
    public let pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public var isValid: Bool {
        width > 0 && height > 0 && width <= Int.max / height && pixels.count == width * height
    }
}

public enum ScrollAlignment: Equatable, Sendable {
    case duplicate
    /// Number of new rows revealed at the bottom by scrolling downward.
    case shifted(pixels: Int)
    case unalignable
}

/// Conservative vertical registration. Ambiguous, upward, and oversized scrolls
/// are rejected instead of guessing. The top quarter is excluded to tolerate a
/// sticky page heading. Select the document content, without a fixed footer.
public enum ScrollStitcher {
    public static func isStable(_ first: ScrollFrame, _ second: ScrollFrame) -> Bool {
        guard compatible(first, second) else { return false }
        return unchanged(first, second, meanTolerance: 0.65)
    }

    public static func align(previous: ScrollFrame, next: ScrollFrame) -> ScrollAlignment {
        guard compatible(previous, next), previous.height >= 48, previous.width >= 8 else {
            return .unalignable
        }
        if unchanged(previous, next, meanTolerance: 0.8) { return .duplicate }
        let height = previous.height
        let top = height / 4
        let bottom = max(2, height / 20)
        let minimumOverlap = max(20, height / 5)
        let maximumShift = height - top - bottom - minimumOverlap
        guard maximumShift > 0 else { return .unalignable }
        let xStep = max(1, previous.width / 32)
        let yStep = max(1, height / 80)
        var candidates: [(shift: Int, score: Double)] = []
        for shift in 1...maximumShift {
            let score = matchScore(previous, next, shift: shift, top: top, bottom: bottom,
                                   xStep: xStep, yStep: yStep)
            if score < 5 { candidates.append((shift, score)) }
        }
        candidates.sort { $0.score < $1.score }
        // Refine separate peaks, so neighboring anti-aliased rows do not crowd
        // the candidate list and hide another equally plausible alignment.
        var peaks: [(shift: Int, score: Double)] = []
        for candidate in candidates {
            if peaks.allSatisfy({ abs($0.shift - candidate.shift) > 3 }) {
                peaks.append(candidate)
                if peaks.count == 8 { break }
            }
        }
        var refined: [(shift: Int, score: Double)] = []
        for peak in peaks {
            // Sparse text can make neighboring offsets tie in the coarse pass.
            // Search around the peak again at full horizontal resolution.
            let neighborhood = max(1, peak.shift - 3)...min(maximumShift, peak.shift + 3)
            let best = neighborhood.map { shift in
                (shift: shift,
                 score: matchScore(previous, next, shift: shift, top: top, bottom: bottom,
                                   xStep: 1, yStep: max(1, height / 400)))
            }.min { $0.score < $1.score }!
            if !refined.contains(where: { abs($0.shift - best.shift) <= 3 }) {
                refined.append(best)
            }
        }
        refined.sort { $0.score < $1.score }
        guard let best = refined.first, best.score <= 2.2 else { return .unalignable }
        if refined.count > 1, refined[1].score <= max(best.score * 1.4, best.score + 0.45) {
            return .unalignable
        }
        // A stationary toolbar at the bottom would be repeated in every strip.
        // Refuse it; blank margin alone is harmless and is not a toolbar.
        if hasFixedFooter(previous, next) { return .unalignable }
        return .shifted(pixels: best.shift)
    }

    private static func compatible(_ first: ScrollFrame, _ second: ScrollFrame) -> Bool {
        first.isValid && second.isValid && first.width == second.width && first.height == second.height
    }

    private static func unchanged(_ first: ScrollFrame, _ second: ScrollFrame, meanTolerance: Double) -> Bool {
        var total = 0.0
        for index in first.pixels.indices {
            let delta = abs(Double(first.pixels[index]) - Double(second.pixels[index]))
            // An average alone can hide a small moving element on a white page.
            if delta > 6 { return false }
            total += delta
        }
        return total / Double(first.pixels.count) <= meanTolerance
    }

    private static func matchScore(_ first: ScrollFrame, _ second: ScrollFrame, shift: Int,
                                   top: Int, bottom: Int, xStep: Int, yStep: Int) -> Double {
        let width = first.width
        let margin = max(1, width / 20) // Scrollbars and viewport borders.
        var error = 0.0
        var weight = 0.0
        var detail = 0.0
        let lastRow = first.height - bottom - shift
        for row in Swift.stride(from: top, to: lastRow, by: yStep) {
            // Vary the sampled phase to avoid always landing between text lines.
            let jitter = (((row / yStep) &* 1_103_515_245 &+ 12_345) & 0x7fff_ffff) >> 8
            let y = min(lastRow - 1, row + jitter % yStep)
            for x in Swift.stride(from: margin, to: width - margin, by: xStep) {
                let a = (y + shift) * width + x
                let b = y * width + x
                let gradient = abs(Double(first.pixels[a]) - Double(first.pixels[a - xStep]))
                    + abs(Double(second.pixels[b]) - Double(second.pixels[b - xStep]))
                    + abs(Double(first.pixels[a]) - Double(first.pixels[a - width]))
                    + abs(Double(second.pixels[b]) - Double(second.pixels[b - width]))
                let pixelWeight = 1 + min(12, gradient / 8)
                error += abs(Double(first.pixels[a]) - Double(second.pixels[b])) * pixelWeight
                weight += pixelWeight
                detail += gradient
            }
        }
        // A featureless surface gives no evidence for a reliable offset.
        guard weight > 0, detail / weight > 0.12 else { return .infinity }
        return error / weight
    }

    private static func hasFixedFooter(_ first: ScrollFrame, _ second: ScrollFrame) -> Bool {
        let width = first.width
        var rows = 0
        var footerMinimum = 255
        var footerMaximum = 0
        for y in Swift.stride(from: first.height - 1, through: first.height * 9 / 10, by: -1) {
            var error = 0.0
            for x in width / 20..<width - width / 20 {
                let index = y * width + x
                error += abs(Double(first.pixels[index]) - Double(second.pixels[index]))
            }
            if error / Double(width - 2 * (width / 20)) > 0.65 { break }
            rows += 1
            for x in width / 20..<width - width / 20 {
                let value = Int(first.pixels[y * width + x])
                footerMinimum = min(footerMinimum, value)
                footerMaximum = max(footerMaximum, value)
            }
        }
        return rows >= max(6, first.height / 100) && footerMaximum - footerMinimum > 24
    }
}
