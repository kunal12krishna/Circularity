import Foundation

/// Output formats the engine can be asked for. Whether a format can actually be
/// *written* on the running macOS is decided at runtime by `FormatSupport`
/// (milestone d); this enum only names them.
public enum OutputFormat: String, Sendable, CaseIterable, Codable {
    case png, jpg, webp, heic, avif, tiff, gif, bmp, pdf, txt, html, docx

    public var fileExtension: String { rawValue }

    /// Formats that can keep transparency.
    public var supportsAlpha: Bool {
        switch self {
        case .jpg, .bmp: false
        default: true
        }
    }

    /// Lossy formats take a quality setting.
    public var isLossy: Bool { self == .jpg || self == .heic || self == .avif || self == .webp }

    /// The label shown on the wheel and in the centre orb.
    public var displayName: String {
        switch self {
        case .webp: "WebP"
        default: rawValue.uppercased()
        }
    }
}

/// The kind of operation, as far as output naming is concerned.
/// v1.1 media operations add cases here when their backend lands (PLAN.md §7).
public enum OperationKind: String, Sendable, CaseIterable, Codable {
    case convert, resize, compress, crop, combine, pdfToImages, extractText, renderDocument

    /// The suffix added to the output name: `photo (resized).jpg`.
    /// A plain format change keeps the original name: `photo.png`.
    public var nameSuffix: String? {
        switch self {
        case .resize: "resized"
        case .compress: "compressed"
        case .crop: "cropped"
        case .combine: "combined"
        case .pdfToImages: "pages"
        case .convert, .extractText, .renderDocument: nil
        }
    }
}
