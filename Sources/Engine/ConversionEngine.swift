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
        if request.operation == .combinePDF {
            let outcome = try await queue.run {
                try await self.combine(request, progress: { progress(JobProgress(fraction: $0, detail: $1)) })
            }
            return JobResult(outcomes: [outcome])
        }
        let tracker = ProgressTracker(count: request.inputs.count, report: progress)
        let outcomes = try await withThrowingTaskGroup(of: (Int, JobOutcome).self) { group in
            for (i, input) in request.inputs.enumerated() {
                group.addTask {
                    try await self.queue.run {
                        let outcome = try await self.process(input, request: request) { fraction, detail in
                            Task { await tracker.update(i, fraction, detail) }
                        }
                        await tracker.update(i, 1, "")
                        return (i, outcome)
                    }
                }
            }
            var collected: [(Int, JobOutcome)] = []
            for try await item in group { collected.append(item) }
            return collected.sorted { $0.0 < $1.0 }.map(\.1)
        }
        return JobResult(outcomes: outcomes)
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
        var context = NamingContext(sourceURL: input, format: .png, operation: request.operation.kind)

        func finish(_ staged: URL?, format: OutputFormat, note: String? = nil, folder: Bool = false) async throws -> JobOutcome {
            try Task.checkCancellation()
            guard let staged else {
                return JobOutcome(inputs: [input], outputs: [], bytesIn: bytesIn, bytesOut: 0, note: note,
                                  usedFallbackFolder: staging.usedFallback)
            }
            context.format = format
            let final = try await staging.publish(staged, planner: planner, template: policy.template, context: context,
                                                  fileExtension: folder ? "" : nil, fallbacks: policy.fallbackFolders,
                                                  collision: policy.collision)
            return JobOutcome(inputs: [input], outputs: [final], bytesIn: bytesIn, bytesOut: Self.size(of: final), note: note,
                              usedFallbackFolder: staging.usedFallback || final.deletingLastPathComponent() != staging.destination)
        }

        let isPDF = type.conforms(to: .pdf)
        let isImage = type.conforms(to: .image) && !isPDF
        progress(0.05, "")

        switch request.operation {
        case let .convert(format):
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

        case .combinePDF:
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
        let out = staging.scratch("pdf")
        try PDFBackend.combine(request.inputs, to: out) { done, total in
            progress(Double(done) / Double(total), "File \(done) of \(total)")
        }
        try Task.checkCancellation()
        let context = NamingContext(sourceURL: first, format: .pdf, operation: .combine)
        let final = try await staging.publish(out, planner: planner, template: request.output.template, context: context,
                                              fallbacks: request.output.fallbackFolders, collision: request.output.collision)
        let bytesIn = request.inputs.reduce(Int64(0)) { $0 + Self.size(of: $1) }
        return JobOutcome(inputs: request.inputs, outputs: [final], bytesIn: bytesIn, bytesOut: Self.size(of: final),
                          note: nil, usedFallbackFolder: staging.usedFallback)
    }

    // MARK: Helpers

    static func type(of url: URL) -> UTType {
        (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType) ?? UTType(filenameExtension: url.pathExtension) ?? .data
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
