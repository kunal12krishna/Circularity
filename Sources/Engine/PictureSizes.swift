import Foundation

/// How large each picture in an unzipped Office package is shown, in inches,
/// so Compress can resample it to a resolution (like Office's own Compress
/// Pictures) instead of only capping huge ones. A picture shown in several
/// places counts at its largest; cropped pictures count at the size the whole
/// picture would have. A picture used somewhere this can't size (a slide
/// background, say) is `nil`: it's only capped, never resampled to a size.
enum PictureSizes {
    struct Shown { var width: Double; var height: Double } // inches, of the whole (uncropped) picture

    /// Absolute media path → largest shown size, or nil where unknown.
    static func read(_ dir: URL) -> [String: Shown?] {
        var out: [String: Shown?] = [:]
        func add(_ path: String, _ shown: Shown?) {
            let key = URL(fileURLWithPath: path).standardizedFileURL.path
            guard let shown else { out[key] = .some(nil); return }
            if let existing = out[key] {
                guard let current = existing else { return } // unknown somewhere: stays unknown
                out[key] = Shown(width: max(current.width, shown.width), height: max(current.height, shown.height))
            } else {
                out[key] = shown
            }
        }
        let fm = FileManager.default
        if fm.fileExists(atPath: dir.appendingPathComponent("content.xml").path) {
            // OpenDocument: draw:frame sizes around draw:image.
            for part in ["content.xml", "styles.xml"] {
                let reader = Reader(openDocument: true)
                reader.parse(dir.appendingPathComponent(part))
                for (href, shown) in reader.uses where !href.contains(":") && !href.contains("..") {
                    add(dir.appendingPathComponent(href).path, shown)
                }
            }
            return out
        }
        // Office Open XML: every part with relationships; r:embed ids → media paths.
        let rels = (fm.enumerator(at: dir, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? [])
            .filter { $0.pathExtension == "rels" && $0.deletingLastPathComponent().lastPathComponent == "_rels" }
        for rel in rels {
            let folder = rel.deletingLastPathComponent().deletingLastPathComponent()
            let part = folder.appendingPathComponent(String(rel.deletingPathExtension().lastPathComponent))
            guard part.pathExtension == "xml", fm.fileExists(atPath: part.path) else { continue }
            let targets = PPTXGeometry.relationships(rel, types: ["/image"])
            guard !targets.isEmpty else { continue }
            let reader = Reader(openDocument: false)
            reader.parse(part)
            for (id, shown) in reader.uses {
                guard let target = targets[id], !target.contains(":") else { continue }
                add(folder.appendingPathComponent(target).path, shown)
            }
        }
        return out
    }

    /// Walks one XML part: each picture reference with the size of the shape around it.
    final class Reader: NSObject, XMLParserDelegate {
        private let openDocument: Bool
        private struct Frame { var size: (Double, Double)?; var crop = (l: 0.0, t: 0.0, r: 0.0, b: 0.0); var refs: [String] = [] }
        private var frames: [Frame] = []
        private(set) var uses: [(String, Shown?)] = []
        private static let containers: Set<String> = ["pic", "sp", "inline", "anchor", "bg", "graphicFrame", "oneCellAnchor", "twoCellAnchor"]

        init(openDocument: Bool) { self.openDocument = openDocument }

        func parse(_ url: URL) {
            guard let parser = XMLParser(contentsOf: url) else { return }
            parser.delegate = self
            _ = parser.parse()
        }

        private func local(_ name: String) -> String { name.split(separator: ":").last.map(String.init) ?? name }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
            if openDocument {
                switch name {
                case "draw:frame":
                    let w = OpenDocument.points(a["svg:width"]).map { Double($0) / 72 }
                    let h = OpenDocument.points(a["svg:height"]).map { Double($0) / 72 }
                    frames.append(Frame(size: w.flatMap { w in h.map { (w, $0) } }))
                case "draw:image", "draw:fill-image":
                    if let href = a["xlink:href"] {
                        if frames.isEmpty { uses.append((href, nil)) } else { frames[frames.count - 1].refs.append(href) }
                    }
                default: break
                }
                return
            }
            let l = local(name)
            if Self.containers.contains(l) { frames.append(Frame()); return }
            guard !frames.isEmpty else {
                if l == "blip", let id = a["r:embed"] ?? a.first(where: { $0.key.hasSuffix(":embed") })?.value { uses.append((id, nil)) }
                return
            }
            switch l {
            case "ext", "extent":
                // The first extent inside a shape is its size (a:ext also names extension lists: those have no cx).
                if frames[frames.count - 1].size == nil, let cx = Double(a["cx"] ?? ""), let cy = Double(a["cy"] ?? ""), cx > 0, cy > 0 {
                    frames[frames.count - 1].size = (cx / 914_400, cy / 914_400)
                }
            case "srcRect":
                let v = { (k: String) in (Double(a[k] ?? "") ?? 0) / 100_000 }
                frames[frames.count - 1].crop = (v("l"), v("t"), v("r"), v("b"))
            case "blip":
                if let id = a["r:embed"] ?? a.first(where: { $0.key.hasSuffix(":embed") })?.value { frames[frames.count - 1].refs.append(id) }
            default: break
            }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let closes = openDocument ? name == "draw:frame" : Self.containers.contains(local(name))
            guard closes, let frame = frames.popLast() else { return }
            for ref in frame.refs {
                guard let (w, h) = frame.size, frame.crop.l + frame.crop.r < 0.95, frame.crop.t + frame.crop.b < 0.95 else {
                    uses.append((ref, nil)); continue
                }
                // Cropped: the whole picture is shown larger than the visible part.
                uses.append((ref, Shown(width: w / max(0.05, 1 - frame.crop.l - frame.crop.r),
                                        height: h / max(0.05, 1 - frame.crop.t - frame.crop.b))))
            }
        }
    }
}
