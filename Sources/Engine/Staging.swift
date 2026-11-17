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
            dir = policy.fallbackFolder
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
    func publish(_ staged: URL, planner: OutputPlanner, template: NamingTemplate, context: NamingContext,
                 fileExtension: String? = nil) async throws -> URL {
        let final = await planner.reserve(in: destination, template: template, context: context,
                                          fileExtensionOverride: fileExtension)
        defer { Task { await planner.release(final) } }
        do {
            try FileManager.default.moveItem(at: staged, to: final)
        } catch {
            throw JobError.writeFailed(error.localizedDescription)
        }
        return final
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: workDir)
    }
}
