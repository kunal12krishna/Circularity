import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Compress for Office files (DOCX, XLSX, PPTX and OpenDocument ODT, ODS,
/// ODP): like Office's own "Compress Pictures". These files are zip packages;
/// the pictures inside are shrunk to the level's size and re-saved in their
/// own format under their own names (so every reference to them still
/// works), and everything is zipped again at the strongest setting. Text,
/// layout, fonts, video and the file's format are untouched. The result is
/// kept only if it's smaller and holds exactly the same parts.
public enum OfficeCompressor {
    /// Zip packages this can compress (the older DOC / XLS / PPT can't be).
    public static let extensions: Set<String> = ["docx", "docm", "xlsx", "xlsm", "pptx", "pptm", "odt", "ods", "odp"]

    public static func canCompress(_ url: URL) -> Bool { extensions.contains(url.pathExtension.lowercased()) }

    public static func canCompress(_ type: UTType) -> Bool {
        type.tags[.filenameExtension]?.contains { extensions.contains($0.lowercased()) } ?? false
    }

    /// Longest side and JPEG quality per level.
    static func limits(_ level: PDFCompression) -> (maxPixel: Int, quality: Double) {
        switch level {
        case .light: (2560, 0.85)
        case .balanced: (1920, 0.75)
        case .strong: (1280, 0.6)
        }
    }

    public enum Verdict: Equatable { case smaller, notSmaller }

    static func compress(_ input: URL, level: PDFCompression, workDir: URL, to output: URL,
                         progress: (Double) -> Void = { _ in }) async throws -> Verdict {
        guard canCompress(input) else { throw JobError.unsupported("compressing \(input.lastPathComponent)") }
        let dir = try await OpenDocument.unzip(input, workDir: workDir, requiring: input.pathExtension.lowercased().hasPrefix("od")
                                                  ? "content.xml" : "[Content_Types].xml")
        let fm = FileManager.default
        let before = try listing(input)
        let (maxPixel, quality) = limits(level)

        // The pictures: Word, Excel and PowerPoint keep them in */media, OpenDocument in Pictures.
        let pictures = (fm.enumerator(at: dir, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []).filter { url in
            let parts = url.pathComponents
            return (parts.contains("media") || parts.contains("Pictures"))
                && ["jpg", "jpeg", "png", "tif", "tiff", "bmp"].contains(url.pathExtension.lowercased())
        }
        for (i, picture) in pictures.enumerated() {
            try Task.checkCancellation()
            shrink(picture, maxPixel: maxPixel, quality: quality)
            progress(0.1 + 0.7 * Double(i + 1) / Double(max(pictures.count, 1)))
        }

        // Zip again. OpenDocument wants "mimetype" first and stored as is.
        let zipped = workDir.appendingPathComponent("office-\(UUID().uuidString).\(input.pathExtension)")
        let mimetype = dir.appendingPathComponent("mimetype")
        if fm.fileExists(atPath: mimetype.path) {
            try await Tool.run("/usr/bin/zip", ["-X", "-0", "-q", zipped.path, "mimetype"], in: dir)
            try await Tool.run("/usr/bin/zip", ["-X", "-9", "-r", "-q", zipped.path, ".", "-x", "mimetype"], in: dir)
        } else {
            try await Tool.run("/usr/bin/zip", ["-X", "-9", "-r", "-q", zipped.path, "."], in: dir)
        }
        progress(0.95)

        // The same parts, nothing lost or added, and actually smaller.
        guard try listing(zipped) == before else { throw JobError.verificationFailed("the compressed file didn't match the original's parts") }
        let original = size(input), shrunk = size(zipped)
        guard shrunk > 0, shrunk < original * 98 / 100 else { return .notSmaller }
        try fm.moveItem(at: zipped, to: output)
        return .smaller
    }

    /// Re-saves one picture smaller, in its own format, if that makes it smaller.
    /// The pixels keep their orientation tag and colour profile, so Office shows it the same way.
    static func shrink(_ url: URL, maxPixel: Int, quality: Double) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let type = CGImageSourceGetType(source),
              CGImageSourceGetCount(source) == 1,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int else { return }
        let isJPEG = UTType(type as String)?.conforms(to: .jpeg) == true
        let tooBig = max(width, height) > maxPixel
        guard tooBig || isJPEG else { return } // lossless pictures only get smaller by being smaller
        let image: CGImage?
        if tooBig {
            // Thumbnail without applying orientation: the tag is copied over below.
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                kCGImageSourceCreateThumbnailWithTransform: false,
            ] as CFDictionary)
        } else {
            image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        guard let image else { return }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type, 1, nil) else { return }
        var options: [CFString: Any] = [:]
        if let orientation = props[kCGImagePropertyOrientation] { options[kCGImagePropertyOrientation] = orientation }
        if isJPEG { options[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(dest, image, options as CFDictionary)
        guard CGImageDestinationFinalize(dest), data.length > 0, data.length < size(url) * 95 / 100 else { return }
        try? (data as Data).write(to: url, options: .atomic)
    }

    /// The package's part names (zipinfo -1), sorted.
    static func listing(_ zip: URL) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zipinfo")
        process.arguments = ["-1", zip.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw JobError.unsupported("\(zip.lastPathComponent): it isn't a valid file (it may be damaged)") }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init).filter { !$0.hasSuffix("/") }.sorted()
    }

    static func size(_ url: URL) -> Int { (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
}
