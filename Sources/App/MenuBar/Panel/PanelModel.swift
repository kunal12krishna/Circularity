import AppKit
import CircularityEngine
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// What the panel asks the app to do (implemented by AppCoordinator).
protocol PanelHost: AnyObject {
    func panelTargetFiles() -> [URL]
    func panelChooseFiles(_ then: @escaping ([URL]) -> Void)
    func panelOpenWheel(files: [URL])
    func panelOpenDialog(_ action: WheelAction, files: [URL])
    func panelSettingsMenu() -> [NSMenuItem]
    /// Shows the settings menu (Settings window arrives in milestone i).
    func panelOpenSettings()
    func panelTutorial()
    func panelTogglePin()
    func panelClose()
    func panelShowHistory()
    func panelShowStats()
    func panelShowWatch()
    func panelClipboard(_ format: OutputFormat?)
}

enum PanelLayout: String, CaseIterable { case stackPlus, tabs, mini }

/// A preset tile in the panel grid.
struct PanelTile: Identifiable, Equatable {
    enum Action: Equatable { case builtin(String), preset(Preset) }
    let id: String
    let big: String
    let small: String
    let action: Action
}

/// One row in the ⌘K results.
struct CommandResult: Identifiable, Equatable {
    enum Kind: Equatable { case command(Command), recent(HistoryItem) }
    let id: String
    let title: String
    let subtitle: String
    let kind: Kind
}

/// The single view model behind all three panel layouts (BRIEF.md: switching
/// layout never changes behaviour).
final class PanelModel: ObservableObject {
    let jobs: JobCenter
    let history: HistoryStore
    let stats: StatsStore
    let watch: WatchFolderService
    let settings: SettingsStore
    weak var host: PanelHost?

    @Published var query = "" { didSet { selected = 0 } }
    @Published var selected = 0
    @Published var notice: String?
    @Published var editing = false
    @Published var focusCommand = false
    @Published var dropTargeted = false
    @Published var dropKind: FileKind = .image
    @Published var miniHover: Int?
    @Published var tab = 0
    @Published var pinned = false
    @Published var dropMode = false
    private var bag: Set<AnyCancellable> = []

    init(jobs: JobCenter, watch: WatchFolderService, settings: SettingsStore) {
        self.jobs = jobs
        history = jobs.history
        stats = jobs.stats
        self.watch = watch
        self.settings = settings
        settings.changes.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        for publisher in [jobs.objectWillChange.eraseToAnyPublisher(), history.objectWillChange.eraseToAnyPublisher(),
                          stats.objectWillChange.eraseToAnyPublisher(), watch.objectWillChange.eraseToAnyPublisher()] {
            publisher.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        }
    }

    // MARK: Appearance

    var accentNS: NSColor { Appearance.accentNS(settings) }
    var accent: Color { Color(nsColor: accentNS) }
    /// Text links: the accent mixed 40 % toward white (board I's #FFB366 for tangerine).
    var link: Color { Color(nsColor: accentNS.blended(withFraction: 0.4, of: .white) ?? accentNS) }
    var layout: PanelLayout { PanelLayout(rawValue: settings.value(SettingsKeys.panelLayout)) ?? .stackPlus }

    // MARK: Header

    var paused: Bool {
        get { settings.value(SettingsKeys.paused) }
        set { settings.set(newValue, for: SettingsKeys.paused); objectWillChange.send() }
    }

    var statusText: String {
        if paused { return "Paused · the wheel will not appear" }
        var parts: [String] = []
        if !jobs.active.isEmpty { parts.append("Converting \(jobs.active.count) file\(jobs.active.count == 1 ? "" : "s")") }
        if watch.enabledCount > 0, jobs.active.isEmpty { parts.append("Watching \(watch.enabledCount) folder\(watch.enabledCount == 1 ? "" : "s")") }
        parts.append(jobs.active.isEmpty && watch.enabledCount == 0 ? "Ready · Shift\u{2011}drag ready" : "Shift\u{2011}drag ready")
        return parts.joined(separator: " · ")
    }

    var statusDot: Color { paused ? Color(hex: 0x9C968D) : accent }

    // MARK: Stats strip

    var todayText: String { "\(stats.today.files) file\(stats.today.files == 1 ? "" : "s")" }
    var savedWeekText: String { Bytes.text(stats.savedThisWeek) }
    var watchingText: String { "\(watch.enabledCount) folder\(watch.enabledCount == 1 ? "" : "s")" }

    // MARK: Recent

    var recentCount: Int { settings.value(SettingsKeys.recentsCount) }
    var recents: [HistoryItem] { Array(history.existing.prefix(recentCount)) }

    func reveal(_ item: HistoryItem) {
        NSWorkspace.shared.activateFileViewerSelecting(item.outputs.map { URL(fileURLWithPath: $0) })
    }

    func quickLook(_ item: HistoryItem) { QuickLook.shared.show(item.outputs.map { URL(fileURLWithPath: $0) }) }
    func convertAgain(_ item: HistoryItem) { item.primaryOutput.map { host?.panelOpenWheel(files: [$0]) } }
    func undo(_ item: HistoryItem) { history.undo(item.id) }
    func open(_ item: HistoryItem) { item.primaryOutput.map { _ = NSWorkspace.shared.open($0) } }

