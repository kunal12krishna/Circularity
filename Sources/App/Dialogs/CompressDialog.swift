import CircularityEngine
import SwiftUI

/// Compress (BRIEF.md): images by quality or target size with a live estimate;
/// PDFs Light / Balanced / Strong with page-by-page verification.
struct CompressDialog: View {
    enum Mode { case quality, target }

    let files: [URL]
    let isPDF: Bool
    let accent: Color
    let onRun: (CircularityEngine.Operation, Preset?) -> Void
    let onCancel: () -> Void
    /// Read once, not on every render (each slider tick re-renders).
    private let totalBytes: Int64
    private let outputFormat: OutputFormat

    init(files: [URL], isPDF: Bool, accent: Color, onRun: @escaping (CircularityEngine.Operation, Preset?) -> Void,
         onCancel: @escaping () -> Void) {
        self.files = files
        self.isPDF = isPDF
        self.accent = accent
        self.onRun = onRun
        self.onCancel = onCancel
        totalBytes = files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        outputFormat = files.first.map { ConversionEngine.compressedFormat(for: $0) } ?? .jpg
    }

    @State private var mode = Mode.quality
    @State private var quality = 70.0
    @State private var targetText = "2"
    @State private var targetInMB = true
    @State private var level = PDFCompression.balanced
    @State private var addButton = false
    @State private var estimate = "estimating…"
    @State private var estimateTask: Task<Void, Never>?

    private var subtitle: String {
        let what = files.count == 1 ? files[0].lastPathComponent : "\(files.count) \(isPDF ? "PDFs" : "images")"
        return "\(what) · \(Bytes.text(totalBytes))"
    }
    private var targetBytes: Int64? {
        guard let v = Double(targetText.replacingOccurrences(of: ",", with: ".")), v > 0 else { return nil }
        return Int64(v * (targetInMB ? 1_000_000 : 1_000))
    }

    var body: some View {
        DialogFrame(title: "Compress", subtitle: subtitle, accent: accent, primaryTitle: "Compress",
                    primaryEnabled: isPDF || mode == .quality || targetBytes != nil, addButton: $addButton,
                    onPrimary: run, onCancel: onCancel) {
            if isPDF { pdfOptions } else { imageOptions }
        }
        .onAppear(perform: refreshEstimate)
        .onDisappear { estimateTask?.cancel() }
    }

    private var imageOptions: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Chip(title: "QUALITY", selected: mode == .quality, accent: accent) { mode = .quality; refreshEstimate() }
                Chip(title: "TARGET SIZE", selected: mode == .target, accent: accent) { mode = .target }
            }
            if mode == .quality {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        SectionLabel(text: "Quality")
                        Spacer()
                        Text("\(Int(quality))%").font(Halo.mono(16)).foregroundStyle(Halo.text)
                    }
                    Slider(value: Binding(get: { quality }, set: { quality = $0.rounded() }), in: 10...100) { Text("Quality") }
                        .labelsHidden()
                        .tint(accent)
                        .onChange(of: quality) { _ in refreshEstimate() }
                    resultLine(estimate)
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .bottom, spacing: 8) {
                        NumberField(label: "Under", text: $targetText)
                        Chip(title: "MB", selected: targetInMB, accent: accent) { targetInMB = true }
                        Chip(title: "KB", selected: !targetInMB, accent: accent) { targetInMB = false }
                    }
                    HStack(spacing: 6) {
                        ForEach([("500 KB", "500", false), ("1 MB", "1", true), ("2 MB", "2", true), ("5 MB", "5", true)], id: \.0) { item in
                            Chip(title: item.0, selected: targetText == item.1 && targetInMB == item.2, accent: accent) {
                                targetText = item.1
                                targetInMB = item.2
                            }
                        }
                    }
                    resultLine("Highest quality that fits; shrinks the image only if it must")
                }
            }
            Text("Saves as \(outputFormat.displayName) next to the original.")
                .font(Halo.rounded(11)).foregroundStyle(Halo.secondary)
        }
    }

    private var pdfOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(PDFCompression.allCases, id: \.self) { option in
                Button { level = option } label: {
                    HStack(spacing: 12) {
                        Text(option.rawValue.uppercased()).font(Halo.mono(13)).frame(width: 96, alignment: .leading)
                        Text(Self.describe(option)).font(Halo.rounded(12)).foregroundStyle(level == option ? Halo.background : Halo.secondary)
                        Spacer()
                    }
                    .foregroundStyle(level == option ? Halo.background : Halo.text)
                    .padding(.horizontal, 14).frame(height: 44)
                    .background(RoundedRectangle(cornerRadius: 10).fill(level == option ? accent : Halo.control))
                    .shadow(color: level == option ? accent.opacity(0.4) : .clear, radius: 8)
                }
                .buttonStyle(.plain)
            }
            Text("Only embedded images are recompressed. Every page is checked against the original; if anything would change, the original is kept.")
                .font(Halo.rounded(11)).foregroundStyle(Halo.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    static func describe(_ level: PDFCompression) -> String {
        switch level {
        case .light: "barely visible, 200 dpi images"
        case .balanced: "good for sharing, 150 dpi"
        case .strong: "smallest, 110 dpi"
        }
    }

    private func resultLine(_ text: String) -> some View {
        Text(text).font(Halo.rounded(13, .semibold)).foregroundStyle(Halo.text)
            .padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Halo.card))
    }

    private func refreshEstimate() {
        guard !isPDF, mode == .quality, let url = files.first else { return }
        estimateTask?.cancel()
        let q = quality / 100, format = outputFormat
        let original = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let many = files.count > 1
        estimateTask = Task {
            try? await Task.sleep(nanoseconds: 150_000_000) // debounce the slider
            guard !Task.isCancelled else { return }
            let bytes = await Task.detached(priority: .userInitiated) {
                SizeEstimator.estimate(url, format: format, quality: q)
            }.value
            guard !Task.isCancelled else { return }
            if let bytes {
                estimate = "about \(Bytes.text(bytes)) (\(Bytes.change(from: original, to: bytes)))\(many ? " for the first image" : "")"
            } else {
                estimate = "no estimate for this file"
            }
        }
    }

    private func run() {
        let operation: CircularityEngine.Operation
        let preset: Preset.Action
        if isPDF {
            operation = .compressPDF(level)
            preset = .compressPDF(level)
        } else if mode == .quality {
            operation = .compressImage(.quality(quality / 100))
            preset = .compressQuality(quality / 100)
        } else {
            guard let bytes = targetBytes else { return }
            operation = .compressImage(.targetBytes(bytes))
            preset = .compressTarget(bytes)
        }
        onRun(operation, addButton ? Preset(applies: isPDF ? .pdfs : .images, action: preset) : nil)
    }
}
