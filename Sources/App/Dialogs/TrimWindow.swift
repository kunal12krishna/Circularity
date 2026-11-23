import AVKit
import AppKit

/// Trim (video and audio): macOS's own trimming bar, the one QuickTime Player
/// uses. Drag the yellow handles, press Trim, and the job keeps that part.
final class TrimWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var playerView: AVPlayerView?
    private var waiter: Task<Void, Never>?

    func show(_ url: URL, isVideo: Bool, onTrim: @escaping (Double, Double) -> Void) {
        close()
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = false
        view.videoGravity = .resizeAspect
        let size = isVideo ? CGSize(width: 760, height: 470) : CGSize(width: 620, height: 150)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Trim · \(url.lastPathComponent)"
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.delegate = self
        window.minSize = isVideo ? CGSize(width: 480, height: 300) : CGSize(width: 480, height: 120)
        window.center()
        self.window = window
        playerView = view
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        // The trimming bar can start once the item is ready (usually at once).
        waiter = Task { @MainActor [weak self, weak view] in
            for _ in 0..<200 {
                guard let view, !Task.isCancelled else { return }
                if view.canBeginTrimming {
                    let result = await view.beginTrimming()
                    guard let self else { return }
                    if result == .okButton {
                        let duration = item.duration.seconds
                        let start = item.reversePlaybackEndTime.isValid ? item.reversePlaybackEndTime.seconds : 0
                        let end = item.forwardPlaybackEndTime.isValid ? item.forwardPlaybackEndTime.seconds : duration
                        let whole = start <= 0.01 && (!duration.isFinite || end >= duration - 0.01)
                        Log.app.notice("Trim: \(start, privacy: .public)–\(end, privacy: .public) of \(duration, privacy: .public) s")
                        self.close()
                        if !whole, end > start { onTrim(max(0, start), end) }
                    } else {
                        Log.app.notice("Trim cancelled")
                        self.close()
                    }
                    return
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            Log.app.error("Trim: this file can't be trimmed here")
            self?.close()
        }
    }

    func close() {
        waiter?.cancel()
        waiter = nil
        playerView?.player?.pause()
        playerView?.player = nil
        playerView = nil
        window?.delegate = nil
        window?.close()
        window = nil
    }

    func windowWillClose(_ notification: Notification) {
        waiter?.cancel()
        playerView?.player?.pause()
        playerView?.player = nil
        playerView = nil
        window = nil
    }
}
