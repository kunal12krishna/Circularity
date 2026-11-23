import Foundation

/// Output formats the engine can be asked for. Whether a format can actually be
/// *written* on the running macOS is decided at runtime by `FormatSupport`
/// (milestone d); this enum only names them.
public enum OutputFormat: String, Sendable, CaseIterable, Codable {
    case png, jpg, webp, heic, avif, tiff, gif, bmp, pdf, txt, html, docx
    /// Video containers (AVFoundation: H.264 / HEVC inside).
    case mp4, mov, m4v
    /// Audio files (AVFoundation / Core Audio).
    case m4a, wav, aiff, flac

    public var fileExtension: String { rawValue }

    public static let videoFormats: [OutputFormat] = [.mp4, .mov, .m4v]
    public static let audioFormats: [OutputFormat] = [.m4a, .wav, .aiff, .flac]

    public var isVideo: Bool { Self.videoFormats.contains(self) }
    public var isAudio: Bool { Self.audioFormats.contains(self) }
    public var isMedia: Bool { isVideo || isAudio }

    /// Formats that can keep transparency.
    public var supportsAlpha: Bool {
        switch self {
        case .jpg, .bmp: false
        default: true
        }
    }

    /// Lossy formats take a quality setting.
    public var isLossy: Bool { self == .jpg || self == .heic || self == .avif || self == .webp }

    /// Formats that keep the audio exactly (no quality is lost converting to them).
    public var isLosslessAudio: Bool { self == .wav || self == .aiff || self == .flac }

    /// The label shown on the wheel and in the centre orb.
    public var displayName: String {
        switch self {
        case .webp: "WebP"
        case .flac: "FLAC"
        default: rawValue.uppercased()
        }
    }
}

/// The kind of operation, as far as output naming is concerned.
/// v1.1 media operations add cases here when their backend lands (PLAN.md §7).
public enum OperationKind: String, Sendable, CaseIterable, Codable {
    case convert, resize, compress, crop, combine, pdfToImages, extractText, renderDocument, cutout
    case trim, mute, split
    case fit, searchable, locked, unlocked, arranged, faster, slower
    case square, portrait, wide, story

    /// The suffix added to the output name: `photo (resized).jpg`.
    /// A plain format change keeps the original name: `photo.png`.
    public var nameSuffix: String? {
        switch self {
        case .resize: "resized"
        case .compress: "compressed"
        case .crop: "cropped"
        case .combine: "combined"
        case .pdfToImages: "pages"
        case .cutout: "cut out"
        case .trim: "trimmed"
        case .mute: "no sound"
        case .split: "split"
        case .fit: "to send"
        case .searchable: "searchable"
        case .locked: "locked"
        case .unlocked: "unlocked"
        case .arranged: "edited"
        case .faster: "faster"
        case .slower: "slower"
        case .square: "square"
        case .portrait: "4×5"
        case .wide: "16×9"
        case .story: "story"
        case .convert, .extractText, .renderDocument: nil
        }
    }
}
