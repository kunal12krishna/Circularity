import AVFoundation
import CircularityEngine
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Make it fit

/// "Will it send?" Pick where the file is going; Circularity finds the
/// smallest change that gets it under that limit (quality, then size).
struct FitDialog: View {
    struct Target: Identifiable, Equatable {
        let id: String
        let name: String
        let megabytes: Double
        let detail: String
    }

    static let targets = [
        Target(id: "email", name: "Email", megabytes: 25, detail: "Gmail, Outlook, iCloud Mail"),
        Target(id: "whatsapp", name: "WhatsApp", megabytes: 16, detail: "videos and photos sent as media"),
        Target(id: "discord", name: "Discord", megabytes: 10, detail: "the free upload limit"),
        Target(id: "forms", name: "Web form", megabytes: 5, detail: "job portals, visa and school forms"),
        Target(id: "tiny", name: "Strict", megabytes: 2, detail: "profile pictures, strict forms"),
    ]

    let files: [URL]
    let accent: Color
    let onRun: (CircularityEngine.Operation, Preset?) -> Void
    let onCancel: () -> Void
    private let totalBytes: Int64

    init(files: [URL], accent: Color, onRun: @escaping (CircularityEngine.Operation, Preset?) -> Void, onCancel: @escaping () -> Void) {
        self.files = files
        self.accent = accent
        self.onRun = onRun
        self.onCancel = onCancel
        totalBytes = files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    @State private var choice = "email"
    @State private var customText = "8"
    @State private var together = true

    private var limit: Int64? {
        if choice == "custom" {
            guard let mb = Double(customText.replacingOccurrences(of: ",", with: ".")), mb > 0.05 else { return nil }
            return Int64(mb * 1_000_000)
        }
        return Self.targets.first { $0.id == choice }.map { Int64($0.megabytes * 1_000_000) }
    }

    private var status: String {
        guard let limit else { return "Type a size in MB" }
        let size = files.count > 1 && !together ? (files.map { Int64((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }.max() ?? 0) : totalBytes
        if size <= limit { return files.count > 1 && !together ? "Every file already fits" : "Already fits: nothing to do" }
        let pct = Int((Double(size - limit) / Double(size) * 100).rounded(.up))
        return "\(Bytes.text(size)) → under \(Bytes.text(limit)) (at least \(pct)% smaller)"
    }

    var body: some View {
        DialogFrame(title: "Make it fit", subtitle: subtitle, accent: accent, primaryTitle: "Make it fit",
                    primaryEnabled: limit != nil, onPrimary: run, onCancel: onCancel) {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "Where is it going?")
                ForEach(Self.targets) { target in
                    row(target.name, "\(Int(target.megabytes)) MB", target.detail, selected: choice == target.id) { choice = target.id }
                }
                HStack(spacing: 8) {
                    Chip(title: "OTHER", selected: choice == "custom", accent: accent) { choice = "custom" }
                    if choice == "custom" {
                        TextField("", text: $customText).textFieldStyle(.plain).font(Halo.mono(14)).foregroundStyle(Halo.text)
                            .frame(width: 60).padding(.horizontal, 8).frame(height: 30)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Halo.control))
                        Text("MB").font(Halo.mono(12, .semibold)).foregroundStyle(Halo.secondary)
                    }
                }
                if files.count > 1 {
                    Toggle(isOn: $together) {
                        Text(together ? "All \(files.count) together (one email, one message)" : "Each file on its own")
                            .font(Halo.rounded(12, .semibold)).foregroundStyle(Halo.text)
                    }
                    .toggleStyle(.switch).tint(accent)
                }
                Text(status).font(Halo.rounded(13, .semibold)).foregroundStyle(Halo.text)
                    .padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Halo.card))
                Text("Pictures get a lower quality first and shrink only if they must; videos get a lower bit rate and size; PDFs and Office files get smaller pictures inside. The original is never changed.")
                    .font(Halo.rounded(11)).foregroundStyle(Halo.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var subtitle: String {
        "\(files.count == 1 ? files[0].lastPathComponent : "\(files.count) files") · \(Bytes.text(totalBytes))"
    }

    private func row(_ name: String, _ size: String, _ detail: String, selected: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(name.uppercased()).font(Halo.mono(12)).frame(width: 92, alignment: .leading)
                Text(size).font(Halo.mono(12, .heavy)).frame(width: 48, alignment: .leading)
                Text(detail).font(Halo.rounded(11)).foregroundStyle(selected ? Halo.background : Halo.secondary).lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? Halo.background : Halo.text)
            .padding(.horizontal, 12).frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 9).fill(selected ? accent : Halo.control))
        }
        .buttonStyle(.plain)
    }

    private func run() {
        guard let limit else { return }
        onRun(.fitTo(bytes: limit, together: together && files.count > 1), nil)
    }
}

