import CircularityEngine
import Foundation
import UniformTypeIdentifiers

nonisolated enum FileKind: Sendable, Hashable {
    case image, pdf, document(DocumentFlavor), video, audio, other
}

nonisolated enum DocumentFlavor: Sendable, Hashable {
    case markdown, html, plainText, rich(OutputFormat?) // rich: rtf/doc/docx/odt (docx → .docx)
    case spreadsheet  // XLSX / XLS / ODS / CSV
    case presentation // PPTX / PPT / ODP
}

/// The three wheels, each on its own key (Settings → Gesture): formats,
/// tools, and things to do with the files themselves.
nonisolated enum WheelKind: String, Sendable, CaseIterable, Hashable {
    case convert, tools, actions

    var title: String {
        switch self {
        case .convert: "Convert"
        case .tools: "Tools"
        case .actions: "Actions"
        }
    }
}

/// Things done with files as they are (the Actions wheel). They work on
/// anything: folders, mixed selections, files nothing can convert.
nonisolated enum FileAction: String, Sendable, Hashable, CaseIterable {
    case airDrop, copy, zip, copyPath, stash, mail, rename, terminal, moveTo, copyTo, quickLook, reveal
}

/// What a wheel button does. Milestone (d) maps these onto engine jobs.
nonisolated enum WheelAction: Sendable, Hashable {
    case convert(OutputFormat)
    case pdfPages(OutputFormat)
    case extractText
    case combinePDF
    case compress, resize, crop
    /// Background removal (macOS 14+).
    case cutout
    case more
    /// A saved one-click button (id of a `Preset`).
    case preset(String)
    /// Same picture, location (GPS) removed.
    case stripLocation
    case splitPDF
    /// Video and audio.
    case trim, mute, combineMedia
    /// Make it fit (a size limit), Text (copy the words), Searchable PDF,
    /// a PDF password (add or remove), Pages (reorder, turn, remove), Speed.
    case fit, copyText, searchable, password, editPages, speed
    /// Smart crop for social (1:1, 4:5, 16:9, 9:16 around the subject).
    case social
    /// The Actions wheel.
    case file(FileAction)

    /// Opens a window first (Orbit marks these with "…").
    var opensDialog: Bool {
        switch self {
        case .compress, .resize, .crop, .trim, .fit, .password, .editPages, .speed, .social, .file(.moveTo), .file(.copyTo), .file(.rename): true
        default: false
        }
    }

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
        case .cutout: "cutout"
        case .more: "more"
        case let .preset(id): "preset.\(id)"
        case .stripLocation: "stripLocation"
        case .splitPDF: "splitPDF"
        case .trim: "trim"
        case .mute: "mute"
        case .combineMedia: "combineMedia"
        case let .file(a): "file.\(a.rawValue)"
        case .fit: "fit"
        case .copyText: "copyText"
        case .searchable: "searchable"
        case .password: "password"
        case .editPages: "editPages"
        case .speed: "speed"
        case .social: "social"
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
    /// Which wheel this is, and the line the centre shows at rest ("⌘ tools · ⌃ actions").
    var kind: WheelKind = .convert
    var restHint: String?

    var isEmpty: Bool { ring.allSatisfy { $0 == nil } }
}

