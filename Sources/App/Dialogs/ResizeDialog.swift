import CircularityEngine
import SwiftUI

/// Resize (BRIEF.md): images by width × height, keeping the aspect (fit) or
/// stretching; PDFs by scale or to A4/Letter. Shows the resulting size.
struct ResizeDialog: View {
    let files: [URL]
    let isPDF: Bool
    let accent: Color
    let onRun: (CircularityEngine.Operation, Preset?) -> Void
    let onCancel: () -> Void

    @State private var source = CGSize(width: 0, height: 0)
    @State private var widthText = ""
    @State private var heightText = ""
    @State private var keepAspect = true
    @State private var pdfByPaper = false
    @State private var scaleText = "50"
    @State private var paper = PaperSize.regional
    @State private var addButton = false
    @State private var estimate = ""
    @State private var estimateTask: Task<Void, Never>?
    @State private var syncing = false

    private var subtitle: String {
        let what = files.count == 1 ? files[0].lastPathComponent : "\(files.count) \(isPDF ? "PDFs" : "images")"
        guard source.width > 0 else { return what }
        return "\(what) · \(Int(source.width)) × \(Int(source.height)) \(isPDF ? "pt" : "px")"
    }
    private var width: Int? { Int(widthText).flatMap { $0 > 0 ? $0 : nil } }
    private var height: Int? { Int(heightText).flatMap { $0 > 0 ? $0 : nil } }
    private var scale: Double? { Double(scaleText).flatMap { $0 > 0 && $0 <= 800 ? $0 / 100 : nil } }

    private var target: CGSize? {
        guard source.width > 0 else { return nil }
        if isPDF {
            if pdfByPaper { return paper.size }
            return scale.map { CGSize(width: source.width * $0, height: source.height * $0) }
        }
        guard width != nil || height != nil else { return nil }
        return ResizeMath.targetSize(source: source, spec: spec)
    }
    private var spec: ResizeSpec {
        keepAspect ? ResizeSpec(width: width, height: height, mode: .fit) : ResizeSpec(width: width, height: height, mode: .stretch)
    }

    var body: some View {
        DialogFrame(title: "Resize", subtitle: subtitle, accent: accent, primaryTitle: "Resize",
                    primaryEnabled: target != nil, addButton: $addButton, onPrimary: run, onCancel: onCancel) {
            if isPDF { pdfOptions } else { imageOptions }
        }
        .onAppear(perform: load)
        .onDisappear { estimateTask?.cancel() }
    }

