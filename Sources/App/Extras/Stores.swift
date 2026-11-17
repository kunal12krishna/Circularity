import AppKit
import Combine

/// ~/Library/Application Support/Circularity
enum AppSupport {
    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent(AppIdentity.name, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func load<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func save<T: Encodable>(_ value: T, to name: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: folder.appendingPathComponent(name), options: .atomic)
    }
}

/// Every finished conversion, newest first (PLAN.md §3.5). Capped at 1,000.
final class HistoryStore: ObservableObject {
    @Published private(set) var items: [HistoryItem]
    private let file: String

    init(file: String = "history.json") {
        self.file = file
        items = AppSupport.load([HistoryItem].self, from: file) ?? []
    }

    func add(_ item: HistoryItem) {
        items.insert(item, at: 0)
        if items.count > 1_000 { items.removeLast(items.count - 1_000) }
        AppSupport.save(items, to: file)
    }

    func remove(_ id: String) {
        items.removeAll { $0.id == id }
        AppSupport.save(items, to: file)
    }

    /// Undo = move the result(s) to the Trash and forget the entry.
    func undo(_ id: String) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        for path in item.outputs { try? FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil) }
        remove(id)
    }

    func clear() {
        items.removeAll()
        AppSupport.save(items, to: file)
    }

    /// Entries whose result still exists.
    var existing: [HistoryItem] { items.filter { $0.primaryOutput.map { FileManager.default.fileExists(atPath: $0.path) } ?? false } }
}

/// Small daily aggregates (PLAN.md §3.5): files, bytes in/out, by format.
final class StatsStore: ObservableObject {
    @Published private(set) var days: [String: DayStats]
    private let file: String

    init(file: String = "stats.json") {
        self.file = file
        days = AppSupport.load([String: DayStats].self, from: file) ?? [:]
    }

    func record(files: Int, bytesIn: Int64, bytesOut: Int64, format: String, date: Date = Date()) {
        StatsMath.record(&days, date: date, files: files, bytesIn: bytesIn, bytesOut: bytesOut, format: format)
        AppSupport.save(days, to: file)
    }

    func reset() {
        days = [:]
        AppSupport.save(days, to: file)
    }

    var today: DayStats { days[StatsMath.dayKey(Date())] ?? DayStats() }
    var savedThisWeek: Int64 { StatsMath.savedLast(days, days: 7) }
    var allTimeSaved: Int64 { days.values.reduce(0) { $0 + $1.saved } }
    var allTimeFiles: Int { days.values.reduce(0) { $0 + $1.files } }
    var byFormat: [(String, Int)] {
        days.values.reduce(into: [String: Int]()) { acc, d in for (k, v) in d.byFormat { acc[k, default: 0] += v } }
            .sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
    }
}
