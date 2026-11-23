import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Runs conversion jobs (PLAN.md §3.1): at most two at a time, with progress
/// and cancellation (cancel the calling Task), writing atomically.
public final class ConversionEngine: Sendable {
    public let queue: JobQueue
    public let planner: OutputPlanner
    public let support: FormatSupport

    public init(queue: JobQueue = JobQueue(), planner: OutputPlanner = OutputPlanner(), support: FormatSupport = .current) {
        self.queue = queue
        self.planner = planner
        self.support = support
    }

    public func run(_ request: JobRequest,
                    progress: @escaping @Sendable (JobProgress) -> Void = { _ in }) async throws -> JobResult {
        guard !request.inputs.isEmpty else { throw JobError.unsupported("an empty selection") }
        if request.operation == .combinePDF || request.operation == .combineMedia {
            let outcome = try await queue.run {
                try await self.combine(request, progress: { progress(JobProgress(fraction: $0, detail: $1)) })
            }
            return JobResult(outcomes: [outcome])
        }
        let tracker = ProgressTracker(count: request.inputs.count, report: progress)
        let batch = request.inputs.count > 1
        // In a batch, one bad file becomes a note on its own outcome; the
        // others keep going and their results are reported. Cancel stops all.
        let collected = try await withThrowingTaskGroup(of: (Int, JobOutcome, Error?).self) { group in
            for (i, input) in request.inputs.enumerated() {
                group.addTask {
                    do {
                        return try await self.queue.run {
                            let outcome = try await self.process(input, request: request) { fraction, detail in
                                Task { await tracker.update(i, fraction, detail) }
                            }
                            await tracker.update(i, 1, "")
                            return (i, outcome, nil)
                        }
                    } catch where batch && !(error is CancellationError) && !Task.isCancelled {
                        await tracker.update(i, 1, "")
                        let note = "\(input.lastPathComponent): \(error.localizedDescription)"
                        return (i, JobOutcome(inputs: [input], outputs: [], bytesIn: Self.size(of: input), bytesOut: 0,
                                              note: note, usedFallbackFolder: false), error)
                    }
                }
            }
            var items: [(Int, JobOutcome, Error?)] = []
            for try await item in group { items.append(item) }
            return items.sorted { $0.0 < $1.0 }
        }
        // Every file failed: report it as a failure, as for a single file.
        if let first = collected.first?.2, collected.allSatisfy({ $0.2 != nil }) { throw first }
        return JobResult(outcomes: collected.map(\.1))
    }

    // MARK: One input

