import CoreGraphics
import Foundation

nonisolated enum WheelLayoutKind: String, Sendable, CaseIterable {
    case ring, orbit, halo
}

/// What the pointer is over.
nonisolated enum WheelTarget: Sendable, Equatable, Hashable {
    case none
    case centre
    case segment(Int)
    case fanChip(Int)
}

/// Pure wheel geometry (PLAN.md §3.3, §9.1). Angles follow the boards:
/// degrees, 0 = 12 o'clock, clockwise. Offsets are relative to the wheel
/// centre in a **y-down** space (as in the boards); renderers flip y.
nonisolated struct WheelGeometry: Sendable, Equatable {
    var kind: WheelLayoutKind
    var scale: CGFloat = 1

    // Values at scale 1, in points.
    var canvas: CGFloat = 720
    var segmentSpan: CGFloat
    var restInner: CGFloat
    var restOuter: CGFloat
    var hoverInner: CGFloat
    var hoverOuter: CGFloat
    var orbDiameter: CGFloat
    var discDiameter: CGFloat
    /// Orbit only: radius of the button centres and button size.
    var buttonRadius: CGFloat = 0
    var buttonDiameter: CGFloat = 0
    var buttonHoverScale: CGFloat = 1
    var fanRadius: CGFloat
    var fanStep: CGFloat
    var fanChipSize: CGSize
    var fanHoverScale: CGFloat
    var dismissMargin: CGFloat = 24

    static let segmentCount = 6
    static let moreSlot = 3

    /// Board D (`wheel-D-chosen.html`).
    static func ring(scale: CGFloat = 1) -> WheelGeometry {
        WheelGeometry(kind: .ring, scale: scale, segmentSpan: 57, restInner: 98, restOuter: 204,
                      hoverInner: 92, hoverOuter: 216, orbDiameter: 180, discDiameter: 436,
                      fanRadius: 270, fanStep: 21, fanChipSize: CGSize(width: 56, height: 56), fanHoverScale: 1.14)
    }

    /// Board C (`wheel-C-halo.html`).
    static func halo(scale: CGFloat = 1) -> WheelGeometry {
        WheelGeometry(kind: .halo, scale: scale, segmentSpan: 58, restInner: 120, restOuter: 188,
                      hoverInner: 116, hoverOuter: 198, orbDiameter: 230, discDiameter: 424,
                      fanRadius: 240, fanStep: 20, fanChipSize: CGSize(width: 72, height: 32), fanHoverScale: 1)
    }

    /// Board B (`wheel-B-orbit.html`).
    static func orbit(scale: CGFloat = 1) -> WheelGeometry {
        WheelGeometry(kind: .orbit, scale: scale, segmentSpan: 60, restInner: 70, restOuter: 209,
                      hoverInner: 70, hoverOuter: 216, orbDiameter: 140, discDiameter: 432,
                      buttonRadius: 165, buttonDiameter: 88, buttonHoverScale: 1.16,
                      fanRadius: 262, fanStep: 24, fanChipSize: CGSize(width: 72, height: 36), fanHoverScale: 1.12)
    }

    static func make(_ kind: WheelLayoutKind, scale: CGFloat = 1) -> WheelGeometry {
        switch kind {
        case .ring: ring(scale: scale)
        case .halo: halo(scale: scale)
        case .orbit: orbit(scale: scale)
        }
    }

    // MARK: Basics

    var size: CGFloat { canvas * scale }
    var orbRadius: CGFloat { orbDiameter / 2 * scale }

    /// Largest radius that still counts as "on the wheel".
    var outerExtent: CGFloat {
        switch kind {
        case .ring: hoverOuter * scale
        case .halo: discDiameter / 2 * scale
        case .orbit: (buttonRadius + buttonDiameter / 2 * buttonHoverScale) * scale
        }
    }

    static func midAngle(ofSlot slot: Int) -> CGFloat { CGFloat(slot) * 60 }

    /// Offset of a point at `radius`/`angle` from the centre (y-down).
    static func offset(radius: CGFloat, angle: CGFloat) -> CGPoint {
        let t = angle * .pi / 180
        return CGPoint(x: radius * sin(t), y: -radius * cos(t))
    }

    /// Clock angle (0…360) of an offset (y-down).
    static func angle(of offset: CGPoint) -> CGFloat {
        var degrees = atan2(offset.x, -offset.y) * 180 / .pi
        if degrees < 0 { degrees += 360 }
        return degrees
    }

    func inner(hovered: Bool) -> CGFloat { (hovered ? hoverInner : restInner) * scale }
    func outer(hovered: Bool) -> CGFloat { (hovered ? hoverOuter : restOuter) * scale }

    /// Where a slot's icon + label (or Orbit button) is centred.
    func contentRadius(hovered: Bool) -> CGFloat {
        kind == .orbit ? buttonRadius * scale : (inner(hovered: hovered) + outer(hovered: hovered)) / 2
    }

    // MARK: More fan

    /// Chip angles, centred on More (180°) or, when flipped, on 12 o'clock.
    /// Either way formats sit on the right and Crop (last) on the left.
    func fanAngles(count: Int, flipped: Bool) -> [CGFloat] {
        let middle = CGFloat(count - 1) / 2
        return (0..<count).map { k in
            flipped ? (middle - CGFloat(k)) * fanStep : 180 + (CGFloat(k) - middle) * fanStep
        }
    }

    func fanOffsets(count: Int, flipped: Bool) -> [CGPoint] {
        fanAngles(count: count, flipped: flipped).map { Self.offset(radius: fanRadius * scale, angle: $0) }
    }

    /// True when any chip would leave `visibleFrame` (screen space, y-up) with
    /// the wheel centred at `center` (screen space).
    func fanNeedsFlip(center: CGPoint, visibleFrame: CGRect, count: Int) -> Bool {
        let w = fanChipSize.width * fanHoverScale * scale, h = fanChipSize.height * fanHoverScale * scale
        return fanOffsets(count: count, flipped: false).contains { o in
            let chip = CGRect(x: center.x + o.x - w / 2, y: center.y - o.y - h / 2, width: w, height: h)
            return !visibleFrame.contains(chip)
        }
    }

    // MARK: Hit testing

    /// What is under `offset` (y-down, relative to the centre).
    func hitTest(_ offset: CGPoint, fanCount: Int, fanOpen: Bool, fanFlipped: Bool) -> WheelTarget {
        if fanOpen {
            let hitRadius = max(fanChipSize.width, fanChipSize.height) / 2 * fanHoverScale * scale + 6 * scale
            for (k, chip) in fanOffsets(count: fanCount, flipped: fanFlipped).enumerated()
            where hypot(offset.x - chip.x, offset.y - chip.y) <= hitRadius {
                return .fanChip(k)
            }
        }
        let distance = hypot(offset.x, offset.y)
        if distance <= orbRadius { return .centre }
        if distance <= outerExtent {
            // No dead zones: the gaps between segments belong to the nearest one.
            let slot = Int((Self.angle(of: offset) + 30) / 60) % Self.segmentCount
            return .segment(slot)
        }
        return .none
    }

    /// True when the pointer has moved far enough away that the wheel should
    /// get out of the way. The open fan extends the area in its own direction.
    func isBeyondDismissDistance(_ offset: CGPoint, fanCount: Int, fanOpen: Bool, fanFlipped: Bool) -> Bool {
        let distance = hypot(offset.x, offset.y)
        var limit = outerExtent + dismissMargin * scale
        if fanOpen, fanCount > 0 {
            let angles = fanAngles(count: fanCount, flipped: fanFlipped)
            let angle = Self.angle(of: offset)
            let low = (angles.min() ?? 0) - fanStep, high = (angles.max() ?? 0) + fanStep
            let inSector = fanFlipped
                ? (angle >= 360 + low || angle <= high)
                : (angle >= low && angle <= high)
            if inSector {
                limit = (fanRadius + max(fanChipSize.width, fanChipSize.height) / 2 * fanHoverScale + dismissMargin) * scale
            }
        }
        return distance > limit
    }
}
