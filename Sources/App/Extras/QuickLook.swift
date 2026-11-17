import AppKit
@preconcurrency import Quartz

/// Space-bar Quick Look for Recent rows.
final class QuickLook: NSObject, QLPreviewPanelDataSource {
    static let shared = QuickLook()
    private var items: [URL] = []

    func show(_ urls: [URL]) {
        items = urls
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.reloadData()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { items.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        let path: String? = MainActor.assumeIsolated { items.indices.contains(index) ? items[index].path : nil }
        return path.map { NSURL(fileURLWithPath: $0) }
    }
}
