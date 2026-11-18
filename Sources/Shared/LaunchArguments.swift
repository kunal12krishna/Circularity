import Foundation

/// Parses the app's command line: file paths to open, plus developer modes
/// (`--render-previews <dir>`, `--drag-test`, `--perf-report [file.md]`, `--check-themes <file.json>`).
nonisolated struct LaunchArguments: Sendable {
    let files: [URL]
    let renderPreviewsDirectory: URL?
    /// `--drag-test`: drive the real wheel panel with simulated drags (PLAN.md §3.9).
    let dragTest: Bool
    /// `--perf-report [file.md]`: measure the budgets (PLAN.md §5).
    let perfReport: Bool
    let perfReportFile: URL?
    /// `--check-themes <file.json>`: Wheel Studio exports must import intact.
    let checkThemesFile: URL?

    init(_ arguments: [String], fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) {
        var files: [URL] = []
        var previews: URL?
        var dragTest = false
        var perf = false
        var perfFile: URL?
        var themesFile: URL?
        var i = 1 // arguments[0] is the executable
        while i < arguments.count {
            let arg = arguments[i]
            if arg == "--render-previews", i + 1 < arguments.count {
                previews = URL(fileURLWithPath: arguments[i + 1], isDirectory: true)
                i += 2
            } else if arg == "--check-themes", i + 1 < arguments.count {
                themesFile = URL(fileURLWithPath: arguments[i + 1])
                i += 2
            } else if arg == "--drag-test" {
                dragTest = true
                i += 1
            } else if arg == "--perf-report" {
                perf = true
                if i + 1 < arguments.count, arguments[i + 1].hasSuffix(".md") {
                    perfFile = URL(fileURLWithPath: arguments[i + 1])
                    i += 2
                } else {
                    i += 1
                }
            } else if arg.hasPrefix("--") {
                i += 1
            } else if arg.hasPrefix("-") {
                // Cocoa user-default overrides such as `-NSDocumentRevisionsDebugMode YES`:
                // skip the flag and its value, unless the value is itself a file to open.
                let next = i + 1 < arguments.count ? arguments[i + 1] : nil
                i += (next != nil && !next!.hasPrefix("-") && !fileExists(next!)) ? 2 : 1
            } else {
                if fileExists(arg) { files.append(URL(fileURLWithPath: arg).standardizedFileURL) }
                i += 1
            }
        }
        self.files = files
        self.renderPreviewsDirectory = previews
        self.dragTest = dragTest
        perfReport = perf
        perfReportFile = perfFile
        checkThemesFile = themesFile
    }
}