// MARK: - Password

/// Lock a PDF with a password, or take the password off one you can open.
struct PasswordDialog: View {
    let files: [URL]
    /// true: the PDF already has a password, so this removes it.
    let unlock: Bool
    let accent: Color
    let onRun: (CircularityEngine.Operation, Preset?) -> Void
    let onCancel: () -> Void

    @State private var password = ""
    @State private var again = ""
    @State private var show = false
    @State private var wrong = false

    private var ready: Bool { !password.isEmpty && (unlock || password == again) }

    /// Unlock: a wrong password is caught here, with the dialog still open to try again.
    private func submit() {
        guard ready else { return }
        if unlock {
            let opens = files.allSatisfy { PDFDocument(url: $0).map { $0.unlock(withPassword: password) } ?? false }
            guard opens else {
                wrong = true
                return
            }
        }
        onRun(unlock ? .unlockPDF(password: password) : .protectPDF(password: password), nil)
    }

    var body: some View {
        DialogFrame(title: unlock ? "Unlock" : "Lock", subtitle: files.count == 1 ? files[0].lastPathComponent : "\(files.count) PDFs",
                    accent: accent, primaryTitle: unlock ? "Remove password" : "Lock", primaryEnabled: ready,
                    onPrimary: submit,
                    onCancel: onCancel) {
            VStack(alignment: .leading, spacing: 12) {
                field(unlock ? "Its password" : "Password", text: $password)
                if unlock, wrong {
                    Text("That password doesn't open it. Try again.").font(Halo.rounded(12, .semibold)).foregroundStyle(Color(hex: 0xFF6B6B))
                }
                if !unlock {
                    field("Type it again", text: $again)
                    if !again.isEmpty, again != password {
                        Text("The two don't match yet.").font(Halo.rounded(12, .semibold)).foregroundStyle(Color(hex: 0xFF6B6B))
                    }
                }
                Toggle(isOn: $show) { Text("Show the password").font(Halo.rounded(12)).foregroundStyle(Halo.text) }
                    .toggleStyle(.checkbox)
                    .onChange(of: password) { _ in wrong = false }
                Text(unlock
                     ? "A copy without the password is saved next to it. The locked one stays as it is."
                     : "A locked copy is saved next to the original. The password isn't kept anywhere: if it's forgotten, the copy can't be opened.")
                    .font(Halo.rounded(11)).foregroundStyle(Halo.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func field(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: label)
            Group {
                if show { TextField("", text: text) } else { SecureField("", text: text) }
            }
            .textFieldStyle(.plain).font(Halo.mono(15)).foregroundStyle(Halo.text)
            .padding(.horizontal, 10).frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 8).fill(Halo.control))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Halo.hairline))
            .accessibilityLabel(label)
        }
    }
}

// MARK: - Speed

/// Faster or slower video and audio; voices keep their pitch.
struct SpeedDialog: View {
    static let rates: [Double] = [0.25, 0.5, 0.75, 1.25, 1.5, 2, 3, 4]

    let files: [URL]
    let accent: Color
    let onRun: (CircularityEngine.Operation, Preset?) -> Void
    let onCancel: () -> Void

    @State private var rate = 2.0
    @State private var duration: Double?

