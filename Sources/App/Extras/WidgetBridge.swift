import Foundation
#if CIRCULARITY_WIDGET
import WidgetKit
#endif

/// Writes the widget snapshot after conversions. A no-op unless the app is
/// built with CIRCULARITY_WIDGET=1 (the widget needs a Developer ID, A6).
enum WidgetBridge {
    static func update(stats: StatsStore, history: HistoryStore) {
        #if CIRCULARITY_WIDGET
        guard let dir = WidgetSnapshot.containerURL else { return }
        let recents = history.existing.prefix(3).map {
            WidgetSnapshot.Recent(name: $0.name, path: $0.outputs.first ?? "", format: $0.format)
        }
        let snapshot = WidgetSnapshot(date: Date(), todayFiles: stats.today.files, savedWeekBytes: stats.savedThisWeek,
                                      allTimeSavedBytes: stats.allTimeSaved, recents: Array(recents))
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: dir.appendingPathComponent(WidgetSnapshot.fileName), options: .atomic)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }
}
