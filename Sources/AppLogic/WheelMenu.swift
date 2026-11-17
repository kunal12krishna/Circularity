import CircularityEngine
import Foundation
import UniformTypeIdentifiers

nonisolated enum FileKind: Sendable, Hashable {
    case image, pdf, document(DocumentFlavor), video, audio, other
}

nonisolated enum DocumentFlavor: Sendable, Hashable {
    case markdown, html, plainText, rich(OutputFormat?) // rich: rtf/doc/docx/odt (docx → .docx)
}

/// What a wheel button does. Milestone (d) maps these onto engine jobs.
nonisolated enum WheelAction: Sendable, Hashable {
    case convert(OutputFormat)
    case pdfPages(OutputFormat)
    case extractText
    case combinePDF
    case compress, resize, crop
    case more
    /// A saved one-click button (id of a `Preset`).
    case preset(String)

    /// Stable key for smart-ordering usage counts.
    var usageKey: String {
        switch self {
        case let .convert(f): "convert.\(f.rawValue)"
        case let .pdfPages(f): "pages.\(f.rawValue)"
        case .extractText: "extractText"
        case .combinePDF: "combine"
        case .compress: "compress"
        case .resize: "resize"
        case .crop: "crop"
        case .more: "more"
        case let .preset(id): "preset.\(id)"
        }
    }
}

nonisolated enum SlotCategory: Sendable, Equatable {
    case format, tool, more
}

/// One button on the ring or in the More fan, with every string each layout needs.
nonisolated struct WheelSlot: Sendable, Equatable {
    var action: WheelAction
    var category: SlotCategory
    var label: String       // Ring/Orbit label: "JPG", "Compress"
    var monoLabel: String   // Halo label: "JPG", "SQZ", "•••"
    var caption: String     // Halo caption: "PHOTO", "COMPRESS"
    var symbol: String      // SF Symbol
    var kicker: String      // orb line 1: "CONVERT TO", "OPEN"
    var big: String         // orb line 2: "JPG", "Compress"
    var hint: String        // orb line 3 until a live estimate exists
    var verb: String        // VoiceOver label and the Orbit cursor pill
}

/// A friendly centre message instead of buttons (video/audio in v1, unsupported files).
nonisolated struct WheelNotice: Sendable, Equatable {
    var kicker: String
    var big: String
    var detail: String
}

nonisolated struct WheelMenu: Sendable, Equatable {
    /// Exactly six entries, slot 0 at 12 o'clock, clockwise; nil = empty segment.
    var ring: [WheelSlot?]
    var fan: [WheelSlot]
    var notice: WheelNotice?

    var isEmpty: Bool { ring.allSatisfy { $0 == nil } }
}

