import AppKit
import CircularityEngine
import UniformTypeIdentifiers

/// Runs conversions through the engine and remembers the latest result for
/// the menu (the panel's In progress / Recent sections arrive in milestone h).
final class JobCenter {
    private let engine = ConversionEngine()
    private let settings: SettingsStore
    private var tasks: [UUID: Task<Void, Never>] = [:]

    /// Called whenever running jobs or the last result change.
    var onChange: (() -> Void)?

    private(set) var runningCount = 0
    private(set) var lastSummary: String?
    private(set) var lastOutputs: [URL] = []

    init(settings: SettingsStore) {
        self.settings = settings
    }

    /// Wheel actions that run straight away (formats, pages, text, combine,
    /// saved buttons). Tools with dialogs are opened by the coordinator.
    @discardableResult
    func run(_ action: WheelAction, files: [URL]) -> String? {
        guard let operation = operation(for: action) else { return "\(action.usageKey) needs a dialog" }
        run(operation, files: files, label: action.usageKey)
        return nil
    }

    func run(_ operation: CircularityEngine.Operation, files: [URL], label: String) {
        guard !files.isEmpty else { return }
        let request = JobRequest(inputs: files, operation: operation, output: OutputPolicy())
        runningCount += 1
        onChange?()
        let id = request.id
        Log.app.notice("Job \(id.uuidString.prefix(8), privacy: .public): \(label, privacy: .public) on \(files.count, privacy: .public) file(s)")
        tasks[id] = Task { [engine] in
            let result: Result<JobResult, Error>
            do { result = .success(try await engine.run(request)) } catch { result = .failure(error) }
            self.finish(id, result)
        }
    }

    func cancelAll() {
        for task in tasks.values { task.cancel() }
    }

    func revealLast() {
        guard !lastOutputs.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(lastOutputs)
    }

    private func finish(_ id: UUID, _ result: Result<JobResult, Error>) {
        tasks[id] = nil
        runningCount -= 1
        switch result {
        case let .success(r):
            lastOutputs = r.outputs
            lastSummary = Self.summary(r)
            Log.app.notice("Job \(id.uuidString.prefix(8), privacy: .public) done: \(r.outputs.count, privacy: .public) output(s), \(r.bytesIn, privacy: .public) → \(r.bytesOut, privacy: .public) bytes")
        case let .failure(error) where error is CancellationError:
            lastSummary = "Cancelled (nothing was written)"
        case let .failure(error):
            lastSummary = "Failed: \(error.localizedDescription)"
            Log.app.error("Job \(id.uuidString.prefix(8), privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
        onChange?()
        if runningCount == 0 { MemoryFootprint.relieve() }
    }

    static func summary(_ r: JobResult) -> String {
        if r.outputs.isEmpty { return r.notes.first ?? "Nothing was written" }
        let folder = r.outputs.first?.deletingLastPathComponent().lastPathComponent ?? "Converted"
        let where_ = r.outcomes.contains(where: \.usedFallbackFolder) ? " (saved in \(folder): the original folder was off-limits)" : ""
        let name = r.outputs.count == 1 ? r.outputs[0].lastPathComponent : "\(r.outputs.count) files"
        var line = "\(name) · \(Bytes.text(r.bytesOut))"
        if r.bytesIn > 0, r.outputs.count == r.outcomes.count { line += " (\(Bytes.change(from: r.bytesIn, to: r.bytesOut)))" }
        return line + where_
    }

    // MARK: Presets ("Also add this as a button")

    var presets: [Preset] { Preset.decodeList(settings.value(SettingsKeys.presetsJSON)) }

    func addPreset(_ preset: Preset) {
        var list = presets
        list.removeAll { $0.name == preset.name && $0.applies == preset.applies }
        list.insert(preset, at: 0)
        settings.set(Preset.encodeList(list), for: SettingsKeys.presetsJSON)
        Log.app.notice("Saved a wheel button: \(preset.name, privacy: .public)")
    }

    func removePreset(id: String) {
        settings.set(Preset.encodeList(presets.filter { $0.id != id }), for: SettingsKeys.presetsJSON)
    }

    // MARK: Mapping

    private func operation(for action: WheelAction) -> CircularityEngine.Operation? {
        switch action {
        case let .convert(format): .convert(format)
        case let .pdfPages(format): .pdfPages(format, scale: 2)
        case .extractText: .extractText
        case .combinePDF: .combinePDF
        case let .preset(id): presets.first { $0.id == id }?.operation
        case .compress, .resize, .crop, .more: nil
        }
    }
}