    private func process(_ input: URL, request: JobRequest,
                         progress: @escaping @Sendable (Double, String) -> Void) async throws -> JobOutcome {
        try Task.checkCancellation()
        guard FileManager.default.isReadableFile(atPath: input.path) else { throw JobError.unreadable(input.lastPathComponent) }
        let type = Self.type(of: input)
        let bytesIn = Self.size(of: input)
        let staging = try Staging.make(for: input, policy: request.output)
        defer { staging.cleanup() }
        let policy = request.output
        var context = NamingContext(sourceURL: Self.namingSource(input, for: request.operation), format: .png, operation: request.operation.kind)

        /// `keepExtension`: the output keeps this extension instead of the format's (an Office file compressed as itself).
        func finish(_ staged: URL?, format: OutputFormat, note: String? = nil, folder: Bool = false,
                    keepExtension: String? = nil) async throws -> JobOutcome {
            try Task.checkCancellation()
            guard let staged else {
                return JobOutcome(inputs: [input], outputs: [], bytesIn: bytesIn, bytesOut: 0, note: note,
                                  usedFallbackFolder: staging.usedFallback)
            }
            context.format = format
            let final = try await staging.publish(staged, planner: planner, template: policy.template, context: context,
                                                  fileExtension: folder ? "" : keepExtension, fallbacks: policy.fallbackFolders,
                                                  collision: policy.collision)
            return JobOutcome(inputs: [input], outputs: [final], bytesIn: bytesIn, bytesOut: Self.size(of: final), note: note,
                              usedFallbackFolder: staging.usedFallback || final.deletingLastPathComponent() != staging.destination)
        }

        let isPDF = type.conforms(to: .pdf)
        let isImage = type.conforms(to: .image) && !isPDF
        let isMedia = Self.isMedia(type)
        let isVideo = isMedia ? await MediaBackend.hasVideo(input) : false
        let mediaProgress: MediaBackend.Progress = { progress(0.05 + $0 * 0.95, "") }
        progress(0.05, "")

        /// Video keeps its container when AVFoundation writes it (else MP4); audio likewise (else M4A).
        func sameMediaFormat() -> OutputFormat { MediaSupport.sameOrDefault(input, video: isVideo) }

        switch request.operation {
        case let .convert(format):
            if isMedia {
                guard support.canWrite(format) else { throw JobError.unsupported("to \(format.displayName) on this Mac") }
                let out = staging.scratch(format.fileExtension)
                if format.isVideo {
                    guard isVideo else { throw JobError.unsupported("\(input.lastPathComponent) to \(format.displayName): it has no picture") }
                    try await MediaBackend.convertVideo(input, to: format, output: out, progress: mediaProgress)
                    return try await finish(out, format: format)
                }
                if format.isAudio {
                    try await MediaBackend.writeAudio([input], to: format, output: out, progress: mediaProgress)
                    return try await finish(out, format: format)
                }
                if format == .gif {
                    let note = try await MediaBackend.gif(input, output: out, progress: mediaProgress)
                    return try await finish(out, format: .gif, note: note)
                }
                throw JobError.unsupported("\(input.lastPathComponent) to \(format.displayName)")
            }
            if isImage {
                guard support.canWrite(format) else { throw JobError.unsupported("to \(format.displayName) on this Mac") }
                let input = try ImageInput.open(input)
                let out = staging.scratch(format.fileExtension)
                try ImageBackend.convert(input, to: format, policy: policy, output: out)
                return try await finish(out, format: format)
            }
            if let flavor = DocumentBackend.flavor(of: type) {
                let out = staging.scratch(format.fileExtension)
                try await DocumentBackend.convert(input, flavor: flavor, to: format, output: out, workDir: staging.workDir)
                return try await finish(out, format: format)
            }
            if isPDF, format == .txt {
                let out = staging.scratch("txt")
                try PDFBackend.extractText(input, to: out)
                return try await finish(out, format: .txt)
            }
            throw JobError.unsupported("\(input.lastPathComponent) to \(format.displayName)")

        case let .resize(spec):
            guard isImage else { throw JobError.unsupported("resizing \(input.lastPathComponent)") }
            let image = try ImageInput.open(input)
            let format = sameFormat(type)
            let out = staging.scratch(format.fileExtension)
            try ImageBackend.resize(image, spec: spec, format: format, policy: policy, output: out)
            return try await finish(out, format: format)

        case .removeBackground:
            guard isImage else { throw JobError.unsupported("cutting out \(input.lastPathComponent)") }
            guard #available(macOS 14.0, *) else { throw JobError.unsupported("cutting out on macOS 13 (it needs macOS 14)") }
            let image = try ImageInput.open(input)
            let out = staging.scratch("png")
            try Cutout.removeBackground(image, policy: policy, output: out)
            progress(0.9, "")
            return try await finish(out, format: .png)

        case let .cropImage(rect):
            guard isImage else { throw JobError.unsupported("cropping \(input.lastPathComponent)") }
            let image = try ImageInput.open(input)
            let format = sameFormat(type)
            let out = staging.scratch(format.fileExtension)
            try ImageBackend.crop(image, rect: rect, format: format, policy: policy, output: out)
            return try await finish(out, format: format)

        case let .compressImage(compression):
            guard isImage else { throw JobError.unsupported("compressing \(input.lastPathComponent) as an image") }
            let image = try ImageInput.open(input)
            let alpha = (try? ImageOps.hasAlpha(image.upright(maxPixel: 64))) ?? false
            let format = ImageBackend.compressedFormat(for: Self.imageFormat(of: type), hasAlpha: alpha, support: support)
            let out = staging.scratch(format.fileExtension)
            let outcome = try ImageBackend.compress(image, compression, format: format, policy: policy, originalBytes: bytesIn,
                                                    output: out) { progress($0 * 0.9, "") }
            switch outcome {
            case let .written(shrunk):
                let note = shrunk.map { "Shrunk to \(Int($0.width)) × \(Int($0.height)) to fit" }
                return try await finish(out, format: format, note: note)
            case .notSmaller:
                return try await finish(nil, format: format, note: "Kept the original: it is already as small as it gets.")
            case .alreadyUnderTarget:
                if case let .targetBytes(t) = compression {
                    return try await finish(nil, format: format,
                                            note: "Kept the original: it is already under \(ByteCountFormatter.string(fromByteCount: t, countStyle: .file)).")
                }
                return try await finish(nil, format: format, note: "Kept the original.")
            }

        case let .pdfPages(format, scale):
            guard isPDF else { throw JobError.unsupported("\(input.lastPathComponent) is not a PDF") }
            let folder = staging.workDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let base = input.deletingPathExtension().lastPathComponent
            try PDFBackend.pages(input, format: format, scale: scale, baseName: base, into: folder,
                                 quality: policy.quality(for: format)) { page, total in
                progress(Double(page) / Double(total), "Page \(page) of \(total)")
            }
            return try await finish(folder, format: format, folder: true)

        case .extractText:
            guard isPDF else { throw JobError.unsupported("extracting text from \(input.lastPathComponent)") }
            let out = staging.scratch("txt")
            try PDFBackend.extractText(input, to: out)
            return try await finish(out, format: .txt)

        case let .compressPDF(level):
            guard isPDF else { throw JobError.unsupported("compressing \(input.lastPathComponent) as a PDF") }
            let out = staging.scratch("pdf")
            let verdict = try PDFBackend.compress(input, level: level, to: out) { page, total in
                progress(Double(page) / Double(total) * 0.9, "Page \(page) of \(total)")
            }
            switch verdict {
            case .smaller: return try await finish(out, format: .pdf)
            case .notSmaller: return try await finish(nil, format: .pdf, note: "Kept the original: the PDF is already compact.")
            case let .changed(why): return try await finish(nil, format: .pdf, note: "Kept the original: \(why).")
            }

        case let .compressOffice(level):
            guard OfficeCompressor.canCompress(input) else { throw JobError.unsupported("compressing \(input.lastPathComponent)") }
            let ext = input.pathExtension
            let out = staging.scratch(ext)
            // {format} in a naming template reads DOCX for every Office file: OutputFormat has no XLSX or PPTX.
            let verdict = try await OfficeCompressor.compress(input, level: level, workDir: staging.workDir, to: out) { progress($0, "") }
            switch verdict {
            case .smaller: return try await finish(out, format: .docx, keepExtension: ext)
            case .notSmaller: return try await finish(nil, format: .docx, note: "Kept the original: its pictures are already small.")
            }

        case let .resizePDF(spec):
            guard isPDF else { throw JobError.unsupported("resizing \(input.lastPathComponent) as a PDF") }
            let out = staging.scratch("pdf")
            try PDFBackend.resize(input, spec, to: out)
            return try await finish(out, format: .pdf)

        case let .cropPDF(rect):
            guard isPDF else { throw JobError.unsupported("cropping \(input.lastPathComponent) as a PDF") }
            let out = staging.scratch("pdf")
            try PDFBackend.crop(input, rect: rect, to: out)
            return try await finish(out, format: .pdf)

        case .splitPDF:
            guard isPDF else { throw JobError.unsupported("\(input.lastPathComponent) is not a PDF") }
            let folder = staging.workDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try PDFBackend.split(input, baseName: input.deletingPathExtension().lastPathComponent, into: folder) { page, total in
                progress(Double(page) / Double(total), "Page \(page) of \(total)")
            }
            return try await finish(folder, format: .pdf, folder: true)

        case let .trimMedia(start, end):
            guard isMedia else { throw JobError.unsupported("trimming \(input.lastPathComponent)") }
            let format = sameMediaFormat()
            let out = staging.scratch(format.fileExtension)
            if isVideo {
                try await MediaBackend.trimVideo(input, start: start, end: end, format: format, output: out, progress: mediaProgress)
            } else {
                try await MediaBackend.writeAudio([input], range: (start, end), to: format, output: out, progress: mediaProgress)
            }
            return try await finish(out, format: format)

        case let .compressMedia(level):
            guard isMedia else { throw JobError.unsupported("compressing \(input.lastPathComponent) as video or audio") }
            let format: OutputFormat = isVideo ? sameMediaFormat() : .m4a
            let out = staging.scratch(format.fileExtension)
            if isVideo {
                try await MediaBackend.compressVideo(input, level: level, format: format, output: out, progress: mediaProgress)
            } else {
                let channels = (try? await MediaBackend.audioShape(input).channels) ?? 2
                try await MediaBackend.writeAudio([input], to: .m4a, bitRate: MediaBackend.audioBitRate(level, channels: min(channels, 2)),
                                                  output: out, progress: mediaProgress)
            }
            guard Self.size(of: out) < bytesIn else {
                return try await finish(nil, format: format, note: "Kept the original: it is already as small as it gets.")
            }
            return try await finish(out, format: format)

        case .removeAudio:
            guard isVideo else { throw JobError.unsupported("removing the sound from \(input.lastPathComponent)") }
            let format = sameMediaFormat()
            let out = staging.scratch(format.fileExtension)
            try await MediaBackend.removeAudio(input, format: format, output: out, progress: mediaProgress)
            return try await finish(out, format: format)

        case let .fitTo(limit, together):
            // Together: the files share the limit in proportion to their size.
            let total = request.inputs.reduce(Int64(0)) { $0 + Self.size(of: $1) }
            let budget = together && request.inputs.count > 1 && total > 0
                ? max(1, Int64(Double(limit) * Double(bytesIn) / Double(total))) : limit
            let limitText = ByteCountFormatter.string(fromByteCount: budget, countStyle: .file)
            guard bytesIn > budget else {
                return try await finish(nil, format: .pdf, note: "Kept the original: it already fits in \(limitText).")
            }
            func over(_ url: URL) -> Bool { Self.size(of: url) > budget }
            if isImage {
                let image = try ImageInput.open(input)
                let alpha = (try? ImageOps.hasAlpha(image.upright(maxPixel: 64))) ?? false
                // It's going to someone else: JPG opens everywhere (PNG when it's see-through), never HEIC or AVIF.
                let format: OutputFormat = alpha ? .png : .jpg
                let out = staging.scratch(format.fileExtension)
                let outcome = try ImageBackend.compress(image, .targetBytes(budget), format: format, policy: policy, originalBytes: bytesIn,
                                                        output: out) { progress($0 * 0.9, "") }
                guard case let .written(shrunk) = outcome, !over(out) else {
                    throw JobError.message("Couldn't get \(input.lastPathComponent) under \(limitText).")
                }
                return try await finish(out, format: format, note: shrunk.map { "Shrunk to \(Int($0.width)) × \(Int($0.height)) to fit" })
            }
            if isPDF || OfficeCompressor.canCompress(input) {
                // The lightest level that fits; otherwise the smallest, with a note.
                var smallest: (url: URL, bytes: Int64)?
                for level in PDFCompression.allCases {
                    let ext = isPDF ? "pdf" : input.pathExtension
                    let out = staging.scratch(ext)
                    let smaller: Bool
                    if isPDF {
                        smaller = try PDFBackend.compress(input, level: level, to: out) { _, _ in } == .smaller
                    } else {
                        smaller = try await OfficeCompressor.compress(input, level: level, workDir: staging.workDir, to: out) { _ in } == .smaller
                    }
                    progress(Double(level == .light ? 1 : level == .balanced ? 2 : 3) / 3 * 0.95, "")
                    guard smaller else { continue }
                    if !over(out) {
                        return try await finish(out, format: isPDF ? .pdf : .docx, keepExtension: isPDF ? nil : ext)
                    }
                    if smallest == nil || Self.size(of: out) < smallest!.bytes { smallest = (out, Self.size(of: out)) }
                }
                if let smallest {
                    return try await finish(smallest.url, format: isPDF ? .pdf : .docx,
                                            note: "Couldn't get under \(limitText); this is as small as it goes.",
                                            keepExtension: isPDF ? nil : input.pathExtension)
                }
                throw JobError.message("Couldn't make \(input.lastPathComponent) any smaller: it's mostly text, which is already compact.")
            }
            if isMedia {
                if isVideo {
                    let format = sameMediaFormat()
                    let out = staging.scratch(format.fileExtension)
                    try await MediaBackend.fitVideo(input, bytes: budget, format: format, output: out, progress: mediaProgress)
                    let note = over(out) ? "It came out a little over \(limitText); try a smaller limit." : nil
                    return try await finish(out, format: format, note: note)
                }
                let out = staging.scratch("m4a")
                try await MediaBackend.fitAudio(input, bytes: budget, output: out, progress: mediaProgress)
                return try await finish(out, format: .m4a)
            }
            throw JobError.unsupported("shrinking \(input.lastPathComponent)")

        case .recognizeText:
            guard isImage || isPDF else { throw JobError.unsupported("reading text from \(input.lastPathComponent)") }
            progress(0.1, "Reading the text…")
            let out = staging.scratch("txt")
            let text = try TextRecognition.text(from: input, isPDF: isPDF) { page, total in
                progress(Double(page) / Double(total) * 0.95, total > 1 ? "Page \(page) of \(total)" : "")
            }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw JobError.message("No text found in \(input.lastPathComponent).")
            }
            try text.write(to: out, atomically: false, encoding: .utf8)
            return try await finish(out, format: .txt)

        case .searchablePDF:
            guard isImage || isPDF else { throw JobError.unsupported("making \(input.lastPathComponent) searchable") }
            let out = staging.scratch("pdf")
            let found = try TextRecognition.searchablePDF(from: input, isPDF: isPDF, to: out) { page, total in
                progress(Double(page) / Double(total) * 0.95, total > 1 ? "Page \(page) of \(total)" : "")
            }
            if isPDF, found == 0 {
                return try await finish(nil, format: .pdf, note: "Kept the original: it's already searchable (or has no text to find).")
            }
            return try await finish(out, format: .pdf)

        case let .protectPDF(password):
            guard isPDF else { throw JobError.unsupported("locking \(input.lastPathComponent): only PDFs take a password") }
            let out = staging.scratch("pdf")
            try PDFTools.protect(input, password: password, to: out)
            return try await finish(out, format: .pdf)

        case let .unlockPDF(password):
            guard isPDF else { throw JobError.unsupported("unlocking \(input.lastPathComponent)") }
            let out = staging.scratch("pdf")
            try PDFTools.unlock(input, password: password, to: out)
            return try await finish(out, format: .pdf)

        case let .arrangePDF(pages):
            guard isPDF else { throw JobError.unsupported("rearranging \(input.lastPathComponent)") }
            let out = staging.scratch("pdf")
            try PDFTools.arrange(input, pages: pages, to: out)
            return try await finish(out, format: .pdf)

        case let .changeSpeed(rate):
            guard isMedia else { throw JobError.unsupported("changing the speed of \(input.lastPathComponent)") }
            let format: OutputFormat = isVideo ? sameMediaFormat() : .m4a
            let out = staging.scratch(format.fileExtension)
            try await MediaBackend.changeSpeed(input, rate: rate, video: isVideo, format: format, output: out, progress: mediaProgress)
            return try await finish(out, format: format)

        case .combinePDF, .combineMedia:
            throw JobError.unsupported("combining one file")
        }
    }

    private func sameFormat(_ type: UTType) -> OutputFormat {
        if let f = Self.imageFormat(of: type), support.canWrite(f) { return f }
        return .png
    }

    // MARK: Combine

    private func combine(_ request: JobRequest, progress: @escaping @Sendable (Double, String) -> Void) async throws -> JobOutcome {
        let first = request.inputs[0]
        let staging = try Staging.make(for: first, policy: request.output)
        defer { staging.cleanup() }
        var format = OutputFormat.pdf
        let out: URL
        if request.operation == .combineMedia {
            guard request.inputs.allSatisfy({ Self.isMedia(Self.type(of: $0)) }) else {
                throw JobError.unsupported("combining these files: they must all be video or all be audio")
            }
            let video = await MediaBackend.hasVideo(first)
            format = MediaSupport.sameOrDefault(first, video: video)
            out = staging.scratch(format.fileExtension)
            let report: MediaBackend.Progress = { progress($0, "") }
            if video {
                try await MediaBackend.mergeVideos(request.inputs, format: format, output: out, progress: report)
            } else {
                try await MediaBackend.writeAudio(request.inputs, to: format, output: out, progress: report)
            }
        } else {
            out = staging.scratch("pdf")
            try PDFBackend.combine(request.inputs, to: out) { done, total in
                progress(Double(done) / Double(total), "File \(done) of \(total)")
            }
        }
        try Task.checkCancellation()
        let context = NamingContext(sourceURL: first, format: format, operation: .combine)
        let final = try await staging.publish(out, planner: planner, template: request.output.template, context: context,
                                              fallbacks: request.output.fallbackFolders, collision: request.output.collision)
        let bytesIn = request.inputs.reduce(Int64(0)) { $0 + Self.size(of: $1) }
        return JobOutcome(inputs: request.inputs, outputs: [final], bytesIn: bytesIn, bytesOut: Self.size(of: final),
                          note: nil, usedFallbackFolder: staging.usedFallback || final.deletingLastPathComponent() != staging.destination)
    }

    // MARK: Helpers

    static func type(of url: URL) -> UTType {
        (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType) ?? UTType(filenameExtension: url.pathExtension) ?? .data
    }

    /// Undoing a step drops its tag: unlocking "Contract (locked).pdf" gives
    /// "Contract (unlocked).pdf", not "Contract (locked) (unlocked).pdf".
    static func namingSource(_ input: URL, for operation: Operation) -> URL {
        let opposite: String? = switch operation {
        case .unlockPDF: " (locked)"
        case .protectPDF: " (unlocked)"
        default: nil
        }
        let stem = input.deletingPathExtension().lastPathComponent
        guard let opposite, stem.hasSuffix(opposite) else { return input }
        return input.deletingLastPathComponent().appendingPathComponent(String(stem.dropLast(opposite.count)))
            .appendingPathExtension(input.pathExtension)
    }

    /// Video or audio that AVFoundation can open on this Mac.
    static func isMedia(_ type: UTType) -> Bool {
        (type.conforms(to: .audiovisualContent) || type.conforms(to: .audio) || type.conforms(to: .movie))
            && MediaSupport.canRead(type)
    }

    static func size(of url: URL) -> Int64 {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue { return Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return items.reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    static func imageFormat(of type: UTType) -> OutputFormat? {
        OutputFormat.allCases.first { f in
            guard let id = f.imageTypeIdentifier, let t = UTType(id) else { return false }
            return type.conforms(to: t)
        }
    }
}

/// Combines per-input progress into one overall fraction.
actor ProgressTracker {
    private var fractions: [Double]
    private let report: @Sendable (JobProgress) -> Void

    init(count: Int, report: @escaping @Sendable (JobProgress) -> Void) {
        fractions = Array(repeating: 0, count: count)
        self.report = report
    }

    func update(_ index: Int, _ fraction: Double, _ detail: String) {
        guard index < fractions.count else { return }
        fractions[index] = max(fractions[index], min(fraction, 1))
        report(JobProgress(fraction: fractions.reduce(0, +) / Double(fractions.count), detail: detail))
    }
}
