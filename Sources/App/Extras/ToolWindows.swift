import AppKit
import Charts
import CircularityEngine
import SwiftUI

/// Opens SwiftUI windows lazily and releases them on close (PLAN.md §5).
final class WindowPresenter: NSObject, NSWindowDelegate {
    private var windows: [String: NSWindow] = [:]

    /// `floating` keeps the window above other apps (the tutorial, so it stays
    /// visible while you drag from Finder).
    func show<V: View>(_ id: String, title: String, size: CGSize, floating: Bool = false, @ViewBuilder content: () -> V) {
        if let existing = windows[id] {
            NSApp.activate(ignoringOtherApps: true)
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = title
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(srgbRed: 13 / 255, green: 15 / 255, blue: 20 / 255, alpha: 1)
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier(id)
        window.contentViewController = NSHostingController(rootView: content().environment(\.colorScheme, .dark))
        window.setContentSize(size)
        window.center()
        window.delegate = self
        if floating { window.level = .floating }
        windows[id] = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close(_ id: String) { windows[id]?.close() }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let id = window.identifier?.rawValue else { return }
        window.delegate = nil
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                window.contentViewController = nil
                self?.windows[id] = nil
                MemoryFootprint.relieve()
            }
        }
    }
}

// MARK: - History ("Show all")

struct HistoryWindowView: View {
    @ObservedObject var model: PanelModel
    @State private var search = ""

    private var items: [HistoryItem] {
        let all = model.history.items
        guard !search.isEmpty else { return all }
        return FuzzyMatcher.rank(all, query: search) { "\($0.name) \($0.label) \($0.outputs.first ?? "")" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("HISTORY").font(Halo.mono(22, .heavy)).tracking(1.2).foregroundStyle(model.accent)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(Halo.secondary)
                TextField("Search name, format or folder", text: $search).textFieldStyle(.plain).font(Halo.rounded(13))
            }
            .padding(.horizontal, 10).frame(height: 34).background(RoundedRectangle(cornerRadius: 9).fill(Halo.control))
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(items) { item in RecentRow(model: model, item: item) }
                    if items.isEmpty { Text("No conversions yet.").font(Halo.rounded(13)).foregroundStyle(Halo.secondary).padding() }
                }
            }
            HStack {
                Text("\(model.history.items.count) conversions").font(Halo.rounded(12)).foregroundStyle(Halo.secondary)
                Spacer()
                Button("Clear History") { model.history.clear() }.buttonStyle(.plain).font(Halo.mono(12)).foregroundStyle(Halo.text)
            }
        }
        .padding(20)
        .frame(minWidth: 460, minHeight: 420)
        .background(Halo.background)
        .environment(\.panelPalette, .dark)
    }
}

// MARK: - Stats

struct StatsWindowView: View {
    @ObservedObject var model: PanelModel
    @State private var confirmReset = false

