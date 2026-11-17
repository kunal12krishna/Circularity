import SwiftUI

/// The default panel layout "Stack+" (board I, PLAN.md §9.2).
struct StackPlusView: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelHeader(model: model)
            CommandBar(model: model)
            if let notice = model.notice {
                Text(notice).font(PanelTokens.rounded(11, .semibold)).foregroundStyle(PanelTokens.secondary).lineLimit(2)
                    .transition(.opacity)
            }
            HStack(spacing: 8) {
                StatTile(label: "TODAY", value: model.todayText) { model.host?.panelShowStats() }
                StatTile(label: "SAVED · WEEK", value: model.savedWeekText, valueColor: model.accent) { model.host?.panelShowStats() }
                StatTile(label: "WATCHING", value: model.watchingText) { model.host?.panelShowWatch() }
            }
            if !model.jobs.active.isEmpty {
                SectionHeader(title: "In progress · \(model.jobs.active.count)", action: "Cancel all", link: model.link) { model.jobs.cancelAll() }
                ForEach(model.jobs.active) { job in
                    JobCard(job: job, accent: model.accent) { model.jobs.cancel(job.id) }
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
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
            DropZone(model: model)
            HStack {
                SectionHeader(title: "Recent", action: "Show all", link: model.link) { model.host?.panelShowHistory() }
            }
            VStack(spacing: 2) {
                if model.recents.isEmpty {
                    Text("Nothing converted yet. Drag a file and tap Shift.")
                        .font(PanelTokens.rounded(12)).foregroundStyle(PanelTokens.meta).padding(.vertical, 6)
                }
                ForEach(model.recents) { item in RecentRow(model: model, item: item) }
            }
            .padding(.top, -4)
            PanelFooter(model: model)
        }
        .padding(14)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: model.jobs.active.count)
    }
}