    func copy(_ item: HistoryItem) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(item.outputs.map { URL(fileURLWithPath: $0) as NSURL })
    }

    func copyPath(_ item: HistoryItem) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(item.outputs.joined(separator: "\n"), forType: .string)
    }

    static func sizeLine(_ item: HistoryItem) -> String {
        let sizes = "\(Bytes.text(item.bytesIn)) → \(Bytes.text(item.bytesOut))"
        return item.label.contains("→") ? "\(item.label) · \(sizes)" : sizes
    }

    static func delta(_ item: HistoryItem) -> String? {
        item.percentChange.map { $0 >= 0 ? "+\($0)%" : "−\(-$0)%" }
    }

    static func when(_ date: Date) -> String {
        let s = Date().timeIntervalSince(date)
        if s < 60 { return "now" }
        if s < 3600 { return "\(Int(s / 60)) min" }
        if s < 86_400 { return "\(Int(s / 3600)) h" }
        return "\(Int(s / 86_400)) d"
    }

    // MARK: Preset tiles

    static let builtins: [PanelTile] = [
        PanelTile(id: "b.jpg", big: "→ JPG", small: "images", action: .builtin("jpg")),
        PanelTile(id: "b.2mb", big: "< 2 MB", small: "compress", action: .builtin("2mb")),
        PanelTile(id: "b.1920", big: "1920w", small: "resize", action: .builtin("1920")),
        PanelTile(id: "b.combine", big: "→ PDF", small: "combine", action: .builtin("combine")),
        PanelTile(id: "b.nogps", big: "No GPS", small: "strip metadata", action: .builtin("nogps")),
        PanelTile(id: "b.clip", big: "Copy PNG", small: "clipboard", action: .builtin("clip")),
    ]

    var allTiles: [PanelTile] {
        let presetTiles = jobs.presets.map { PanelTile(id: "p.\($0.id)", big: $0.name, small: $0.applies == .pdfs ? "PDF button" : "your button", action: .preset($0)) }
        let available = Self.builtins + presetTiles
        let order = settings.value(SettingsKeys.panelTiles)
        guard !order.isEmpty else { return available }
        let ids = order.split(separator: ",").map(String.init)
        let ordered = ids.compactMap { id in available.first { $0.id == id } }
        let newPresets = presetTiles.filter { tile in !ids.contains(tile.id) && !ids.contains("-\(tile.id)") }
        return ordered + newPresets
    }

    /// Settings → Menu bar → sections (Stack+).
    var sections: [String] { PanelSections.parse(settings.value(SettingsKeys.panelSections)) }
    var compact: Bool { settings.value(SettingsKeys.panelDensity) == "compact" }

    var gridColumns: Int { settings.value(SettingsKeys.presetGrid).hasPrefix("4") ? 4 : 3 }
    var gridRows: Int { settings.value(SettingsKeys.presetGrid).hasSuffix("1") ? 1 : 2 }
    var visibleTiles: [PanelTile] { editing ? allTiles : Array(allTiles.prefix(gridColumns * gridRows)) }

    func colorIndex(_ tile: PanelTile) -> Int { settings.value(SettingsKeys.panelTileColors)[tile.id] ?? 0 }
    static let tileColors: [UInt32?] = [nil, 0x2F7D5B, 0x3B6FD8, 0x8E3B5E, 0x6B5B2E]

    func cycleColor(_ tile: PanelTile) {
        var colors = settings.value(SettingsKeys.panelTileColors)
        colors[tile.id] = ((colors[tile.id] ?? 0) + 1) % Self.tileColors.count
        settings.set(colors, for: SettingsKeys.panelTileColors)
        objectWillChange.send()
    }

    func removeTile(_ tile: PanelTile) {
        var ids = allTiles.map(\.id).filter { $0 != tile.id }
        if tile.id.hasPrefix("p.") { ids.append("-\(tile.id)") } // hidden from the panel, still on the wheel
        settings.set(ids.joined(separator: ","), for: SettingsKeys.panelTiles)
        objectWillChange.send()
    }

    func moveTile(_ id: String, before target: String) {
        var ids = allTiles.map(\.id)
        guard let from = ids.firstIndex(of: id), ids.contains(target), id != target else { return }
        ids.remove(at: from)
        ids.insert(id, at: ids.firstIndex(of: target) ?? ids.endIndex)
        settings.set(ids.joined(separator: ","), for: SettingsKeys.panelTiles)
        objectWillChange.send()
    }

    func restoreTiles() {
        settings.set("", for: SettingsKeys.panelTiles)
        objectWillChange.send()
    }

    /// Click: runs on the last files handed to the app (or asks for files).
    /// Drop: runs on the dropped files.
    func run(_ tile: PanelTile, files dropped: [URL]? = nil) {
        if case .builtin("clip") = tile.action {
            host?.panelClipboard(.png)
            return
        }
        let files = dropped ?? host?.panelTargetFiles() ?? []
        guard !files.isEmpty else {
            host?.panelChooseFiles { [weak self] chosen in self?.run(tile, files: chosen) }
            return
        }
        switch tile.action {
        case .builtin("jpg"): jobs.run(CircularityEngine.Operation.convert(.jpg), files: files, label: "tile.jpg")
        case .builtin("2mb"): jobs.run(.compressUnder(2_000_000), files: files)
        case .builtin("1920"): jobs.run(.resizeWidth(1920), files: files)
        case .builtin("combine"): jobs.run(.combine, files: files)
        case .builtin("nogps"): jobs.run(.stripGPS, files: files)
        case let .preset(preset): jobs.run(preset.operation, files: files, label: "tile.\(preset.name)")
        default: break
        }
        notice = "\(tile.big) — \(files.count == 1 ? files[0].lastPathComponent : "\(files.count) files")"
    }

    // MARK: ⌘K

    var results: [CommandResult] {
        let commands = CommandParser.parse(query).map {
            CommandResult(id: "c.\($0.title)", title: $0.title, subtitle: $0.needsFiles ? targetDescription : "", kind: .command($0))
        }
        let recents = FuzzyMatcher.rank(history.existing, query: query) { "\($0.name) \($0.label)" }.prefix(6).map {
            CommandResult(id: "r.\($0.id)", title: $0.name, subtitle: "\($0.label) · \(Self.when($0.date)) ago", kind: .recent($0))
        }
        return Array((commands + recents).prefix(8))
    }

    private var targetDescription: String {
        let files = host?.panelTargetFiles() ?? []
        return files.isEmpty ? "choose files…" : (files.count == 1 ? files[0].lastPathComponent : "\(files.count) files")
    }

    func moveSelection(_ delta: Int) {
        let count = results.count
        guard count > 0 else { return }
        selected = (selected + delta + count) % count
    }

    func runSelected(reveal: Bool) {
        let list = results
        guard list.indices.contains(selected) else { return }
        run(list[selected], reveal: reveal)
    }

    func run(_ result: CommandResult, reveal: Bool) {
        switch result.kind {
        case let .recent(item):
            if reveal { self.reveal(item) } else { open(item) }
        case let .command(command):
            switch command {
            case .pause: paused.toggle()
            case .settings: host?.panelOpenSettings()
            case .watch: host?.panelShowWatch()
            case .stats: host?.panelShowStats()
            case .history: host?.panelShowHistory()
            case let .clipboard(format): host?.panelClipboard(format)
            default:
                let files = host?.panelTargetFiles() ?? []
                if files.isEmpty {
                    host?.panelChooseFiles { [weak self] chosen in self?.jobs.run(command, files: chosen) }
                } else {
                    jobs.run(command, files: files)
                }
                notice = command.title
            }
        }
        query = ""
    }

    // MARK: Drop zone → mini wheel

    /// The six mini-wheel segments for what is being dragged (board I uses
    /// short labels: Shrink, Size).
    var miniSlots: [WheelSlot?] {
        let type: UTType = switch dropKind {
        case .pdf: .pdf
        case .document: .plainText
        default: .rawImage // a neutral image type: no format is hidden as "the source"
        }
        return SlotProvider.menu(for: [type], canWrite: { FormatSupport.current.canWrite($0) }).ring
    }

    static func miniLabel(_ slot: WheelSlot?) -> String {
        guard let slot else { return "" }
        switch slot.action {
        case .compress: return "Shrink"
        case .resize: return "Size"
        default: return slot.label
        }
    }

    func dropOnMini(_ index: Int?, files: [URL]) {
        dropTargeted = false
        dropMode = false
        guard !files.isEmpty else { return }
        guard let index, let slot = miniSlots[index] else {
            host?.panelOpenWheel(files: files) // centre "Drop": the full wheel
            return
        }
        switch slot.action {
        case .more: host?.panelOpenWheel(files: files)
        case .compress, .resize, .crop: host?.panelOpenDialog(slot.action, files: files)
        default:
            jobs.run(slot.action, files: files)
            notice = "\(slot.verb) — \(files.count == 1 ? files[0].lastPathComponent : "\(files.count) files")"
        }
    }

    /// Loads file URLs from SwiftUI drop providers.
    static func loadURLs(_ providers: [NSItemProvider], _ done: @escaping ([URL]) -> Void) {
        let collector = URLCollector(count: providers.count, done: done)
        for provider in providers {
            _ = provider.loadObject(ofClass: NSURL.self) { object, _ in
                collector.add((object as? NSURL) as URL?)
            }
        }
        if providers.isEmpty { done([]) }
    }
}

/// Gathers asynchronously loaded URLs and reports once, on the main thread.
nonisolated private final class URLCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    private var remaining: Int
    private let done: ([URL]) -> Void

    init(count: Int, done: @escaping ([URL]) -> Void) {
        remaining = count
        self.done = done
    }

    func add(_ url: URL?) {
        lock.lock()
        if let url, url.isFileURL { urls.append(url) }
        remaining -= 1
        let finished = remaining == 0
        let result = urls
        lock.unlock()
        guard finished else { return }
        let box = UncheckedSendable(done)
        DispatchQueue.main.async { box.value(result) }
    }
}
