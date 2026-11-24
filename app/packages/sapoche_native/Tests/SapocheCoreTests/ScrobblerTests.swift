import XCTest
@testable import SapocheCore

/// The cases of ScrobblerTest.kt
@MainActor
final class ScrobblerTests: XCTestCase {
    private final class Storage: ScrobbleStorage {
        var token: String? = "tok"
        var state: String?
        func loadState() -> String? { state }
        func saveState(_ text: String) { state = text }
    }

    /// Answers from `replies` in turn (the last one for ever); one that is nil is a failure to reach the service.
    private final class Http: ScrobbleHTTP, @unchecked Sendable {
        var replies: [ScrobbleReply?] = [ScrobbleReply(status: 200)]
        var asked: [(path: String, token: String, body: String?)] = []

        func send(path: String, token: String, body: String?) async throws -> ScrobbleReply {
            asked.append((path, token, body))
            let reply = replies.count > 1 ? replies.removeFirst() : replies.first ?? nil
            guard let reply else { throw URLError(.notConnectedToInternet) }
            return reply
        }

        var submitted: [JSON] {
            asked.filter { $0.path == "/1/submit-listens" }.map { JSON.parse($0.body!)! }
        }
    }

    private var time: VirtualTime!
    private var scope: Scope!
    private var storage: Storage!
    private var http: Http!
    private let ok = ScrobbleReply(status: 200, body: "{\"status\":\"ok\"}")
    private let song = TrackRef(videoId: "vid1", title: "Song (Official Video)", artist: "Artist - Topic", thumb: nil, durMs: 200_000)

    override func setUp() async throws {
        time = VirtualTime()
        scope = Scope()
        storage = Storage()
        http = Http()
        http.replies = [ok]
    }

    override func tearDown() async throws {
        scope.cancel()
    }

    private func scrobbler(_ storage: Storage? = nil) -> Scrobbler {
        Scrobbler(storage: storage ?? self.storage, service: ListenBrainzService(http: http, version: "1.50.0"), scope: scope, time: time,
                  namer: { ($0.title.replacingOccurrences(of: " (Official Video)", with: ""), $0.artist.replacingOccurrences(of: " - Topic", with: "")) },
                  wall: { [unowned self] in 1_700_000_000_000 + self.time.now })
    }

    private func pending(_ storage: Storage) -> Int {
        JSON.parse(storage.state!)!["listens"].array.count
    }

    private func type(_ body: JSON) -> String? { body["listen_type"].string }

    func testTheBodiesAreTheSameOnEveryPlatform() throws {
        let vectors = JSON.parse(data: try fixture("scrobble_vectors"))!
        let version = vectors["version"].string!
        for item in vectors["cases"].array {
            let listens = item["listens"].array.map {
                Listen(listenedAt: $0["listenedAt"].int64!, videoId: $0["videoId"].string!, title: $0["title"].string!,
                       artist: $0["artist"].string!, durationMs: $0["durationMs"].int64!)
            }
            let body = ListenBrainzService.body(item["type"].string!, listens, version: version)
            let made = try JSONSerialization.jsonObject(with: Data(body.utf8)) as! NSDictionary
            XCTAssertEqual(made, item["body"].object! as NSDictionary, item["name"].string!)
        }
    }

    func testWithoutATokenNothingIsCountedAndNothingGoesOut() async {
        let empty = Storage()
        empty.token = nil
        let scrobbler = scrobbler(empty)
        scrobbler.watch(song, playing: true, durationMs: 200_000)
        await time.advance(600_000)
        XCTAssertTrue(http.asked.isEmpty)
        XCTAssertNil(empty.state)
        XCTAssertFalse(scrobbler.status().connected)
    }

    func testAGoodTokenIsKeptWithTheNameOfItsOwner() async {
        let empty = Storage()
        empty.token = nil
        http.replies = [ScrobbleReply(status: 200, body: "{\"code\":200,\"message\":\"Token valid.\",\"valid\":true,\"user_name\":\"tvh\"}")]
        let scrobbler = scrobbler(empty)
        let result = await scrobbler.connect(" tok \n")
        XCTAssertEqual(result, .ok)
        XCTAssertEqual(empty.token, "tok")
        XCTAssertEqual(scrobbler.status().user, "tvh")
        XCTAssertEqual(http.asked[0].token, "tok")
    }

