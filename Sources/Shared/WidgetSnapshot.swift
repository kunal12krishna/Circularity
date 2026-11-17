import Foundation

/// What the desktop widget shows; written by the app into the App Group
/// container (PLAN.md §3.5). Only used when built with CIRCULARITY_WIDGET=1.
nonisolated struct WidgetSnapshot: Codable, Sendable {
    struct Recent: Codable, Sendable {
        var name: String
        var path: String
        var format: String
    }

    var date: Date
    var todayFiles: Int
    var savedWeekBytes: Int64
    var allTimeSavedBytes: Int64
    var recents: [Recent]

    static let fileName = "widget-snapshot.json"

    /// The App Group container, when the build has one (Developer ID builds).
    static var containerURL: URL? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "CircularityAppGroup") as? String, !group.isEmpty else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
    }

    static func load() -> WidgetSnapshot? {
        guard let url = containerURL?.appendingPathComponent(fileName), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }
}
