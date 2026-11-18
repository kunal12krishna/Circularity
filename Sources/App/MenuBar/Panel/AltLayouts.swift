import CircularityEngine
import SwiftUI
import UniformTypeIdentifiers

/// Per-window size state. Kept outside the view so the view's structure never
/// changes while the panel is open (replacing it reset the ⌘K field's focus).
final class PanelSizing: ObservableObject {
    @Published var contentHeight: CGFloat = 0
    @Published var height: CGFloat?
    @Published var scrolls = false
}

private struct PanelContentHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Chooses the layout; all three share one PanelModel. With `sizing` (live
/// windows) the content scrolls past the window's height and reports its own
/// height; without it (previews) the content is laid out at its natural size.
struct PanelRoot: View {
    @ObservedObject var model: PanelModel
    let width: CGFloat
    var sizing: PanelSizing?

    var body: some View {
        let light = model.isLight
        let palette = (light ? PanelPalette.light : .dark).with(onAccent: model.accent.readableText)
        Group {
            if let sizing {
                SizedScroll(sizing: sizing) { content }
            } else {
                content
            }
        }
        .frame(width: width)
        .background(light ? Color(hex: 0xF8F6F2, opacity: 0.82) : PanelTokens.tint)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(light ? Color.white.opacity(0.9) : Color.white.opacity(0.12), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .environment(\.panelPalette, palette)
        .environment(\.colorScheme, light ? .light : .dark)
    }

    @ViewBuilder private var content: some View {
        switch model.layout {
        case .stackPlus: StackPlusView(model: model)
        case .tabs: TabsView(model: model)
        case .mini: MiniView(model: model, width: width)
        }
    }
}

private struct SizedScroll<Content: View>: View {
    @ObservedObject var sizing: PanelSizing
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView(.vertical, showsIndicators: sizing.scrolls) {
            content()
                .background(GeometryReader { proxy in Color.clear.preference(key: PanelContentHeight.self, value: proxy.size.height) })
        }
        .scrollDisabled(!sizing.scrolls)
        .frame(height: sizing.height)
        .onPreferenceChange(PanelContentHeight.self) { h in
            if abs(h - sizing.contentHeight) > 0.5 { sizing.contentHeight = h }
        }
    }
}

// MARK: - Tabs (board F)

struct TabsView: View {
    @ObservedObject var model: PanelModel
    @Environment(\.panelPalette) private var palette
    @State private var search = ""
    @State private var filter = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(AppIdentity.name).font(PanelTokens.rounded(16, .heavy)).foregroundStyle(palette.primary)
                Spacer()
                Circle().fill(model.paused ? Color(hex: 0x9C968D) : Color(hex: 0x2E9E5B)).frame(width: 7, height: 7)
                Text(model.paused ? "Paused" : "Ready").font(PanelTokens.rounded(12)).foregroundStyle(palette.secondary)
                Button { model.paused.toggle() } label: {
                    Image(systemName: model.paused ? "play.fill" : "pause.fill").font(.system(size: 11)).foregroundStyle(palette.primary)
                        .frame(width: 30, height: 30).background(Circle().fill(palette.chip))
                }
                .buttonStyle(.plain).accessibilityLabel(model.paused ? "Resume" : "Pause")
            }
            HStack(spacing: 2) {
                ForEach(Array(["Now", "Recent", "Presets"].enumerated()), id: \.offset) { i, title in
                    Button { model.tab = i } label: {
                        Text(title).font(PanelTokens.rounded(13, model.tab == i ? .bold : .medium)).foregroundStyle(palette.primary)
                            .frame(maxWidth: .infinity, minHeight: 30)
                            .background(RoundedRectangle(cornerRadius: 8).fill(model.tab == i ? palette.selected : .clear)
                                .shadow(color: .black.opacity(model.tab == i ? 0.08 : 0), radius: 2, y: 1))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
                }
            }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 10).fill(palette.chip))

            switch model.tab {
            case 1: recentTab
            case 2: presetsTab
            default: nowTab
            }

            HStack {
                Button("Settings") { model.host?.panelOpenSettings() }.keyboardShortcut(",", modifiers: .command)
                Button("Tutorial") { model.host?.panelTutorial() }
                Spacer()
                Text("⌘1 ⌘2 ⌘3 switch tabs").font(PanelTokens.rounded(11)).foregroundStyle(palette.tertiary)
                Button(model.pinned ? "Unpin" : "Pin") { model.host?.panelTogglePin() }
                Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q", modifiers: .command)
            }
            .buttonStyle(.plain)
            .font(PanelTokens.rounded(12, .semibold))
            .foregroundStyle(palette.primary)
            .padding(.top, 10)
            .overlay(alignment: .top) { Rectangle().fill(palette.hairline).frame(height: 1) }
        }
        .padding(14)
    }

    private var nowTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                bigStat("TODAY", model.todayText, detail: todayDetail, color: palette.primary)
                bigStat("SPACE SAVED", model.savedWeekText, detail: "this week", color: model.accentText)
            }
            ForEach(model.jobs.active) { job in
                HStack(spacing: 10) {
                    RingProgress(fraction: job.fraction, accent: model.accent, track: palette.track).frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(job.title).font(PanelTokens.rounded(13, .bold)).foregroundStyle(palette.primary).lineLimit(1).truncationMode(.middle)
                        Text(job.meta).font(PanelTokens.rounded(11)).foregroundStyle(palette.meta)
                    }
                    Spacer()
                    Button("Cancel") { model.jobs.cancel(job.id) }.buttonStyle(.plain)
                        .font(PanelTokens.rounded(12, .semibold)).foregroundStyle(palette.primary)
                        .padding(.horizontal, 10).frame(height: 28).background(RoundedRectangle(cornerRadius: 8).fill(palette.chip))
                }
                .padding(10).background(RoundedRectangle(cornerRadius: 14).fill(palette.surface))
            }
            SectionHeader(title: "Quick presets · drop on one", action: model.editing ? "Done" : "Edit", link: linkColor) { model.editing.toggle() }
            tileGrid(height: 74)
            DropZone(model: model, height: 64, compactHint: true)
        }
    }

    private var recentTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .semibold)).foregroundStyle(palette.meta)
                TextField("Search name, format or folder", text: $search).textFieldStyle(.plain).font(PanelTokens.rounded(12))
            }
            .padding(.horizontal, 10).frame(height: 32).background(RoundedRectangle(cornerRadius: 9).fill(palette.field))
            HStack(spacing: 6) {
                ForEach(Array(["All", "Images", "PDFs", "Docs"].enumerated()), id: \.offset) { i, title in
                    Button(title) { filter = i }.buttonStyle(.plain)
                        .font(PanelTokens.rounded(11, .bold)).foregroundStyle(filter == i ? model.accent.readableText : palette.primary)
                        .padding(.horizontal, 10).frame(height: 26)
                        .background(Capsule().fill(filter == i ? model.accent : palette.chip))
                        .accessibilityAddTraits(filter == i ? .isSelected : [])
                }
            }
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(filtered.prefix(30)) { item in RecentRow(model: model, item: item) }
                    if filtered.isEmpty { Text("Nothing here yet.").font(PanelTokens.rounded(12)).foregroundStyle(palette.meta).padding(8) }
                }
            }
            .frame(height: 360)
        }
    }

    private var presetsTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Presets · drop on one", action: model.editing ? "Done" : "Edit", link: linkColor) { model.editing.toggle() }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(model.allTiles) { tile in TileView(model: model, tile: tile, height: 74) }
            }
            if model.editing {
                Button("Restore the built-in tiles") { model.restoreTiles() }.buttonStyle(.plain)
                    .font(PanelTokens.rounded(12, .semibold)).foregroundStyle(linkColor)
            }
        }
    }

    private var linkColor: Color { model.link }

    private var todayDetail: String {
        let f = model.stats.today.byFormat
        let images = f.filter { ["JPG", "PNG", "HEIC", "WEBP", "AVIF", "TIFF", "GIF", "BMP"].contains($0.key) }.values.reduce(0, +)
        let pdfs = f["PDF"] ?? 0
        return "\(images) images · \(pdfs) PDFs"
    }

    private var filtered: [HistoryItem] {
        model.history.existing.filter { item in
            let fmt = item.format.uppercased()
            let kindOK: Bool = switch filter {
            case 1: ["JPG", "PNG", "HEIC", "WEBP", "AVIF", "TIFF", "GIF", "BMP"].contains(fmt)
            case 2: fmt == "PDF"
            case 3: ["TXT", "HTML", "DOCX"].contains(fmt)
            default: true
            }
            return kindOK && (search.isEmpty || FuzzyMatcher.score(search, in: "\(item.name) \(item.label) \(item.outputs.first ?? "")") != nil)
        }
    }

    private func tileGrid(height: CGFloat) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
            ForEach(model.visibleTiles) { tile in TileView(model: model, tile: tile, height: height) }
        }
    }

    private func bigStat(_ label: String, _ value: String, detail: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(PanelTokens.rounded(11, .bold)).foregroundStyle(palette.meta)
            Text(value).font(PanelTokens.rounded(26, .heavy)).foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.6)
            Text(detail).font(PanelTokens.rounded(11)).foregroundStyle(palette.meta)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(palette.surface))
        .onTapGesture { model.host?.panelShowStats() }
    }
}

