import AppKit
import CircularityEngine
import Combine
import CoreServices

/// Watch folders (BRIEF.md): an FSEventStream exists only while at least one
/// rule is enabled, so with none nothing runs. New files are converted once
/// their size stops changing; files we wrote are never picked up again.
final class WatchFolderService: ObservableObject {
    @Published private(set) var rules: [WatchRule]
    private let settings: SettingsStore
    private let jobs: JobCenter
    private var stream: FSEventStreamRef?
    private var pending: [String: (size: Int64, work: DispatchWorkItem)] = [:]
    private var produced: Set<String> = []
    private var bag: Set<AnyCancellable> = []

    init(settings: SettingsStore, jobs: JobCenter) {
        self.settings = settings
        self.jobs = jobs
        rules = Self.decode(settings.value(SettingsKeys.watchRulesJSON))
        restart()
        // An imported settings file may bring different rules.
        settings.changes.sink { [weak self] name in
            guard let self, name.isEmpty || name == SettingsKeys.watchRulesJSON.name else { return }
            let stored = Self.decode(settings.value(SettingsKeys.watchRulesJSON))
            if stored != rules {
                rules = stored
                restart()
            }
        }.store(in: &bag)
    }

    var enabledCount: Int { rules.filter(\.enabled).count }
    var isStreaming: Bool { stream != nil }

    func add(_ rule: WatchRule) { rules.append(rule); save() }
    func update(_ rule: WatchRule) {
        guard let i = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules[i] = rule
        save()
    }
    func remove(_ id: String) { rules.removeAll { $0.id == id }; save() }

    /// The screenshot folder (System Settings may move it), for the built-in suggestion.
    static var screenshotFolder: URL {
        if let path = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location"), !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
    }

    /// Desktop, Documents and Downloads make macOS ask once for access.
    static func isProtected(_ folder: URL) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["Desktop", "Documents", "Downloads"].contains { folder.path.hasPrefix("\(home)/\($0)") }
    }

    private func save() {
        settings.set(Self.encode(rules), for: SettingsKeys.watchRulesJSON)
        restart()
    }

    private static func decode(_ json: String) -> [WatchRule] { (try? JSONDecoder().decode([WatchRule].self, from: Data(json.utf8))) ?? [] }
    private static func encode(_ rules: [WatchRule]) -> String { (try? String(data: JSONEncoder().encode(rules), encoding: .utf8)) ?? "[]" }

    // MARK: FSEvents

    private func restart() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        let folders = rules.filter(\.enabled).map(\.folder)
        guard !folders.isEmpty else {
            Log.app.notice("Watch folders: none enabled, no stream running")
            return
        }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        // Not IgnoreSelf: files saved by this app (e.g. from another tool) count too.
        // Loops are prevented by `produced` and by skipping files already in the target format.
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        guard let made = FSEventStreamCreate(nil, { _, info, count, paths, eventFlags, _ in
            guard let info else { return }
            let service = Unmanaged<WatchFolderService>.fromOpaque(info).takeUnretainedValue()
            let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            var events: [(String, FSEventStreamEventFlags)] = []
            for i in 0..<min(count, list.count) { events.append((list[i], eventFlags[i])) }
            MainActor.assumeIsolated { service.handle(events) }
        }, &context, folders as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0, flags) else { return }
        FSEventStreamSetDispatchQueue(made, DispatchQueue.main)
        FSEventStreamStart(made)
        stream = made
        Log.app.notice("Watch folders: watching \(folders.count, privacy: .public) folder(s)")
    }

    private func handle(_ events: [(String, FSEventStreamEventFlags)]) {
        for (path, flags) in events {
            let isFile = flags & UInt32(kFSEventStreamEventFlagItemIsFile) != 0
            let interesting = flags & UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRenamed
                | kFSEventStreamEventFlagItemModified) != 0
            guard isFile, interesting, !produced.contains(path) else { continue }
            let url = URL(fileURLWithPath: path)
            // FSEvents reports resolved paths (/private/var/…), so compare resolved folders.
            let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().path
            guard let rule = rules.first(where: { $0.enabled && URL(fileURLWithPath: $0.folder).resolvingSymlinksInPath().path == parent }) else { continue }
            scheduleCheck(url, rule: rule)
        }
    }

    /// Waits until the file stops growing (downloads, screenshots being written).
    /// Gives up after about a minute of an empty or still-changing file (a
    /// stalled download or a placeholder); a later write starts it again.
    private func scheduleCheck(_ url: URL, rule: WatchRule, attempt: Int = 0) {
        pending[url.path]?.work.cancel()
        let size = Self.size(url)
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = Self.size(url)
                if now != size || now == 0 {
                    if attempt < 40, FileManager.default.fileExists(atPath: url.path) {
                        self.scheduleCheck(url, rule: rule, attempt: attempt + 1)
                    } else {
                        self.pending[url.path] = nil
                    }
                    return
                }
                self.pending[url.path] = nil
                self.convert(url, rule: rule)
            }
        }
        pending[url.path] = (size, work)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private func convert(_ url: URL, rule: WatchRule) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let kind = SlotProvider.kind(of: DraggedFiles.type(of: url))
        guard rule.accepts(url, kind: kind) else { return }
        var policy = jobs.outputPolicy(for: .convert(rule.format))
        switch rule.output {
        case .inPlace: policy.destination = .nextToOriginal
        case let .subfolder(name): policy.destination = .folder(URL(fileURLWithPath: rule.folder).appendingPathComponent(name, isDirectory: true))
        case let .folder(path): policy.destination = .folder(URL(fileURLWithPath: path, isDirectory: true))
        }
        let operation: CircularityEngine.Operation = kind == .pdf && rule.format != .pdf ? .pdfPages(rule.format, scale: 2) : .convert(rule.format)
        Log.app.notice("Watch folder: converting a new file to \(rule.format.displayName, privacy: .public)")
        jobs.run(operation, files: [url], label: "watch", policy: policy, interactive: false) { [weak self] result in
            guard let self, case let .success(r) = result else { return }
            for output in r.outputs { self.produced.insert(output.path) }
            if rule.trashOriginal, !r.outputs.isEmpty {
                try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
            }
        }
    }

    private static func size(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
}