    var body: some View {
        let days = StatsMath.lastDays(model.stats.days, count: 30)
        VStack(alignment: .leading, spacing: 16) {
            Text("STATS").font(Halo.mono(22, .heavy)).tracking(1.2).foregroundStyle(model.accent)
            HStack(spacing: 10) {
                tile("TODAY", "\(model.stats.today.files) files")
                tile("SAVED · WEEK", Bytes.text(model.stats.savedThisWeek), accent: true)
                tile("ALL TIME SAVED", Bytes.text(model.stats.allTimeSaved), accent: true)
                tile("ALL TIME", "\(model.stats.allTimeFiles) files")
            }
            SectionLabel(text: "Files per day · last 30 days")
            Chart(Array(days.enumerated()), id: \.offset) { index, day in
                BarMark(x: .value("Day", index), y: .value("Files", day.stats.files))
                    .foregroundStyle(model.accent)
                    .cornerRadius(2)
            }
            .chartXAxis(.hidden)
            .chartYAxis { AxisMarks { _ in AxisGridLine().foregroundStyle(Halo.hairline); AxisValueLabel().foregroundStyle(Halo.secondary) } }
            .frame(height: 150)
            .accessibilityLabel("Files converted per day over the last 30 days")
            SectionLabel(text: "By format")
            VStack(spacing: 6) {
                let formats = model.stats.byFormat
                if formats.isEmpty { Text("Nothing converted yet.").font(Halo.rounded(12)).foregroundStyle(Halo.secondary) }
                ForEach(formats.prefix(8), id: \.0) { format, count in
                    HStack {
                        Text(format).font(Halo.mono(12)).foregroundStyle(Halo.text).frame(width: 60, alignment: .leading)
                        GeometryReader { g in
                            Capsule().fill(model.accent.opacity(0.8))
                                .frame(width: g.size.width * CGFloat(count) / CGFloat(max(1, formats.first?.1 ?? 1)))
                        }
                        .frame(height: 8)
                        Text("\(count)").font(Halo.mono(12)).foregroundStyle(Halo.secondary).frame(width: 40, alignment: .trailing)
                    }
                }
            }
            Spacer()
            HStack {
                Text("Stored on this Mac as small daily totals.").font(Halo.rounded(11)).foregroundStyle(Halo.secondary)
                Spacer()
                Button("Reset Stats…") { confirmReset = true }.buttonStyle(.plain).font(Halo.mono(12)).foregroundStyle(Halo.text)
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 520)
        .background(Halo.background)
        .alert("Reset all stats?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) { model.stats.reset() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("History and your files are not affected.") }
    }

    private func tile(_ label: String, _ value: String, accent: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(Halo.mono(9, .semibold)).tracking(0.6).foregroundStyle(Halo.secondary)
            Text(value).font(Halo.rounded(17, .heavy)).foregroundStyle(accent ? model.accent : Halo.text).lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10).background(RoundedRectangle(cornerRadius: 10).fill(Halo.card))
    }
}

// MARK: - Watch folders

struct WatchFoldersView: View {
    @ObservedObject var watch: WatchFolderService
    let accent: Color
    @State private var confirmTrash: WatchRule?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("WATCH FOLDERS").font(Halo.mono(22, .heavy)).tracking(1.2).foregroundStyle(accent)
            Text("New files that land in these folders are converted automatically. Nothing is watched unless you add it here, and with no folder switched on nothing runs at all.")
                .font(Halo.rounded(12)).foregroundStyle(Halo.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(watch.rules) { rule in ruleCard(rule) }
                    if watch.rules.isEmpty {
                        Text("No folders yet.").font(Halo.rounded(13)).foregroundStyle(Halo.secondary).padding(.vertical, 12)
                    }
                }
            }
            HStack(spacing: 8) {
                Button { addFolder(nil) } label: { pill("ADD FOLDER…", filled: true) }.buttonStyle(.plain)
                if !watch.rules.contains(where: { $0.folder == WatchFolderService.screenshotFolder.path }) {
                    Button { addFolder(WatchFolderService.screenshotFolder) } label: { pill("SCREENSHOTS → JPG", filled: false) }.buttonStyle(.plain)
                }
                Spacer()
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 440)
        .background(Halo.background)
        .alert("Move originals to the Trash?", isPresented: Binding(get: { confirmTrash != nil }, set: { if !$0 { confirmTrash = nil } })) {
            Button("Move to Trash After Converting", role: .destructive) {
                if var r = confirmTrash { r.trashOriginal = true; watch.update(r) }
                confirmTrash = nil
            }
            Button("Cancel", role: .cancel) { confirmTrash = nil }
        } message: { Text("After each file is converted successfully, the original goes to the Trash (you can still restore it from there).") }
    }

    private func ruleCard(_ rule: WatchRule) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "folder.fill").foregroundStyle(accent)
                Text(URL(fileURLWithPath: rule.folder).lastPathComponent).font(Halo.rounded(14, .bold)).foregroundStyle(Halo.text)
                Text(rule.folder).font(Halo.rounded(11)).foregroundStyle(Halo.secondary).lineLimit(1).truncationMode(.head)
                Spacer()
                Toggle("", isOn: binding(rule, \.enabled)).toggleStyle(.switch).tint(accent).labelsHidden()
                Button { watch.remove(rule.id) } label: { Image(systemName: "trash").foregroundStyle(Halo.secondary) }.buttonStyle(.plain)
                    .accessibilityLabel("Remove \(rule.title)")
            }
            HStack(spacing: 8) {
                Picker("Files", selection: binding(rule, \.match)) {
                    Text("Images").tag(WatchRule.Match.images)
                    Text("PDFs").tag(WatchRule.Match.pdfs)
                    Text("Images & PDFs").tag(WatchRule.Match.all)
                }
                .frame(width: 170)
                Picker("→", selection: binding(rule, \.format)) {
                    ForEach([OutputFormat.jpg, .png, .heic, .avif, .webp, .tiff, .pdf].filter { FormatSupport.current.canWrite($0) }, id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                }
                .frame(width: 110)
                Picker("Save", selection: Binding(get: { outputTag(rule.output) }, set: { tag in setOutput(rule, tag) })) {
                    Text("next to it").tag("inPlace")
                    Text("in “Converted”").tag("subfolder")
                    Text(rule.output.folderName.map { "in \($0)" } ?? "in another folder…").tag("folder")
                }
                .frame(width: 190)
            }
            .font(Halo.rounded(12))
            Toggle(isOn: Binding(get: { rule.trashOriginal }, set: { on in
                if on { confirmTrash = rule } else { var r = rule; r.trashOriginal = false; watch.update(r) }
            })) {
                Text("Move the original to the Trash after converting").font(Halo.rounded(12)).foregroundStyle(Halo.text)
            }
            .toggleStyle(.checkbox)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Halo.card))
    }

    private func binding<T>(_ rule: WatchRule, _ key: WritableKeyPath<WatchRule, T>) -> Binding<T> {
        Binding(get: { rule[keyPath: key] }, set: { value in var r = rule; r[keyPath: key] = value; watch.update(r) })
    }

    private func outputTag(_ output: WatchRule.Output) -> String {
        switch output {
        case .inPlace: "inPlace"
        case .subfolder: "subfolder"
        case .folder: "folder"
        }
    }

    private func setOutput(_ rule: WatchRule, _ tag: String) {
        var r = rule
        switch tag {
        case "subfolder": r.output = .subfolder("Converted")
        case "folder":
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.prompt = "Save Here"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            r.output = .folder(url.path)
        default: r.output = .inPlace
        }
        watch.update(r)
    }

    private func addFolder(_ suggested: URL?) {
        var folder = suggested
        if folder == nil {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.prompt = "Watch"
            panel.message = "Choose a folder to watch. New files in it will be converted."
            guard panel.runModal() == .OK else { return }
            folder = panel.url
        }
        guard let folder else { return }
        if WatchFolderService.isProtected(folder) {
            // Explain the system prompt before it appears (BRIEF.md).
            let alert = NSAlert()
            alert.messageText = "macOS will ask once"
            alert.informativeText = "\(folder.lastPathComponent) is a protected folder, so macOS will ask whether \(AppIdentity.name) may access it. Choose Allow so new files there can be converted. You can change this later in System Settings → Privacy & Security → Files and Folders."
            alert.addButton(withTitle: "Continue")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        watch.add(WatchRule(folder: folder.path, match: .images, format: .jpg))
    }

    private func pill(_ title: String, filled: Bool) -> some View {
        Text(title).font(Halo.mono(12, .heavy)).tracking(0.6)
            .foregroundStyle(filled ? Halo.background : Halo.text)
            .padding(.horizontal, 14).frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 9).fill(filled ? accent : Halo.control))
    }
}

extension WatchRule.Output {
    var folderName: String? {
        if case let .folder(path) = self { return URL(fileURLWithPath: path).lastPathComponent }
        return nil
    }
}