struct RingProgress: View {
    let fraction: Double
    let accent: Color
    var track: Color = Color.white.opacity(0.12)
    var lineWidth: CGFloat = 4
    var body: some View {
        ZStack {
            Circle().stroke(track, lineWidth: lineWidth)
            Circle().trim(from: 0, to: max(0.02, fraction)).stroke(accent, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(lineWidth / 2)
        .animation(.easeOut(duration: 0.2), value: fraction)
    }
}

// MARK: - Mini (board G, Halo)

struct MiniView: View {
    @ObservedObject var model: PanelModel
    var width: CGFloat = 340
    @State private var hover: Int?
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Text(AppIdentity.name.uppercased()).font(Halo.mono(15, .heavy)).tracking(1.2).foregroundStyle(Halo.text)
                Spacer()
                Text(model.paused ? "PAUSED" : "ACTIVE").font(Halo.mono(12, .heavy))
                    .foregroundStyle(model.paused ? Halo.secondary : model.accent)
                    .padding(.horizontal, 8).frame(height: 26)
                    .background(RoundedRectangle(cornerRadius: 6).fill((model.paused ? Halo.secondary : model.accent).opacity(0.15)))
                Button { model.paused.toggle() } label: {
                    Image(systemName: model.paused ? "play.fill" : "pause.fill").font(.system(size: 12, weight: .bold)).foregroundStyle(Halo.text)
                        .frame(width: 36, height: 36).background(RoundedRectangle(cornerRadius: 10).fill(Halo.control))
                }
                .buttonStyle(.plain).accessibilityLabel(model.paused ? "Resume" : "Pause")
            }
            wheel
            ForEach(model.jobs.active) { job in
                HStack(spacing: 12) {
                    RingProgress(fraction: job.fraction, accent: model.accent, lineWidth: 4).frame(width: 34, height: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(job.title.replacingOccurrences(of: "Compress", with: "SQZ")).font(Halo.mono(13)).foregroundStyle(Halo.text).lineLimit(1).truncationMode(.middle)
                        Text(job.meta).font(Halo.rounded(12)).foregroundStyle(Halo.secondary).lineLimit(1).minimumScaleFactor(0.8)
                    }
                    Spacer()
                    Button { model.jobs.cancel(job.id) } label: {
                        Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Halo.text)
                            .frame(width: 26, height: 26).background(RoundedRectangle(cornerRadius: 7).fill(Halo.control))
                    }
                    .buttonStyle(.plain)
                }
                .padding(12).background(RoundedRectangle(cornerRadius: 12).fill(Halo.card))
            }
            HStack {
                Text("RECENT · DRAG OUT TO USE").font(Halo.mono(11, .semibold)).tracking(0.8).foregroundStyle(Halo.secondary)
                Spacer()
                Button("All") { model.host?.panelShowHistory() }.buttonStyle(.plain).font(Halo.mono(12, .heavy)).foregroundStyle(model.accent)
            }
            HStack(spacing: 8) {
                ForEach(Array(model.history.existing.prefix(5))) { item in
                    VStack(spacing: 4) {
                        FileThumb(url: item.primaryOutput, size: 56, corner: 10)
                            .onDrag { item.primaryOutput.flatMap { NSItemProvider(contentsOf: $0) } ?? NSItemProvider() }
                            .onTapGesture { model.quickLook(item) }
                            .help(item.name)
                        Text(item.format.uppercased()).font(Halo.mono(10)).foregroundStyle(Halo.secondary)
                    }
                }
                if model.history.existing.isEmpty {
                    Text("Nothing yet").font(Halo.rounded(12)).foregroundStyle(Halo.secondary)
                }
            }
            CommandBar(model: model)
            Text("↑↓ select · ↩ run · ⌘↩ reveal · ⌘, settings · ⌘Q quit").font(Halo.mono(10, .regular)).foregroundStyle(Halo.secondary)
            HStack {
                Button(model.pinned ? "UNPIN" : "PIN") { model.host?.panelTogglePin() }
                Button("SETTINGS") { model.host?.panelOpenSettings() }.keyboardShortcut(",", modifiers: .command)
                Spacer()
                Button("QUIT") { NSApp.terminate(nil) }.keyboardShortcut("q", modifiers: .command)
            }
            .buttonStyle(.plain).font(Halo.mono(11)).foregroundStyle(Halo.text)
        }
        .padding(16)
        .background(Halo.background.opacity(0.92))
    }

    /// Board G: a Halo mini wheel as the drop target (r 52 → 108, mono labels).
    private var wheel: some View {
        let slots = model.miniSlots
        return Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - 108, y: c.y - 108, width: 216, height: 216)), with: .color(model.accent.opacity(0.3)), lineWidth: 1)
            for i in 0..<6 {
                let mid = Double(i) * 60
                let hot = hover == i && slots[i] != nil
                let r1: CGFloat = hot ? 50 : 54, r2: CGFloat = hot ? 104 : 98
                var p = Path()
                p.addArc(center: c, radius: r2, startAngle: .degrees(mid - 29 - 90), endAngle: .degrees(mid + 29 - 90), clockwise: false)
                p.addArc(center: c, radius: r1, startAngle: .degrees(mid + 29 - 90), endAngle: .degrees(mid - 29 - 90), clockwise: true)
                p.closeSubpath()
                ctx.fill(p, with: .color(hot ? model.accent : Halo.control))
                let t = WheelGeometry.offset(radius: (r1 + r2) / 2, angle: CGFloat(mid))
                ctx.draw(Text(slots[i]?.monoLabel ?? "").font(Halo.mono(13, .bold)).foregroundColor(hot ? Halo.background : Halo.text),
                         at: CGPoint(x: c.x + t.x, y: c.y + t.y))
            }
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - 48, y: c.y - 48, width: 96, height: 96)), with: .color(Halo.card))
            let hotSlot = hover.flatMap { slots[$0] }
            ctx.draw(Text(hotSlot?.kicker ?? "CONVERT").font(Halo.rounded(10, .semibold)).foregroundColor(Halo.secondary), at: CGPoint(x: c.x, y: c.y - 20))
            ctx.draw(Text(hotSlot?.monoLabel ?? "DROP").font(Halo.mono(20, .heavy)).foregroundColor(model.accent), at: c)
            ctx.draw(Text("drop a file here").font(Halo.rounded(10)).foregroundColor(Halo.secondary), at: CGPoint(x: c.x, y: c.y + 20))
        }
        .frame(height: 236)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(hex: 0x111317)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(targeted ? model.accent : Halo.hairline))
        .onDrop(of: [.fileURL], delegate: HaloMiniDrop(model: model, hover: $hover, targeted: $targeted, centre: CGPoint(x: (width - 32) / 2, y: 118)))
        .onTapGesture { model.host?.panelChooseFiles { files in model.host?.panelOpenWheel(files: files) } }
        .accessibilityLabel("Drop files on a format, or click to choose files")
    }
}

struct HaloMiniDrop: DropDelegate {
    let model: PanelModel
    @Binding var hover: Int?
    @Binding var targeted: Bool
    let centre: CGPoint

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.fileURL]) }
    func dropEntered(info: DropInfo) {
        model.dropKind = info.hasItemsConforming(to: [.pdf]) ? .pdf : .image
        targeted = true
    }
    func dropExited(info: DropInfo) { targeted = false; hover = nil }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        hover = segment(info.location)
        return DropProposal(operation: .copy)
    }
    func performDrop(info: DropInfo) -> Bool {
        let index = segment(info.location)
        PanelModel.loadURLs(info.itemProviders(for: [.fileURL])) { urls in model.dropOnMini(index, files: urls) }
        targeted = false
        hover = nil
        return true
    }
    private func segment(_ p: CGPoint) -> Int? {
        let o = CGPoint(x: p.x - centre.x, y: p.y - centre.y)
        let d = hypot(o.x, o.y)
        guard d > 48, d <= 116 else { return nil }
        return Int((WheelGeometry.angle(of: o) + 30) / 60) % 6
    }
}
