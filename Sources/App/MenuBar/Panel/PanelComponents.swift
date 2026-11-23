import AppKit
import CircularityEngine
import SwiftUI
import UniformTypeIdentifiers

/// Board I tokens (PLAN.md §9.2).
enum PanelTokens {
    static let primary = Color(hex: 0xF4F1EC)
    static let strong2 = Color(hex: 0xE6E1D8)
    static let secondary = Color(hex: 0xC9C3B9)
    static let meta = Color(hex: 0xB4AEA5)
    static let tertiary = Color(hex: 0xA9A39A)
    static let placeholder = Color(hex: 0x9C968D)
    static let onAccent = Color(hex: 0x1A1206)
    static let smaller = Color(hex: 0x8BE0A4)
    static let tint = Color(hex: 0x1E1E22, opacity: 0.74)

    static func rounded(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight, design: .rounded) }
}

/// Colours for a panel layout: dark (boards I and G) or light (board F).
struct PanelPalette {
    var primary, strong2, secondary, meta, tertiary, placeholder, onAccent, smaller: Color
    var surface, surfaceHover, field, hairline, docThumb: Color
    /// Small fills for chips and segmented controls, the selected segment, and progress tracks.
    var chip = Color.white.opacity(0.10), selected = Color.white.opacity(0.16), track = Color.white.opacity(0.12)
    var isLight = false

    static let dark = PanelPalette(
        primary: PanelTokens.primary, strong2: PanelTokens.strong2, secondary: PanelTokens.secondary, meta: PanelTokens.meta,
        tertiary: PanelTokens.tertiary, placeholder: PanelTokens.placeholder, onAccent: PanelTokens.onAccent, smaller: PanelTokens.smaller,
        surface: Color.white.opacity(0.06), surfaceHover: Color.white.opacity(0.08), field: Color.white.opacity(0.07),
        hairline: Color.white.opacity(0.08), docThumb: Color(hex: 0xEDE8E1))

    /// Board F (light, warm).
    static let light = PanelPalette(
        primary: Color(hex: 0x1D1B18), strong2: Color(hex: 0x4A443B), secondary: Color(hex: 0x5E574D), meta: Color(hex: 0x6B645A),
        tertiary: Color(hex: 0x6B645A), placeholder: Color(hex: 0x8A8378), onAccent: Color(hex: 0x1A1206), smaller: Color(hex: 0x2E9E5B),
        surface: Color.white, surfaceHover: Color.black.opacity(0.05), field: Color.white,
        hairline: Color.black.opacity(0.08), docThumb: Color(hex: 0xEDE8E1),
        chip: Color.black.opacity(0.07), selected: Color.white, track: Color(hex: 0xE4DED4), isLight: true)
}

extension PanelPalette {
    func with(onAccent color: Color) -> PanelPalette {
        var copy = self
        copy.onAccent = color
        return copy
    }
}

private struct PanelPaletteKey: EnvironmentKey {
    static let defaultValue = PanelPalette.dark
}

extension EnvironmentValues {
    var panelPalette: PanelPalette {
        get { self[PanelPaletteKey.self] }
        set { self[PanelPaletteKey.self] = newValue }
    }
}

/// The board-H glyph as a SwiftUI image.
struct GlyphImage: View {
    let size: CGFloat
    let color: NSColor
    var body: some View { Image(nsImage: StatusGlyph.image(pointSize: size, color: color, template: false)) }
}

struct SectionHeader: View {
    @Environment(\.panelPalette) private var palette
    let title: String
    var action: String?
    var link: Color = .orange
    var perform: () -> Void = {}

    var body: some View {
        HStack {
            Text(title.uppercased()).font(PanelTokens.rounded(11, .bold)).tracking(0.88).foregroundStyle(palette.tertiary)
            Spacer()
            if let action {
                Button(action: perform) { Text(action).font(PanelTokens.rounded(12, .semibold)).foregroundStyle(link) }
                    .buttonStyle(.plain).padding(4)
            }
        }
    }
}

