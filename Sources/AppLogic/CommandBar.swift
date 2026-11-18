import CircularityEngine
import Foundation
import UniformTypeIdentifiers

/// What a ⌘K query asks for (BRIEF.md: "webp", "< 2mb", "1920w", "no gps",
/// "clipboard", "pause", "settings", "watch").
nonisolated enum Command: Equatable, Sendable {
    case convert(OutputFormat)
    case compressUnder(Int64)
    case resizeWidth(Int)
    case stripGPS
    case combine
    case clipboard(OutputFormat?)
    case pause
    case settings
    case watch
    case stats
    case history
    case openRecent(String) // history item id

    var title: String {
        switch self {
        case let .convert(f): "Convert to \(f.displayName)"
        case let .compressUnder(b): "Compress under \(ByteCountFormatter.string(fromByteCount: b, countStyle: .file))"
        case let .resizeWidth(w): "Resize to \(w) px wide"
        case .stripGPS: "Remove location (No GPS)"
        case .combine: "Combine into one PDF"
        case let .clipboard(f): "Convert the clipboard\(f.map { " to \($0.displayName)" } ?? "")"
        case .pause: "Pause or resume"
        case .settings: "Settings"
        case .watch: "Watch folders"
        case .stats: "Stats"
        case .history: "Show all history"
        case .openRecent: "Recent"
        }
    }

    /// Commands that act on files (the last files handed to the app).
    var needsFiles: Bool {
        switch self {
        case .convert, .compressUnder, .resizeWidth, .stripGPS, .combine: true
        default: false
        }
    }
}

nonisolated enum CommandParser {
    static let formatWords: [String: OutputFormat] = [
        "png": .png, "jpg": .jpg, "jpeg": .jpg, "webp": .webp, "heic": .heic, "avif": .avif, "tif": .tiff, "tiff": .tiff,
        "gif": .gif, "bmp": .bmp, "pdf": .pdf, "txt": .txt, "text": .txt, "html": .html, "docx": .docx,
    ]

    /// Exact intents typed into the bar, best first.
    static func parse(_ raw: String) -> [Command] {
        let q = raw.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        var out: [Command] = []
        let compact = q.replacingOccurrences(of: " ", with: "")
        if let f = formatWords[compact] ?? formatWords[q.replacingOccurrences(of: "to ", with: "").replacingOccurrences(of: "→", with: "").trimmingCharacters(in: .whitespaces)] {
            out.append(.convert(f))
        }
        if let m = compact.wholeMatch(of: /(?:<|under)?(\d+(?:\.\d+)?)(kb|mb|k|m)/) {
            let value = Double(m.1) ?? 0
            let unit: Double = m.2.hasPrefix("m") ? 1_000_000 : 1_000
            if value > 0 { out.append(.compressUnder(Int64(value * unit))) }
        }
        if let m = compact.wholeMatch(of: /(\d{2,5})(?:w|px|wide)/) { out.append(.resizeWidth(Int(m.1) ?? 0)) }
        if compact == "nogps" || compact == "gps" || compact == "nolocation" { out.append(.stripGPS) }
        if compact.hasPrefix("clip") {
            let rest = q.split(separator: " ").dropFirst().joined()
            out.append(.clipboard(formatWords[rest]))
        }
        for (word, command) in [("pause", Command.pause), ("resume", .pause), ("settings", .settings), ("prefs", .settings),
                                ("watch", .watch), ("stats", .stats), ("history", .history), ("combine", .combine), ("merge", .combine)]
        where word.hasPrefix(compact) && compact.count >= 2 && !out.contains(command) {
            out.append(command)
        }
        return out
    }
}

/// Subsequence fuzzy matching with a score (higher is better); nil = no match.
nonisolated enum FuzzyMatcher {
    static func score(_ query: String, in candidate: String) -> Int? {
        let q = Array(query.lowercased().filter { !$0.isWhitespace }), c = Array(candidate.lowercased())
        guard !q.isEmpty else { return 0 }
        var score = 0, qi = 0, last = -2, streak = 0
        for (ci, ch) in c.enumerated() where qi < q.count && ch == q[qi] {
            streak = ci == last + 1 ? streak + 1 : 0
            score += 1 + streak * 3 + (ci == 0 || " ._-(".contains(c[max(0, ci - 1)]) ? 5 : 0)
            last = ci
            qi += 1
        }
        return qi == q.count ? score - c.count / 10 : nil
    }

    static func rank<T>(_ items: [T], query: String, key: (T) -> String) -> [T] {
        items.compactMap { item in score(query, in: key(item)).map { (item, $0) } }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }
}

