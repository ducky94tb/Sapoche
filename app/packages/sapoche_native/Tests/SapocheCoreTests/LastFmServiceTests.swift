import XCTest
@testable import SapocheCore

/// The cases of LastFmServiceTest.kt
@MainActor
final class LastFmServiceTests: XCTestCase {
    private final class Storage: ScrobbleStorage {
        var token: String? = "sk"
        var state: String?
        func loadState() -> String? { state }
        func saveState(_ text: String) { state = text }
    }

    /// Answers from `replies` in turn (the last one for ever); one that is nil is a failure to reach the server.
    private final class Http: LastFmHTTP, @unchecked Sendable {
        var replies: [ScrobbleReply?] = []
        var asked: [String] = []

        func send(form: String) async throws -> ScrobbleReply {
            asked.append(form)
            let reply = replies.count > 1 ? replies.removeFirst() : replies.first ?? nil
            guard let reply else { throw URLError(.notConnectedToInternet) }
            return reply
        }
    }

    private var http: Http!
    private var logged: [String] = []
    private var service: LastFmService!
    private let one = [Listen(listenedAt: 1_700_000_000, videoId: "a", title: "A", artist: "B", durationMs: 200_000)]

    override func setUp() async throws {
        http = Http()
        logged = []
        service = LastFmService(http: http, log: { [unowned self] in self.logged.append($0) })
    }

    private func reply(_ status: Int, _ body: String) -> ScrobbleReply { ScrobbleReply(status: status, body: body) }

    func testTheFormsAreTheSameOnEveryPlatform() throws {
        let vectors = JSON.parse(data: try fixture("lastfm_vectors"))!
        for item in vectors["cases"].array {
            let listens = item["listens"].array.map {
                Listen(listenedAt: $0["listenedAt"].int64!, videoId: $0["videoId"].string!, title: $0["title"].string!,
                       artist: $0["artist"].string!, durationMs: $0["durationMs"].int64!)
            }
            let session = item["session"].string!
            let params = item["kind"].string == "scrobble" ? LastFmService.scrobbleParams(session, listens) : LastFmService.nowPlayingParams(session, listens[0])
            XCTAssertEqual(LastFmService.form(params), item["form"].string!, item["name"].string!)
        }
    }

    func testATokenComesWithThePageThatAllowsIt() async throws {
        http.replies = [reply(200, "{\"token\":\"t1\",\"url\":\"https://www.last.fm/api/auth/?api_key=k&token=t1\"}")]
        let begin = try await service.begin()
        XCTAssertEqual(begin.token, "t1")
        XCTAssertEqual(begin.url, "https://www.last.fm/api/auth/?api_key=k&token=t1")
        XCTAssertEqual(http.asked, ["method=auth.getToken"])
    }

    func testAServerWithoutLastFmAndOneThatCannotBeReachedAreToldApart() async throws {
        http.replies = [reply(503, "Last.fm is not set up on this server")]
        let none = try await service.begin()
        XCTAssertTrue(none.unavailable)
        http.replies = [nil]
        let offline = try await service.begin()
        XCTAssertNil(offline.token)
        XCTAssertFalse(offline.unavailable)
    }

    func testTheSessionComesOnceThePersonHasAllowedIt() async throws {
        http.replies = [reply(200, "{\"session\":{\"name\":\"tvh\",\"key\":\"sk-1\",\"subscriber\":0}}")]
        let login = try await service.check(" t1 ")
        XCTAssertEqual(login.result, .ok)
        XCTAssertEqual(login.user, "tvh")
        XCTAssertEqual(login.credential, "sk-1")
        XCTAssertEqual(http.asked, ["method=auth.getSession&token=t1"])
    }

    func testATokenNotYetAllowedIsPendingAndOneGoneOrUnreachableIsNot() async throws {
        func check(_ r: ScrobbleReply?) async throws -> ScrobbleConnect {
            http.replies = [r]
            return try await service.check("t").result
        }
        var result = try await check(reply(403, "{\"error\":14,\"message\":\"Unauthorized Token - This token has not been authorized\"}"))
        XCTAssertEqual(result, .pending)
        result = try await check(reply(403, "{\"error\":15,\"message\":\"This token has expired\"}"))
        XCTAssertEqual(result, .invalid)
        result = try await check(reply(403, "{\"error\":4}"))
        XCTAssertEqual(result, .invalid)
        result = try await check(reply(500, "{\"error\":16}"))
        XCTAssertEqual(result, .offline)
        result = try await check(reply(502, "Last.fm cannot be reached"))
        XCTAssertEqual(result, .offline)
        result = try await check(reply(401, "Unauthorized"))
        XCTAssertEqual(result, .offline)
        result = try await check(nil)
        XCTAssertEqual(result, .offline)
    }

