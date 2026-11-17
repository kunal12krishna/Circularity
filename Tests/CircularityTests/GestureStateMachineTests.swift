import CoreGraphics
import XCTest

final class GestureStateMachineTests: XCTestCase {
    private var machine = GestureStateMachine()
    private var t: TimeInterval = 100

    private func send(_ e: GestureEvent) -> [GestureEffect] { machine.handle(e) }

    /// Press, move past the threshold, and let the drag pasteboard confirm files.
    private func startFileDrag(triggerHeld: Bool = false, allowed: Bool = true) -> [GestureEffect] {
        var effects = send(.mouseDown(CGPoint(x: 100, y: 100), triggerDown: triggerHeld, time: t))
        t += 0.05
        effects += send(.mouseMoved(CGPoint(x: 110, y: 100), time: t))
        effects += send(.fileDragDetected(allowed: allowed, time: t))
        return effects
    }

    private func isShow(_ effects: [GestureEffect]) -> Bool {
        effects.contains { if case .showWheel = $0 { return true }; return false }
    }

    func testTapOpensTheWheel() {
        XCTAssertEqual(startFileDrag(), [.startSampling])
        XCTAssertEqual(machine.phase, .fileDrag)
        t += 0.2
        let effects = send(.triggerChanged(isDown: true, time: t))
        XCTAssertEqual(effects, [.showWheel(at: CGPoint(x: 110, y: 100), reason: .trigger)])
        XCTAssertEqual(machine.phase, .wheelShown)
    }

    func testSmallMovesAreNotADrag() {
        _ = send(.mouseDown(CGPoint(x: 0, y: 0), triggerDown: false, time: t))
        XCTAssertEqual(send(.mouseMoved(CGPoint(x: 3, y: 0), time: t)), [])
        XCTAssertEqual(machine.phase, .pressed)
    }

    func testNoFilesMeansNoWheel() {
        _ = send(.mouseDown(CGPoint(x: 0, y: 0), triggerDown: false, time: t))
        _ = send(.mouseMoved(CGPoint(x: 20, y: 0), time: t))
        XCTAssertFalse(isShow(send(.triggerChanged(isDown: true, time: t + 0.1))))
        XCTAssertEqual(machine.phase, .dragging)
    }

    func testTriggerHeldAtDragStartStaysOutOfTheWay() {
        _ = startFileDrag(triggerHeld: true)
        XCTAssertFalse(isShow(send(.tick(time: t + 0.5))), "held from the start: Finder's own Shift-drag")
        XCTAssertFalse(isShow(send(.triggerChanged(isDown: true, time: t + 0.6))))
        _ = send(.triggerChanged(isDown: false, time: t + 0.7))
        XCTAssertTrue(isShow(send(.triggerChanged(isDown: true, time: t + 0.8))), "released and pressed again")
    }

    func testTriggerPressedBeforeMovingCountsAsHeldAtStart() {
        _ = send(.mouseDown(CGPoint(x: 0, y: 0), triggerDown: false, time: t))
        _ = send(.triggerChanged(isDown: true, time: t + 0.01))
        _ = send(.mouseMoved(CGPoint(x: 30, y: 0), time: t + 0.02))
        XCTAssertFalse(isShow(send(.fileDragDetected(allowed: true, time: t + 0.03))))
    }

    func testTriggerPressedBeforeFilesConfirmOpensOnConfirm() {
        _ = send(.mouseDown(CGPoint(x: 0, y: 0), triggerDown: false, time: t))
        _ = send(.mouseMoved(CGPoint(x: 30, y: 0), time: t + 0.01))
        _ = send(.triggerChanged(isDown: true, time: t + 0.02))
        XCTAssertTrue(isShow(send(.fileDragDetected(allowed: true, time: t + 0.03))))
    }

    func testHoldModeNeedsTheKeyHeldForTheDelay() {
        machine.config.triggerMode = .hold
        machine.config.triggerDelay = 0.3
        _ = startFileDrag()
        _ = send(.triggerChanged(isDown: true, time: t))
        XCTAssertFalse(isShow(send(.tick(time: t + 0.2))))
        XCTAssertTrue(isShow(send(.tick(time: t + 0.31))))
    }

    func testHoldModeReleaseCancels() {
        machine.config.triggerMode = .hold
        _ = startFileDrag()
        _ = send(.triggerChanged(isDown: true, time: t))
        _ = send(.triggerChanged(isDown: false, time: t + 0.1))
        XCTAssertFalse(isShow(send(.tick(time: t + 1))))
    }

    func testTapWithDelayOpensAfterTheDelayEvenIfReleased() {
        machine.config.triggerDelay = 0.2
        _ = startFileDrag()
        XCTAssertFalse(isShow(send(.triggerChanged(isDown: true, time: t))))
        _ = send(.triggerChanged(isDown: false, time: t + 0.05))
        XCTAssertTrue(isShow(send(.tick(time: t + 0.21))))
    }

