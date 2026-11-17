import CoreGraphics
import Foundation

nonisolated enum TriggerMode: String, Sendable, CaseIterable {
    /// The wheel opens when the trigger key goes down (after the delay).
    case tap
    /// The trigger key must stay down for the delay (at least `minimumHold`).
    case hold
}

nonisolated struct GestureConfig: Sendable, Equatable {
    var triggerMode: TriggerMode = .tap
    var triggerDelay: TimeInterval = 0
    var minimumHold: TimeInterval = 0.25
    var dragThreshold: CGFloat = 4
    var shakeEnabled = true
    var shake: ShakeDetector.Thresholds = .medium
}

nonisolated enum WheelOpenReason: String, Sendable {
    case trigger, shake
}

nonisolated enum GestureEvent: Sendable, Equatable {
    case mouseDown(CGPoint, triggerDown: Bool, time: TimeInterval)
    case mouseMoved(CGPoint, time: TimeInterval)
    case mouseUp(time: TimeInterval)
    case triggerChanged(isDown: Bool, time: TimeInterval)
    /// The drag pasteboard now carries files; `allowed` is the trigger policy's verdict.
    case fileDragDetected(allowed: Bool, time: TimeInterval)
    case tick(time: TimeInterval)
    /// The drag left the wheel; the wheel hid itself and the drag goes on.
    case wheelDismissed(triggerDown: Bool, time: TimeInterval)
    /// Something was dropped on the wheel (a segment or the centre).
    case wheelFinished
}

nonisolated enum GestureEffect: Sendable, Equatable {
    case startSampling
    case stopSampling
    case showWheel(at: CGPoint, reason: WheelOpenReason)
    case hideWheel
}

/// The Shift-drag gesture (PLAN.md §3.2) as a pure state machine:
/// `(state, event) → (state, effects)`. No AppKit; fully unit-tested.
nonisolated struct GestureStateMachine: Sendable {
    enum Phase: Sendable, Equatable {
        case idle
        case pressed      // button down, not moved enough yet
        case dragging     // moving, no files on the drag pasteboard yet
        case fileDrag     // a file drag: waiting for the trigger or a shake
        case wheelShown
        case finished     // dropped on the wheel; nothing more until mouse up
        case blocked      // paused, excluded app or full screen
    }

    private(set) var phase: Phase = .idle
    private(set) var lastPoint: CGPoint = .zero
    var config: GestureConfig {
        didSet { shake.thresholds = config.shake }
    }

    private var pressPoint: CGPoint = .zero
    private var triggerDown = false
    /// The trigger was already down when the drag started: stay out of the way
    /// until it is released and pressed again.
    private var mustReleaseTrigger = false
    private var triggerPressedAt: TimeInterval?
    private var shake: ShakeDetector

    init(config: GestureConfig = GestureConfig()) {
        self.config = config
        shake = ShakeDetector(thresholds: config.shake)
    }

    var isSampling: Bool {
        switch phase {
        case .idle, .pressed: false
        default: true
        }
    }

    mutating func handle(_ event: GestureEvent) -> [GestureEffect] {
        switch event {
        case let .mouseDown(point, down, _):
            let effects = endEffects()
            resetDrag()
            phase = .pressed
            pressPoint = point
            lastPoint = point
            triggerDown = down
            mustReleaseTrigger = down
            return effects

        case let .mouseMoved(point, time):
            lastPoint = point
            switch phase {
            case .pressed:
                if hypot(point.x - pressPoint.x, point.y - pressPoint.y) > config.dragThreshold {
                    phase = .dragging
                    return [.startSampling]
                }
            case .fileDrag:
                if config.shakeEnabled, shake.add(x: point.x, time: time) {
                    return open(.shake)
                }
            default:
                break
            }
            return []

        case .mouseUp:
            let effects = endEffects()
            resetDrag()
            phase = .idle
            return effects

        case let .triggerChanged(isDown, time):
            guard isDown != triggerDown else { return [] }
            triggerDown = isDown
            guard isDown else {
                mustReleaseTrigger = false
                if config.triggerMode == .hold { triggerPressedAt = nil }
                return []
            }
            switch phase {
            case .pressed:
                // Pressed before the drag really started: counts as "held at start".
                mustReleaseTrigger = true
                return []
            case .dragging, .fileDrag:
                guard !mustReleaseTrigger else { return [] }
                triggerPressedAt = time
                return phase == .fileDrag ? evaluateTrigger(now: time) : []
            default:
                return []
            }

        case let .fileDragDetected(allowed, time):
            guard phase == .pressed || phase == .dragging else { return [] }
            let effects: [GestureEffect] = phase == .pressed ? [.startSampling] : []
            guard allowed else {
                phase = .blocked
                return effects
            }
            phase = .fileDrag
            shake.reset()
            return effects + evaluateTrigger(now: time)

        case let .tick(time):
            return phase == .fileDrag ? evaluateTrigger(now: time) : []

        case let .wheelDismissed(down, _):
            guard phase == .wheelShown else { return [] }
            phase = .fileDrag
            triggerDown = down
            mustReleaseTrigger = down
            triggerPressedAt = nil
            shake.reset()
            return []

        case .wheelFinished:
            if phase == .wheelShown { phase = .finished }
            return []
        }
    }

    private mutating func evaluateTrigger(now: TimeInterval) -> [GestureEffect] {
        guard phase == .fileDrag, let since = triggerPressedAt else { return [] }
        switch config.triggerMode {
        case .tap:
            if now - since >= config.triggerDelay { return open(.trigger) }
        case .hold:
            if triggerDown, now - since >= max(config.triggerDelay, config.minimumHold) { return open(.trigger) }
        }
        return []
    }

    private mutating func open(_ reason: WheelOpenReason) -> [GestureEffect] {
        phase = .wheelShown
        triggerPressedAt = nil
        shake.reset()
        return [.showWheel(at: lastPoint, reason: reason)]
    }

    private func endEffects() -> [GestureEffect] {
        var effects: [GestureEffect] = []
        if phase == .wheelShown { effects.append(.hideWheel) }
        if isSampling { effects.append(.stopSampling) }
        return effects
    }

    private mutating func resetDrag() {
        triggerPressedAt = nil
        mustReleaseTrigger = false
        shake.reset()
    }
}
