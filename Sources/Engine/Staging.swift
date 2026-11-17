import Foundation

/// Atomic output (PLAN.md §3.1): backends write into a private work folder on
/// the destination's volume; only a finished file is moved into place under a
/// reserved, collision-free name. Failures and cancellations leave nothing behind.
struct Staging {
    let destination: URL
    let workDir: URL
    let usedFallback: Bool

    static func make(for input: URL, policy: OutputPolicy) throws -> Staging {
        let fm = FileManager.default
        var dir: URL = switch policy.destination {
        case .nextToOriginal: input.deletingLastPathComponent()
        case let .folder(url): url
        }
        var fallback = false
        if !fm.isWritableFile(atPath: dir.path) {
            dir = Self.firstWritable(policy.fallbackFolders) ?? policy.fallbackFolder
            fallback = true
        }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let work: URL
        do {
            work = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: dir, create: true)
        } catch {
            // Some volumes have no replacement directory: stage in a hidden folder beside the output.
            work = dir.appendingPathComponent(".\(UUID().uuidString).circularity", isDirectory: true)
            do { try fm.createDirectory(at: work, withIntermediateDirectories: true) } catch {
                guard !fallback else { throw JobError.writeFailed(error.localizedDescription) }
                var p = policy
                p.destination = .folder(policy.fallbackFolder)
                return try make(for: input, policy: p).withFallbackFlag()
            }
        }
        return Staging(destination: dir, workDir: work, usedFallback: fallback)
    }

    private func withFallbackFlag() -> Staging { Staging(destination: destination, workDir: workDir, usedFallback: true) }

    /// A scratch path for the backend to write.
    func scratch(_ ext: String) -> URL {
        workDir.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
    }

    /// Moves a finished file (or folder) into the destination under a free name.
    /// If macOS refuses the folder (for example Desktop/Downloads access was
    /// declined), the result goes to the first fallback folder that accepts it.
    func publish(_ staged: URL, planner: OutputPlanner, template: NamingTemplate, context: NamingContext,
                 fileExtension: String? = nil, fallbacks: [URL] = [], collision: CollisionStyle = .number) async throws -> URL {
        var lastError: Error?
        for folder in [destination] + fallbacks.filter({ $0 != destination }) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let final = await planner.reserve(in: folder, template: template, context: context,
                                              fileExtensionOverride: fileExtension, collision: collision)
            do {
                try FileManager.default.moveItem(at: staged, to: final)
                await planner.release(final)
                return final
            } catch {
                await planner.release(final)
                lastError = error
                guard Self.isPermissionError(error) else { break }
            }
        }
        throw JobError.writeFailed(lastError?.localizedDescription ?? "unknown error")
    }

    static func firstWritable(_ folders: [URL]) -> URL? {
        let fm = FileManager.default
        return folders.first { folder in
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            return fm.isWritableFile(atPath: folder.path)
        }
    }

    static func isPermissionError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, [NSFileWriteNoPermissionError, NSFileWriteVolumeReadOnlyError].contains(ns.code) { return true }
        let posix = (ns.userInfo[NSUnderlyingErrorKey] as? NSError) ?? ns
        return posix.domain == NSPOSIXErrorDomain && [Int(EPERM), Int(EACCES), Int(EROFS)].contains(posix.code)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: workDir)
    }
}