/// Builds the wheel's buttons for the files being dragged (PLAN.md §3.3, §9.1).
nonisolated enum SlotProvider {
    static func kind(of type: UTType) -> FileKind {
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if let markdown = UTType("net.daringfireball.markdown"), type.conforms(to: markdown) { return .document(.markdown) }
        if type.conforms(to: .html) { return .document(.html) }
        if type.conforms(to: .rtf) || type.conforms(to: .rtfd) { return .document(.rich(nil)) }
        for identifier in ["com.microsoft.word.doc", "org.oasis-open.opendocument.text"] {
            if let t = UTType(identifier), type.conforms(to: t) { return .document(.rich(nil)) }
        }
        if let docx = UTType("org.openxmlformats.wordprocessingml.document"), type.conforms(to: docx) {
            return .document(.rich(.docx))
        }
        if type.conforms(to: .plainText) { return .document(.plainText) }
        return .other
    }

    /// The output format an image type already is, if any.
    static func imageFormat(of type: UTType) -> OutputFormat? {
        OutputFormat.allCases.first { f in
            guard let id = f.imageTypeIdentifier, let t = UTType(id) else { return false }
            return type.conforms(to: t)
        }
    }

    static let ringImageCandidates: [OutputFormat] = [.png, .jpg, .webp, .heic, .avif, .tiff, .gif, .bmp]

    /// Adds matching saved buttons to the front of the More fan (at most three).
    static func menu(for types: [UTType], canWrite: (OutputFormat) -> Bool, usage: [String: Int] = [:],
                     smartOrdering: Bool = false, presets: [Preset]) -> WheelMenu {
        var menu = menu(for: types, canWrite: canWrite, usage: usage, smartOrdering: smartOrdering)
        let kinds = Set(types.map { kind(of: $0) })
        let applies: Preset.Applies? = kinds == [.image] ? .images : (kinds == [.pdf] ? .pdfs : nil)
        guard let applies, let moreIndex = menu.ring.firstIndex(where: { $0?.action == .more }) else { return menu }
        let slots = presets.filter { $0.applies == applies }.prefix(3).map { presetSlot($0, count: types.count) }
        guard !slots.isEmpty else { return menu }
        menu.fan.insert(contentsOf: slots, at: 0)
        menu.ring[moreIndex] = moreSlot(fanCount: menu.fan.count)
        return menu
    }

    static func presetSlot(_ preset: Preset, count: Int) -> WheelSlot {
        WheelSlot(action: .preset(preset.id), category: .tool, label: preset.name, monoLabel: preset.name.uppercased(),
                  caption: "BUTTON", symbol: "bolt", kicker: "ONE CLICK", big: preset.name,
                  hint: "your saved button", verb: "\(preset.name)\(count > 1 ? " for \(count) files" : "")")
    }

    static func menu(for types: [UTType], canWrite: (OutputFormat) -> Bool,
                     usage: [String: Int] = [:], smartOrdering: Bool = false) -> WheelMenu {
        let count = types.count
        let kinds = types.map(kind(of:))
        guard let first = kinds.first else {
            return WheelMenu(ring: Array(repeating: nil, count: 6), fan: [],
                             notice: WheelNotice(kicker: "NOTHING TO", big: "Convert", detail: "drop files here"))
        }
        if kinds.contains(where: { $0 == .video || $0 == .audio }) {
            let isVideo = kinds.contains(.video)
            return WheelMenu(ring: Array(repeating: nil, count: 6), fan: [],
                             notice: WheelNotice(kicker: "COMING SOON", big: isVideo ? "Video" : "Audio",
                                                 detail: "Video & audio arrive in the next update"))
        }
        if kinds.allSatisfy({ $0 == .image }) {
            let formats = Set(types.compactMap(imageFormat(of:)))
            let source = formats.count == 1 && types.allSatisfy({ imageFormat(of: $0) != nil }) ? formats.first : nil
            return imageMenu(count: count, source: source, canWrite: canWrite, usage: usage, smartOrdering: smartOrdering)
        }
        if kinds.allSatisfy({ $0 == .pdf }) { return pdfMenu(count: count) }
        if kinds.allSatisfy({ $0 == .image || $0 == .pdf }) {
            return WheelMenu(ring: [combine(count: count), nil, nil, nil, nil, nil], fan: [], notice: nil)
        }
        if case let .document(flavor) = first, kinds.allSatisfy({ $0 == first }) {
            return documentMenu(flavor: flavor, count: count)
        }
        let ext = types.count == 1 ? (types[0].preferredFilenameExtension?.uppercased() ?? "File") : "Mixed"
        return WheelMenu(ring: Array(repeating: nil, count: 6), fan: [],
                         notice: WheelNotice(kicker: "CAN'T CONVERT", big: ext, detail: "try images, PDFs or documents"))
    }

    // MARK: Images

    static func imageMenu(count: Int, source: OutputFormat?, canWrite: (OutputFormat) -> Bool,
                          usage: [String: Int], smartOrdering: Bool) -> WheelMenu {
        let available = ringImageCandidates.filter { $0 != source && canWrite($0) }
        var ordered = available
        if smartOrdering {
            // Stable: equal usage keeps the default order. Only format slots move.
            ordered = available.enumerated().sorted { a, b in
                let ua = usage[WheelAction.convert(a.element).usageKey] ?? 0
                let ub = usage[WheelAction.convert(b.element).usageKey] ?? 0
                return ua != ub ? ua > ub : a.offset < b.offset
            }.map(\.element)
        }
        // A batch puts "Combine into one PDF" on the ring (board B, slot 2).
        let ringFormats = Array(ordered.prefix(count > 1 ? 2 : 3))
        // Fan: the rest in canonical order, at most 4 image formats; BMP only fills a gap.
        var rest = ringImageCandidates.filter { available.contains($0) && !ringFormats.contains($0) }
        if rest.filter({ $0 != .bmp }).count >= 4 { rest.removeAll { $0 == .bmp } }
        let fanFormats = Array(rest.prefix(4))

        var fan = fanFormats.map { formatSlot($0, count: count) }
        if count > 1 {
            // Both PDF choices side by side, so it's clear which one you get.
            fan.append(combineChip(count: count))
            fan.append(separatePDFsChip(count: count))
        } else {
            fan.append(formatSlot(.pdf, count: count))
        }
        fan.append(cropSlot(count: count))

        var ring: [WheelSlot?] = ringFormats.map { formatSlot($0, count: count) }
        if count > 1 { ring.append(combine(count: count)) }
        while ring.count < 3 { ring.append(nil) }
        ring += [moreSlot(fanCount: fan.count), compressSlot(count: count, pdf: false), resizeSlot(count: count, pdf: false)]
        return WheelMenu(ring: ring, fan: fan, notice: nil)
    }

    // MARK: PDFs and documents

    static func pdfMenu(count: Int) -> WheelMenu {
        var fan = [cropSlot(count: count)]
        if count > 1 { fan.insert(combine(count: count), at: 0) }
        let ring: [WheelSlot?] = [
            pagesSlot(.png, count: count), pagesSlot(.jpg, count: count), extractTextSlot(count: count),
            moreSlot(fanCount: fan.count), compressSlot(count: count, pdf: true), resizeSlot(count: count, pdf: true),
        ]
        return WheelMenu(ring: ring, fan: fan, notice: nil)
    }

    static func documentMenu(flavor: DocumentFlavor, count: Int) -> WheelMenu {
        let outputs: [OutputFormat] = switch flavor {
        case .markdown: [.pdf, .html, .txt]
        case .html: [.pdf, .txt, .docx]
        case .plainText: [.pdf, .docx, .html]
        case let .rich(own): [.pdf, .txt, .docx, .html].filter { $0 != own }
        }
        var ring: [WheelSlot?] = outputs.prefix(3).map { formatSlot($0, count: count) }
        while ring.count < 6 { ring.append(nil) }
        return WheelMenu(ring: ring, fan: [], notice: nil)
    }

    // MARK: Slot builders (copy from PLAN.md §9.1 and the boards)

    private static func many(_ count: Int) -> String { count > 1 ? " \(count)" : "" }

    static func formatSlot(_ f: OutputFormat, count: Int) -> WheelSlot {
        let (caption, hint): (String, String) = switch f {
        case .png: ("LOSSLESS", "lossless, keeps transparency")
        case .jpg: ("PHOTO", "small, best for photos")
        case .webp: ("SMALL", "smaller than JPG")
        case .heic: ("COMPACT", "compact, for Apple devices")
        case .avif: ("SMALLEST", "smallest files")
        case .tiff: ("PRINT", "lossless, for print")
        case .gif: ("256 COLOURS", "256 colours")
        case .bmp: ("BITMAP", "uncompressed")
        case .pdf: ("DOCUMENT", count > 1 ? "one PDF per image" : "a one-page PDF")
        case .txt: ("TEXT", "plain text only")
        case .html: ("WEB", "a web page")
        case .docx: ("WORD", "a Word document")
        }
        let isDocument = f.imageTypeIdentifier == nil
        return WheelSlot(action: .convert(f), category: .format, label: f.displayName,
                         monoLabel: f.displayName.uppercased(), caption: caption,
                         symbol: isDocument ? "doc.text" : "photo", kicker: "CONVERT TO", big: f.displayName,
                         hint: hint, verb: "Convert\(many(count)) to \(f.displayName)")
    }

    static func pagesSlot(_ f: OutputFormat, count: Int) -> WheelSlot {
        WheelSlot(action: .pdfPages(f), category: .format, label: f.displayName, monoLabel: f.displayName.uppercased(),
                  caption: "PAGES", symbol: "photo.on.rectangle", kicker: "CONVERT TO", big: f.displayName,
                  hint: "one image per page", verb: "Convert pages to \(f.displayName)")
    }

    static func extractTextSlot(count: Int) -> WheelSlot {
        WheelSlot(action: .extractText, category: .format, label: "TXT", monoLabel: "TXT", caption: "TEXT",
                  symbol: "doc.plaintext", kicker: "EXTRACT", big: "TXT", hint: "text only", verb: "Extract text")
    }

    static func combine(count: Int) -> WheelSlot {
        WheelSlot(action: .combinePDF, category: .format, label: "Combine", monoLabel: "PDF", caption: "COMBINE",
                  symbol: "doc.on.doc", kicker: "COMBINE INTO", big: "PDF", hint: "\(count) files, in drop order",
                  verb: "Combine into one PDF")
    }

    /// "1 PDF": every image as a page of one PDF.
    static func combineChip(count: Int) -> WheelSlot {
        WheelSlot(action: .combinePDF, category: .format, label: "1 PDF", monoLabel: "1 PDF", caption: "COMBINE",
                  symbol: "doc.on.doc", kicker: "COMBINE INTO", big: "1 PDF", hint: "all \(count) images in one PDF",
                  verb: "Combine into one PDF")
    }

    /// "N PDFs": a separate PDF for each image.
    static func separatePDFsChip(count: Int) -> WheelSlot {
        WheelSlot(action: .convert(.pdf), category: .format, label: "\(count) PDFs", monoLabel: "\(count) PDFS",
                  caption: "SEPARATE", symbol: "doc", kicker: "CONVERT TO", big: "\(count) PDFs",
                  hint: "a separate PDF for each image", verb: "Make \(count) separate PDFs")
    }

    static func moreSlot(fanCount: Int) -> WheelSlot {
        WheelSlot(action: .more, category: .more, label: "More", monoLabel: "•••", caption: "MORE",
                  symbol: "ellipsis", kicker: "REST HERE FOR", big: "More", hint: "\(fanCount) more options",
                  verb: "More formats")
    }

    static func compressSlot(count: Int, pdf: Bool) -> WheelSlot {
        WheelSlot(action: .compress, category: .tool, label: "Compress", monoLabel: "SQZ", caption: "COMPRESS",
                  symbol: "arrow.up.right.and.arrow.down.left", kicker: "OPEN", big: "Compress",
                  hint: pdf ? "light · balanced · strong" : "quality or target size", verb: "Compress\(many(count))…")
    }

    static func resizeSlot(count: Int, pdf: Bool) -> WheelSlot {
        WheelSlot(action: .resize, category: .tool, label: "Resize", monoLabel: "SIZE", caption: "RESIZE",
                  symbol: "arrow.down.left.and.arrow.up.right", kicker: "OPEN", big: "Resize",
                  hint: pdf ? "page size" : "width × height", verb: "Resize\(many(count))…")
    }

    static func cropSlot(count: Int) -> WheelSlot {
        WheelSlot(action: .crop, category: .tool, label: "Crop", monoLabel: "CROP", caption: "CROP",
                  symbol: "crop", kicker: "OPEN", big: "Crop", hint: "1:1 · 4:3 · 16:9", verb: "Crop\(many(count))…")
    }
}
