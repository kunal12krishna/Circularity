import Foundation

/// Batch rename (Actions → More → Rename…): what each file will be called,
/// and whether the whole set can be renamed safely. Pure and unit-tested.
nonisolated enum RenamePlanner {
    enum Mode: Equatable, Sendable {
        /// `{name}` the old name, `{n}` a counter, `{date}` the file's date (2026-11-23), `{ext}` the extension.
        case pattern(String, start: Int, digits: Int)
        case replace(find: String, with: String, ignoreCase: Bool)
    }

    struct Item: Equatable, Sendable {
        var old: String
        var new: String
        var problem: String?
    }

    /// Names that can't be used on a Mac (empty, "/" or ":", "." and "..", too long).
    static func invalid(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "empty name" }
        if name.contains("/") || name.contains(":") { return "can't contain / or :" }
        if name == "." || name == ".." || name.hasPrefix(".") { return "would be hidden" }
        if name.utf8.count > 255 { return "too long" }
        return nil
    }

    /// `files`: (name, date) in order. `taken`: other names already in the folder.
    static func plan(_ files: [(name: String, date: Date)], mode: Mode, taken: Set<String>) -> [Item] {
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd"
        var items: [Item] = files.enumerated().map { i, file in
            let ns = file.name as NSString
            let ext = ns.pathExtension, stem = ext.isEmpty ? file.name : ns.deletingPathExtension
            let new: String
            switch mode {
            case let .pattern(pattern, start, digits):
                let number = String(start + i)
                let padded = String(repeating: "0", count: max(0, digits - number.count)) + number
                var stemOut = pattern.replacingOccurrences(of: "{name}", with: stem)
                    .replacingOccurrences(of: "{n}", with: padded)
                    .replacingOccurrences(of: "{date}", with: day.string(from: file.date))
                    .replacingOccurrences(of: "{ext}", with: ext)
                if !pattern.contains("{n}"), files.count > 1, !pattern.contains("{name}") {
                    stemOut += " \(padded)" // several files, one fixed name: number them
                }
                new = ext.isEmpty ? stemOut : "\(stemOut).\(ext)"
            case let .replace(find, with, ignoreCase):
                guard !find.isEmpty else { new = file.name; break }
                let replaced = stem.replacingOccurrences(of: find, with: with, options: ignoreCase ? [.caseInsensitive] : [])
                new = ext.isEmpty ? replaced : "\(replaced).\(ext)"
            }
            return Item(old: file.name, new: new, problem: invalid(new))
        }
        // Clashes: two files getting the same name, or a name another file in the folder already has.
        // (Case-insensitive, as macOS volumes usually are.)
        let olds = Set(items.map { $0.old.lowercased() })
        var seen: [String: Int] = [:]
        for i in items.indices where items[i].problem == nil {
            let key = items[i].new.lowercased()
            if let first = seen[key] {
                items[i].problem = "same name as \(items[first].old)"
            } else {
                seen[key] = i
                if taken.contains(where: { $0.lowercased() == key }) && !olds.contains(key) {
                    items[i].problem = "already in the folder"
                }
            }
        }
        return items
    }

    /// Ready to rename: no problems, and at least one name changes.
    static func canApply(_ items: [Item]) -> Bool {
        !items.isEmpty && items.allSatisfy { $0.problem == nil } && items.contains { $0.old != $0.new }
    }
}
