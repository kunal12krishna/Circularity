import AppKit
import CircularityEngine
import Combine
import UniformTypeIdentifiers

/// One running job, for the panel's In progress cards and the icon's ring.
struct ActiveJob: Identifiable, Equatable {
    let id: UUID
    let title: String
    let firstInput: URL?
    let isPDF: Bool
    let started: Date
    var fraction: Double
    var detail: String

    /// "71 % · Page 31 of 44 · about 9 s left"
    var meta: String {
        var parts = ["\(Int((fraction * 100).rounded())) %"]
        if !detail.isEmpty { parts.append(detail) }
        let elapsed = Date().timeIntervalSince(started)
        if fraction > 0.05, elapsed > 1 {
            let left = elapsed * (1 - fraction) / fraction
            parts.append(left < 60 ? "about \(max(1, Int(left))) s left" : "about \(Int(left / 60) + 1) min left")
        }
        return parts.joined(separator: " · ")
    }
}

/// Runs conversions, tracks progress, and records results in History and Stats.
final class JobCenter: ObservableObject {
    private let engine = ConversionEngine()
    private let settings: SettingsStore
    let history: HistoryStore
    let stats: StatsStore
    private var tasks: [UUID: Task<Void, Never>] = [:]

    @Published private(set) var active: [ActiveJob] = []
    @Published private(set) var lastSummary: String?
    @Published private(set) var lastOutputs: [URL] = []
    /// Set by a failure; cleared when the panel is opened (icon error badge).
    @Published var lastError: String?
    /// Fires when a job finishes successfully (icon "done" pulse).
    let finished = PassthroughSubject<Void, Never>()
    /// Every finished job with its result (notifications).
    let completed = PassthroughSubject<(title: String, result: Result<JobResult, Error>, interactive: Bool), Never>()
    /// Milestones just reached (ids), for the panel banner and a notification.
    let milestones = PassthroughSubject<[String], Never>()

    var runningCount: Int { active.count }
    var overallProgress: Double? { active.isEmpty ? nil : active.map(\.fraction).reduce(0, +) / Double(active.count) }

    init(settings: SettingsStore, history: HistoryStore = HistoryStore(), stats: StatsStore = StatsStore()) {
        self.settings = settings
        self.history = history
        self.stats = stats
    }

    /// Wheel actions that run straight away (formats, pages, text, combine,
    /// saved buttons). Tools with dialogs are opened by the coordinator.
    @discardableResult
    func run(_ action: WheelAction, files: [URL]) -> String? {
        guard let operation = operation(for: action) else { return "\(action.usageKey) needs a dialog" }
        run(operation, files: files, label: action.usageKey)
        return nil
    }

    /// `policy` nil = Settings → Output. `interactive` jobs (the wheel, the
    /// panel, ⌘K, Services) also run the after-conversion actions; watch
    /// folders and the clipboard pass false and handle their own results.
    func run(_ operation: CircularityEngine.Operation, files: [URL], label: String, policy: OutputPolicy? = nil,
             interactive: Bool = true, completion: ((Result<JobResult, Error>) -> Void)? = nil) {
        guard !files.isEmpty else { return }
        // Practice pictures: results next to them, no after-actions.
        let practice = PracticeFiles.all(files)
        let interactive = interactive && !practice
        let request = JobRequest(inputs: files, operation: operation,
                                 output: policy ?? (practice ? OutputPolicy() : outputPolicy(for: operation)))
        let id = request.id
        let job = ActiveJob(id: id, title: Self.title(operation, files: files), firstInput: files.first,
                            isPDF: files.first.map { DraggedFiles.type(of: $0).conforms(to: .pdf) } ?? false,
                            started: Date(), fraction: 0, detail: "")
        active.append(job)
        Log.app.notice("Job \(id.uuidString.prefix(8), privacy: .public): \(label, privacy: .public) on \(files.count, privacy: .public) file(s)")
        tasks[id] = Task { [engine] in
            let result: Result<JobResult, Error>
            do {
                result = .success(try await engine.run(request) { progress in
                    Task { @MainActor in self.update(id, progress) }
                })
            } catch { result = .failure(error) }
            self.finish(id, operation: operation, result, record: !practice)
            if interactive, case let .success(r) = result { self.afterConversion(r) }
            self.completed.send((Self.title(operation, files: files), result, interactive))
            completion?(result)
        }
    }

    func cancel(_ id: UUID) { tasks[id]?.cancel() }

    /// For --render-previews: show a job card without running anything.
    func injectPreviewJob(_ job: ActiveJob) { active.append(job) }
    func cancelAll() { for task in tasks.values { task.cancel() } }

    func revealLast() {
        guard !lastOutputs.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(lastOutputs)
    }

    private func update(_ id: UUID, _ progress: JobProgress) {
        guard let i = active.firstIndex(where: { $0.id == id }) else { return }
        active[i].fraction = progress.fraction
        if !progress.detail.isEmpty { active[i].detail = progress.detail }
    }

