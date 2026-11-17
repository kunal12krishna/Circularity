import AppKit

// AppKit lifecycle for an LSUIElement agent (no Dock icon, no main window).
// SwiftUI is deliberately not loaded at launch (idle RSS budget, PLAN.md §5).
let appDelegate = AppDelegate()
NSApplication.shared.delegate = appDelegate
NSApplication.shared.run()
