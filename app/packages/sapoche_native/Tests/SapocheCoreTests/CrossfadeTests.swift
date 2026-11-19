import XCTest
@testable import SapocheCore

final class CrossfadeTests: XCTestCase {
    /// The same table is in `CrossfadeTest.kt` and `crossfade_test.dart`: the three platforms fade by the same amount.
    private let table: [(position: Int64, duration: Int64, seconds: Int, fadeIn: Bool, fadeOut: Bool, level: Float)] = [
        // 6 s: the start fades in over 3 s, the end out over 6 s
        (0, 200_000, 6, true, true, 0),
        (750, 200_000, 6, true, true, 0.1464),
        (1_500, 200_000, 6, true, true, 0.5),
        (2_250, 200_000, 6, true, true, 0.8536),
        (3_000, 200_000, 6, true, true, 1),
        (100_000, 200_000, 6, true, true, 1),
        (194_000, 200_000, 6, true, true, 1),
        (195_500, 200_000, 6, true, true, 0.8536),
        (197_000, 200_000, 6, true, true, 0.5),
        (198_500, 200_000, 6, true, true, 0.1464),
        (200_000, 200_000, 6, true, true, 0),
        (201_000, 200_000, 6, true, true, 0),
        // A song that did not come by itself starts at full, one with nothing after it ends at full
        (0, 200_000, 6, false, true, 1),
        (200_000, 200_000, 6, true, false, 1),
        // Off, and songs shorter than three times the fade
        (0, 200_000, 0, true, true, 1),
        (0, 17_999, 6, true, true, 1),
        (17_999, 17_999, 6, true, true, 1),
        (0, 18_000, 6, true, true, 0),
        // The shortest and the longest setting
        (500, 200_000, 1, true, true, 1),
        (199_500, 200_000, 1, true, true, 0.5),
        (6_000, 600_000, 12, true, true, 1),
        (3_000, 600_000, 12, true, true, 0.5),
    ]

    func testTheVolumeOfAPositionFollowsTheTable() {
        for r in table {
            let level = Crossfade.ramp(positionMs: r.position, durationMs: r.duration, seconds: r.seconds, fadeIn: r.fadeIn, fadeOut: r.fadeOut)
            XCTAssertEqual(level, r.level, accuracy: 0.0001, "\(r.position) of \(r.duration) ms, \(r.seconds) s")
        }
    }

    func testASecondsValueOutOfRangeIsNoFade() {
        XCTAssertFalse(Crossfade.applies(durationMs: 600_000, seconds: 0))
        XCTAssertFalse(Crossfade.applies(durationMs: 600_000, seconds: 13))
        XCTAssertTrue(Crossfade.applies(durationMs: 600_000, seconds: 12))
    }

    func testASongSeenNearItsEndEndedByItselfOneSeenInTheMiddleDidNot() {
        XCTAssertTrue(Crossfade.endedItself(lastPositionMs: 197_000, durationMs: 200_000, elapsedMs: 3_200))
        XCTAssertTrue(Crossfade.endedItself(lastPositionMs: 100_000, durationMs: 200_000, elapsedMs: 100_500))
        XCTAssertFalse(Crossfade.endedItself(lastPositionMs: 100_000, durationMs: 200_000, elapsedMs: 20_000))
        XCTAssertFalse(Crossfade.endedItself(lastPositionMs: 0, durationMs: 0, elapsedMs: 5_000))
    }
}
