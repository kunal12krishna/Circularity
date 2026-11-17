import CircularityEngine
import SwiftUI

/// Interactive crop (BRIEF.md): a movable, resizable box with ratio locks
/// 1:1, 4:3, 3:2, 16:9, 9:16 and free. PDFs crop every page the same way.
struct CropDialog: View {
    struct Ratio: Hashable {
        let title: String
        let value: CGFloat?
        static let all = [Ratio(title: "FREE", value: nil), Ratio(title: "1:1", value: 1), Ratio(title: "4:3", value: 4.0 / 3),
                          Ratio(title: "3:2", value: 3.0 / 2), Ratio(title: "16:9", value: 16.0 / 9), Ratio(title: "9:16", value: 9.0 / 16)]
    }

    let files: [URL]
    let isPDF: Bool
    let accent: Color
    let onRun: (CircularityEngine.Operation, Preset?) -> Void
    let onCancel: () -> Void

    @State private var preview: CGImage?
    @State private var sourceSize = CGSize(width: 1, height: 1)
    @State private var rect = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
    @State private var ratio = Ratio.all[0]
    @State private var active: (handle: CropMath.Handle, start: CGRect)?

    private var aspect: CGFloat { sourceSize.width / max(sourceSize.height, 1) }
    private var subtitle: String {
        let what = files.count == 1 ? files[0].lastPathComponent : "\(files.count) \(isPDF ? "PDFs" : "images") (same crop for all)"
        let unit = isPDF ? "pt" : "px"
        return "\(what) · \(Int((rect.width * sourceSize.width).rounded())) × \(Int((rect.height * sourceSize.height).rounded())) \(unit)"
    }

    var body: some View {
        DialogFrame(title: "Crop", subtitle: subtitle, accent: accent, primaryTitle: "Crop", primaryEnabled: preview != nil,
                    onPrimary: { onRun(isPDF ? .cropPDF(rect) : .cropImage(rect), nil) }, onCancel: onCancel) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 6) {
                    ForEach(Ratio.all, id: \.self) { r in
                        Chip(title: r.title, selected: ratio == r, accent: accent) {
                            ratio = r
                            rect = CropMath.centred(ratio: r.value, imageAspect: aspect)
                        }
                    }
                }
                editor
                if isPDF {
                    Text("Shown: page 1. The same crop box is applied to every page.")
                        .font(Halo.rounded(11)).foregroundStyle(Halo.secondary)
                }
            }
        }
        .onAppear(perform: load)
    }

    private var editor: some View {
        let box = fittedSize(in: CGSize(width: 412, height: 300))
        return ZStack(alignment: .topLeading) {
            if let preview {
                Image(decorative: preview, scale: 1).resizable().frame(width: box.width, height: box.height)
            } else {
                Rectangle().fill(Halo.card).frame(width: box.width, height: box.height)
            }
            overlay(size: box)
        }
        .frame(width: box.width, height: box.height)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .frame(maxWidth: .infinity)
        .gesture(dragGesture(size: box))
        .accessibilityElement()
        .accessibilityLabel("Crop area, \(Int(rect.width * 100)) by \(Int(rect.height * 100)) percent of the \(isPDF ? "page" : "image")")
    }

    private func overlay(size: CGSize) -> some View {
        let r = CGRect(x: rect.minX * size.width, y: rect.minY * size.height, width: rect.width * size.width, height: rect.height * size.height)
        return ZStack(alignment: .topLeading) {
            // Dim everything outside the box.
            Path { p in
                p.addRect(CGRect(origin: .zero, size: size))
                p.addRect(r)
            }
            .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
            // Rule of thirds.
            Path { p in
                for k in 1...2 {
                    let x = r.minX + r.width * CGFloat(k) / 3, y = r.minY + r.height * CGFloat(k) / 3
                    p.move(to: CGPoint(x: x, y: r.minY)); p.addLine(to: CGPoint(x: x, y: r.maxY))
                    p.move(to: CGPoint(x: r.minX, y: y)); p.addLine(to: CGPoint(x: r.maxX, y: y))
                }
            }
            .stroke(Color.white.opacity(0.25), lineWidth: 1)
            Rectangle().path(in: r).stroke(accent, lineWidth: 2).shadow(color: accent.opacity(0.5), radius: 2)
            ForEach(Array(handlePoints(r).enumerated()), id: \.offset) { _, point in
                RoundedRectangle(cornerRadius: 2).fill(accent).frame(width: 10, height: 10)
                    .position(point)
            }
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }

    private func handlePoints(_ r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY),
         CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.midX, y: r.maxY), CGPoint(x: r.minX, y: r.midY), CGPoint(x: r.maxX, y: r.midY)]
    }

    private func dragGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if active == nil { active = (handle(at: value.startLocation, size: size), rect) }
                guard let active else { return }
                let delta = CGVector(dx: value.translation.width / size.width, dy: value.translation.height / size.height)
                rect = CropMath.drag(active.start, handle: active.handle, delta: delta, ratio: ratio.value, imageAspect: aspect)
            }
            .onEnded { _ in active = nil }
    }

    /// Corners and edges within 12 pt grab that handle; inside moves the box.
    private func handle(at p: CGPoint, size: CGSize) -> CropMath.Handle {
        let r = CGRect(x: rect.minX * size.width, y: rect.minY * size.height, width: rect.width * size.width, height: rect.height * size.height)
        let tol: CGFloat = 12
        let nearL = abs(p.x - r.minX) < tol, nearR = abs(p.x - r.maxX) < tol
        let nearT = abs(p.y - r.minY) < tol, nearB = abs(p.y - r.maxY) < tol
        switch (nearL, nearR, nearT, nearB) {
        case (true, _, true, _): return .topLeft
        case (_, true, true, _): return .topRight
        case (true, _, _, true): return .bottomLeft
        case (_, true, _, true): return .bottomRight
        case (_, _, true, _) where p.x > r.minX && p.x < r.maxX: return .top
        case (_, _, _, true) where p.x > r.minX && p.x < r.maxX: return .bottom
        case (true, _, _, _) where p.y > r.minY && p.y < r.maxY: return .left
        case (_, true, _, _) where p.y > r.minY && p.y < r.maxY: return .right
        default: return .move
        }
    }

    private func fittedSize(in box: CGSize) -> CGSize {
        let k = min(box.width / max(sourceSize.width, 1), box.height / max(sourceSize.height, 1))
        return CGSize(width: (sourceSize.width * k).rounded(), height: (sourceSize.height * k).rounded())
    }

    private func load() {
        guard let url = files.first else { return }
        if isPDF {
            if let page = Thumbnails.pdfPage(url, maxPixel: 900) {
                preview = page.image
                sourceSize = page.size
            }
        } else {
            sourceSize = Thumbnails.pixelSize(url) ?? CGSize(width: 1, height: 1)
            preview = Thumbnails.image(url, maxPixel: 900)
        }
    }
}
