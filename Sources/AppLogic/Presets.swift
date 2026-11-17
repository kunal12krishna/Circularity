import CircularityEngine
import CoreGraphics
import Foundation

/// A one-click wheel button made with "Also add this as a button" in the
/// Resize/Compress dialogs (BRIEF.md "Custom buttons"). Shown in the More fan
/// only for matching file types.
nonisolated struct Preset: Codable, Equatable, Identifiable, Sendable {
    enum Applies: String, Codable, Sendable { case images, pdfs }

    enum Action: Codable, Equatable, Sendable {
        case resize(width: Int?, height: Int?, stretch: Bool)
        case compressQuality(Double)
        case compressTarget(Int64)
        case compressPDF(PDFCompression)
        case resizePDFScale(Double)
        case resizePDFPaper(PaperSize)
    }

    var id: String
    var name: String
    var applies: Applies
    var action: Action

    init(id: String = UUID().uuidString, applies: Applies, action: Action) {
        self.id = id
        self.applies = applies
        self.action = action
        name = Self.name(for: action)
    }

    var operation: CircularityEngine.Operation {
        switch action {
        case let .resize(w, h, stretch): .resize(ResizeSpec(width: w, height: h, mode: stretch ? .stretch : .fit))
        case let .compressQuality(q): .compressImage(.quality(q))
        case let .compressTarget(bytes): .compressImage(.targetBytes(bytes))
        case let .compressPDF(level): .compressPDF(level)
        case let .resizePDFScale(s): .resizePDF(.scale(s))
        case let .resizePDFPaper(p): .resizePDF(.paper(p))
        }
    }

    /// Short names that fit a fan chip: "1920w", "1920×1080", "<2 MB", "Q70".
    static func name(for action: Action) -> String {
        switch action {
        case let .resize(w?, h?, _): "\(w)×\(h)"
        case let .resize(w?, nil, _): "\(w)w"
        case let .resize(nil, h?, _): "\(h)h"
        case .resize: "Resize"
        case let .compressQuality(q): "Q\(Int((q * 100).rounded()))"
        case let .compressTarget(bytes): "<" + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        case let .compressPDF(level): "PDF \(level.rawValue.capitalized)"
        case let .resizePDFScale(s): "\(Int((s * 100).rounded()))%"
        case let .resizePDFPaper(p): p == .a4 ? "A4" : "Letter"
        }
    }

    static func decodeList(_ json: String) -> [Preset] {
        (try? JSONDecoder().decode([Preset].self, from: Data(json.utf8))) ?? []
    }

    static func encodeList(_ presets: [Preset]) -> String {
        (try? String(data: JSONEncoder().encode(presets), encoding: .utf8)) ?? "[]"
    }
}

/// Crop-box arithmetic in normalised image space (0…1, top-left origin) for
/// the crop editor. Pure and unit-tested.
nonisolated enum CropMath {
    enum Handle: Sendable { case move, topLeft, topRight, bottomLeft, bottomRight, top, bottom, left, right }

    /// The largest rect with `ratio` (width/height in pixels) centred in the
    /// image; `imageAspect` is the image's width/height.
    static func centred(ratio: CGFloat?, imageAspect: CGFloat) -> CGRect {
        guard let ratio, ratio > 0, imageAspect > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        let normalised = ratio / imageAspect // ratio in normalised units
        var w: CGFloat = 1, h: CGFloat = 1
        if normalised >= 1 { h = 1 / normalised } else { w = normalised }
        return CGRect(x: (1 - w) / 2, y: (1 - h) / 2, width: w, height: h)
    }

    /// Applies a drag of `delta` (normalised) on `handle`, keeping the rect
    /// inside 0…1, at least `minimum` in size, and at `ratio` if given.
    static func drag(_ rect: CGRect, handle: Handle, delta: CGVector, ratio: CGFloat?, imageAspect: CGFloat,
                     minimum: CGFloat = 0.05) -> CGRect {
        var r = rect
        switch handle {
        case .move:
            r.origin.x = min(max(0, rect.minX + delta.dx), 1 - rect.width)
            r.origin.y = min(max(0, rect.minY + delta.dy), 1 - rect.height)
            return r
        case .topLeft: r = CGRect(x: rect.minX + delta.dx, y: rect.minY + delta.dy, width: rect.width - delta.dx, height: rect.height - delta.dy)
        case .topRight: r = CGRect(x: rect.minX, y: rect.minY + delta.dy, width: rect.width + delta.dx, height: rect.height - delta.dy)
        case .bottomLeft: r = CGRect(x: rect.minX + delta.dx, y: rect.minY, width: rect.width - delta.dx, height: rect.height + delta.dy)
        case .bottomRight: r = CGRect(x: rect.minX, y: rect.minY, width: rect.width + delta.dx, height: rect.height + delta.dy)
        case .top: r = CGRect(x: rect.minX, y: rect.minY + delta.dy, width: rect.width, height: rect.height - delta.dy)
        case .bottom: r = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height + delta.dy)
        case .left: r = CGRect(x: rect.minX + delta.dx, y: rect.minY, width: rect.width - delta.dx, height: rect.height)
        case .right: r = CGRect(x: rect.minX, y: rect.minY, width: rect.width + delta.dx, height: rect.height)
        }
        r.size.width = max(minimum, r.width)
        r.size.height = max(minimum, r.height)
        if let ratio, ratio > 0, imageAspect > 0 {
            // Keep the ratio: height follows width (normalised units).
            let normalised = ratio / imageAspect
            r.size.height = r.width / normalised
            if [.topLeft, .topRight, .top].contains(handle) { r.origin.y = rect.maxY - r.height }
            if [.topLeft, .bottomLeft, .left].contains(handle) { r.origin.x = rect.maxX - r.width }
        }
        return clamp(r)
    }

    /// Fits a rect inside 0…1 without changing its proportions.
    static func clamp(_ rect: CGRect) -> CGRect {
        var r = rect.standardized
        let k = min(1, 1 / max(r.width, 0.0001), 1 / max(r.height, 0.0001))
        if k < 1 { r.size = CGSize(width: r.width * k, height: r.height * k) }
        r.origin.x = min(max(0, r.minX), 1 - r.width)
        r.origin.y = min(max(0, r.minY), 1 - r.height)
        return r
    }
}
