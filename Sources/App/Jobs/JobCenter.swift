import AppKit
import CircularityEngine
import UniformTypeIdentifiers

/// Runs wheel choices through the engine and remembers the latest result for
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

    /// Starts a job for a wheel action, or returns why it can't run yet.
    @discardableResult
    func run(_ action: WheelAction, files: [URL]) -> String? {
        guard !files.isEmpty else { return "No files to convert" }
        guard let operation = operation(for: action, files: files) else {
            return "\(action.title) opens a dialog in the next milestone (g)"
        }
        let request = JobRequest(inputs: files, operation: operation, output: OutputPolicy())
        runningCount += 1
        onChange?()
        let id = request.id
        Log.app.notice("Job \(id.uuidString.prefix(8), privacy: .public): \(action.usageKey, privacy: .public) on \(files.count, privacy: .public) file(s)")
        tasks[id] = Task { [engine] in
            let result: Result<JobResult, Error>
            do { result = .success(try await engine.run(request)) } catch { result = .failure(error) }
            self.finish(id, result)
        }
        return nil
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
        let f = ByteCountFormatter()
        f.countStyle = .file
        if r.outputs.isEmpty { return r.notes.first ?? "Nothing was written" }
        let where_ = r.outcomes.contains(where: \.usedFallbackFolder) ? " (in Documents › Converted)" : ""
        let name = r.outputs.count == 1 ? r.outputs[0].lastPathComponent : "\(r.outputs.count) files"
        var line = "\(name) · \(f.string(fromByteCount: r.bytesOut))"
        if r.bytesIn > 0, r.outputs.count == r.outcomes.count {
            let change = Double(r.bytesOut - r.bytesIn) / Double(r.bytesIn) * 100
            line += String(format: " (%@%.0f%%)", change >= 0 ? "+" : "−", abs(change))
        }
        return line + where_
    }

    // MARK: Mapping wheel actions to engine operations

    private func operation(for action: WheelAction, files: [URL]) -> CircularityEngine.Operation? {
        switch action {
        case let .convert(format): return .convert(format)
        case let .pdfPages(format): return .pdfPages(format, scale: 2)
        case .extractText: return .extractText
        case .combinePDF: return .combinePDF
        case .compress:
            // Until the Compress dialog (g): Balanced for PDFs, quality 0.7 for images.
            let allPDF = files.allSatisfy { DraggedFiles.type(of: $0).conforms(to: .pdf) }
            return allPDF ? .compressPDF(.balanced) : .compressImage(.quality(0.7))
        case .resize, .crop, .more:
            return nil
        }
    }
}

extension WheelAction {
    var title: String {
        switch self {
        case .resize: "Resize"
        case .crop: "Crop"
        case .compress: "Compress"
        case .more: "More"
        default: "This action"
        }
    }
}
