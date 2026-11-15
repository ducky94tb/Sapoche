import XCTest
@testable import SapocheCore

/// The cases of QueuesTest.kt for the search for songs that autoplay repeats.
@MainActor
final class AutoplayRetryTests: XCTestCase {
    /// Time that does not wait: it only writes down how long it was asked to.
    private final class Waits: TimeSource {
        var waits: [Int64] = []
        func nowMs() -> Int64 { waits.reduce(0, +) }
        func sleep(ms: Int64) async throws { waits.append(ms) }
    }

    private struct Offline: Error {}

    func testASearchThatFindsSongsAtOnceIsNotRepeated() async throws {
        let time = Waits()
        var tries = 0
        let found = try await Queues.retrying(time: time, stillWanted: { true }) { tries += 1; return ["a"] }
        XCTAssertEqual(found, ["a"])
        XCTAssertEqual(tries, 1)
        XCTAssertEqual(time.waits, [])
    }

    func testASearchThatFoundNothingOrFailedIsTriedAgainAfterEachWait() async throws {
        let time = Waits()
        var missed: [(Int, Bool)] = []
        var tries = 0
        let found: [String] = try await Queues.retrying(time: time, stillWanted: { true }, missed: { n, e in missed.append((n, e != nil)) }) {
            tries += 1
            if tries == 1 { throw Offline() }
            return tries == 2 ? [] : ["a"]
        }
        XCTAssertEqual(found, ["a"])
        XCTAssertEqual(tries, 3)
        XCTAssertEqual(time.waits, [3_000, 10_000])
        XCTAssertEqual(missed.map(\.0), [1, 2])
        XCTAssertEqual(missed.map(\.1), [true, false])
    }

    func testItGivesUpAfterTheLastWaitFourTriesInAll() async throws {
        let time = Waits()
        var tries = 0
        let found: [String] = try await Queues.retrying(time: time, stillWanted: { true }) { tries += 1; return [] }
        XCTAssertTrue(found.isEmpty)
        XCTAssertEqual(tries, 4)
        XCTAssertEqual(time.waits, [3_000, 10_000, 30_000])
    }

    func testItStopsQuietlyWhenTheSongsAreNoLongerWanted() async throws {
        let time = Waits()
        var tries = 0
        var wanted = true
        let found: [String] = try await Queues.retrying(time: time, stillWanted: { wanted }) {
            tries += 1
            wanted = false // the person asked for something else while the search ran
            return []
        }
        XCTAssertTrue(found.isEmpty)
        XCTAssertEqual(tries, 1)
        let never: [String] = try await Queues.retrying(time: time, stillWanted: { false }) { XCTFail("not asked"); return [] }
        XCTAssertTrue(never.isEmpty)
    }
}
