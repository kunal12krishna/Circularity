import Foundation
import ImageIO

/// Which image formats ImageIO can read and write on the running macOS
/// (PLAN.md §3.1). Probed once; the wheel hides formats it cannot write.
public struct FormatSupport: Sendable, Equatable {
    public let writableImageTypes: Set<String>
    public let readableImageTypes: Set<String>

    public static let current = FormatSupport()

    public init() {
        writableImageTypes = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
        readableImageTypes = Set((CGImageSourceCopyTypeIdentifiers() as? [String]) ?? [])
    }

    public init(writable: Set<String>, readable: Set<String> = []) {
        writableImageTypes = writable
        readableImageTypes = readable
    }

    /// Image formats depend on ImageIO; FLAC on Core Audio's encoder; document,
    /// video and the other audio formats are always offered.
    public func canWrite(_ format: OutputFormat) -> Bool {
        if format == .flac { return MediaSupport.canWriteFLAC }
        guard let identifier = format.imageTypeIdentifier else { return true }
        return writableImageTypes.contains(identifier)
    }
}

extension OutputFormat {
    /// The ImageIO type identifier for image formats; nil for documents.
    public var imageTypeIdentifier: String? {
        switch self {
        case .png: "public.png"
        case .jpg: "public.jpeg"
        case .webp: "org.webmproject.webp"
        case .heic: "public.heic"
        case .avif: "public.avif"
        case .tiff: "public.tiff"
        case .gif: "com.compuserve.gif"
        case .bmp: "com.microsoft.bmp"
        case .pdf, .txt, .html, .docx, .mp4, .mov, .m4v, .m4a, .wav, .aiff, .flac: nil
        }
    }
}
