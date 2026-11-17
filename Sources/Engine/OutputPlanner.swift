import Foundation

/// Hands out final output URLs. Reservation is serialised inside the actor so
/// two concurrent jobs can never pick the same name (PLAN.md §3.1).
/// Milestone (d) adds destinations (next to original / folder / per-type) and
/// the ~/Documents/Converted fallback.
public actor OutputPlanner {
    private var reserved: Set<String> = []
    private let fileExists: @Sendable (String) -> Bool

    public init(fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) {
        self.fileExists = fileExists
    }

    /// Reserves and returns a free URL in `directory`. Call `release(_:)` once
    /// the file has been moved into place (or the job failed).
    public func reserve(in directory: URL, template: NamingTemplate = .default, context: NamingContext,
                        fileExtensionOverride: String? = nil) -> URL {
        let base = OutputNaming.baseName(template: template, context: context)
        let ext = fileExtensionOverride ?? context.format.fileExtension
        let name = OutputNaming.uniqueFileName(base: base, fileExtension: ext) { candidate in
            let path = directory.appendingPathComponent(candidate).path
            return reserved.contains(path) || fileExists(path)
        }
        let url = directory.appendingPathComponent(name)
        reserved.insert(url.path)
        return url
    }

    public func release(_ url: URL) {
        reserved.remove(url.path)
    }

    public var reservedCount: Int { reserved.count }
}
