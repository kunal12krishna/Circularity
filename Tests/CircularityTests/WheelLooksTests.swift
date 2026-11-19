@testable import CircularityEngine
import XCTest

/// Wheel Studio looks that live in shared geometry (the Studio's canvas uses the same numbers).
final class WheelLooksTests: XCTestCase {
    func testHoverPopOfOneIsTheBoard() {
        for kind in WheelLayoutKind.allCases {
            XCTAssertEqual(WheelGeometry.make(kind, tweaks: WheelTweaks(pop: 1)), WheelGeometry.make(kind), "\(kind)")
        }
    }

    func testHoverPopScalesTheBulge() {
        let board = WheelGeometry.ring(), flat = WheelGeometry.make(.ring, tweaks: WheelTweaks(pop: 0))
        XCTAssertEqual(flat.hoverOuter, flat.restOuter)
        XCTAssertEqual(flat.hoverInner, flat.restInner)
        let big = WheelGeometry.make(.ring, tweaks: WheelTweaks(pop: 2))
        XCTAssertEqual(big.hoverOuter - big.restOuter, 2 * (board.hoverOuter - board.restOuter), accuracy: 0.001)
        XCTAssertEqual(big.restInner - big.hoverInner, 2 * (board.restInner - board.hoverInner), accuracy: 0.001)
        XCTAssertEqual(WheelGeometry.make(.orbit, tweaks: WheelTweaks(pop: 2)).buttonHoverScale, 1.32, accuracy: 0.001)
        // Out of range is clamped, and a bigger bulge still fits the disc.
        let huge = WheelGeometry.make(.halo, tweaks: WheelTweaks(pop: 9))
        XCTAssertEqual(huge.hoverOuter - huge.restOuter, 2.5 * 10, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(huge.discDiameter, (huge.hoverOuter + 2) * 2)
    }
}