/// Header: app tile, name, status line, Pause switch (board I).
struct PanelHeader: View {
    @Environment(\.panelPalette) private var palette
    @ObservedObject var model: PanelModel
    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            RoundedRectangle(cornerRadius: 10).fill(model.accent).frame(width: 34, height: 34)
                .overlay(GlyphImage(size: 20, color: NSColor(srgbRed: 0x1A / 255, green: 0x12 / 255, blue: 0x06 / 255, alpha: 1)))
            VStack(alignment: .leading, spacing: 1) {
                Text(AppIdentity.name).font(PanelTokens.rounded(15, .heavy)).foregroundStyle(palette.primary)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Circle().fill(model.statusDot).frame(width: 7, height: 7).offset(y: -1)
                    Text(model.statusText).font(PanelTokens.rounded(12)).foregroundStyle(palette.secondary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 6)
            Button { model.paused.toggle() } label: {
                HStack(spacing: 8) {
                    Text("Pause").font(PanelTokens.rounded(12, .semibold)).foregroundStyle(palette.secondary)
                    ZStack(alignment: model.paused ? .trailing : .leading) {
                        Capsule().fill(model.paused ? model.accent : Color.white.opacity(0.18)).frame(width: 34, height: 20)
                        Circle().fill(Color.white).frame(width: 16, height: 16).padding(2).shadow(color: .black.opacity(0.4), radius: 1.5, y: 1)
                    }
                    .frame(width: 34, height: 20)
                    .animation(.spring(response: 0.25, dampingFraction: 0.8), value: model.paused)
                }
                .padding(6)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("p", modifiers: .command)
            .accessibilityLabel("Pause \(AppIdentity.name)")
            .accessibilityValue(model.paused ? "on" : "off")
            .contextMenu {
                Button("Pause for 1 hour") { model.pause(for: 3600) }
                Button("Pause until tomorrow") { model.pauseUntilTomorrow() }
                Button("Pause until I resume") { model.paused = true }
            }
        }
    }
}

/// ⌘K bar (board I): fuzzy search over recents plus commands.
struct CommandBar: View {
    @Environment(\.panelPalette) private var palette
    @ObservedObject var model: PanelModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                PromptGlyph().stroke(palette.tertiary, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                    .frame(width: 14, height: 14)
                TextField("", text: $model.query, prompt: Text("Search recents, or type “webp”, “< 2mb”…").foregroundColor(palette.placeholder))
                    .textFieldStyle(.plain)
                    .font(PanelTokens.rounded(12))
                    .foregroundStyle(palette.primary)
                    .lineLimit(1)
                    .focused($focused)
                    .onSubmit { model.runSelected(reveal: NSEvent.modifierFlags.contains(.command)) }
                    .onMoveCommand { direction in
                        if direction == .down { model.moveSelection(1) } else if direction == .up { model.moveSelection(-1) }
                    }
                    .accessibilityLabel("Command bar")
                Text("⌘K").font(PanelTokens.rounded(10, .bold)).foregroundStyle(Color(hex: 0xD9D3CA))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 5).fill(palette.chip))
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(RoundedRectangle(cornerRadius: 10).fill(palette.field))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.08)))
            .background(Button("") { focused = true }.keyboardShortcut("k", modifiers: .command).opacity(0))

            if !model.query.isEmpty {
                VStack(spacing: 2) {
                    let list = model.results
                    if list.isEmpty {
                        Text("No matches. Try “jpg”, “< 1mb”, “1920w”, “no gps”, “clipboard”.")
                            .font(PanelTokens.rounded(11)).foregroundStyle(palette.meta)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                    ForEach(Array(list.enumerated()), id: \.element.id) { index, result in
                        Button { model.run(result, reveal: false) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(result.title).font(PanelTokens.rounded(13, .bold))
                                    if !result.subtitle.isEmpty { Text(result.subtitle).font(PanelTokens.rounded(11)).opacity(0.75) }
                                }
                                Spacer()
                                if index == model.selected { Text("↩").font(PanelTokens.rounded(12, .bold)) }
                            }
                            .foregroundStyle(index == model.selected ? palette.onAccent : palette.primary)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 8).fill(index == model.selected ? model.accent : Color.white.opacity(0.04)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .onAppear { if model.focusCommand { focused = true; model.focusCommand = false } }
        .onChange(of: model.focusCommand) { want in if want { focused = true; model.focusCommand = false } }
    }
}

/// Board I's prompt glyph: `M4 17l6-6-6-6M12 19h8` in a 24 box.
nonisolated struct PromptGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let k = rect.width / 24
        var p = Path()
        p.move(to: CGPoint(x: 4 * k, y: 17 * k)); p.addLine(to: CGPoint(x: 10 * k, y: 11 * k)); p.addLine(to: CGPoint(x: 4 * k, y: 5 * k))
        p.move(to: CGPoint(x: 12 * k, y: 19 * k)); p.addLine(to: CGPoint(x: 20 * k, y: 19 * k))
        return p
    }
}