    func testBlockedByPolicy() {
        _ = startFileDrag(allowed: false)
        XCTAssertEqual(machine.phase, .blocked)
        XCTAssertFalse(isShow(send(.triggerChanged(isDown: true, time: t + 0.1))))
    }

    func testDismissedWheelCanBeReopenedInTheSameDrag() {
        _ = startFileDrag()
        _ = send(.triggerChanged(isDown: true, time: t))
        _ = send(.wheelDismissed(triggerDown: true, time: t + 0.5))
        XCTAssertEqual(machine.phase, .fileDrag)
        XCTAssertFalse(isShow(send(.tick(time: t + 0.6))), "still holding the key from last time")
        _ = send(.triggerChanged(isDown: false, time: t + 0.7))
        XCTAssertTrue(isShow(send(.triggerChanged(isDown: true, time: t + 0.8))))
    }

    func testMouseUpHidesAndStopsSampling() {
        _ = startFileDrag()
        _ = send(.triggerChanged(isDown: true, time: t))
        XCTAssertEqual(send(.mouseUp(time: t + 1)), [.hideWheel, .stopSampling])
        XCTAssertEqual(machine.phase, .idle)
    }

    func testAfterADropNothingMoreHappensUntilMouseUp() {
        _ = startFileDrag()
        _ = send(.triggerChanged(isDown: true, time: t))
        _ = send(.wheelFinished)
        XCTAssertEqual(machine.phase, .finished)
        XCTAssertEqual(send(.mouseUp(time: t + 1)), [.stopSampling])
    }

    func testShakeOpensTheWheel() {
        _ = startFileDrag()
        var opened = false
        for (i, x) in [110, 170, 110, 170, 110].enumerated() {
            opened = opened || isShow(send(.mouseMoved(CGPoint(x: CGFloat(x), y: 100), time: t + Double(i) * 0.08)))
        }
        XCTAssertTrue(opened)
    }

    func testShakeCanBeTurnedOff() {
        machine.config.shakeEnabled = false
        _ = startFileDrag()
        var opened = false
        for (i, x) in [110, 170, 110, 170, 110, 170].enumerated() {
            opened = opened || isShow(send(.mouseMoved(CGPoint(x: CGFloat(x), y: 100), time: t + Double(i) * 0.08)))
        }
        XCTAssertFalse(opened)
    }
}

final class ShakeDetectorTests: XCTestCase {
    private func run(_ xs: [CGFloat], every dt: TimeInterval, thresholds: ShakeDetector.Thresholds = .medium) -> Bool {
        var d = ShakeDetector(thresholds: thresholds)
        var fired = false
        for (i, x) in xs.enumerated() where d.add(x: x, time: Double(i) * dt) { fired = true }
        return fired
    }

    /// 60 Hz samples moving linearly between waypoints.
    private func path(_ waypoints: [CGFloat], samplesPerLeg: Int) -> [CGFloat] {
        var xs: [CGFloat] = []
        for (a, b) in zip(waypoints, waypoints.dropFirst()) {
            for k in 0..<samplesPerLeg { xs.append(a + (b - a) * CGFloat(k) / CGFloat(samplesPerLeg)) }
        }
        return xs + [waypoints.last ?? 0]
    }

    func testAQuickShakeFires() {
        XCTAssertTrue(run(path([0, 60, 0, 60, 0], samplesPerLeg: 6), every: 1.0 / 60))
    }

    func testANormalDragAcrossTheScreenDoesNot() {
        XCTAssertFalse(run(path([0, 1400], samplesPerLeg: 90), every: 1.0 / 60))
    }

    func testOvershootAndCorrectDoesNot() {
        XCTAssertFalse(run(path([0, 500, 440, 470], samplesPerLeg: 20), every: 1.0 / 60))
    }

    func testSmallJitterDoesNot() {
        XCTAssertFalse(run(path([0, 15, 0, 15, 0, 15, 0, 15], samplesPerLeg: 3), every: 1.0 / 60))
    }

    func testASlowBackAndForthDoesNot() {
        // Hovering over a folder, drifting left and right over ~3 s.
        XCTAssertFalse(run(path([0, 80, 0, 80, 0], samplesPerLeg: 45), every: 1.0 / 60))
    }

    func testSensitivityNames() {
        XCTAssertEqual(ShakeDetector.Thresholds.named("low"), .low)
        XCTAssertEqual(ShakeDetector.Thresholds.named("unknown"), .medium)
        XCTAssertFalse(run(path([0, 45, 0, 45, 0], samplesPerLeg: 6), every: 1.0 / 60, thresholds: .low))
        XCTAssertTrue(run(path([0, 45, 0, 45, 0], samplesPerLeg: 6), every: 1.0 / 60, thresholds: .medium))
    }
}