    private func finish(_ id: UUID, operation: CircularityEngine.Operation, _ result: Result<JobResult, Error>, record shouldRecord: Bool) {
        tasks[id] = nil
        active.removeAll { $0.id == id }
        switch result {
        case let .success(r):
            lastOutputs = r.outputs
            lastSummary = Self.summary(r)
            if shouldRecord {
                record(r, operation: operation)
                checkMilestones()
            }
            if !r.outputs.isEmpty { finished.send() }
            Log.app.notice("Job \(id.uuidString.prefix(8), privacy: .public) done: \(r.outputs.count, privacy: .public) output(s), \(r.bytesIn, privacy: .public) → \(r.bytesOut, privacy: .public) bytes")
        case let .failure(error) where error is CancellationError:
            lastSummary = "Cancelled (nothing was written)"
        case let .failure(error):
            lastSummary = "Failed: \(error.localizedDescription)"
            lastError = error.localizedDescription
            Log.app.error("Job \(id.uuidString.prefix(8), privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
        if active.isEmpty { MemoryFootprint.relieve() }
    }

    private func checkMilestones() {
        let celebrated = settings.value(SettingsKeys.milestones)
        let fresh = Milestone.new(files: stats.allTimeFiles, saved: stats.allTimeSaved, celebrated: celebrated)
        // Everything reached so far counts as celebrated, so lower ones never pop later.
        let reached = Milestone.reached(files: stats.allTimeFiles, saved: stats.allTimeSaved)
        let union = Array(Set(celebrated).union(reached)).sorted()
        if union != celebrated.sorted() { settings.set(union, for: SettingsKeys.milestones) }
        if !fresh.isEmpty { milestones.send(fresh) }
    }

    private func record(_ r: JobResult, operation: CircularityEngine.Operation) {
        for outcome in r.outcomes where !outcome.outputs.isEmpty {
            let from = outcome.inputs.first?.pathExtension.uppercased() ?? ""
            let to = outcome.outputs.first?.pathExtension.uppercased() ?? ""
            let label: String = switch operation.kind {
            case .convert, .pdfToImages, .extractText, .renderDocument: "\(from) → \(to.isEmpty ? "folder" : to)"
            case .resize: "Resized"
            case .compress: "Compressed"
            case .crop: "Cropped"
            case .combine: "Combined \(outcome.inputs.count) files"
            case .cutout: "Cut out"
            }
            history.add(HistoryItem(id: UUID().uuidString, date: Date(), inputs: outcome.inputs.map(\.path),
                                    outputs: outcome.outputs.map(\.path), bytesIn: outcome.bytesIn, bytesOut: outcome.bytesOut,
                                    label: label, format: to.isEmpty ? "PNG" : to))
            stats.record(files: outcome.inputs.count, bytesIn: outcome.bytesIn, bytesOut: outcome.bytesOut, format: to.isEmpty ? "PNG" : to)
        }
    }

    static func title(_ operation: CircularityEngine.Operation, files: [URL]) -> String {
        let name = files.count == 1 ? files[0].lastPathComponent : "\(files.count) files"
        let target: String = switch operation {
        case let .convert(f): f.displayName
        case let .pdfPages(f, _): "\(f.displayName) pages"
        case .extractText: "TXT"
        case .combinePDF: "PDF (combined)"
        case .resize, .resizePDF: "Resize"
        case .compressImage: "Compress"
        case let .compressPDF(level), let .compressOffice(level): "Compress · \(level.rawValue)"
        case .removeBackground: "Cut out"
        case .cropImage, .cropPDF: "Crop"
        }
        return "\(name) → \(target)"
    }

    static func summary(_ r: JobResult) -> String {
        if r.outputs.isEmpty { return r.notes.first ?? "Nothing was written" }
        let folder = r.outputs.first?.deletingLastPathComponent().lastPathComponent ?? "Converted"
        let where_ = r.outcomes.contains(where: \.usedFallbackFolder) ? " (saved in \(folder): the original folder was off-limits)" : ""
        let name = r.outputs.count == 1 ? r.outputs[0].lastPathComponent : "\(r.outputs.count) files"
        var line = "\(name) · \(Bytes.text(r.bytesOut))"
        if r.bytesIn > 0, r.outputs.count == r.outcomes.count { line += " (\(Bytes.change(from: r.bytesIn, to: r.bytesOut)))" }
        if r.outputs.count == 1, DraggedFiles.type(of: r.outputs[0]).conforms(to: .image), let px = Thumbnails.pixelSize(r.outputs[0]) {
            line += " · \(Int(px.width)) × \(Int(px.height))"
        }
        if let note = r.notes.first { line += " — \(note)" }
        return line + where_
    }

    // MARK: Settings → Output

    /// The output policy from Settings → Output for an operation.
    func outputPolicy(for operation: CircularityEngine.Operation) -> OutputPolicy {
        var policy = OutputPolicy()
        if settings.value(SettingsKeys.destination) == "folder" {
            let perType: String = switch Self.outputGroup(operation) {
            case .images: settings.value(SettingsKeys.folderImages)
            case .pdfs: settings.value(SettingsKeys.folderPDFs)
            case .documents: settings.value(SettingsKeys.folderDocuments)
            }
            let path = perType.isEmpty ? settings.value(SettingsKeys.outputFolder) : perType
            if !path.isEmpty { policy.destination = .folder(URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)) }
        }
        let template = settings.value(SettingsKeys.namingTemplate).trimmingCharacters(in: .whitespaces)
        policy.template = template.isEmpty ? .default : NamingTemplate(template)
        policy.collision = settings.value(SettingsKeys.collisionStyle) == "time" ? .timestamp : .number
        policy.metadata = MetadataPolicy(rawValue: settings.value(SettingsKeys.metadata)) ?? .keep
        func q(_ key: SettingsKey<Double>) -> Double { min(1, max(0.1, settings.value(key))) }
        policy.quality = [.jpg: q(SettingsKeys.qualityJPG), .heic: q(SettingsKeys.qualityHEIC),
                          .avif: q(SettingsKeys.qualityAVIF), .webp: q(SettingsKeys.qualityWebP)]
        return policy
    }

    enum OutputGroup { case images, pdfs, documents }

    static func outputGroup(_ operation: CircularityEngine.Operation) -> OutputGroup {
        switch operation {
        case let .convert(f): f == .pdf ? .pdfs : (f.imageTypeIdentifier != nil ? .images : .documents)
        case .pdfPages, .resize, .compressImage, .cropImage, .removeBackground: .images
        case .combinePDF, .resizePDF, .compressPDF, .cropPDF: .pdfs
        case .extractText, .compressOffice: .documents
        }
    }

    /// Open / reveal / copy, and "replace the original" (to the Trash).
    private func afterConversion(_ r: JobResult) {
        guard !r.outputs.isEmpty else { return }
        if settings.value(SettingsKeys.replaceOriginal) {
            // Only one-to-one results; a combined PDF never trashes its inputs.
            for outcome in r.outcomes where outcome.inputs.count == 1 && outcome.outputs.count == 1 {
                let input = outcome.inputs[0], output = outcome.outputs[0]
                // A PDF split into a folder of pages is not "one new file": keep the original.
                let isFile = (try? output.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                guard isFile, output.standardizedFileURL != input.standardizedFileURL,
                      FileManager.default.fileExists(atPath: input.path) else { continue }
                do {
                    try FileManager.default.trashItem(at: input, resultingItemURL: nil)
                } catch {
                    Log.app.error("Couldn't move the original to the Trash: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        if settings.value(SettingsKeys.afterCopy) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects(r.outputs as [NSURL])
        }
        if settings.value(SettingsKeys.afterReveal) { NSWorkspace.shared.activateFileViewerSelecting(r.outputs) }
        if settings.value(SettingsKeys.afterOpen) {
            // A batch could be hundreds of files: open at most five.
            for url in r.outputs.prefix(5) { NSWorkspace.shared.open(url) }
        }
    }

    // MARK: Presets ("Also add this as a button")

    var presets: [Preset] { Preset.decodeList(settings.value(SettingsKeys.presetsJSON)) }

    func addPreset(_ preset: Preset) {
        var list = presets
        list.removeAll { $0.name == preset.name && $0.applies == preset.applies }
        list.insert(preset, at: 0)
        settings.set(Preset.encodeList(list), for: SettingsKeys.presetsJSON)
        objectWillChange.send()
        Log.app.notice("Saved a wheel button: \(preset.name, privacy: .public)")
    }

    func removePreset(id: String) {
        settings.set(Preset.encodeList(presets.filter { $0.id != id }), for: SettingsKeys.presetsJSON)
        objectWillChange.send()
    }

    // MARK: Mapping

    private func operation(for action: WheelAction) -> CircularityEngine.Operation? {
        switch action {
        case let .convert(format): .convert(format)
        case let .pdfPages(format): .pdfPages(format, scale: 2)
        case .extractText: .extractText
        case .combinePDF: .combinePDF
        case .cutout: .removeBackground
        case let .preset(id): presets.first { $0.id == id }?.operation
        case .compress, .resize, .crop, .more: nil
        }
    }

    /// Runs a ⌘K command on files.
    func run(_ command: Command, files: [URL]) {
        switch command {
        case let .convert(f): run(.convert(f), files: files, label: "command.convert")
        case let .compressUnder(bytes): run(.compressImage(.targetBytes(bytes)), files: files, label: "command.compress")
        case let .resizeWidth(w): run(.resize(ResizeSpec(width: w, height: nil)), files: files, label: "command.resize")
        case .combine: run(.combinePDF, files: files, label: "command.combine")
        case .stripGPS:
            // Same format, location removed.
            var policy = outputPolicy(for: .convert(.png))
            policy.metadata = .stripGPS
            for file in files {
                run(.convert(ConversionEngine.sameFormat(for: file)), files: [file], label: "command.nogps", policy: policy)
            }
        default: break
        }
    }
}
