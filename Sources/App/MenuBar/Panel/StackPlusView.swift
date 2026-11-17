import SwiftUI

/// The default panel layout "Stack+" (board I, PLAN.md §9.2). Sections follow
/// Settings → Menu bar (order, shown or hidden, density).
struct StackPlusView: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: model.compact ? 8 : 12) {
            PanelHeader(model: model)
            if let notice = model.notice {
                Text(notice).font(PanelTokens.rounded(11, .semibold)).foregroundStyle(PanelTokens.secondary).lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
            ForEach(model.sections, id: \.self) { section in
                self.section(section)
            }
            PanelFooter(model: model)
        }
        .padding(model.compact ? 10 : 14)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: model.jobs.active.count)
    }

    @ViewBuilder
    private func section(_ id: String) -> some View {
        switch id {
        case "command":
            CommandBar(model: model)
        case "stats":
            HStack(spacing: 8) {
                StatTile(label: "TODAY", value: model.todayText) { model.host?.panelShowStats() }
                StatTile(label: "SAVED · WEEK", value: model.savedWeekText, valueColor: model.accent) { model.host?.panelShowStats() }
                StatTile(label: "WATCHING", value: model.watchingText) { model.host?.panelShowWatch() }
            }
        case "progress":
            if !model.jobs.active.isEmpty {
                VStack(alignment: .leading, spacing: model.compact ? 6 : 8) {
                    SectionHeader(title: "In progress · \(model.jobs.active.count)", action: "Cancel all", link: model.link) { model.jobs.cancelAll() }
                    ForEach(model.jobs.active) { job in
                        JobCard(job: job, accent: model.accent) { model.jobs.cancel(job.id) }
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        case "presets":
            VStack(alignment: .leading, spacing: model.compact ? 6 : 8) {
                SectionHeader(title: "Presets · drop onto one", action: model.editing ? "Done" : "Edit", link: model.link) { model.editing.toggle() }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: model.gridColumns), spacing: 8) {
                    ForEach(model.visibleTiles) { tile in TileView(model: model, tile: tile) }
                }
                if model.editing {
                    Text("Drag tiles to reorder · ✕ removes · palette changes the colour. Save new tiles with “Also add this as a button” in Resize or Compress.")
                        .font(PanelTokens.rounded(11)).foregroundStyle(PanelTokens.meta).fixedSize(horizontal: false, vertical: true)
                    Button("Restore the built-in tiles") { model.restoreTiles() }
                        .buttonStyle(.plain).font(PanelTokens.rounded(12, .semibold)).foregroundStyle(model.link)
                }
            }
        case "drop":
            DropZone(model: model)
        case "recent":
            VStack(alignment: .leading, spacing: 2) {
                SectionHeader(title: "Recent", action: "Show all", link: model.link) { model.host?.panelShowHistory() }
                    .padding(.bottom, 4)
                if model.recents.isEmpty {
                    Text("Nothing converted yet. Drag a file and tap Shift.")
                        .font(PanelTokens.rounded(12)).foregroundStyle(PanelTokens.meta).padding(.vertical, 6)
                }
                ForEach(model.recents) { item in RecentRow(model: model, item: item) }
            }
        default:
            EmptyView()
        }
    }
}