    func testATokenThatIsNotGoodIsNotKeptAndNoNetworkIsToldApart() async {
        let empty = Storage()
        empty.token = nil
        let scrobbler = scrobbler(empty)
        http.replies = [ScrobbleReply(status: 200, body: "{\"code\":200,\"message\":\"Token invalid.\",\"valid\":false}")]
        var result = await scrobbler.connect("bad")
        XCTAssertEqual(result, .invalid)
        http.replies = [ScrobbleReply(status: 401, body: "{\"code\":401}")]
        result = await scrobbler.connect("bad")
        XCTAssertEqual(result, .invalid)
        http.replies = [nil]
        result = await scrobbler.connect("tok")
        XCTAssertEqual(result, .offline)
        http.replies = [ScrobbleReply(status: 503)]
        result = await scrobbler.connect("tok")
        XCTAssertEqual(result, .offline)
        XCTAssertNil(empty.token)
    }

    func testASongIsShownPlayingAFewSecondsInAndSentOnceItCountsAtTheTimeItBegan() async {
        let scrobbler = scrobbler()
        await time.advance(1_000)
        scrobbler.watch(song, playing: true, durationMs: 200_000)
        await time.advance(4_000)
        XCTAssertTrue(http.submitted.isEmpty, "not yet: a song skipped at once must not show")
        await time.advance(1_100)
        XCTAssertEqual(http.submitted.map(type), ["playing_now"])
        await time.advance(95_000) // 100 s of playing: half the song
        let sent = http.submitted.last!
        XCTAssertEqual(type(sent), "single")
        let listen = sent["payload"][0]
        XCTAssertEqual(listen["listened_at"].int64, 1_700_000_001)
        XCTAssertEqual(listen["track_metadata"]["track_name"].string, "Song")
        XCTAssertEqual(listen["track_metadata"]["artist_name"].string, "Artist")
        XCTAssertEqual(scrobbler.status().pending, 0)
        scrobbler.disconnect()
    }

    func testASongLeftBeforeTheMarkIsNotSentAndAPausedOneDoesNotCount() async {
        let scrobbler = scrobbler()
        scrobbler.watch(song, playing: true, durationMs: 200_000)
        await time.advance(60_000)
        scrobbler.watch(song, playing: false, durationMs: 200_000)
        await time.advance(600_000)
        scrobbler.watch(nil, playing: false, durationMs: 0)
        XCTAssertTrue(http.submitted.allSatisfy { type($0) == "playing_now" })
        XCTAssertEqual(scrobbler.status().pending, 0)
    }

    func testPlayingNowIsLeftOutWhenThePersonDoesNotWantIt() async {
        let scrobbler = scrobbler()
        scrobbler.setNowPlaying(false)
        scrobbler.watch(song, playing: true, durationMs: 200_000)
        await time.advance(20_000)
        XCTAssertTrue(http.submitted.isEmpty)
        scrobbler.disconnect()
    }

    func testWithNoNetworkTheListensWaitOnThePhoneAndGoTogetherWhenItIsBack() async {
        http.replies = [nil]
        let scrobbler = scrobbler()
        scrobbler.setNowPlaying(false)
        scrobbler.watch(song, playing: true, durationMs: 200_000)
        await time.advance(100_000)
        scrobbler.watch(TrackRef(videoId: "vid2", title: "Two", artist: "B", thumb: nil, durMs: 100_000), playing: true, durationMs: 100_000)
        await time.advance(50_000)
        scrobbler.watch(nil, playing: false, durationMs: 0)
        XCTAssertEqual(scrobbler.status().pending, 2)
        XCTAssertEqual(pending(storage), 2, "kept on the phone")
        http.replies = [ok]
        await time.advance(5 * 60_000)
        XCTAssertEqual(scrobbler.status().pending, 0)
        let sent = http.submitted.last!
        XCTAssertEqual(type(sent), "import")
        XCTAssertEqual(sent["payload"].array.count, 2)
        scrobbler.disconnect()
    }