/// Builds the wheel's buttons for the files being dragged (PLAN.md §3.3, §9.1).
nonisolated enum SlotProvider {
    static func kind(of type: UTType) -> FileKind {
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return MediaSupport.canRead(type) ? .video : .other }
        if type.conforms(to: .audio) { return MediaSupport.canRead(type) ? .audio : .other }
        if let markdown = UTType("net.daringfireball.markdown"), type.conforms(to: markdown) { return .document(.markdown) }
        if type.conforms(to: .html) { return .document(.html) }
        if type.conforms(to: .rtf) || type.conforms(to: .rtfd) { return .document(.rich(nil)) }
        for identifier in ["com.microsoft.word.doc", "org.oasis-open.opendocument.text"] {
            if let t = UTType(identifier), type.conforms(to: t) { return .document(.rich(nil)) }
        }
        if let docx = UTType("org.openxmlformats.wordprocessingml.document"), type.conforms(to: docx) {
            return .document(.rich(.docx))
        }
        // Before plain text: CSV is plain text too.
        if OfficeBackend.spreadsheetSource(of: type) != nil { return .document(.spreadsheet) }
        if OfficeBackend.presentationSource(of: type) != nil { return .document(.presentation) }
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

    /// Settings → Wheel → image format order ("jpg,png,…"). Unknown entries
    /// are ignored and missing formats keep their default place at the end.
    static func imageFormatOrder(_ setting: String) -> [OutputFormat] {
        var seen: [OutputFormat] = []
        for part in setting.split(separator: ",") {
            let ext = part.trimmingCharacters(in: .whitespaces).lowercased()
            if let f = ringImageCandidates.first(where: { $0.fileExtension == ext || ($0 == .jpg && ext == "jpeg") }), !seen.contains(f) {
                seen.append(f)
            }
        }
        return seen + ringImageCandidates.filter { !seen.contains($0) }
    }

    /// Adds matching saved buttons to the front of the More fan (at most three).
    static func menu(for types: [UTType], canWrite: (OutputFormat) -> Bool, usage: [String: Int] = [:],
                     smartOrdering: Bool = false, presets: [Preset], formatOrder: [OutputFormat] = ringImageCandidates,
                     slots: [String]? = nil, cutout: Bool = Cutout.isAvailable) -> WheelMenu {
        var menu = menu(for: types, canWrite: canWrite, usage: usage, smartOrdering: smartOrdering, formatOrder: formatOrder,
                        slots: slots, cutout: cutout)
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
                     usage: [String: Int] = [:], smartOrdering: Bool = false,
                     formatOrder: [OutputFormat] = ringImageCandidates,
                     slots: [String]? = nil, cutout: Bool = Cutout.isAvailable) -> WheelMenu {
        let count = types.count
        let kinds = types.map(kind(of:))
        guard let first = kinds.first else {
            return WheelMenu(ring: Array(repeating: nil, count: 6), fan: [],
                             notice: WheelNotice(kicker: "NOTHING TO", big: "Convert", detail: "drop files here"))
        }
        if kinds.allSatisfy({ $0 == .video }) {
            return videoMenu(count: count, source: commonMediaFormat(types), canWrite: canWrite)
        }
        if kinds.allSatisfy({ $0 == .audio }) {
            return audioMenu(count: count, source: commonMediaFormat(types), canWrite: canWrite)
        }
        if kinds.allSatisfy({ $0 == .video || $0 == .audio }) {
            // Videos and songs together: the sound of each, as an audio file.
            return audioMenu(count: count, source: nil, canWrite: canWrite, joinable: false)
        }
        if kinds.allSatisfy({ $0 == .image }) {
            let formats = Set(types.compactMap(imageFormat(of:)))
            let source = formats.count == 1 && types.allSatisfy({ imageFormat(of: $0) != nil }) ? formats.first : nil
            if let slots, let custom = customImageMenu(slots, count: count, source: source, canWrite: canWrite,
                                                         formatOrder: formatOrder, cutout: cutout) {
                return custom
            }
            return imageMenu(count: count, source: source, canWrite: canWrite, usage: usage, smartOrdering: smartOrdering,
                             formatOrder: formatOrder, cutout: cutout)
        }
        if kinds.allSatisfy({ $0 == .pdf }) { return pdfMenu(count: count) }
        if kinds.allSatisfy({ $0 == .image || $0 == .pdf }) {
            return WheelMenu(ring: [combine(count: count), nil, nil, nil, nil, nil], fan: [], notice: nil)
        }
        if case let .document(flavor) = first, kinds.allSatisfy({ $0 == first }) {
            return documentMenu(flavor: flavor, count: count, compressible: types.allSatisfy(OfficeCompressor.canCompress))
        }
        return WheelMenu(ring: Array(repeating: nil, count: 6), fan: [],
                         notice: WheelNotice(kicker: "CAN'T CONVERT", big: noticeName(types),
                                             detail: "try images, PDFs, documents, video or audio"))
    }

    /// "Folder", "MKV", "Mixed" for a centre notice.
    static func noticeName(_ types: [UTType]) -> String {
        guard types.count == 1 else { return "Mixed" }
        if types[0].conforms(to: .folder) || types[0].conforms(to: .directory) { return "Folder" }
        return types[0].preferredFilenameExtension?.uppercased() ?? "File"
    }

    /// The one writable format every file is already in, if they share one.
    static func commonMediaFormat(_ types: [UTType]) -> OutputFormat? {
        let formats = Set(types.map { t in t.preferredFilenameExtension.flatMap { MediaSupport.format(of: URL(fileURLWithPath: "x.\($0)")) } })
        guard formats.count == 1, let only = formats.first else { return nil }
        return only
    }

    // MARK: Video and audio (AVFoundation)

    /// Ring: two video formats, GIF, More, Compress, Trim (one file) or Join (several).
    /// More: the other video format, the sound as audio, and Mute.
    static func videoMenu(count: Int, source: OutputFormat?, canWrite: (OutputFormat) -> Bool) -> WheelMenu {
        let videos = OutputFormat.videoFormats.filter { $0 != source }
        var fan = videos.dropFirst(2).map { mediaSlot($0, count: count, fromVideo: true) }
        fan += OutputFormat.audioFormats.filter(canWrite).map { mediaSlot($0, count: count, fromVideo: true) }
        fan.append(muteSlot(count: count))
        var ring: [WheelSlot?] = videos.prefix(2).map { mediaSlot($0, count: count, fromVideo: true) }
        ring.append(gifSlot(count: count))
        ring.append(moreSlot(fanCount: fan.count))
        ring.append(mediaCompressSlot(count: count, video: true))
        ring.append(count > 1 ? joinSlot(count: count, video: true) : trimSlot(count: count))
        return WheelMenu(ring: ring, fan: fan, notice: nil)
    }

    /// Ring: three audio formats, More (the fourth), Compress, Trim (one file)
    /// or Join (several of one kind; a mix of video and audio can't be joined).
    static func audioMenu(count: Int, source: OutputFormat?, canWrite: (OutputFormat) -> Bool, joinable: Bool = true) -> WheelMenu {
        let formats = OutputFormat.audioFormats.filter { $0 != source && canWrite($0) }
        var ring: [WheelSlot?] = formats.prefix(3).map { mediaSlot($0, count: count, fromVideo: false) }
        let fan = formats.dropFirst(3).map { mediaSlot($0, count: count, fromVideo: false) }
        while ring.count < 3 { ring.append(nil) }
        ring.append(fan.isEmpty ? nil : moreSlot(fanCount: fan.count))
        ring.append(mediaCompressSlot(count: count, video: false))
        ring.append(count > 1 ? (joinable ? joinSlot(count: count, video: false) : nil) : trimSlot(count: count))
        return WheelMenu(ring: ring, fan: fan, notice: nil)
    }

    static func mediaSlot(_ f: OutputFormat, count: Int, fromVideo: Bool) -> WheelSlot {
        let (caption, hint): (String, String) = switch f {
        case .mp4: ("VIDEO", "plays everywhere")
        case .mov: ("QUICKTIME", "for Apple apps and editing")
        case .m4v: ("APPLE TV", "for Apple TV and iTunes")
        case .m4a: (fromVideo ? "SOUND" : "AAC", fromVideo ? "just the sound, small" : "small, plays everywhere")
        case .wav: ("PCM", fromVideo ? "just the sound, uncompressed" : "uncompressed, for editing")
        case .aiff: ("APPLE PCM", "uncompressed, for Apple apps")
        case .flac: ("LOSSLESS", "lossless and smaller than WAV")
        default: (f.displayName, "")
        }
        let symbol = f.isVideo ? "film" : "waveform"
        let kicker = fromVideo && f.isAudio ? "SOUND AS" : "CONVERT TO"
        let verb = fromVideo && f.isAudio ? "Save the sound\(many(count)) as \(f.displayName)" : "Convert\(many(count)) to \(f.displayName)"
        return WheelSlot(action: .convert(f), category: .format, label: f.displayName, monoLabel: f.displayName.uppercased(),
                         caption: caption, symbol: symbol, kicker: kicker, big: f.displayName, hint: hint, verb: verb)
    }

    static func gifSlot(count: Int) -> WheelSlot {
        WheelSlot(action: .convert(.gif), category: .format, label: "GIF", monoLabel: "GIF", caption: "LOOP",
                  symbol: "photo.stack", kicker: "CONVERT TO", big: "GIF", hint: "a looping GIF, 480 px",
                  verb: "Make\(many(count)) GIF\(count > 1 ? "s" : "")")
    }

    static func trimSlot(count: Int) -> WheelSlot {
        WheelSlot(action: .trim, category: .tool, label: "Trim", monoLabel: "TRIM", caption: "LENGTH",
                  symbol: "timeline.selection", kicker: "OPEN", big: "Trim", hint: "keep just the part you want",
                  verb: "Trim…")
    }

    static func muteSlot(count: Int) -> WheelSlot {
        WheelSlot(action: .mute, category: .tool, label: "Mute", monoLabel: "MUTE", caption: "NO SOUND",
                  symbol: "speaker.slash", kicker: "REMOVE THE", big: "Sound", hint: "same picture, silent",
                  verb: "Remove the sound\(many(count))")
    }

    static func joinSlot(count: Int, video: Bool) -> WheelSlot {
        WheelSlot(action: .combineMedia, category: .tool, label: "Join", monoLabel: "JOIN", caption: "JOIN",
                  symbol: "rectangle.stack.badge.plus", kicker: "JOIN INTO", big: video ? "1 video" : "1 track",
                  hint: "\(count) files, in drop order", verb: "Join \(count) files into one")
    }

    static func mediaCompressSlot(count: Int, video: Bool) -> WheelSlot {
        WheelSlot(action: .compress, category: .tool, label: "Compress", monoLabel: "SQZ", caption: "COMPRESS",
                  symbol: "arrow.up.right.and.arrow.down.left", kicker: "OPEN", big: "Compress",
                  hint: video ? "HEVC · light · balanced · strong" : "AAC · light · balanced · strong", verb: "Compress\(many(count))…")
    }

    // MARK: The Tools wheel

    /// Tools for the files being dragged: what changes the file rather than its
    /// format. More than six: the first five on the ring, the rest under More.
    static func toolsMenu(for types: [UTType], cutout: Bool = Cutout.isAvailable) -> WheelMenu {
        let count = types.count
        let kinds = types.map(kind(of:))
        var tools: [WheelSlot] = []
        if !kinds.isEmpty, kinds.allSatisfy({ $0 == .image }) {
            tools = [compressSlot(count: count, pdf: false), fitSlot(count: count), copyTextSlot(count: count),
                     socialSlot(count: count), cropSlot(count: count), resizeSlot(count: count, pdf: false)]
            if cutout { tools.append(cutoutSlot(count: count)) }
            tools.append(count > 1 ? combine(count: count) : formatSlot(.pdf, count: count))
            tools.append(searchableSlot(count: count, scan: true))
            tools.append(stripLocationSlot(count: count))
        } else if !kinds.isEmpty, kinds.allSatisfy({ $0 == .pdf }) {
            tools = [compressSlot(count: count, pdf: true), fitSlot(count: count), copyTextSlot(count: count)]
            if count == 1 { tools += [editPagesSlot(), passwordSlot(count: count)] } else { tools += [combine(count: count), passwordSlot(count: count)] }
            tools += [searchableSlot(count: count, scan: false), splitSlot(count: count), resizeSlot(count: count, pdf: true), cropSlot(count: count)]
        } else if !kinds.isEmpty, kinds.allSatisfy({ $0 == .image || $0 == .pdf }) {
            tools = [combine(count: count), fitSlot(count: count), copyTextSlot(count: count)]

        } else if !kinds.isEmpty, kinds.allSatisfy({ $0 == .video }) {
            if count == 1 { tools.append(trimSlot(count: count)) }
            tools += [mediaCompressSlot(count: count, video: true), fitSlot(count: count), speedSlot(count: count),
                      muteSlot(count: count), gifSlot(count: count), mediaSlot(.m4a, count: count, fromVideo: true)]
            if count > 1 { tools.insert(joinSlot(count: count, video: true), at: 0) }
        } else if !kinds.isEmpty, kinds.allSatisfy({ $0 == .audio }) {
            if count == 1 { tools.append(trimSlot(count: count)) }
            tools += [mediaCompressSlot(count: count, video: false), fitSlot(count: count), speedSlot(count: count)]
            if count > 1 { tools.append(joinSlot(count: count, video: false)) }
        } else if let first = kinds.first, case .document = first, kinds.allSatisfy({ $0 == first }),
                  types.allSatisfy(OfficeCompressor.canCompress) {
            var compress = compressSlot(count: count, pdf: false)
            compress.hint = "smaller pictures, same file"
            tools = [compress, fitSlot(count: count)]
        } else if !kinds.isEmpty, zip(kinds, types).allSatisfy({ kind, type in
            [.image, .pdf, .video, .audio].contains(kind) || OfficeCompressor.canCompress(type)
        }) {
            // A mix (photos and a video for one email, say): Fit works on every kind.
            tools = [fitSlot(count: count)]
        }
        guard !tools.isEmpty else {
            return WheelMenu(ring: Array(repeating: nil, count: 6), fan: [],
                             notice: WheelNotice(kicker: "NO TOOLS FOR", big: types.isEmpty ? "These" : noticeName(types),
                                                 detail: "try the Actions wheel"), kind: .tools)
        }
        var menu = ringWithMore(tools)
        menu.kind = .tools
        return menu
    }

    static func fitSlot(count: Int) -> WheelSlot {
        WheelSlot(action: .fit, category: .tool, label: "Fit", monoLabel: "FIT", caption: "TO SEND",
                  symbol: "paperplane", kicker: "MAKE IT", big: "Fit", hint: "under a size: email, WhatsApp, Discord…",
                  verb: "Make\(many(count)) fit…")
    }

    static func copyTextSlot(count: Int) -> WheelSlot {
        WheelSlot(action: .copyText, category: .tool, label: "Text", monoLabel: "TEXT", caption: "COPY WORDS",
                  symbol: "text.viewfinder", kicker: "COPY THE", big: "Text", hint: "the words, even from a photo or scan",
                  verb: "Copy the text")
    }

    static func searchableSlot(count: Int, scan: Bool) -> WheelSlot {
        WheelSlot(action: .searchable, category: .tool, label: "OCR", monoLabel: "OCR", caption: "SEARCHABLE",
                  symbol: "doc.text.magnifyingglass", kicker: "SEARCHABLE", big: "PDF",
                  hint: scan ? "a PDF you can search and copy from" : "find and copy text in scanned pages",
                  verb: "Make\(many(count)) searchable")
    }

    static func passwordSlot(count: Int) -> WheelSlot {
        WheelSlot(action: .password, category: .tool, label: "Lock", monoLabel: "LOCK", caption: "PASSWORD",
                  symbol: "lock", kicker: "PASSWORD", big: "Lock", hint: "add a password, or remove one",
                  verb: "Password…")
    }

    static func editPagesSlot() -> WheelSlot {
        WheelSlot(action: .editPages, category: .tool, label: "Pages", monoLabel: "PAGES", caption: "REORDER",
                  symbol: "square.grid.2x2", kicker: "EDIT", big: "Pages", hint: "reorder, turn or remove pages",
                  verb: "Edit pages…")
    }

    static func socialSlot(count: Int) -> WheelSlot {
        WheelSlot(action: .social, category: .tool, label: "Social", monoLabel: "SOCIAL", caption: "1:1 · 9:16",
                  symbol: "rectangle.portrait.on.rectangle.portrait", kicker: "CROP FOR", big: "Social", hint: "1:1, 4:5, 16:9, 9:16, subject kept",
                  verb: "Crop for social…")
    }

    static func speedSlot(count: Int) -> WheelSlot {
        WheelSlot(action: .speed, category: .tool, label: "Speed", monoLabel: "SPEED", caption: "FASTER",
                  symbol: "gauge.with.dots.needle.67percent", kicker: "CHANGE THE", big: "Speed", hint: "0.25× to 4×, voices keep their pitch",
                  verb: "Speed…")
    }

    static func stripLocationSlot(count: Int) -> WheelSlot {
        WheelSlot(action: .stripLocation, category: .tool, label: "No GPS", monoLabel: "NO GPS", caption: "PRIVACY",
                  symbol: "location.slash", kicker: "REMOVE THE", big: "Location", hint: "same picture, no GPS",
                  verb: "Remove the location\(many(count))")
    }

    static func splitSlot(count: Int) -> WheelSlot {
        WheelSlot(action: .splitPDF, category: .tool, label: "Split", monoLabel: "SPLIT", caption: "PAGES",
                  symbol: "square.split.2x1", kicker: "SPLIT INTO", big: "Pages", hint: "a PDF for every page",
                  verb: "Split\(many(count)) into pages")
    }

    // MARK: The Actions wheel

    /// The same for every selection, folders included. Ring: send, copy, zip,
    /// More, path, stash; More: Mail, Terminal, Move to…, Copy to…, Look, Finder.
    static func actionsMenu(count: Int) -> WheelMenu {
        let fan: [WheelSlot] = [.mail, .rename, .terminal, .moveTo, .copyTo, .quickLook, .reveal].map { actionSlot($0, count: count) }
        let ring: [WheelSlot?] = [actionSlot(.airDrop, count: count), actionSlot(.copy, count: count),
                                  actionSlot(.zip, count: count), moreSlot(fanCount: fan.count),
                                  actionSlot(.copyPath, count: count), actionSlot(.stash, count: count)]
        var menu = WheelMenu(ring: ring, fan: fan, notice: nil)
        menu.kind = .actions
        return menu
    }

    static func actionSlot(_ action: FileAction, count: Int) -> WheelSlot {
        let them = count > 1 ? "them" : "it"
        let (label, mono, caption, symbol, kicker, big, hint, verb): (String, String, String, String, String, String, String, String) =
            switch action {
            case .airDrop: ("AirDrop", "AIRDROP", "NEARBY", "dot.radiowaves.left.and.right", "SEND WITH", "AirDrop", "to a nearby Mac, iPhone or iPad", "AirDrop")
            case .copy: ("Copy", "COPY", "CLIPBOARD", "doc.on.doc", "TO CLIPBOARD", "Copy",
                         count > 1 ? "paste them into a folder or a chat" : "pastes as a file, or a picture in chats", "Copy")
            case .zip: ("Zip", "ZIP", "ARCHIVE", "archivebox", "PACK INTO", "Zip", count > 1 ? "one .zip with all \(count)" : "a .zip next to \(them)", "Zip")
            case .copyPath: ("Path", "PATH", "AS TEXT", "link", "COPY THE", "Path", count > 1 ? "one path per line" : "the full path, as text", "Copy path")
            case .stash: ("Stash", "STASH", "COLLECT", "tray.and.arrow.down", "ADD TO THE", "Stash",
                          "collect files, drag them out together", "Add to the Stash")
            case .mail: ("Mail", "MAIL", "ATTACH", "envelope", "ATTACH TO", "Email", "a new message with \(them) attached", "Email")
            case .rename: ("Rename", "NAME", "BATCH", "character.cursor.ibeam", "RENAME", count > 1 ? "\(count) files" : "It",
                           "a pattern, or find and replace", "Rename…")
            case .terminal: ("Shell", "TERM", "TERMINAL", "terminal", "OPEN IN", "Terminal", "a new window in this folder", "Open in Terminal")
            case .moveTo: ("Move to", "MOVE TO", "FOLDER", "folder", "MOVE TO", "Folder…", "choose where \(them) go", "Move to…")
            case .copyTo: ("Copy to", "COPY TO", "FOLDER", "folder.badge.plus", "COPY TO", "Folder…", "the original stays", "Copy to…")
            case .quickLook: ("Look", "LOOK", "PREVIEW", "eye", "QUICK", "Look", "preview without opening", "Quick Look")
            case .reveal: ("Finder", "SHOW", "FINDER", "magnifyingglass", "SHOW IN", "Finder", "select \(them) in a Finder window", "Show in Finder")
            }
        return WheelSlot(action: .file(action), category: .tool, label: label, monoLabel: mono, caption: caption, symbol: symbol,
                         kicker: kicker, big: big, hint: hint, verb: verb)
    }

    /// Up to six on the ring; more than six: five, then More with the rest.
    static func ringWithMore(_ slots: [WheelSlot]) -> WheelMenu {
        if slots.count <= 6 {
            return WheelMenu(ring: slots.map(Optional.some) + Array(repeating: nil, count: 6 - slots.count), fan: [], notice: nil)
        }
        let fan = Array(slots.dropFirst(5))
        let ring: [WheelSlot?] = Array(slots.prefix(3)) + [moreSlot(fanCount: fan.count)] + Array(slots.dropFirst(3).prefix(2))
        return WheelMenu(ring: ring, fan: fan, notice: nil)
    }

    // MARK: Images

    static func imageMenu(count: Int, source: OutputFormat?, canWrite: (OutputFormat) -> Bool,
                          usage: [String: Int], smartOrdering: Bool,
                          formatOrder: [OutputFormat] = ringImageCandidates, cutout: Bool = Cutout.isAvailable) -> WheelMenu {
        let candidates = formatOrder.filter { ringImageCandidates.contains($0) }
        let available = candidates.filter { $0 != source && canWrite($0) }
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
        var rest = candidates.filter { available.contains($0) && !ringFormats.contains($0) }
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
        if cutout { fan.append(cutoutSlot(count: count)) }
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

    /// Office files (Word, Excel, PowerPoint and their open formats) get two
    /// buttons: PDF, and Compress where the file is a zip package (DOCX, XLSX,
    /// PPTX, ODT, ODS, ODP); DOC, XLS, PPT, RTF and CSV get PDF alone.
    static func documentMenu(flavor: DocumentFlavor, count: Int, compressible: Bool = false) -> WheelMenu {
        let outputs: [OutputFormat] = switch flavor {
        case .markdown: [.pdf, .html, .txt]
        case .html: [.pdf, .txt, .docx]
        case .plainText: [.pdf, .docx, .html]
        case .rich, .spreadsheet, .presentation: [.pdf]
        }
        var ring: [WheelSlot?] = outputs.prefix(3).map { slot -> WheelSlot in
            var s = formatSlot(slot, count: count)
            if slot == .pdf {
                s.hint = switch flavor {
                case .spreadsheet: "every sheet, fitted to the page"
                case .presentation: "one page per slide"
                default: count > 1 ? "one PDF each" : "every page, as a PDF"
                }
            }
            return s
        }
        let office: Bool = switch flavor {
        case .rich, .spreadsheet, .presentation: true
        default: false
        }
        if office, compressible {
            var compress = compressSlot(count: count, pdf: false)
            compress.hint = "smaller pictures, same file"
            ring.append(compress)
        }
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
        case .mp4, .mov, .m4v, .m4a, .wav, .aiff, .flac: (f.displayName, "")
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

    static func cutoutSlot(count: Int) -> WheelSlot {
        WheelSlot(action: .cutout, category: .tool, label: "Cut out", monoLabel: "CUT", caption: "NO BG",
                  symbol: "scissors", kicker: "CUT OUT THE", big: "Subject", hint: "background made transparent (PNG)",
                  verb: "Remove the background\(many(count))")
    }

    // MARK: Your own wheel buttons (Settings → Wheel)

    /// What each of the six image ring positions can hold.
    static let slotTokens = ["png", "jpg", "webp", "heic", "avif", "tiff", "gif", "bmp", "pdf",
                             "compress", "resize", "crop", "cutout", "more"]
    static let defaultSlots = ["png", "jpg", "webp", "more", "compress", "resize"]

    /// "png,jpg,…" → six known tokens with exactly one More, else nil (= the built-in layout).
    static func parseSlots(_ setting: String) -> [String]? {
        let tokens = setting.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard tokens.count == 6, tokens.allSatisfy(slotTokens.contains), tokens.filter({ $0 == "more" }).count == 1,
              Set(tokens).count == 6 else { return nil }
        return tokens
    }

    /// The image wheel with the user's six buttons. Formats this Mac can't
    /// write (or the file's own format) are replaced by the next free format;
    /// everything not on the ring goes into the More fan.
    static func customImageMenu(_ tokens: [String], count: Int, source: OutputFormat?, canWrite: (OutputFormat) -> Bool,
                                formatOrder: [OutputFormat], cutout: Bool) -> WheelMenu? {
        guard tokens.count == 6 else { return nil }
        let candidates = formatOrder.filter { ringImageCandidates.contains($0) && $0 != source && canWrite($0) }
        let chosenFormats = tokens.compactMap { t in ringImageCandidates.first { $0.fileExtension == t } }
        var spare = candidates.filter { !chosenFormats.contains($0) }
        var used: [OutputFormat] = []
        var tools: Set<String> = []
        var ring: [WheelSlot?] = []
        for token in tokens {
            if let f = ringImageCandidates.first(where: { $0.fileExtension == token }) {
                let pick = candidates.contains(f) && !used.contains(f) ? f : (spare.isEmpty ? nil : spare.removeFirst())
                if let pick { used.append(pick) }
                ring.append(pick.map { formatSlot($0, count: count) })
                continue
            }
            switch token {
            case "pdf": ring.append(count > 1 ? combine(count: count) : formatSlot(.pdf, count: count))
            case "compress": ring.append(compressSlot(count: count, pdf: false))
            case "resize": ring.append(resizeSlot(count: count, pdf: false))
            case "crop": ring.append(cropSlot(count: count))
            case "cutout":
                if cutout {
                    ring.append(cutoutSlot(count: count))
                } else {
                    let pick = spare.isEmpty ? nil : spare.removeFirst()
                    if let pick { used.append(pick) }
                    ring.append(pick.map { formatSlot($0, count: count) })
                }
            default: ring.append(nil) // "more", filled below
            }
            tools.insert(token)
        }
        // Fan: up to four formats not on the ring, the PDF choices, then the tools that aren't.
        var fanFormats = candidates.filter { !used.contains($0) }
        if fanFormats.filter({ $0 != .bmp }).count >= 4 { fanFormats.removeAll { $0 == .bmp } }
        var fan = fanFormats.prefix(4).map { formatSlot($0, count: count) }
        if count > 1 {
            if !tools.contains("pdf") { fan.append(combineChip(count: count)) }
            fan.append(separatePDFsChip(count: count))
        } else if !tools.contains("pdf") {
            fan.append(formatSlot(.pdf, count: count))
        }
        if !tools.contains("compress") { fan.append(compressSlot(count: count, pdf: false)) }
        if !tools.contains("resize") { fan.append(resizeSlot(count: count, pdf: false)) }
        if cutout && !tools.contains("cutout") { fan.append(cutoutSlot(count: count)) }
        if !tools.contains("crop") { fan.append(cropSlot(count: count)) }
        guard let moreIndex = tokens.firstIndex(of: "more") else { return nil }
        ring[moreIndex] = moreSlot(fanCount: fan.count)
        return WheelMenu(ring: ring, fan: fan, notice: nil)
    }

    static func cropSlot(count: Int) -> WheelSlot {
        WheelSlot(action: .crop, category: .tool, label: "Crop", monoLabel: "CROP", caption: "CROP",
                  symbol: "crop", kicker: "OPEN", big: "Crop", hint: "1:1 · 4:3 · 16:9", verb: "Crop\(many(count))…")
    }
}
