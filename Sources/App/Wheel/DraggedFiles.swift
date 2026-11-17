import AppKit
import UniformTypeIdentifiers

/// What a drag or a hand-off carries: file URLs and/or file promises
/// (Photos, Mail, browsers) (PLAN.md §3.2).
struct DraggedFiles {
    var urls: [URL] = []
    var promisedTypes: [UTType] = []

    var count: Int { urls.count + promisedTypes.count }
    var types: [UTType] { urls.map(Self.type(of:)) + promisedTypes }

    static func type(of url: URL) -> UTType {
        (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
            ?? UTType(filenameExtension: url.pathExtension) ?? .data
    }

    static let promiseTypes = Set(NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })

    /// Only looks at the advertised types: cheap, reads no file data.
    static func hasFiles(_ pasteboard: NSPasteboard) -> Bool {
        guard let types = pasteboard.types else { return false }
        return types.contains(.fileURL) || types.contains(NSPasteboard.PasteboardType("NSFilenamesPboardType"))
            || types.contains { promiseTypes.contains($0) }
    }

    static func read(_ pasteboard: NSPasteboard) -> DraggedFiles {
        var files = DraggedFiles()
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        files.urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL]) ?? []
        if files.urls.isEmpty,
           let receivers = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver] {
            files.promisedTypes = receivers.flatMap { $0.fileTypes.compactMap { UTType($0) } }
        }
        return files
    }
}