    func testWhatWaitedWhenTheAppWasClosedIsSentWhenItOpens() async {
        storage.state = "{\"listens\":[{\"listenedAt\":1700000000,\"videoId\":\"a\",\"title\":\"A\",\"artist\":\"B\",\"durationMs\":1000}]}"
        let scrobbler = scrobbler()
        XCTAssertEqual(scrobbler.status().pending, 1)
        scrobbler.resume()
        await time.advance(1)
        XCTAssertEqual(scrobbler.status().pending, 0)
        XCTAssertEqual(http.submitted.count, 1)
    }

    func testABusyServiceIsWaitedForAsLongAsItSays() async {
        http.replies = [ScrobbleReply(status: 429, body: "", resetInSec: 30), ok]
        let scrobbler = scrobbler()
        scrobbler.setNowPlaying(false)
        scrobbler.watch(song, playing: true, durationMs: 200_000)
        await time.advance(100_100)
        XCTAssertEqual(http.submitted.count, 1)
        await time.advance(30_000)
        XCTAssertEqual(http.submitted.count, 1, "31 s: not before it said")
        await time.advance(2_000)
        XCTAssertEqual(http.submitted.count, 2)
        XCTAssertEqual(scrobbler.status().pending, 0)
        scrobbler.disconnect()
    }

    func testATokenThatIsRefusedStopsItAndAsksToConnectAgainKeepingTheListens() async {
        http.replies = [ScrobbleReply(status: 401)]
        let scrobbler = scrobbler()
        scrobbler.setNowPlaying(false)
        scrobbler.watch(song, playing: true, durationMs: 200_000)
        await time.advance(100_100)
        let status = scrobbler.status()
        XCTAssertTrue(status.reconnect)
        XCTAssertEqual(status.pending, 1)
        await time.advance(600_000)
        XCTAssertEqual(http.submitted.count, 1, "no more asks with a token that is refused")
        scrobbler.watch(song, playing: true, durationMs: 200_000)
        XCTAssertEqual(http.submitted.count, 1)
    }

    func testWhenTheServiceRefusesABatchTheListensGoOneByOneAndOnlyTheBadOneIsDropped() async {
        storage.state = """
        {"listens":[{"listenedAt":1700000000,"videoId":"a","title":"A","artist":"B","durationMs":1000},
        {"listenedAt":1700000001,"videoId":"b","title":"","artist":"B","durationMs":1000},
        {"listenedAt":1700000002,"videoId":"c","title":"C","artist":"B","durationMs":1000}]}
        """
        http.replies = [ScrobbleReply(status: 400), ok, ScrobbleReply(status: 400), ok]
        let scrobbler = scrobbler()
        scrobbler.resume()
        await time.advance(1)
        XCTAssertEqual(scrobbler.status().pending, 0)
        XCTAssertEqual(http.submitted.map(type), ["import", "single", "single", "single"])
    }

    func testDisconnectingForgetsTheTokenAndTheQueueAndStopsEverything() async {
        http.replies = [nil]
        let scrobbler = scrobbler()
        scrobbler.setNowPlaying(false)
        scrobbler.watch(song, playing: true, durationMs: 200_000)
        await time.advance(100_100)
        XCTAssertEqual(scrobbler.status().pending, 1)
        scrobbler.disconnect()
        XCTAssertNil(storage.token)
        XCTAssertEqual(pending(storage), 0)
        let asks = http.asked.count
        await time.advance(600_000)
        XCTAssertEqual(http.asked.count, asks)
    }

    func testListensOlderThanTwoWeeksAndBeyondAThousandAreDropped() {
        let now: Int64 = 1_700_000_000
        let old = (1...3).map { "{\"listenedAt\":\(now - 15 * 24 * 3600 + Int64($0)),\"videoId\":\"o\($0)\",\"title\":\"T\",\"artist\":\"A\",\"durationMs\":1}" }
        let recent = (1...1_005).map { "{\"listenedAt\":\(now - Int64($0)),\"videoId\":\"r\($0)\",\"title\":\"T\",\"artist\":\"A\",\"durationMs\":1}" }
        storage.state = "{\"listens\":[\((old + recent).joined(separator: ","))]}"
        http.replies = [nil]
        XCTAssertEqual(scrobbler().status().pending, 1000)
    }
}
