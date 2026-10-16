import AppKit

struct CaptureItem: Codable, Identifiable {
    enum Kind: String, Codable { case image, video }
    let id: UUID
    let kind: Kind
    let url: URL
    let createdAt: Date
}

/// Keeps capture originals and their history available across relaunches. No account or upload.
@MainActor
final class CaptureLibrary {
    let storageDirectory: URL
    private let directory: URL
    private let indexURL: URL
    private(set) var recentItems: [CaptureItem] = []
    var latestImage: CaptureItem? { recentItems.first { $0.kind == .image } }
    var latestVideo: CaptureItem? { recentItems.first { $0.kind == .video } }

    init(storageDirectory: URL? = nil) {
        self.storageDirectory = storageDirectory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ArtShot X", isDirectory: true)
        directory = self.storageDirectory.appendingPathComponent("Captures", isDirectory: true)
        // Keep the filename and array format compatible with the former latest-only index.
        indexURL = directory.appendingPathComponent("latest.json")
        if let data = try? Data(contentsOf: indexURL),
           let items = try? JSONDecoder().decode([CaptureItem].self, from: data) {
            recentItems = items.filter { FileManager.default.fileExists(atPath: $0.url.path) }
                .sorted { $0.createdAt > $1.createdAt }
        }
    }

    func add(image: NSImage) throws -> CaptureItem {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let data = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID()
        let url = directory.appendingPathComponent("\(id.uuidString).png")
        try data.write(to: url, options: .atomic)
        let item = CaptureItem(id: id, kind: .image, url: url, createdAt: Date())
        do { try insert(item) }
        catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        return item
    }

    func add(video url: URL) throws -> CaptureItem {
        let item = CaptureItem(id: UUID(), kind: .video, url: url, createdAt: Date())
        try insert(item)
        return item
    }

    func discard(_ item: CaptureItem) throws {
        // Only files created inside our private application-support directory can be discarded.
        let base = storageDirectory.resolvingSymlinksInPath().path + "/"
        let candidate = item.url.resolvingSymlinksInPath()
        guard candidate.path.hasPrefix(base) else { throw CocoaError(.fileWriteNoPermission) }
        if FileManager.default.fileExists(atPath: candidate.path) {
            let folder = candidate.deletingLastPathComponent()
            let isRecordingProject = item.kind == .video
                && folder.deletingLastPathComponent().lastPathComponent == "Recordings"
                && UUID(uuidString: folder.lastPathComponent) != nil
            try FileManager.default.trashItem(at: isRecordingProject ? folder : candidate, resultingItemURL: nil)
        }
        let remaining = recentItems.filter { $0.id != item.id }
        try saveIndex(remaining)
        recentItems = remaining
    }

    private func insert(_ item: CaptureItem) throws {
        let items = [item] + recentItems
        try saveIndex(items)
        recentItems = items
    }

    private func saveIndex(_ items: [CaptureItem]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(items)
        try data.write(to: indexURL, options: .atomic)
    }
}
