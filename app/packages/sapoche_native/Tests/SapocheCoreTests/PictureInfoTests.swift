import XCTest
@testable import SapocheCore

/// What the screen is told of the heights of the picture; mirrors `PictureInfo` of Kotlin (`PictureInfoTest` there is the same cases).
final class PictureInfoTests: XCTestCase {
    private let heights = [144, 240, 360, 480, 720, 1080]

    func testNothingPlayingTellsNoLimit() {
        let info = PictureInfo.of(heights: [], now: 0, asked: 1080, metered: false, budgetKbps: 0)
        XCTAssertEqual(info, PictureInfo())
        XCTAssertEqual(PictureInfo.of(heights: heights, now: 0, asked: 1080, metered: false, budgetKbps: 5000).limit, nil)
    }

    func testTheHeightAskedForPlayingIsNoLimit() {
        let info = PictureInfo.of(heights: heights, now: 720, asked: 720, metered: false, budgetKbps: 5000)
        XCTAssertEqual(info.heights, heights)
        XCTAssertEqual(info.now, 720)
        XCTAssertNil(info.limit)
    }

    func testAHeightBelowTheOneAskedForBecauseOfTheLinkIsTheNetwork() {
        XCTAssertEqual(PictureInfo.of(heights: heights, now: 480, asked: 1080, metered: false, budgetKbps: 900).limit, "network")
        // Nothing measured: a lower one was not chosen for the link
        XCTAssertNil(PictureInfo.of(heights: heights, now: 480, asked: 1080, metered: false, budgetKbps: 0).limit)
    }

    func testASongWithNothingTallerThanItPlaysIsTheVideoNotTheNetwork() {
        let info = PictureInfo.of(heights: [144, 360, 720], now: 720, asked: 1080, metered: false, budgetKbps: 5000)
        XCTAssertEqual(info.limit, "video")
    }

    func testAnIPhoneNeverGoesAbove1080SoMobileDataHoldsBackNothing() {
        XCTAssertEqual(PictureInfo.of(heights: heights, now: 1080, asked: 2160, metered: false, budgetKbps: 5000).max, 1080)
        XCTAssertNil(PictureInfo.of(heights: heights, now: 1080, asked: 2160, metered: false, budgetKbps: 5000).limit, "asked 2160, 1080 is what there is on this phone")
        XCTAssertNil(PictureInfo.of(heights: heights, now: 1080, asked: 2160, metered: true, budgetKbps: 5000).limit, "nothing is lost to mobile data, so nothing is said")
    }

    func testTheStateCarriesTheHeights() throws {
        let info = PictureInfo(heights: [360, 720], now: 720, max: 1080, limit: "network")
        let text = UiJson.state(GroupController.View(), trimMs: 0, video: true, videoHeight: 1080, picture: info)
        let json = try XCTUnwrap(JSON.parse(text))
        XCTAssertEqual(json.at("videoHeights").array.map { $0.int }, [360, 720])
        XCTAssertEqual(json.at("videoHeightNow").int, 720)
        XCTAssertEqual(json.at("videoHeightMax").int, 1080)
        XCTAssertEqual(json.at("videoLimit").string, "network")
        let none = try XCTUnwrap(JSON.parse(UiJson.state(GroupController.View(), trimMs: 0)))
        XCTAssertEqual(none.at("videoHeights").array.count, 0)
        XCTAssertNil(none.at("videoLimit").string)
    }
}
