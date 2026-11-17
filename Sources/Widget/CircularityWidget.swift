import SwiftUI
import WidgetKit

// Built only with CIRCULARITY_WIDGET=1 (PLAN.md A6): small (today + saved),
// medium (last 3 conversions; tapping reveals the file), large (stats + recents).

@main
struct CircularityWidgetBundle: WidgetBundle {
    var body: some Widget { CircularityWidget() }
}

struct CircularityWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "circularity", provider: SnapshotProvider()) { entry in
            WidgetView(entry: entry)
        }
        .configurationDisplayName(AppIdentity.name)
        .description("Today’s conversions, space saved and recent files.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry { SnapshotEntry(date: .now, snapshot: nil) }
    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        completion(SnapshotEntry(date: .now, snapshot: WidgetSnapshot.load()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        // The app asks for a reload after each conversion; nothing polls.
        completion(Timeline(entries: [SnapshotEntry(date: .now, snapshot: WidgetSnapshot.load())], policy: .never))
    }
}

struct WidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SnapshotEntry
    private let accent = Color(red: 0xC6 / 255, green: 1, blue: 0x3D / 255)

    var body: some View {
        let s = entry.snapshot
        VStack(alignment: .leading, spacing: 8) {
            if family != .systemMedium {
                stat("TODAY", "\(s?.todayFiles ?? 0) files", Color.primary)
                stat("SAVED · WEEK", ByteCountFormatter.string(fromByteCount: s?.savedWeekBytes ?? 0, countStyle: .file), accent)
            }
            if family != .systemSmall {
                Text("RECENT").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(.secondary)
                ForEach(Array((s?.recents ?? []).enumerated()), id: \.offset) { _, recent in
                    Link(destination: URL(fileURLWithPath: recent.path).deletingLastPathComponent()) {
                        HStack {
                            Text(recent.format).font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(accent)
                            Text(recent.name).font(.system(size: 12, weight: .semibold, design: .rounded)).lineLimit(1)
                        }
                    }
                }
                if (s?.recents ?? []).isEmpty { Text("Nothing yet").font(.caption).foregroundStyle(.secondary) }
            }
            if family == .systemLarge {
                stat("ALL TIME SAVED", ByteCountFormatter.string(fromByteCount: s?.allTimeSavedBytes ?? 0, countStyle: .file), accent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(Color(red: 13 / 255, green: 15 / 255, blue: 20 / 255), for: .widget)
    }

    private func stat(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 22, weight: .heavy, design: .rounded)).foregroundStyle(color).minimumScaleFactor(0.6)
        }
    }
}
