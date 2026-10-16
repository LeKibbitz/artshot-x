import AppKit

// Standalone persistence harness. Every file lives in an isolated temporary directory.
@main struct CaptureLibrarySmokeTests {
    @MainActor static func main() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("artshot-library-tests-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: root) }

        let library = CaptureLibrary(storageDirectory: root)
        precondition(library.storageDirectory == root && library.recentItems.isEmpty)
        let context = CGContext(data: nil, width: 8, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 4))
        let image = NSImage(cgImage: context.makeImage()!, size: NSSize(width: 4, height: 2))
        let first = try library.add(image: image)
        let second = try library.add(image: image)
        let third = try library.add(image: image)
        let videoURL = root.appendingPathComponent("Recordings/\(UUID().uuidString)/capture.mov")
        try files.createDirectory(at: videoURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0]).write(to: videoURL)
        let video = try library.add(video: videoURL)
        let expected = [video.id, third.id, second.id, first.id]
        precondition(library.recentItems.map(\.id) == expected, "History dropped older captures")
        precondition(library.latestImage?.id == third.id && library.latestVideo?.id == video.id)
        let bitmap = NSBitmapImageRep(data: try Data(contentsOf: first.url))!
        precondition(bitmap.pixelsWide == 8 && bitmap.pixelsHigh == 4, "Stored PNG lost native resolution")

        let reloaded = CaptureLibrary(storageDirectory: root)
        precondition(reloaded.recentItems.map(\.id) == expected, "Relaunch lost capture history or ordering")
        // A missing source must still be removable from the manifest; no test file enters the user's Trash.
        try files.removeItem(at: second.url)
        try reloaded.discard(second)
        let afterDiscard = CaptureLibrary(storageDirectory: root)
        precondition(afterDiscard.recentItems.map(\.id) == [video.id, third.id, first.id],
                     "Discard removed other history entries")
        precondition(files.fileExists(atPath: first.url.path) && files.fileExists(atPath: third.url.path)
                     && files.fileExists(atPath: videoURL.path), "Discard touched another original")
        try files.removeItem(at: third.url)
        try afterDiscard.discard(third)
        precondition(afterDiscard.latestImage?.id == first.id, "Latest image did not fall back after discard")

        let legacyRoot = root.appendingPathComponent("Legacy", isDirectory: true)
        let legacyIndex = legacyRoot.appendingPathComponent("Captures/latest.json")
        try files.createDirectory(at: legacyIndex.deletingLastPathComponent(), withIntermediateDirectories: true)
        // The previous app wrote [latestImage, latestVideo], rather than chronological order.
        try JSONEncoder().encode([first, video]).write(to: legacyIndex)
        let legacy = CaptureLibrary(storageDirectory: legacyRoot)
        precondition(legacy.recentItems.map(\.id) == [video.id, first.id], "Legacy latest.json was not migrated")
        let fresh = try legacy.add(image: image)
        let migrated = CaptureLibrary(storageDirectory: legacyRoot)
        precondition(migrated.recentItems.map(\.id) == [fresh.id, video.id, first.id],
                     "Adding a capture discarded migrated history")

        print("PASS: complete history; chronological order; native PNG resolution; relaunch; targeted manifest discard; latest fallback; legacy latest.json compatibility")
    }
}
