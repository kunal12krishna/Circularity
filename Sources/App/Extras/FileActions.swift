import AppKit
import CircularityEngine

/// The Actions wheel: things done with files as they are, nothing converted.
/// Works on anything Finder can drag: folders, mixed selections, any file type.
/// No permission is used: AirDrop, Mail and Terminal are opened the way Finder
/// opens them, Zip is macOS's own `ditto`, and the clipboard is only written.
final class FileActionPerformer {
    private let shelf: DropShelf
    let stash = DropShelf(mode: .stash)
    private let accent: () -> NSColor
    /// Move to, Copy to and Zip go into History, so the panel can undo them.
    var record: ((HistoryItem) -> Void)?

    init(shelf: DropShelf, accent: @escaping () -> NSColor) {
        self.shelf = shelf
        self.accent = accent
    }

    func perform(_ action: FileAction, files: [URL]) {
        let files = files.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !files.isEmpty else {
            say("Nothing to do", "The files are no longer where they were.")
            return
        }
        Log.app.notice("Action \(action.rawValue, privacy: .public) on \(files.count, privacy: .public) item(s)")
        switch action {
        case .airDrop:
            guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: files) else {
                say("AirDrop isn't available", "Turn on Wi-Fi and Bluetooth, then try again.")
                return
            }
            NSApp.activate(ignoringOtherApps: true)
            service.perform(withItems: files)
        case .copy:
            Clipboard.write(files)
            say("Copied", files.count == 1 ? "Paste it into a folder, an email or a chat." : "\(files.count) items. Paste them anywhere.",
                original: files.first)
        case .zip:
            zip(files)
        case .mail:
            guard let service = NSSharingService(named: .composeEmail), service.canPerform(withItems: files) else {
                say("No mail app is set up", "Set one up in Mail, then try again.")
                return
            }
            NSApp.activate(ignoringOtherApps: true)
            service.perform(withItems: files)
        case .copyPath:
            let text = Self.paths(files)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            say(files.count == 1 ? "Path copied" : "\(files.count) paths copied", files.count == 1 ? Self.abbreviated(files[0]) : "one per line")
        case .terminal:
            openTerminal(at: Self.folders(files))
        case .stash:
            stash.show(files, accent: accent())
        case .moveTo:
            transfer(files, move: true)
        case .copyTo:
            transfer(files, move: false)
        case .quickLook:
            QuickLook.shared.show(files)
        case .reveal:
            NSWorkspace.shared.activateFileViewerSelecting(files)
        }
    }

    // MARK: Pure helpers (unit-tested through the wheel tests' style)

    /// One path per line; paths with spaces stay as they are (paste into quotes in a shell).
    static func paths(_ files: [URL]) -> String { files.map(\.path).joined(separator: "\n") }

    /// "~/Desktop/report.pdf"
    static func abbreviated(_ url: URL) -> String { (url.path as NSString).abbreviatingWithTildeInPath }

    /// Folders themselves, or the folder a file is in; each once, in order.
    static func folders(_ files: [URL]) -> [URL] {
        var seen: [URL] = []
        for url in files {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            let isPackage = (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) == true
            let folder = isDir && !isPackage ? url : url.deletingLastPathComponent()
            if !seen.contains(folder.standardizedFileURL) { seen.append(folder.standardizedFileURL) }
        }
        return seen
    }

    /// A free name in `folder`: "report.pdf", then "report 2.pdf" (as Finder does).
    nonisolated static func freeDestination(for url: URL, in folder: URL, exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> URL {
        let name = url.lastPathComponent
        var candidate = folder.appendingPathComponent(name)
        guard exists(candidate.path) else { return candidate }
        let ext = url.pathExtension
        let base = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
        var n = 2
        repeat {
            candidate = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        } while exists(candidate.path)
        return candidate
    }

    // MARK: Zip

    /// "Invoices.zip" for one item (as Finder names it), "Archive.zip" for several.
    static func zipName(_ files: [URL]) -> String {
        files.count == 1 ? "\(files[0].lastPathComponent).zip" : "Archive.zip"
    }

    private func zip(_ files: [URL]) {
        var folder = files[0].deletingLastPathComponent()
        if !FileManager.default.isWritableFile(atPath: folder.path) {
            folder = OutputPolicy.documentsConverted
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let target = Self.freeDestination(for: URL(fileURLWithPath: Self.zipName(files)), in: folder)
        let bytesIn = files.reduce(Int64(0)) { $0 + Self.size(of: $1) }
        let started = Date()
        Task.detached(priority: .userInitiated) {
            let result = Result { try Self.makeZip(files, to: target) }
            await MainActor.run { [weak self] in
                guard let self else { return }
                switch result {
                case .success:
                    Log.app.notice("Zipped \(files.count, privacy: .public) item(s) in \(Date().timeIntervalSince(started), privacy: .public) s")
                    self.record?(HistoryItem(id: UUID().uuidString, date: Date(), inputs: files.map(\.path), outputs: [target.path],
                                             bytesIn: bytesIn, bytesOut: Self.size(of: target),
                                             label: files.count == 1 ? "Zipped" : "Zipped \(files.count) items", format: "ZIP", kind: "zip"))
                    self.shelf.show([target], accent: self.accent(), bytesIn: bytesIn, undoable: true)
                case let .failure(error):
                    self.say("Couldn't zip that", error.localizedDescription)
                }
            }
        }
    }

    /// A folder keeps its name inside the archive; a file sits at the root.
    /// Writes the archive beside the target first and moves it into place, so
    /// a failed zip never leaves half a file. Several items are cloned into one
    /// folder (instant on APFS) so they sit side by side at the archive's root.
    nonisolated static func makeZip(_ files: [URL], to target: URL) throws {
        let fm = FileManager.default
        let work = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: target.deletingLastPathComponent(), create: true)
        defer { try? fm.removeItem(at: work) }
        let scratch = work.appendingPathComponent("out.zip")
        // Clean archives: no __MACOSX folder of resource forks and Finder tags,
        // so they open tidily on Windows and Linux too.
        var arguments = ["-c", "-k", "--norsrc", "--noextattr", "--noqtn", "--noacl"]
        if files.count == 1 {
            let isFolder = (try? files[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            arguments += (isFolder ? ["--keepParent"] : []) + [files[0].path, scratch.path]
        } else {
            let gather = work.appendingPathComponent("items", isDirectory: true)
            try fm.createDirectory(at: gather, withIntermediateDirectories: true)
            for url in files { try fm.copyItem(at: url, to: freeDestination(for: url, in: gather)) }
            arguments += [gather.path, scratch.path]
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw JobError.toolFailed(message.isEmpty ? "ditto stopped (\(process.terminationStatus))" : message)
        }
        try fm.moveItem(at: scratch, to: target)
    }

    nonisolated static func size(of url: URL) -> Int64 {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .totalFileAllocatedSizeKey, .fileSizeKey]) else { return 0 }
        guard values.isDirectory == true else { return Int64(values.fileSize ?? 0) }
        let items = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
        var total: Int64 = 0
        while let item = items?.nextObject() as? URL { total += Int64((try? item.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return total
    }

    // MARK: Terminal

    private func openTerminal(at folders: [URL]) {
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            say("Terminal isn't installed", "It's in Applications → Utilities on every Mac.")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        // Several folders open several windows; keep it to a sensible few.
        NSWorkspace.shared.open(Array(folders.prefix(4)), withApplicationAt: terminal, configuration: configuration) { [weak self] _, error in
            guard let error else { return }
            let message = error.localizedDescription
            Task { @MainActor [weak self] in
                Log.app.error("Terminal: \(message, privacy: .public)")
                self?.say("Couldn't open Terminal", message)
            }
        }
    }

    // MARK: Move and copy

    private func transfer(_ files: [URL], move: Bool) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = move ? "Move Here" : "Copy Here"
        panel.message = move
            ? "Move \(files.count == 1 ? "“\(files[0].lastPathComponent)”" : "\(files.count) items") to…"
            : "Copy \(files.count == 1 ? "“\(files[0].lastPathComponent)”" : "\(files.count) items") to…"
        panel.directoryURL = files.first?.deletingLastPathComponent()
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        var done: [URL] = []
        var pairs: [(URL, URL)] = []
        var failed: [String] = []
        for url in files {
            // Moving into the folder it's already in does nothing; into itself is refused.
            if move, url.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL { done.append(url); continue }
            if folder.standardizedFileURL.path.hasPrefix(url.standardizedFileURL.path + "/") || folder.standardizedFileURL == url.standardizedFileURL {
                failed.append("\(url.lastPathComponent) can't go inside itself")
                continue
            }
            let target = Self.freeDestination(for: url, in: folder)
            do {
                if move { try FileManager.default.moveItem(at: url, to: target) } else { try FileManager.default.copyItem(at: url, to: target) }
                done.append(target)
                pairs.append((url, target))
            } catch {
                failed.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        let verb = move ? "Moved" : "Copied"
        if !pairs.isEmpty {
            record?(HistoryItem(id: UUID().uuidString, date: Date(), inputs: pairs.map { $0.0.path }, outputs: pairs.map { $0.1.path },
                                bytesIn: 0, bytesOut: 0, label: "\(verb) to \(folder.lastPathComponent)", format: "", kind: move ? "move" : "copy"))
        }
        if failed.isEmpty {
            say("\(verb) \(done.count == 1 ? done[0].lastPathComponent : "\(done.count) items")", "to \(Self.abbreviated(folder))",
                original: done.first)
        } else {
            say(done.isEmpty ? "Couldn't \(move ? "move" : "copy") that" : "\(verb) \(done.count) of \(files.count)",
                failed.first ?? "", original: done.first)
        }
    }

    // MARK: Feedback by the pointer

    private func say(_ title: String, _ detail: String, original: URL? = nil) {
        shelf.showMessage(title, detail, original: original, accent: accent())
    }
}
