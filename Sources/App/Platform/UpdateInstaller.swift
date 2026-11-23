import AppKit
import CryptoKit

/// Installs an update in place and relaunches (Settings → General → Updates).
///
/// Nothing is replaced unless every check passes:
/// 1. the DMG's SHA-256 matches the feed, and the feed's Ed25519 signature of
///    that hash verifies with the public key built into this app (so only a
///    DMG signed with the release key can install, wherever it's hosted);
/// 2. the app inside has this app's bundle ID and exactly the feed's version,
///    and its code signature verifies.
/// Then a tiny script waits for this app to quit, swaps the bundle (keeping the
/// old one until the new one is in place) and opens the new version.
final class UpdateInstaller: ObservableObject {
    enum State: Equatable {
        case idle, downloading(Double), checking, ready, failed(String)
    }

    @Published private(set) var state = State.idle

    static var publicKey: Curve25519.Signing.PublicKey? {
        guard let hex = Bundle.main.object(forInfoDictionaryKey: "CircularityUpdatePublicKey") as? String,
              let data = Data(hex: hex), data.count == 32 else { return nil }
        return try? Curve25519.Signing.PublicKey(rawRepresentation: data)
    }

    /// The feed is signed and this build knows the key: it can install in place.
    static func canInstall(_ feed: UpdateFeed) -> Bool {
        feed.sha256 != nil && feed.signature != nil && publicKey != nil && URL(string: feed.url)?.scheme == "https"
    }

    /// Where this app lives must be writable to swap it (Applications usually is).
    static var targetIsWritable: Bool {
        FileManager.default.isWritableFile(atPath: Bundle.main.bundleURL.deletingLastPathComponent().path)
    }

    func install(_ feed: UpdateFeed, allowInsecureURL: Bool = false) {
        guard state != .checking, !isDownloading else { return }
        guard let url = URL(string: feed.url), url.scheme == "https" || allowInsecureURL,
              let expectedHash = feed.sha256?.lowercased(), let signature = feed.signature.flatMap(Data.init(hex:)),
              let key = Self.publicKey else {
            state = .failed("This update can't be installed from here. Download it instead.")
            return
        }
        state = .downloading(0)
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("\(AppIdentity.name)-Update-\(UUID().uuidString)")
        Task {
            do {
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                let dmg = work.appendingPathComponent("update.dmg")
                try await download(url, to: dmg)
                state = .checking
                let staged = try await Task.detached(priority: .userInitiated) {
                    try Self.verifyAndStage(dmg: dmg, expectedHash: expectedHash, signature: signature, key: key,
                                            version: feed.version, work: work)
                }.value
                state = .ready
                Log.app.notice("Update \(feed.version, privacy: .public) verified; relaunching into it")
                try Self.swapAndRelaunch(staged: staged, work: work)
            } catch {
                Log.app.error("Update failed: \(error.localizedDescription, privacy: .public)")
                try? FileManager.default.removeItem(at: work) // nothing half-done is left behind
                state = .failed(error.localizedDescription)
            }
        }
    }

    private var isDownloading: Bool { if case .downloading = state { return true }; return false }

    private func download(_ url: URL, to destination: URL) async throws {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 120)
        request.setValue("\(AppIdentity.name)/\(UpdateChecker.currentVersion)", forHTTPHeaderField: "User-Agent")
        let (file, response) = try await URLSession.shared.download(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("the download wasn't found") }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: file, to: destination)
    }

    /// Checks the DMG and copies the app out of it; returns the staged app.
    nonisolated static func verifyAndStage(dmg: URL, expectedHash: String, signature: Data, key: Curve25519.Signing.PublicKey,
                                           version: String, work: URL) throws -> URL {
        let digest = Data(SHA256.hash(data: try Data(contentsOf: dmg, options: .mappedIfSafe)))
        guard digest.hex == expectedHash else { throw UpdateError("the download was damaged (its checksum doesn't match)") }
        guard key.isValidSignature(signature, for: digest) else { throw UpdateError("the download isn't signed by Circularity") }

        let mount = work.appendingPathComponent("mount", isDirectory: true)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        try run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path, dmg.path])
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }
        guard let app = (try FileManager.default.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil))
            .first(where: { $0.pathExtension == "app" }), let info = Bundle(url: app)?.infoDictionary else {
            throw UpdateError("there's no app in the download")
        }
        guard info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier else { throw UpdateError("the download is a different app") }
        guard info["CFBundleShortVersionString"] as? String == version else { throw UpdateError("the download is a different version") }
        try run("/usr/bin/codesign", ["--verify", "--strict", app.path])
        let staged = work.appendingPathComponent(Bundle.main.bundleURL.lastPathComponent)
        try run("/usr/bin/ditto", [app.path, staged.path])
        return staged
    }

    /// Hands over to a script that swaps the app once this one has quit, then opens it.
    private static func swapAndRelaunch(staged: URL, work: URL) throws {
        let script = work.appendingPathComponent("swap.sh")
        try """
        #!/bin/sh
        while kill -0 "$OLD_PID" 2>/dev/null; do sleep 0.2; done
        rm -rf "$TARGET.old"
        if mv "$TARGET" "$TARGET.old" && mv "$STAGED" "$TARGET"; then
            rm -rf "$TARGET.old"
        elif [ -d "$TARGET.old" ] && [ ! -d "$TARGET" ]; then
            mv "$TARGET.old" "$TARGET"
        fi
        xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null
        open "$TARGET"
        rm -rf "$WORK"
        """.write(to: script, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path]
        process.environment = ["OLD_PID": String(ProcessInfo.processInfo.processIdentifier),
                               "TARGET": Bundle.main.bundleURL.path, "STAGED": staged.path, "WORK": work.path,
                               "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        try process.run()
        NSApp.terminate(nil)
    }

    @discardableResult
    nonisolated private static func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = out
        try process.run()
        process.waitUntilExit()
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw UpdateError("\((tool as NSString).lastPathComponent) failed: \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return text
    }
}

struct UpdateError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { "Couldn't update: \(message)." }
}

nonisolated extension Data {
    init?(hex: String) {
        let s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.count % 2 == 0 else { return nil }
        var data = Data(capacity: s.count / 2)
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            guard let byte = UInt8(s[i..<j], radix: 16) else { return nil }
            data.append(byte)
            i = j
        }
        self = data
    }

    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