struct StatTile: View {
    @Environment(\.panelPalette) private var palette
    let label: String
    let value: String
    var valueColor: Color?
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(PanelTokens.rounded(10, .bold)).tracking(0.6).foregroundStyle(palette.tertiary)
                Text(value).font(PanelTokens.rounded(17, .heavy)).foregroundStyle(valueColor ?? palette.primary).lineLimit(1).minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8).padding(.horizontal, 10)
            .background(RoundedRectangle(cornerRadius: 10).fill(palette.surface))
        }
        .buttonStyle(.plain)
    }
}

/// A file's thumbnail (images) or a document glyph (board I).
struct FileThumb: View {
    @Environment(\.panelPalette) private var palette
    let url: URL?
    let size: CGFloat
    let corner: CGFloat
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 2).resizable().aspectRatio(contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: corner).fill(palette.docThumb)
                VStack(alignment: .leading, spacing: size * 0.08) {
                    ForEach([1.0, 1.0, 0.6], id: \.self) { w in
                        Capsule().fill(Color(hex: 0x5E574D)).frame(width: size * 0.4 * w, height: max(1.5, size * 0.05))
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner))
        .task(id: url) {
            guard let url, DraggedFiles.type(of: url).conforms(to: .image) else { return }
            let px = Int(size * 2)
            let made = await Task.detached(priority: .utility) { UncheckedSendable(Thumbnails.image(url, maxPixel: px)) }.value
            image = made.value
        }
    }
}

/// An in-progress job card (board I).
struct JobCard: View {
    @Environment(\.panelPalette) private var palette
    let job: ActiveJob
    let accent: Color
    let cancel: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            FileThumb(url: job.firstInput, size: 42, corner: 9)
            VStack(alignment: .leading, spacing: 6) {
                Text(job.title).font(PanelTokens.rounded(13, .bold)).foregroundStyle(palette.primary).lineLimit(1).truncationMode(.middle)
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(palette.track)
                        Capsule().fill(accent).frame(width: max(5, g.size.width * job.fraction))
                    }
                }
                .frame(height: 5)
                .animation(.easeOut(duration: 0.2), value: job.fraction)
                Text(job.meta).font(PanelTokens.rounded(11)).foregroundStyle(palette.meta)
            }
            Button(action: cancel) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(palette.strong2)
                    .frame(width: 28, height: 28).background(Circle().fill(palette.chip))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel \(job.title)")
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(palette.surface))
    }
}

/// A preset tile: click runs it, drop files onto it, edit mode removes/recolours/reorders.
struct TileView: View {
    @Environment(\.panelPalette) private var palette
    @ObservedObject var model: PanelModel
    let tile: PanelTile
    var height: CGFloat = 58
    @State private var hovering = false
    @State private var targeted = false

    private var tint: Color? { PanelModel.tileColors[model.colorIndex(tile)].map { Color(hex: $0) } }

    var body: some View {
        let hot = hovering || targeted
        Button { if !model.editing { model.run(tile) } } label: {
            VStack(spacing: 2) {
                Text(tile.big).font(PanelTokens.rounded(14, .heavy)).lineLimit(1).minimumScaleFactor(0.7)
                Text(tile.small).font(PanelTokens.rounded(10, .semibold)).opacity(0.8).lineLimit(1)
            }
            .foregroundStyle(hot && !model.editing ? palette.onAccent : palette.primary)
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
            .background(RoundedRectangle(cornerRadius: 12).fill(hot && !model.editing ? model.accent : (tint ?? palette.surface)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(hot ? model.accent : Color.white.opacity(0.08)))
            .overlay(alignment: .topTrailing) {
                if model.editing {
                    HStack(spacing: 4) {
                        Button { model.cycleColor(tile) } label: { Image(systemName: "paintpalette.fill").font(.system(size: 9)) }
                            .buttonStyle(.plain).accessibilityLabel("Change colour of \(tile.big)")
                        Button { model.removeTile(tile) } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 12)) }
                            .buttonStyle(.plain).accessibilityLabel("Remove \(tile.big)")
                    }
                    .foregroundStyle(palette.strong2)
                    .padding(5)
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .onDrag { NSItemProvider(object: "tile:\(tile.id)" as NSString) }
        .onDrop(of: [.fileURL, .plainText], isTargeted: $targeted) { providers in
            if let text = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) && !$0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) {
                let box = UncheckedSendable((model, tile.id))
                _ = text.loadObject(ofClass: NSString.self) { object, _ in
                    let id = (object as? NSString).map(String.init) ?? ""
                    DispatchQueue.main.async {
                        if id.hasPrefix("tile:") { box.value.0.moveTile(String(id.dropFirst(5)), before: box.value.1) }
                    }
                }
                return true
            }
            PanelModel.loadURLs(providers) { urls in if !urls.isEmpty { model.run(tile, files: urls) } }
            return true
        }
        .accessibilityLabel("Preset \(tile.big), \(tile.small)")
    }
}

