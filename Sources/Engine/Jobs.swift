import CoreGraphics
import Foundation

// The engine's public model (PLAN.md §3.1). The app, the CLI and the tests all
// build `JobRequest`s and read `JobResult`s; nothing here touches UI.

public enum ResizeMode: String, Sendable, Codable {
    /// Keep the aspect ratio and fit inside width × height.
    case fit
    /// Exactly width × height.
    case stretch
}

public struct ResizeSpec: Sendable, Equatable, Codable {
    public var width: Int?
    public var height: Int?
    public var mode: ResizeMode
    public init(width: Int?, height: Int?, mode: ResizeMode = .fit) {
        self.width = width
        self.height = height
        self.mode = mode
    }
}

public enum ImageCompression: Sendable, Equatable, Codable {
    /// 0…1 encoder quality.
    case quality(Double)
    /// The highest quality whose file fits, downscaling only if needed.
    case targetBytes(Int64)
}

public enum PDFCompression: String, Sendable, Codable, CaseIterable {
    case light, balanced, strong
}

public enum PaperSize: String, Sendable, Codable {
    case a4, letter

    /// Points (1/72 in).
    public var size: CGSize {
        switch self {
        case .a4: CGSize(width: 595.28, height: 841.89)
        case .letter: CGSize(width: 612, height: 792)
        }
    }

    /// Letter in the Americas regions that use it, A4 everywhere else (PLAN.md A7).
    public static func forRegion(_ code: String?) -> PaperSize {
        ["US", "CA", "MX", "PH", "CL", "CO", "VE", "GT"].contains(code?.uppercased() ?? "") ? .letter : .a4
    }

    public static var regional: PaperSize { forRegion(Locale.current.region?.identifier) }
}

public enum PDFResize: Sendable, Equatable, Codable {
    case scale(Double)
    case paper(PaperSize)
}

/// One page of an edited PDF: which original page (0-based) and how much to turn it.
public struct PageEdit: Sendable, Equatable, Codable, Hashable {
    public var index: Int
    /// Extra clockwise turn: 0, 90, 180 or 270.
    public var rotation: Int
    public init(index: Int, rotation: Int = 0) {
        self.index = index
        self.rotation = rotation
    }
}

public enum Operation: Sendable, Equatable {
    /// Images ↔ images/PDF, documents ↔ PDF/HTML/TXT/DOCX.
    case convert(OutputFormat)
    case resize(ResizeSpec)
    case compressImage(ImageCompression)
    /// Normalised rect (0…1, top-left origin) in the upright image.
    case cropImage(CGRect)
    /// One image per page into a folder; `scale` 2 ≈ 144 dpi.
    case pdfPages(OutputFormat, scale: Double)
    case extractText
    case combinePDF
    case compressPDF(PDFCompression)
    /// DOCX / XLSX / PPTX / ODT / ODS / ODP: the pictures inside shrunk, same format (OfficeCompressor).
    case compressOffice(PDFCompression)
    case resizePDF(PDFResize)
    /// Normalised rect (0…1, top-left origin) applied to every page's crop box.
    case cropPDF(CGRect)
    /// Keeps the subject and makes the background transparent (PNG). macOS 14+.
    case removeBackground
    /// Every page of a PDF as its own PDF, in a folder.
    case splitPDF
    /// Video or audio: keep `start…end` seconds, same format (audio AVFoundation can't write becomes M4A).
    case trimMedia(start: Double, end: Double)
    /// Video: HEVC at a lower bit rate (and size); audio: AAC at a lower bit rate.
    case compressMedia(PDFCompression)
    /// Video without its sound track.
    case removeAudio
    /// Several videos (or several audio files) one after another, in drop order.
    case combineMedia
    /// Smallest change that gets each file under `bytes` (pictures, PDFs, Office,
    /// video, audio). `together`: the files share the limit, in proportion to their size.
    case fitTo(bytes: Int64, together: Bool)
    /// The words in a picture or a scanned PDF as a .txt (on-device text recognition).
    case recognizeText
    /// A PDF whose text can be searched, selected and copied (an invisible text layer).
    case searchablePDF
    /// A PDF that asks for this password to open.
    case protectPDF(password: String)
    /// The same PDF without its password (it must be the right one).
    case unlockPDF(password: String)
    /// Pages in a new order, some turned, some left out.
    case arrangePDF([PageEdit])
    /// Video or audio played faster (> 1) or slower (< 1); voices keep their pitch.
    case changeSpeed(Double)

    public var kind: OperationKind {
        switch self {
        case .convert: .convert
        case .resize, .resizePDF: .resize
        case .compressImage, .compressPDF, .compressOffice: .compress
        case .cropImage, .cropPDF: .crop
        case .pdfPages: .pdfToImages
        case .extractText: .extractText
        case .combinePDF, .combineMedia: .combine
        case .removeBackground: .cutout
        case .splitPDF: .split
        case .trimMedia: .trim
        case .compressMedia: .compress
        case .removeAudio: .mute
        case .fitTo: .fit
        case .recognizeText: .extractText
        case .searchablePDF: .searchable
        case .protectPDF: .locked
        case .unlockPDF: .unlocked
        case .arrangePDF: .arranged
        case let .changeSpeed(rate): rate >= 1 ? .faster : .slower
        }
    }
}