// MARK: History and stats (persisted by the app; the arithmetic is pure)

nonisolated struct HistoryItem: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var date: Date
    var inputs: [String]   // paths
    var outputs: [String]  // paths
    var bytesIn: Int64
    var bytesOut: Int64
    var label: String      // "HEIC → JPG", "Compress"
    var format: String     // output extension, for the stats breakdown

    var primaryOutput: URL? { outputs.first.map { URL(fileURLWithPath: $0) } }
    var name: String { primaryOutput?.lastPathComponent ?? "—" }
    /// −78 means 78 % smaller.
    var percentChange: Int? {
        guard bytesIn > 0, bytesOut > 0 else { return nil }
        return Int((Double(bytesOut - bytesIn) / Double(bytesIn) * 100).rounded())
    }
}

nonisolated struct DayStats: Codable, Equatable, Sendable {
    var files = 0
    var bytesIn: Int64 = 0
    var bytesOut: Int64 = 0
    var byFormat: [String: Int] = [:]
    var saved: Int64 { max(0, bytesIn - bytesOut) }
}

nonisolated enum StatsMath {
    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func record(_ days: inout [String: DayStats], date: Date, files: Int, bytesIn: Int64, bytesOut: Int64, format: String) {
        let key = dayKey(date)
        var d = days[key] ?? DayStats()
        d.files += files
        d.bytesIn += bytesIn
        d.bytesOut += bytesOut
        d.byFormat[format, default: 0] += files
        days[key] = d
        // Keep about 400 days.
        if days.count > 400 { for k in days.keys.sorted().prefix(days.count - 400) { days[k] = nil } }
    }

    /// The last `count` days, oldest first, including empty ones.
    static func lastDays(_ days: [String: DayStats], count: Int, now: Date = Date(), calendar: Calendar = .current) -> [(key: String, stats: DayStats)] {
        (0..<count).reversed().map { back in
            let date = calendar.date(byAdding: .day, value: -back, to: now) ?? now
            let key = dayKey(date, calendar: calendar)
            return (key, days[key] ?? DayStats())
        }
    }

    static func savedLast(_ days: [String: DayStats], days count: Int, now: Date = Date()) -> Int64 {
        lastDays(days, count: count, now: now).reduce(0) { $0 + $1.stats.saved }
    }
}

// MARK: Watch folders

nonisolated struct WatchRule: Codable, Equatable, Identifiable, Sendable {
    enum Match: String, Codable, Sendable, CaseIterable { case images, pdfs, all }
    enum Output: Codable, Equatable, Sendable {
        case inPlace
        case subfolder(String)
        case folder(String)
    }

    var id = UUID().uuidString
    var folder: String
    var match: Match = .images
    var format: OutputFormat = .jpg
    var output: Output = .inPlace
    var trashOriginal = false
    var enabled = true

    var title: String { "\(URL(fileURLWithPath: folder).lastPathComponent) → \(format.displayName)" }

    /// Whether a new file in the folder should be converted by this rule.
    func accepts(_ url: URL, kind: FileKind) -> Bool {
        let name = url.lastPathComponent
        if name.hasPrefix(".") { return false }
        for partial in ["download", "crdownload", "part", "partial", "tmp"] where url.pathExtension.lowercased() == partial { return false }
        // Our own outputs carry an operation suffix or collision counter.
        if name.contains(" (converted)") { return false }
        if let type = UTType(filenameExtension: url.pathExtension), SlotProvider.imageFormat(of: type) == format { return false }
        // Already a PDF and the rule makes PDFs: nothing to do.
        if kind == .pdf && format == .pdf { return false }
        switch match {
        case .images: return kind == .image
        case .pdfs: return kind == .pdf
        case .all: return kind == .image || kind == .pdf
        }
    }
}

/// Settings → Menu bar → sections (Stack+): which show, in what order.
nonisolated enum PanelSections {
    static let all = ["command", "stats", "progress", "presets", "drop", "recent"]

    /// Known ids in the stored order, no duplicates. "" (never set) shows
    /// everything; "-" means the user hid every section.
    static func parse(_ stored: String) -> [String] {
        var out: [String] = []
        for part in stored.split(separator: ",").map({ String($0).trimmingCharacters(in: .whitespaces) })
            where all.contains(part) && !out.contains(part) {
            out.append(part)
        }
        return stored.trimmingCharacters(in: .whitespaces).isEmpty ? all : out
    }
}
