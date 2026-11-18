import AppKit
import CircularityEngine
import UniformTypeIdentifiers

/// Converts the image or PDF on the clipboard and puts the result back
/// (BRIEF.md). Reads the clipboard only when the user asks — never polls.
enum ClipboardConverter {
    static func convert(to requested: OutputFormat?, jobs: JobCenter, done: @escaping (String) -> Void) {
        let pasteboard = NSPasteboard.general
        // Read (copy) first: the clipboard may point at the previous result.
        let source = readSource(pasteboard)
        removeOldCopies(keeping: source?.deletingLastPathComponent())
        guard let source else {
            done("The clipboard has no image or PDF (or macOS didn't allow reading it).")
            return
        }
        let format: OutputFormat = requested ?? (source.pathExtension.lowercased() == "png" ? .jpg : .png)
        let outDir = source.deletingLastPathComponent().appendingPathComponent("out", isDirectory: true)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let isPDF = source.pathExtension.lowercased() == "pdf"
        let operation: CircularityEngine.Operation = isPDF && format != .pdf ? .pdfPages(format, scale: 2) : .convert(format)
        jobs.run(operation, files: [source], label: "clipboard", policy: OutputPolicy(destination: .folder(outDir)),
                 interactive: false) { result in
            guard case let .success(r) = result, var output = r.outputs.first else {
                done("Couldn't convert the clipboard.")
                return
            }
            // PDF → images makes a folder; put the first page on the clipboard.
            if (try? output.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
               let first = (try? FileManager.default.contentsOfDirectory(at: output, includingPropertiesForKeys: nil))?.sorted(by: { $0.path < $1.path }).first {
                output = first
            }
            guard let data = try? Data(contentsOf: output), let uti = UTType(filenameExtension: output.pathExtension) else {
                done("Couldn't read the converted file.")
                return
            }
            pasteboard.clearContents()
            pasteboard.setData(data, forType: NSPasteboard.PasteboardType(uti.identifier))
            pasteboard.writeObjects([output as NSURL])
            done("The clipboard now holds a \(format.displayName) (\(Bytes.text(Int64(data.count)))).")
        }
    }

    /// Earlier clipboard conversions' private copies (the newest one stays until
    /// the next conversion, because its result is what the clipboard points at).
    private static func removeOldCopies(keeping current: URL?) {
        let tmp = FileManager.default.temporaryDirectory
        let prefix = "\(AppIdentity.name)-Clipboard-"
        for item in (try? FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)) ?? []
            where item.lastPathComponent.hasPrefix(prefix) && item.lastPathComponent != current?.lastPathComponent {
            try? FileManager.default.removeItem(at: item)
        }
    }

    /// Writes the clipboard's file, image or PDF to a private temp file.
    private static func readSource(_ pasteboard: NSPasteboard) -> URL? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("\(AppIdentity.name)-Clipboard-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let url = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])?.first,
           let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) || type.conforms(to: .pdf) {
            let copy = dir.appendingPathComponent("Clipboard").appendingPathExtension(url.pathExtension)
            return (try? FileManager.default.copyItem(at: url, to: copy)) != nil ? copy : nil
        }
        let candidates: [(NSPasteboard.PasteboardType, String)] = [
            (.png, "png"), (NSPasteboard.PasteboardType("public.jpeg"), "jpg"), (NSPasteboard.PasteboardType("public.heic"), "heic"),
            (.pdf, "pdf"), (.tiff, "tiff"),
        ]
        for (type, ext) in candidates {
            if let data = pasteboard.data(forType: type) {
                let url = dir.appendingPathComponent("Clipboard").appendingPathExtension(ext)
                if (try? data.write(to: url)) != nil { return url }
            }
        }
        return nil
    }
}