public enum MetadataPolicy: String, Sendable, Codable {
    case keep, stripGPS, stripAll
}

public enum Destination: Sendable, Equatable {
    case nextToOriginal
    case folder(URL)
}

public struct OutputPolicy: Sendable {
    public var destination: Destination
    public var template: NamingTemplate
    /// Used when the destination cannot be written (PLAN.md §3.1).
    public var fallbackFolder: URL
    public var metadata: MetadataPolicy
    public var quality: [OutputFormat: Double]
    public var collision: CollisionStyle = .number

    public static let defaultQuality: [OutputFormat: Double] = [.jpg: 0.85, .heic: 0.8, .avif: 0.75, .webp: 0.8]

    public init(destination: Destination = .nextToOriginal, template: NamingTemplate = .default,
                fallbackFolder: URL = OutputPolicy.documentsConverted, metadata: MetadataPolicy = .keep,
                quality: [OutputFormat: Double] = OutputPolicy.defaultQuality) {
        self.destination = destination
        self.template = template
        self.fallbackFolder = fallbackFolder
        self.metadata = metadata
        self.quality = quality
    }

    /// Where results go if the destination can't be written: the chosen
    /// fallback, then ~/Converted (outside the folders macOS asks about).
    public var fallbackFolders: [URL] {
        [fallbackFolder, FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Converted", isDirectory: true)]
    }

    public static var documentsConverted: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Converted", isDirectory: true)
    }

    func quality(for format: OutputFormat) -> Double { quality[format] ?? Self.defaultQuality[format] ?? 0.85 }
}

public struct JobRequest: Sendable {
    public var id: UUID
    public var inputs: [URL]
    public var operation: Operation
    public var output: OutputPolicy

    public init(id: UUID = UUID(), inputs: [URL], operation: Operation, output: OutputPolicy = OutputPolicy()) {
        self.id = id
        self.inputs = inputs
        self.operation = operation
        self.output = output
    }
}

/// What happened to one input (or to the whole batch for Combine).
public struct JobOutcome: Sendable {
    public var inputs: [URL]
    public var outputs: [URL]
    public var bytesIn: Int64
    public var bytesOut: Int64
    /// e.g. "Kept the original: it is already compact." Set when nothing was written.
    public var note: String?
    /// Written to the fallback folder because the destination was not writable.
    public var usedFallbackFolder: Bool
}

public struct JobResult: Sendable {
    public var outcomes: [JobOutcome]
    public var outputs: [URL] { outcomes.flatMap(\.outputs) }
    public var bytesIn: Int64 { outcomes.reduce(0) { $0 + $1.bytesIn } }
    public var bytesOut: Int64 { outcomes.reduce(0) { $0 + $1.bytesOut } }
    public var notes: [String] { outcomes.compactMap(\.note) }
}

public struct JobProgress: Sendable, Equatable {
    public var fraction: Double
    public var detail: String
}

public enum JobError: LocalizedError, Equatable {
    case unsupported(String)
    case unreadable(String)
    case encodeFailed(String)
    case writeFailed(String)
    case toolFailed(String)
    case targetUnreachable(Int64)
    case verificationFailed(String)
    /// Said as it is (no "Can't convert" in front).
    case message(String)

    public var errorDescription: String? {
        switch self {
        case let .unsupported(what): "Can't convert \(what)."
        case let .unreadable(name): "Couldn't read \(name)."
        case let .encodeFailed(what): "Couldn't write \(what)."
        case let .writeFailed(why): "Couldn't save the result: \(why)"
        case let .toolFailed(why): "The converter failed: \(why)"
        case let .targetUnreachable(bytes): "Couldn't get under \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))."
        case let .verificationFailed(why): "The result didn't match the original (\(why)); kept the original."
        case let .message(text): text
        }
    }
}

/// Fit/stretch arithmetic for image resizes (pure, unit-tested).
public enum ResizeMath {
    public static func targetSize(source: CGSize, spec: ResizeSpec) -> CGSize {
        let w = spec.width.map(CGFloat.init), h = spec.height.map(CGFloat.init)
        switch spec.mode {
        case .stretch:
            let width = w ?? (h.map { source.width * $0 / source.height } ?? source.width)
            let height = h ?? (w.map { source.height * $0 / source.width } ?? source.height)
            return CGSize(width: max(1, width.rounded()), height: max(1, height.rounded()))
        case .fit:
            let sx = w.map { $0 / source.width } ?? .infinity
            let sy = h.map { $0 / source.height } ?? .infinity
            let s = min(sx, sy)
            guard s.isFinite else { return source }
            return CGSize(width: max(1, (source.width * s).rounded()), height: max(1, (source.height * s).rounded()))
        }
    }
}