/// Drop zone that becomes a mini 6-segment wheel while files hover (board I).
struct DropZone: View {
    @Environment(\.panelPalette) private var palette
    @ObservedObject var model: PanelModel
    var height: CGFloat = 128
    var compactHint = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .fill(model.dropTargeted ? model.accent.opacity(0.08) : palette.chip.opacity(0.4))
            RoundedRectangle(cornerRadius: 14)
                .stroke(model.dropTargeted ? model.link : (palette.isLight ? Color.black.opacity(0.28) : Color.white.opacity(0.22)), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            if model.dropTargeted || model.dropMode {
                MiniWheel(slots: model.miniSlots, hover: model.miniHover, accent: model.accent)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.down.to.line").font(.system(size: 24, weight: .medium)).foregroundStyle(model.link)
                    Text(compactHint ? "Drop here for the full wheel" : "Drop files to convert").font(PanelTokens.rounded(13, .bold)).foregroundStyle(palette.strong2)
                    if !compactHint {
                        Text("or click to choose · works on the menu bar icon too").font(PanelTokens.rounded(11)).foregroundStyle(palette.meta)
                    }
                }
            }
        }
        .frame(height: height)
        .contentShape(Rectangle())
        .onTapGesture { model.host?.panelChooseFiles { files in model.host?.panelOpenWheel(files: files) } }
        .onDrop(of: [.fileURL], delegate: MiniWheelDrop(model: model, size: CGSize(width: 352, height: height)))
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: model.dropTargeted)
        .accessibilityLabel("Drop files here, or click to choose files")
    }
}

/// Six segments, r 26 → 58, ±28°, centre "Drop" (board I).
struct MiniWheel: View {
    let slots: [WheelSlot?]
    let hover: Int?
    let accent: Color
    static let inner: CGFloat = 26, outer: CGFloat = 58

    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            for i in 0..<6 {
                let mid = Double(i) * 60
                var p = Path()
                p.addArc(center: c, radius: Self.outer, startAngle: .degrees(mid - 28 - 90), endAngle: .degrees(mid + 28 - 90), clockwise: false)
                p.addArc(center: c, radius: Self.inner, startAngle: .degrees(mid + 28 - 90), endAngle: .degrees(mid - 28 - 90), clockwise: true)
                p.closeSubpath()
                let hot = hover == i && slots[i] != nil
                ctx.fill(p, with: .color(hot ? accent : Color.white.opacity(slots[i] == nil ? 0.03 : 0.08)))
                ctx.stroke(p, with: .color(Color.white.opacity(0.14)), lineWidth: 1)
                let t = WheelGeometry.offset(radius: 42, angle: CGFloat(mid))
                ctx.draw(Text(PanelModel.miniLabel(slots[i])).font(PanelTokens.rounded(10, .bold))
                    .foregroundColor(hot ? accent.readableText : PanelTokens.strong2), at: CGPoint(x: c.x + t.x, y: c.y + t.y))
            }
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - 24, y: c.y - 24, width: 48, height: 48)), with: .color(Color(hex: 0x0E0E10, opacity: 0.8)))
            ctx.draw(Text("Drop").font(PanelTokens.rounded(10, .bold)).foregroundColor(PanelTokens.secondary), at: c)
        }
    }
}

struct MiniWheelDrop: DropDelegate {
    let model: PanelModel
    let size: CGSize

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.fileURL]) }

    func dropEntered(info: DropInfo) {
        model.dropKind = info.hasItemsConforming(to: [.pdf]) ? .pdf : (info.hasItemsConforming(to: [.image]) ? .image : .image)
        model.dropTargeted = true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        model.miniHover = Self.segment(at: info.location, in: size)
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        model.dropTargeted = false
        model.miniHover = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        let index = Self.segment(at: info.location, in: size)
        PanelModel.loadURLs(info.itemProviders(for: [.fileURL])) { urls in model.dropOnMini(index, files: urls) }
        model.miniHover = nil
        return true
    }

    static func segment(at p: CGPoint, in size: CGSize) -> Int? {
        let o = CGPoint(x: p.x - size.width / 2, y: p.y - size.height / 2)
        let d = hypot(o.x, o.y)
        guard d > MiniWheel.inner, d <= MiniWheel.outer + 12 else { return nil }
        return Int((WheelGeometry.angle(of: o) + 30) / 60) % 6
    }
}

