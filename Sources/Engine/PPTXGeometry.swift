import Foundation

/// Where things sit on each slide of a PPTX: every shape's frame on the slide,
/// its layout and its master, in the deck's own order (hidden slides left
/// out, as Quick Look leaves them out). Used to tell Quick Look's stray
/// pictures (a shape from another slide) from pictures that belong there.
enum PPTXGeometry {
    struct Deck { var size: CGSize; var slides: [[CGRect]] } // EMU

    static func read(_ dir: URL) -> Deck? {
        let ppt = dir.appendingPathComponent("ppt", isDirectory: true)
        let presentation = FrameReader()
        guard (try? presentation.parse(ppt.appendingPathComponent("presentation.xml"))) != nil,
              let size = presentation.slideSize else { return nil }
        let rels = relationships(ppt.appendingPathComponent("_rels/presentation.xml.rels"))
        var slides: [[CGRect]] = []
        for id in presentation.slideIDs {
            guard let target = rels[id], let slide = resolve(target, from: ppt) else { return nil }
            let reader = FrameReader()
            guard (try? reader.parse(slide)) != nil else { return nil }
            if reader.hidden { continue }
            var frames = reader.frames
            // The slide's layout, and the layout's master.
            var parent: URL? = layoutOrMaster(of: slide)
            var hops = 0
            while let p = parent, hops < 2 {
                let inherited = FrameReader()
                if (try? inherited.parse(p)) != nil { frames += inherited.frames }
                parent = layoutOrMaster(of: p); hops += 1
            }
            slides.append(frames)
        }
        return Deck(size: size, slides: slides)
    }

    private static func layoutOrMaster(of part: URL) -> URL? {
        let rels = part.deletingLastPathComponent().appendingPathComponent("_rels/\(part.lastPathComponent).rels")
        let found = relationships(rels, types: ["/slideLayout", "/slideMaster"])
        return found.values.first.flatMap { resolve($0, from: part.deletingLastPathComponent()) }
    }

    /// A relationship target inside the package only.
    private static func resolve(_ target: String, from folder: URL) -> URL? {
        guard !target.contains(":") else { return nil }
        let url = folder.appendingPathComponent(target).standardizedFileURL
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Id → Target, optionally only the relationships whose Type ends with one of `types`.
    static func relationships(_ url: URL, types: [String]? = nil) -> [String: String] {
        let reader = XLSXReader.Attributes()
        guard (try? reader.parse(url, elements: ["Relationship"])) != nil else { return [:] }
        var out: [String: String] = [:]
        for a in reader.found {
            guard let id = a["Id"], let target = a["Target"] else { continue }
            if let types, !types.contains(where: { a["Type"]?.hasSuffix($0) == true }) { continue }
            out[id] = target
        }
        return out
    }

    /// a:off + a:ext pairs (shape frames), the slide size, slide ids and `show="0"`.
    final class FrameReader: NSObject, XMLParserDelegate {
        private(set) var frames: [CGRect] = []
        private(set) var slideSize: CGSize?
        private(set) var slideIDs: [String] = []
        private(set) var hidden = false
        private var offset: CGPoint?

        func parse(_ url: URL) throws {
            guard let parser = XMLParser(contentsOf: url) else { throw JobError.unreadable(url.lastPathComponent) }
            parser.delegate = self
            guard parser.parse() else { throw parser.parserError ?? JobError.unreadable(url.lastPathComponent) }
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
            switch name {
            case "p:sld": hidden = a["show"] == "0"
            case "p:sldSz": if let w = Double(a["cx"] ?? ""), let h = Double(a["cy"] ?? "") { slideSize = CGSize(width: w, height: h) }
            case "p:sldId": if let id = a["r:id"] ?? a.first(where: { $0.key.hasSuffix(":id") })?.value { slideIDs.append(id) }
            case "a:off": if let x = Double(a["x"] ?? ""), let y = Double(a["y"] ?? "") { offset = CGPoint(x: x, y: y) }
            case "a:ext":
                if let o = offset, let w = Double(a["cx"] ?? ""), let h = Double(a["cy"] ?? "") {
                    frames.append(CGRect(origin: o, size: CGSize(width: w, height: h)))
                }
                offset = nil
            default: break
            }
        }
    }
}