    var body: some View {
        DialogFrame(title: "Speed", subtitle: files.count == 1 ? files[0].lastPathComponent : "\(files.count) files",
                    accent: accent, primaryTitle: "Change speed", onPrimary: { onRun(.changeSpeed(rate), nil) }, onCancel: onCancel) {
            VStack(alignment: .leading, spacing: 14) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                    ForEach(Self.rates, id: \.self) { r in
                        Chip(title: Self.label(r), selected: rate == r, accent: accent) { rate = r }
                    }
                }
                if let duration {
                    Text("\(Self.clock(duration)) → \(Self.clock(duration / rate))")
                        .font(Halo.mono(16, .heavy)).foregroundStyle(Halo.text)
                        .padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Halo.card))
                }
                Text("Voices and music keep their pitch. Video stays in its own format; audio comes out as M4A.")
                    .font(Halo.rounded(11)).foregroundStyle(Halo.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .task {
            guard files.count == 1, let url = files.first else { return }
            duration = try? await AVURLAsset(url: url).load(.duration).seconds
        }
    }

    static func label(_ r: Double) -> String {
        r == r.rounded() ? "\(Int(r))×" : "\(String(format: "%g", r))×"
    }

    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "–" }
        let s = Int(seconds.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Pages

/// Reorder, turn and remove a PDF's pages. Drag a page to move it.
struct PagesDialog: View {
    struct Tile: Identifiable, Equatable {
        let id = UUID()
        let index: Int
        var rotation = 0
    }

    let file: URL
    let accent: Color
    let onRun: (CircularityEngine.Operation, Preset?) -> Void
    let onCancel: () -> Void

    @State private var tiles: [Tile] = []
    @State private var pictures: [Int: NSImage] = [:]
    @State private var dragging: Tile?
    @State private var original: [Tile] = []

    private var changed: Bool { tiles.map(\.index) != original.map(\.index) || tiles.contains { $0.rotation != 0 } }

    var body: some View {
        DialogFrame(title: "Pages", subtitle: "\(file.lastPathComponent) · \(tiles.count) of \(original.count) page\(original.count == 1 ? "" : "s")",
                    accent: accent, primaryTitle: "Save copy", primaryEnabled: changed && !tiles.isEmpty,
                    onPrimary: { onRun(.arrangePDF(tiles.map { PageEdit(index: $0.index, rotation: $0.rotation) }), nil) },
                    onCancel: onCancel) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Chip(title: "REVERSE", accent: accent) { withAnimation { tiles.reverse() } }
                    Chip(title: "TURN ALL", accent: accent) { withAnimation { for i in tiles.indices { tiles[i].rotation = (tiles[i].rotation + 90) % 360 } } }
                    Chip(title: "RESET", accent: accent) { withAnimation { tiles = original } }
                }
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(92), spacing: 10), count: 4), spacing: 12) {
                        ForEach(tiles) { tile in
                            page(tile)
                                .onDrag {
                                    dragging = tile
                                    return NSItemProvider(object: tile.id.uuidString as NSString)
                                }
                                .onDrop(of: [.text], delegate: Reorder(target: tile, tiles: $tiles, dragging: $dragging))
                        }
                    }
                    .padding(4)
                }
                .frame(height: 330)
                // A page let go anywhere in the grid (or outside it) ends the drag.
                .onDrop(of: [.text], isTargeted: nil) { _ in
                    dragging = nil
                    return true
                }
                .onChange(of: tiles) { _ in
                    if dragging != nil { DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { dragging = nil } }
                }
                Text("Drag a page to move it. ↻ turns it, ✕ leaves it out. A new copy is saved; the original stays as it is.")
                    .font(Halo.rounded(11)).foregroundStyle(Halo.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .task { await load() }
    }

    private func page(_ tile: Tile) -> some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.92))
                if let image = pictures[tile.index] {
                    // Turned sideways, the page is scaled down so it still fits its tile.
                    let sideways = tile.rotation % 180 != 0
                    Image(nsImage: image).resizable().scaledToFit().padding(2)
                        .frame(width: sideways ? 112 : 92, height: sideways ? 88 : 116)
                        .rotationEffect(.degrees(Double(tile.rotation)))
                        .frame(width: 92, height: 116)
                        .clipped()
                }
            }
            .frame(width: 92, height: 116)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(dragging?.id == tile.id ? accent : Halo.hairline, lineWidth: dragging?.id == tile.id ? 2 : 1))
            HStack(spacing: 4) {
                Text("\(tile.index + 1)").font(Halo.mono(11, .bold)).foregroundStyle(Halo.secondary)
                Spacer()
                Button { withAnimation { turn(tile) } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).foregroundStyle(Halo.text).accessibilityLabel("Turn page \(tile.index + 1)")
                Button { withAnimation { tiles.removeAll { $0.id == tile.id } } } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundStyle(Halo.text).accessibilityLabel("Remove page \(tile.index + 1)")
                    .disabled(tiles.count == 1)
            }
            .font(.system(size: 11, weight: .bold))
            .frame(width: 92)
        }
    }

    private func turn(_ tile: Tile) {
        guard let i = tiles.firstIndex(where: { $0.id == tile.id }) else { return }
        tiles[i].rotation = (tiles[i].rotation + 90) % 360
    }

    private func load() async {
        let url = file
        let images = await Task.detached(priority: .userInitiated) {
            UncheckedSendable(PDFTools.thumbnails(url, maxPixel: 180))
        }.value.value
        var loaded: [Int: NSImage] = [:]
        for (i, image) in images.enumerated() { loaded[i] = NSImage(cgImage: image, size: .zero) }
        pictures = loaded
        original = images.indices.map { Tile(index: $0) }
        tiles = original
    }

    private struct Reorder: DropDelegate {
        let target: Tile
        @Binding var tiles: [Tile]
        @Binding var dragging: Tile?

        func dropEntered(info: DropInfo) {
            guard let dragging, dragging.id != target.id,
                  let from = tiles.firstIndex(where: { $0.id == dragging.id }),
                  let to = tiles.firstIndex(where: { $0.id == target.id }) else { return }
            withAnimation(.easeOut(duration: 0.15)) {
                tiles.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
            }
        }

        func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

        func performDrop(info: DropInfo) -> Bool {
            dragging = nil
            return true
        }
    }
}
