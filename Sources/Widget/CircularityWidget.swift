import SwiftUI
import WidgetKit

// Built only with CIRCULARITY_WIDGET=1 (PLAN.md A6). Milestone (h2) adds the
// small / medium / large layouts fed by the App Group snapshot.

@main
struct CircularityWidgetBundle: WidgetBundle {
    var body: some Widget {
        TodayWidget()
    }
}

struct TodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "today", provider: TodayProvider()) { entry in
            TodayView(entry: entry)
        }
        .configurationDisplayName(AppIdentity.name)
        .description("Files converted today.")
        .supportedFamilies([.systemSmall])
    }
}

struct TodayEntry: TimelineEntry {
    let date: Date
    let filesToday: Int
}

struct TodayProvider: TimelineProvider {
    func placeholder(in context: Context) -> TodayEntry { TodayEntry(date: .now, filesToday: 0) }

    func getSnapshot(in context: Context, completion: @escaping (TodayEntry) -> Void) {
        completion(TodayEntry(date: .now, filesToday: 0))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TodayEntry>) -> Void) {
        completion(Timeline(entries: [TodayEntry(date: .now, filesToday: 0)], policy: .never))
    }
}

struct TodayView: View {
    let entry: TodayEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("TODAY").font(.system(size: 10, weight: .bold, design: .rounded)).foregroundStyle(.secondary)
            Text("\(entry.filesToday) files").font(.system(size: 17, weight: .heavy, design: .rounded))
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}