    func testTheAnswersOfAScrobble() async throws {
        func send(_ r: ScrobbleReply?) async throws -> ScrobbleSend {
            http.replies = [r]
            return try await service.submit("sk", one)
        }
        var sent = try await send(reply(200, "{\"scrobbles\":{\"@attr\":{\"accepted\":1,\"ignored\":0}}}"))
        XCTAssertEqual(sent.kind, .sent)
        sent = try await send(reply(403, "{\"error\":9,\"message\":\"Invalid session key\"}"))
        XCTAssertEqual(sent.kind, .reauth)
        sent = try await send(reply(403, "{\"error\":26,\"message\":\"Suspended API key\"}"))
        XCTAssertEqual(sent.kind, .suspended)
        sent = try await send(reply(429, "{\"error\":29,\"message\":\"Rate limit exceeded\"}"))
        XCTAssertEqual(sent.kind, .wait)
        XCTAssertEqual(sent.waitSec, 60)
        sent = try await send(reply(500, "{\"error\":16}"))
        XCTAssertEqual(sent.kind, .retry)
        sent = try await send(reply(503, ""))
        XCTAssertEqual(sent.kind, .retry)
        sent = try await send(reply(400, "{\"error\":6,\"message\":\"Invalid parameters\"}"))
        XCTAssertEqual(sent.kind, .refused)
        sent = try await send(reply(403, "{\"error\":13}"))
        XCTAssertEqual(sent.kind, .refused)
        sent = try await send(nil)
        XCTAssertEqual(sent.kind, .retry)
        // The server of the room, not Last.fm
        sent = try await send(reply(401, "Unauthorized"))
        XCTAssertEqual(sent.kind, .suspended)
        sent = try await send(reply(429, "Too many requests"))
        XCTAssertEqual(sent.kind, .wait)
    }

    func testAListenThatLastFmIgnoredIsCountedAsSentAndLogged() async throws {
        http.replies = [reply(200, "{\"scrobbles\":{\"@attr\":{\"accepted\":0,\"ignored\":1},\"scrobble\":{\"ignoredMessage\":{\"code\":\"3\",\"#text\":\"Timestamp too old\"}}}}")]
        let sent = try await service.submit("sk", one)
        XCTAssertEqual(sent.kind, .sent)
        XCTAssertTrue(logged.contains { $0.contains("ignored 1 of 1") }, "\(logged)")
    }

    private func lastFm(_ storage: Storage, _ time: VirtualTime, _ scope: Scope) -> Scrobbler {
        Scrobbler(storage: storage, service: service, scope: scope, time: time, namer: { ($0.title, $0.artist) },
                  wall: { 1_700_000_000_000 + time.now })
    }

    func testTheQueueOfLastFmGoesInBatchesOfFifty() async throws {
        let time = VirtualTime()
        let scope = Scope()
        defer { scope.cancel() }
        let storage = Storage()
        let items = (0..<120).map { "{\"listenedAt\":\(1_700_000_000 + $0),\"videoId\":\"v\($0)\",\"title\":\"T\($0)\",\"artist\":\"A\",\"durationMs\":200000}" }
        storage.state = "{\"listens\":[\(items.joined(separator: ","))]}"
        http.replies = [reply(200, "{\"scrobbles\":{\"@attr\":{\"accepted\":50,\"ignored\":0}}}")]
        let scrobbler = lastFm(storage, time, scope)
        scrobbler.resume()
        await time.advance(1)
        XCTAssertEqual(scrobbler.status().pending, 0)
        XCTAssertEqual(http.asked.count, 3, "50, 50 and 20")
        XCTAssertEqual(http.asked[0].components(separatedBy: "artist%5B").count - 1, 50)
        XCTAssertEqual(http.asked[2].components(separatedBy: "artist%5B").count - 1, 20)
    }

    func testASessionKeyThatLastFmRefusedStopsItAndKeepsTheListens() async throws {
        let time = VirtualTime()
        let scope = Scope()
        defer { scope.cancel() }
        let storage = Storage()
        storage.state = "{\"user\":\"tvh\",\"listens\":[{\"listenedAt\":1700000000,\"videoId\":\"a\",\"title\":\"A\",\"artist\":\"B\",\"durationMs\":1000}]}"
        http.replies = [reply(403, "{\"error\":9,\"message\":\"Invalid session key\"}")]
        let scrobbler = lastFm(storage, time, scope)
        scrobbler.resume()
        await time.advance(1)
        XCTAssertTrue(scrobbler.status().reconnect)
        XCTAssertEqual(scrobbler.status().pending, 1)
        XCTAssertEqual(http.asked.count, 1)
    }

    func testAKeyThatLastFmSuspendedIsTriedAgainAtTheNextOpeningNotBefore() async throws {
        let time = VirtualTime()
        let scope = Scope()
        defer { scope.cancel() }
        let storage = Storage()
        storage.state = "{\"user\":\"tvh\",\"listens\":[{\"listenedAt\":1700000000,\"videoId\":\"a\",\"title\":\"A\",\"artist\":\"B\",\"durationMs\":1000}]}"
        http.replies = [reply(403, "{\"error\":26,\"message\":\"Suspended API key\"}")]
        let scrobbler = lastFm(storage, time, scope)
        scrobbler.resume()
        await time.advance(600_000)
        XCTAssertEqual(http.asked.count, 1, "not in a loop")
        XCTAssertEqual(scrobbler.status().pending, 1)
        XCTAssertFalse(scrobbler.status().reconnect)
        http.replies = [reply(200, "{\"scrobbles\":{\"@attr\":{\"accepted\":1,\"ignored\":0}}}")]
        scrobbler.resume()
        await time.advance(1)
        XCTAssertEqual(scrobbler.status().pending, 0)
    }
}