    private var imageOptions: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .bottom, spacing: 10) {
                NumberField(label: "Width", text: $widthText, unit: "px")
                    .onChange(of: widthText) { _ in followAspect(fromWidth: true) }
                Button { keepAspect.toggle(); followAspect(fromWidth: true) } label: {
                    Image(systemName: keepAspect ? "link" : "link.badge.plus")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(keepAspect ? accent : Halo.secondary)
                        .frame(width: 36, height: 36)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Halo.control))
                }
                .buttonStyle(.plain)
                .help(keepAspect ? "Keeping the aspect ratio" : "Stretching to exactly this size")
                .accessibilityLabel(keepAspect ? "Keep aspect ratio, on" : "Keep aspect ratio, off")
                NumberField(label: "Height", text: $heightText, unit: "px")
                    .onChange(of: heightText) { _ in followAspect(fromWidth: false) }
            }
            HStack(spacing: 6) {
                ForEach(["50%", "25%", "1920w", "1280w", "1080²", "4K"], id: \.self) { name in
                    Chip(title: name, accent: accent) { applyChip(name) }
                }
            }
            resultLine
        }
    }

    private var pdfOptions: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Chip(title: "SCALE", selected: !pdfByPaper, accent: accent) { pdfByPaper = false }
                Chip(title: "PAPER", selected: pdfByPaper, accent: accent) { pdfByPaper = true }
            }
            if pdfByPaper {
                HStack(spacing: 8) {
                    Chip(title: "A4", selected: paper == .a4, accent: accent) { paper = .a4 }
                    Chip(title: "LETTER", selected: paper == .letter, accent: accent) { paper = .letter }
                }
                Text("Each page is fitted onto the paper, centred, keeping its orientation.")
                    .font(Halo.rounded(11)).foregroundStyle(Halo.secondary)
            } else {
                HStack(alignment: .bottom, spacing: 8) {
                    NumberField(label: "Scale", text: $scaleText, unit: "%")
                    ForEach(["50", "75", "150"], id: \.self) { v in
                        Chip(title: "\(v)%", selected: scaleText == v, accent: accent) { scaleText = v }
                    }
                }
            }
            resultLine
        }
    }

    private var resultLine: some View {
        let text: String = {
            guard let t = target else { return "Type a width or a height" }
            let unit = isPDF ? "pt" : "px"
            var s = "\(Int(t.width.rounded())) × \(Int(t.height.rounded())) \(unit)"
            if !estimate.isEmpty { s += " · \(estimate)" }
            if files.count > 1 { s += isPDF ? " (first PDF)" : (keepAspect ? " · each image fits inside" : " · every image") }
            return s
        }()
        return Text(text).font(Halo.rounded(13, .semibold)).foregroundStyle(Halo.text)
            .padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Halo.card))
    }

    private func load() {
        guard let url = files.first else { return }
        if isPDF {
            source = Thumbnails.pdfPage(url, maxPixel: 64)?.size ?? .zero
        } else if let size = Thumbnails.pixelSize(url) {
            source = size
            syncing = true
            widthText = "\(Int(size.width))"
            heightText = "\(Int(size.height))"
            syncing = false
        }
    }

    private func followAspect(fromWidth: Bool) {
        guard !syncing, keepAspect, source.width > 0, source.height > 0 else { refreshEstimate(); return }
        syncing = true
        if fromWidth, let w = width {
            heightText = "\(max(1, Int((Double(w) * source.height / source.width).rounded())))"
        } else if !fromWidth, let h = height {
            widthText = "\(max(1, Int((Double(h) * source.width / source.height).rounded())))"
        }
        syncing = false
        refreshEstimate()
    }

    private func applyChip(_ name: String) {
        guard source.width > 0 else { return }
        keepAspect = true
        switch name {
        case "50%": widthText = "\(Int(source.width / 2))"
        case "25%": widthText = "\(Int(source.width / 4))"
        case "1920w": widthText = "1920"
        case "1280w": widthText = "1280"
        case "4K": widthText = "3840"
        case "1080²":
            keepAspect = false
            syncing = true
            widthText = "1080"
            heightText = "1080"
            syncing = false
        default: break
        }
        followAspect(fromWidth: true)
    }

    private func refreshEstimate() {
        guard !isPDF, let url = files.first, let t = target else { estimate = ""; return }
        estimateTask?.cancel()
        let format = ConversionEngine.sameFormat(for: url)
        estimateTask = Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            let bytes = await Task.detached(priority: .userInitiated) {
                SizeEstimator.estimate(url, format: format, quality: OutputPolicy.defaultQuality[format] ?? 0.85, pixels: t)
            }.value
            guard !Task.isCancelled else { return }
            estimate = bytes.map { "about \(Bytes.text($0))" } ?? ""
        }
    }

    private func run() {
        if isPDF {
            if pdfByPaper {
                onRun(.resizePDF(.paper(paper)), addButton ? Preset(applies: .pdfs, action: .resizePDFPaper(paper)) : nil)
            } else if let s = scale {
                onRun(.resizePDF(.scale(s)), addButton ? Preset(applies: .pdfs, action: .resizePDFScale(s)) : nil)
            }
            return
        }
        guard width != nil || height != nil else { return }
        // Saved buttons keep the aspect by width ("1920w"), or exact size when stretching.
        let action: Preset.Action = keepAspect ? .resize(width: width, height: nil, stretch: false)
            : .resize(width: width, height: height, stretch: true)
        onRun(.resize(spec), addButton ? Preset(applies: .images, action: action) : nil)
    }
}
