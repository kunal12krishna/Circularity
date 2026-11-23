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
    /// `keys`: the wheels whose keys are down at the press.
    case press(CGPoint, keys: Set<WheelKind>, time: TimeInterval)
    case mouseMoved(CGPoint, time: TimeInterval)
    case mouseUp(time: TimeInterval)
    /// The wheel keys that are down now (Shift → Convert, ⌘ → Tools, ⌃ → Actions by default).
    case keysChanged(Set<WheelKind>, time: TimeInterval)
    /// The drag pasteboard now carries files; `allowed` is the trigger policy's verdict.
    case fileDragDetected(allowed: Bool, time: TimeInterval)
    case tick(time: TimeInterval)
    /// The drag left the wheel; the wheel hid itself and the drag goes on.
    case dismissed(keys: Set<WheelKind>, time: TimeInterval)
    /// Something was dropped on the wheel (a segment or the centre).
    case wheelFinished

    /// One trigger key (the Convert wheel's), as before there were three wheels.
    static func mouseDown(_ point: CGPoint, triggerDown: Bool, time: TimeInterval) -> GestureEvent {
        .press(point, keys: triggerDown ? [.convert] : [], time: time)
    }

    static func triggerChanged(isDown: Bool, time: TimeInterval) -> GestureEvent {
        .keysChanged(isDown ? [.convert] : [], time: time)
    }

    static func wheelDismissed(triggerDown: Bool, time: TimeInterval) -> GestureEvent {
        .dismissed(keys: triggerDown ? [.convert] : [], time: time)
    }
}

nonisolated enum GestureEffect: Sendable, Equatable {
    case startSampling
    case stopSampling
    case showWheel(at: CGPoint, reason: WheelOpenReason, kind: WheelKind = .convert)
    /// Another wheel's key went down while a wheel was showing.
    case switchWheel(WheelKind)
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
    /// Wheel keys down now. A key only counts when it goes down during the
    /// drag: one already held when the drag started (Finder's own ⌘- or
    /// Shift-drag) stays out of the way until it is released and pressed again.
    private var keysDown: Set<WheelKind> = []
    private var triggerPressedAt: TimeInterval?
    /// The wheel the last key press asked for.
    private var pendingKind: WheelKind = .convert
    /// The wheel on screen.
    private(set) var shownKind: WheelKind = .convert
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
        case let .press(point, keys, _):
            let effects = endEffects()
            resetDrag()
            phase = .pressed
            pressPoint = point
            lastPoint = point
            keysDown = keys
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

        case let .keysChanged(keys, time):
            let pressed = keys.subtracting(keysDown)
            let released = keysDown.subtracting(keys)
            keysDown = keys
            if config.triggerMode == .hold, released.contains(pendingKind) { triggerPressedAt = nil }
            // Several at once (unlikely): Convert, then Tools, then Actions.
            guard let kind = WheelKind.allCases.first(where: pressed.contains) else { return [] }
            switch phase {
            case .pressed:
                // Pressed before the drag really started: counts as "held at start".
                return []
            case .dragging, .fileDrag:
                pendingKind = kind
                triggerPressedAt = time
                return phase == .fileDrag ? evaluateTrigger(now: time) : []
            case .wheelShown:
                guard kind != shownKind else { return [] }
                shownKind = kind
                return [.switchWheel(kind)]
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

        case let .dismissed(keys, _):
            guard phase == .wheelShown else { return [] }
            phase = .fileDrag
            keysDown = keys
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
            if keysDown.contains(pendingKind), now - since >= max(config.triggerDelay, config.minimumHold) { return open(.trigger) }
        }
        return []
    }

    private mutating func open(_ reason: WheelOpenReason) -> [GestureEffect] {
        phase = .wheelShown
        triggerPressedAt = nil
        shake.reset()
        // A shake always opens Convert.
        shownKind = reason == .shake ? .convert : pendingKind
        return [.showWheel(at: lastPoint, reason: reason, kind: shownKind)]
    }

    private func endEffects() -> [GestureEffect] {
        var effects: [GestureEffect] = []
        if phase == .wheelShown { effects.append(.hideWheel) }
        if isSampling { effects.append(.stopSampling) }
        return effects
    }

    private mutating func resetDrag() {
        triggerPressedAt = nil
        pendingKind = .convert
        shake.reset()
    }
}
