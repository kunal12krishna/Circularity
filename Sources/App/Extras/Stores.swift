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

    /// Undo: the result(s) go to the Trash and any original that went there
    /// comes back. A move goes back where it came from. Returns what it said
    /// it did, for the card by the pointer.
    @discardableResult
    func undo(_ id: String) -> String? {
        guard let item = items.first(where: { $0.id == id }) else { return nil }
        let fm = FileManager.default
        var message = "The result is in the Trash."
        if item.kind == "move" {
            // Two steps, through temporary names, so a rename that swapped names (a ↔ b) swaps back.
            // A name is free if nothing is there, or if what's there is itself being moved back.
            let moving = Set(item.outputs)
            var parked: [(temp: String, input: String)] = []
            for (output, input) in zip(item.outputs, item.inputs) where fm.fileExists(atPath: output)
                && (!fm.fileExists(atPath: input) || moving.contains(input)) {
                let temp = (output as NSString).deletingLastPathComponent + "/.circularity-undo-\(UUID().uuidString)"
                if (try? fm.moveItem(atPath: output, toPath: temp)) != nil { parked.append((temp, input)) }
            }
            var back = 0
            for p in parked {
                if !fm.fileExists(atPath: p.input), (try? fm.moveItem(atPath: p.temp, toPath: p.input)) != nil { back += 1 }
                else if let original = zip(item.inputs, item.outputs).first(where: { $0.0 == p.input })?.1 {
                    try? fm.moveItem(atPath: p.temp, toPath: original) // couldn't go back: leave it where it was
                }
            }
            message = back == 1 ? "It's back where it was." : "\(back) items are back where they were."
        } else {
            for path in item.outputs { try? fm.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil) }
            var restored = 0
            for (original, inTrash) in item.trashed ?? [:] where !fm.fileExists(atPath: original) && fm.fileExists(atPath: inTrash) {
                if (try? fm.moveItem(atPath: inTrash, toPath: original)) != nil { restored += 1 }
            }
            if restored > 0 { message = restored == 1 ? "The result is in the Trash and the original is back." : "The results are in the Trash and \(restored) originals are back." }
        }
        remove(id)
        Log.app.notice("Undo \(item.kind ?? "conversion", privacy: .public): \(message, privacy: .public)")
        return message
    }

    /// The entry that wrote exactly these files (the card's Undo).
    func item(writing outputs: [URL]) -> HistoryItem? {
        let paths = Set(outputs.map(\.path))
        return items.first { !$0.outputs.isEmpty && Set($0.outputs).isSubset(of: paths) && paths.isSubset(of: Set($0.outputs)) }
            ?? items.first { !Set($0.outputs).isDisjoint(with: paths) }
    }

    /// Remembers where "Move the original to the Trash" put an original.
    func noteTrashed(original: URL, at trashURL: URL, output: URL) {
        guard let i = items.firstIndex(where: { $0.outputs.contains(output.path) }) else { return }
        var trashed = items[i].trashed ?? [:]
        trashed[original.path] = trashURL.path
        items[i].trashed = trashed
        AppSupport.save(items, to: file)
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
