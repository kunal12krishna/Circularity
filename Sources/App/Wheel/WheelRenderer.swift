import AppKit
import QuartzCore

/// Hover/fan state the renderers draw.
struct WheelVisualState: Equatable {
    var hover: WheelTarget = .none
    var fanOpen = false
    var fanFlipped = false
    /// Pointer offset from the centre (y-down), for Orbit's cursor pill.
    var cursor: CGPoint?
}

/// What the centre shows about the files.
struct OrbContent {
    var fileLine: String     // Ring/Halo: "IMG_2041.HEIC · 3.2 MB"
    var title: String        // Orbit: "IMG_2041.HEIC" or "3 images"
    var detail: String       // Orbit: "3.2 MB" or "8.7 MB total"
    var count: Int
    var thumbnail: CGImage?
    var clickMode: Bool
}

/// A wheel look (PLAN.md §3.3). Renderers own a canvas-sized layer tree that
/// is built once and only re-configured; no continuous redraw.
protocol WheelRenderer: AnyObject {
    var layer: CALayer { get }
    /// Ring sits on a behind-window glass disc (NSVisualEffectView).
    var usesGlass: Bool { get }
    /// 3D tilt of the hovered segment (off for offscreen previews).
    var allowsTilt: Bool { get set }
    func configure(menu: WheelMenu, orb: OrbContent, accent: CGColor, geometry: WheelGeometry, contentsScale: CGFloat)
    func setThumbnail(_ image: CGImage?)
    /// Same buttons, new detail lines (live size estimates).
    func updateHints(_ menu: WheelMenu)
    func apply(_ state: WheelVisualState, animated: Bool)
    func popIn()
    func release(to target: WheelTarget, from offset: CGPoint?)
}

/// The centre text for the current hover (PLAN.md §9.1 "Orb copy per hover state").
struct OrbText: Equatable {
    var kicker: String
    var big: String
    var detail: String
    var cancelHot: Bool

    static func make(menu: WheelMenu, state: WheelVisualState, clickMode: Bool) -> OrbText {
        let cancel = OrbText(kicker: clickMode ? "CLICK HERE TO" : "DROP HERE TO", big: "Cancel",
                             detail: "nothing is changed", cancelHot: false)
        switch state.hover {
        case let .segment(i):
            if let s = menu.ring[i] { return OrbText(kicker: s.kicker, big: s.big, detail: s.hint, cancelHot: false) }
        case let .fanChip(k) where k < menu.fan.count:
            let s = menu.fan[k]
            return OrbText(kicker: s.kicker, big: s.big, detail: s.hint, cancelHot: false)
        case .centre:
            if let n = menu.notice { return OrbText(kicker: n.kicker, big: n.big, detail: n.detail, cancelHot: false) }
            var hot = cancel
            hot.cancelHot = true
            return hot
        default:
            break
        }
        if state.fanOpen, let more = menu.ring.compactMap({ $0 }).first(where: { $0.action == .more }) {
            return OrbText(kicker: more.kicker, big: more.big, detail: more.hint, cancelHot: false)
        }
        if let n = menu.notice { return OrbText(kicker: n.kicker, big: n.big, detail: n.detail, cancelHot: false) }
        return cancel
    }
}

extension WheelMenu {
    func slot(for target: WheelTarget) -> WheelSlot? {
        switch target {
        case let .segment(i) where i < ring.count: ring[i]
        case let .fanChip(k) where k < fan.count: fan[k]
        default: nil
        }
    }

    var moreIndex: Int? { ring.firstIndex { $0?.action == .more } }
}

/// Moves a layer, springing from wherever it currently is on screen.
func move(_ layer: CALayer, to position: CGPoint, animated: Bool, delay: CFTimeInterval = 0) {
    let from = layer.presentation()?.position ?? layer.position
    layer.position = position
    if animated, from != position {
        layer.add(Motion.spring("position", from: NSValue(point: from), to: NSValue(point: position), delay: delay),
                  forKey: "position")
    }
}

/// Sets a property inside a short implicit transaction (or none).
func transact(_ duration: CFTimeInterval, animated: Bool, _ body: () -> Void) {
    CATransaction.begin()
    CATransaction.setDisableActions(!animated)
    CATransaction.setAnimationDuration(duration)
    body()
    CATransaction.commit()
}
