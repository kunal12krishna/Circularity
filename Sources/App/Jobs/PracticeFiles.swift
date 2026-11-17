import AppKit

/// The practice pictures of Settings → Gesture and the tutorial. Jobs on them
/// ignore Output settings and after-conversion actions, and don't count in
/// history, stats or smart ordering ("nothing of yours changes").
enum PracticeFiles {
    static var folders: [URL] {
        let tmp = FileManager.default.temporaryDirectory
        return ["Practice", "Tutorial", "Sample"].map { tmp.appendingPathComponent("\(AppIdentity.name)-\($0)", isDirectory: true) }
    }

    static func contains(_ url: URL) -> Bool {
        let path = url.resolvingSymlinksInPath().path
        return folders.contains { path.hasPrefix($0.resolvingSymlinksInPath().path + "/") }
    }

    static func all(_ urls: [URL]) -> Bool { !urls.isEmpty && urls.allSatisfy(contains) }
}