/// A Recent row (board I): thumbnail, name, before → after, % change; hover
/// shows Reveal, Quick Look, Convert again, Undo; drag out as a real file.
struct RecentRow: View {
    @Environment(\.panelPalette) private var palette
    @ObservedObject var model: PanelModel
    let item: HistoryItem
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            FileThumb(url: item.primaryOutput, size: 36, corner: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(PanelTokens.rounded(13, .bold)).foregroundStyle(palette.primary).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 4) {
                    Text(PanelModel.sizeLine(item)).foregroundStyle(palette.meta).lineLimit(1)
                    if let delta = PanelModel.delta(item) {
                        Text(delta).fontWeight(.bold).foregroundStyle((item.percentChange ?? 0) < 0 ? palette.smaller : palette.meta)
                    }
                }
                .font(PanelTokens.rounded(11))
            }
            Spacer(minLength: 4)
            if hovering {
                HStack(spacing: 2) {
                    rowButton("folder", "Show in Finder") { model.reveal(item) }
                    rowButton("eye", "Quick Look") { model.quickLook(item) }
                    if item.kind == nil { rowButton("arrow.triangle.2.circlepath", "Convert again as…") { model.convertAgain(item) } }
                    rowButton("arrow.uturn.backward", PanelModel.undoHelp(item)) { model.undo(item) }
                }
            } else {
                Text(PanelModel.when(item.date)).font(PanelTokens.rounded(11)).foregroundStyle(palette.tertiary)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10).fill(hovering ? palette.surfaceHover : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { model.open(item) }
        .onDrag { item.primaryOutput.flatMap { NSItemProvider(contentsOf: $0) } ?? NSItemProvider() }
        .contextMenu {
            Button("Open") { model.open(item) }
            Button("Show in Finder") { model.reveal(item) }
            Button("Quick Look") { model.quickLook(item) }
            if item.kind == nil { Button("Convert Again As…") { model.convertAgain(item) } }
            Divider()
            Button("Copy") { model.copy(item) }
            Button("Copy Path") { model.copyPath(item) }
            Divider()
            Button(PanelModel.undoHelp(item)) { model.undo(item) }
            Button("Remove from History") { model.history.remove(item.id) }
        }
        .accessibilityElement(children: .combine)
    }

    private func rowButton(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(palette.primary)
                .frame(width: 26, height: 26).background(RoundedRectangle(cornerRadius: 7).fill(palette.chip))
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Footer (board I + the brief's Pin button).
struct PanelFooter: View {
    @Environment(\.panelPalette) private var palette
    @ObservedObject var model: PanelModel
    var body: some View {
        HStack(spacing: 4) {
            footerButton("gearshape", "Settings") { model.host?.panelOpenSettings() }
                .keyboardShortcut(",", modifiers: .command)
            footerButton("play.circle", "Tutorial") { model.host?.panelTutorial() }
            Spacer()
            Text("⌘, · ⌘Q").font(PanelTokens.rounded(11)).foregroundStyle(palette.tertiary).lineLimit(1).fixedSize()
            iconButton(model.pinned ? "pin.slash" : "pin", model.pinned ? "Unpin" : "Pin the panel") { model.host?.panelTogglePin() }
            iconButton("power", "Quit \(AppIdentity.name)") { NSApp.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
        }
        .padding(.top, 10)
        .overlay(alignment: .top) { Rectangle().fill(palette.hairline).frame(height: 1) }
    }

    private func footerButton(_ symbol: String, _ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 13))
                Text(title).font(PanelTokens.rounded(12, .semibold))
            }
            .foregroundStyle(palette.strong2).padding(.horizontal, 10).frame(height: 30)
            .fixedSize()
        }
        .buttonStyle(.plain)
    }

    private func iconButton(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(palette.strong2).frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

extension PanelModel {
    func pause(for seconds: TimeInterval) {
        paused = true
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            MainActor.assumeIsolated { self?.paused = false }
        }
    }

    func pauseUntilTomorrow() {
        let tomorrow = Calendar.current.startOfDay(for: Date().addingTimeInterval(86_400))
        pause(for: tomorrow.timeIntervalSinceNow)
    }
}
