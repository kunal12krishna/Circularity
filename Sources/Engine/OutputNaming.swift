import Foundation

/// A user-editable naming template. Tokens: `{name}` `{format}` `{date}` `{size}`.
public struct NamingTemplate: Sendable, Equatable, Codable {
    public var pattern: String
    public init(_ pattern: String) { self.pattern = pattern }
    public static let `default` = NamingTemplate("{name}")
    public static let tokens = ["{name}", "{format}", "{date}", "{size}"]
}

/// Everything the naming rules need to know about one output.
public struct NamingContext: Sendable {
    public var sourceURL: URL
    public var format: OutputFormat
    public var operation: OperationKind
    public var date: Date
    public var pixelSize: PixelSize?
    public var timeZone: TimeZone

    public init(sourceURL: URL, format: OutputFormat, operation: OperationKind,
                date: Date = Date(), pixelSize: PixelSize? = nil, timeZone: TimeZone = .current) {
        self.sourceURL = sourceURL
        self.format = format
        self.operation = operation
        self.date = date
        self.pixelSize = pixelSize
        self.timeZone = timeZone
    }
}

public struct PixelSize: Sendable, Equatable, Codable {
    public var width: Int
    public var height: Int
    public init(width: Int, height: Int) { self.width = width; self.height = height }
}

/// Pure naming rules (PLAN.md §3.1): `photo.png`, `photo (resized).jpg`,
/// `scan (combined).pdf`, and `name (1).ext`, `name (2).ext` on collisions.
public enum OutputNaming {
    /// Longest file name APFS/HFS+ accept, in UTF-8 bytes.
    static let maxFileNameBytes = 255
    /// Room kept for " (9999)" plus "." and the longest extension.
    static let reservedTailBytes = 16

    /// The base name (no extension, no collision counter) for an output.
    public static func baseName(template: NamingTemplate = .default, context: NamingContext) -> String {
        let sourceName = context.sourceURL.deletingPathExtension().lastPathComponent
        var name = template.pattern
            .replacingOccurrences(of: "{name}", with: sourceName)
            .replacingOccurrences(of: "{format}", with: context.format.displayName)
            .replacingOccurrences(of: "{date}", with: dateString(context.date, timeZone: context.timeZone))
            .replacingOccurrences(of: "{size}", with: context.pixelSize.map { "\($0.width)x\($0.height)" } ?? "")
        if let suffix = context.operation.nameSuffix {
            name += " (\(suffix))"
        }
        return sanitize(name)
    }

    /// `base.ext`, or the first free `base (n).ext`. `exists` decides what counts
    /// as taken (the file system plus names reserved by running jobs).
    public static func uniqueFileName(base: String, fileExtension ext: String, exists: (String) -> Bool) -> String {
        let candidate = join(base, ext)
        if !exists(candidate) { return candidate }
        for n in 1...9_999 {
            let numbered = join("\(base) (\(n))", ext)
            if !exists(numbered) { return numbered }
        }
        // 10,000 collisions: fall back to something guaranteed unique.
        return join("\(base) (\(UUID().uuidString.prefix(8)))", ext)
    }

    /// Makes a name safe for the file system: no path separators or colons, no
    /// leading dots (hidden files), collapsed whitespace, bounded length.
    public static func sanitize(_ raw: String) -> String {
        var s = raw.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\0", with: "")
        s = s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        while s.hasPrefix(".") { s.removeFirst() }
        s = s.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { s = "Untitled" }
        let limit = maxFileNameBytes - reservedTailBytes
        while s.utf8.count > limit { s.removeLast() }
        return s
    }

    private static func join(_ base: String, _ ext: String) -> String {
        ext.isEmpty ? base : "\(base).\(ext)"
    }

    private static func dateString(_ date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
