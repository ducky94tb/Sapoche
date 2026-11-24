import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// How a connect went. `pending` is Last.fm only: the person has not yet allowed the app on its page.
enum ScrobbleConnect: Equatable {
    case ok, invalid, pending, offline
}

/// The answer of a connect: with `.ok`, whose account it is ([user]) and what to keep to send with ([credential]).
struct ScrobbleLogin {
    var result: ScrobbleConnect
    var user: String?
    var credential: String?

    init(_ result: ScrobbleConnect, user: String? = nil, credential: String? = nil) {
        self.result = result
        self.user = user
        self.credential = credential
    }
}

/// How a send went; [waitSec] is only read with `.wait`.
enum ScrobbleSent: Equatable {
    case sent
    /// Not reached, or the service is in trouble: try again later, with growing waits.
    case retry
    /// Too often: wait [ScrobbleSend.waitSec] seconds.
    case wait
    /// The credential is not good any more: the person has to connect again.
    case reauth
    /// Something in it was refused: one listen at a time finds what.
    case refused
    /// Nothing more can be sent for now, and connecting again would not help (a key that was turned down, a wrong room key).
    case suspended
}

struct ScrobbleSend {
    var kind: ScrobbleSent
    var waitSec = 0

    init(_ kind: ScrobbleSent, waitSec: Int = 0) {
        self.kind = kind
        self.waitSec = waitSec
    }
}

/// What differs between the places listens can be sent to; `Scrobbler` keeps what is the same (the counting, the queue, the
/// waits). A service throws only when it is cancelled: not being reached is an answer (`.offline`, `.retry`).
/// Kotlin and Dart counterparts: `ScrobbleService.kt`, `scrobble_service.dart`.
@MainActor
protocol ScrobbleService {
    /// The most listens one send takes.
    var batch: Int { get }
    /// Whether [secret], what the person gave (a token), makes a connection.
    func check(_ secret: String) async throws -> ScrobbleLogin
    func submit(_ credential: String, _ listens: [Listen]) async throws -> ScrobbleSend
    /// Tells what plays now. Throws when the service cannot be reached; the caller only logs it.
    func playingNow(_ credential: String, _ listen: Listen) async throws
}

/// [ListenBrainz](https://listenbrainz.org): the token the person pastes is the credential.
@MainActor
struct ListenBrainzService: ScrobbleService {
    static let batchSize = 100
    private static let submitPath = "/1/submit-listens"

    var http: ScrobbleHTTP
    var version: String

    var batch: Int { Self.batchSize }

    func check(_ secret: String) async throws -> ScrobbleLogin {
        let clean = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        let reply: ScrobbleReply
        do {
            reply = try await http.send(path: "/1/validate-token", token: clean, body: nil)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return ScrobbleLogin(.offline)
        }
        if reply.status >= 500 || reply.status == 429 { return ScrobbleLogin(.offline) }
        let answer = JSON.parse(reply.body)
        guard reply.status == 200, answer?["valid"].bool == true, let name = answer?["user_name"].string, !name.isEmpty else {
            return ScrobbleLogin(.invalid)
        }
        return ScrobbleLogin(.ok, user: name, credential: clean)
    }

    func submit(_ credential: String, _ listens: [Listen]) async throws -> ScrobbleSend {
        let reply: ScrobbleReply
        do {
            reply = try await http.send(path: Self.submitPath, token: credential,
                                        body: Self.body(listens.count == 1 ? "single" : "import", listens, version: version))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return ScrobbleSend(.retry)
        }
        if reply.status >= 500 { return ScrobbleSend(.retry) }
        if reply.status == 200 { return ScrobbleSend(.sent) }
        if reply.status == 429 { return ScrobbleSend(.wait, waitSec: reply.resetInSec ?? 60) }
        if reply.status == 401 { return ScrobbleSend(.reauth) }
        return ScrobbleSend(.refused)
    }

    func playingNow(_ credential: String, _ listen: Listen) async throws {
        _ = try await http.send(path: Self.submitPath, token: credential, body: Self.body("playing_now", [listen], version: version))
    }

    /// The ask that submits [batch] as [type]: `single`, `import` or `playing_now` (which carries no time).
    nonisolated static func body(_ type: String, _ batch: [Listen], version: String) -> String {
        let payload: [[String: Any]] = batch.map { listen in
            var info: [String: Any] = ["media_player": "Sapoche", "submission_client": "Sapoche", "submission_client_version": version]
            if !listen.videoId.hasPrefix("local:") {
                info["music_service"] = "youtube.com"
                info["origin_url"] = "https://music.youtube.com/watch?v=\(listen.videoId)"
            }
            if listen.durationMs > 0 { info["duration_ms"] = listen.durationMs }
            var item: [String: Any] = ["track_metadata": ["artist_name": listen.artist, "track_name": listen.title, "additional_info": info] as [String: Any]]
            if type != "playing_now" { item["listened_at"] = listen.listenedAt }
            return item
        }
        return JSONText.encode(["listen_type": type, "payload": payload] as [String: Any])
    }
}

/// Asks Last.fm through the room server, which signs for the app (see `server/src/lastfm.ts`): [form] is the call, as a form.
protocol LastFmHTTP {
    func send(form: String) async throws -> ScrobbleReply
}

/// Last.fm through the room server: its `/lastfm` takes the call, signs it and passes it on. The server and the key are asked
/// for at each call, because the key can be set while the app runs. Any answer is a [ScrobbleReply]; only a failure to reach the server throws.
struct RoomLastFmHTTP: LastFmHTTP {
    var config: () -> ServerConfig
    var client: HTTPClient = URLSessionHTTP()

    func send(form: String) async throws -> ScrobbleReply {
        let config = config()
        guard let url = URL(string: config.server + "/lastfm") else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data(form.utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        for (name, value) in config.authHeaders { request.setValue(value, forHTTPHeaderField: name) }
        let reply = try await client.send(request)
        return ScrobbleReply(status: reply.status, body: reply.text, resetInSec: nil)
    }
}

/// [Last.fm](https://www.last.fm). The person is never asked for a password: [begin] gets a token and the page where it is
/// allowed, and once it is, `check` turns it into a session key, which is the credential. Every call goes to the room
/// server, so the app never holds the API key or its secret.
@MainActor
struct LastFmService: ScrobbleService {
    static let batchSize = 50

    var http: LastFmHTTP
    var log: (String) -> Void = { _ in }

    var batch: Int { Self.batchSize }

    /// The token to allow and the address where to allow it; nil token when the server has no Last.fm ([unavailable]) or cannot be reached.
    struct Begin {
        var token: String?
        var url: String?
        var unavailable = false
    }

    func begin() async throws -> Begin {
        let reply: ScrobbleReply
        do {
            reply = try await http.send(form: Self.form([("method", "auth.getToken")]))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return Begin()
        }
        if reply.status == 503 { return Begin(unavailable: true) }
        let answer = JSON.parse(reply.body)
        if reply.status == 200, let token = answer?["token"].string, !token.isEmpty, let url = answer?["url"].string, !url.isEmpty {
            return Begin(token: token, url: url)
        }
        return Begin()
    }

    func check(_ secret: String) async throws -> ScrobbleLogin {
        let reply: ScrobbleReply
        do {
            reply = try await http.send(form: Self.form([("method", "auth.getSession"),
                                                         ("token", secret.trimmingCharacters(in: .whitespacesAndNewlines))]))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return ScrobbleLogin(.offline)
        }
        let answer = JSON.parse(reply.body)
        if reply.status == 200, let key = answer?["session"]["key"].string, !key.isEmpty,
           let name = answer?["session"]["name"].string, !name.isEmpty {
            return ScrobbleLogin(.ok, user: name, credential: key)
        }
        switch answer?["error"].int {
        case 14: return ScrobbleLogin(.pending)
        case 11, 16, 29: return ScrobbleLogin(.offline)
        case nil: return ScrobbleLogin(reply.status == 400 || reply.status == 403 ? .invalid : .offline)
        default: return ScrobbleLogin(.invalid)
        }
    }

    func submit(_ credential: String, _ listens: [Listen]) async throws -> ScrobbleSend {
        let reply: ScrobbleReply
        do {
            reply = try await http.send(form: Self.form(Self.scrobbleParams(credential, listens)))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return ScrobbleSend(.retry)
        }
        let answer = JSON.parse(reply.body)
        if let error = answer?["error"].int {
            switch error {
            case 4, 9, 14, 15: return ScrobbleSend(.reauth)
            case 26: return ScrobbleSend(.suspended)
            case 29: return ScrobbleSend(.wait, waitSec: 60)
            case 11, 16: return ScrobbleSend(.retry)
            default: return ScrobbleSend(.refused)
            }
        }
        // The room server did not take the call: its key is wrong, or it does not let this address ask so often
        if reply.status == 401 { return ScrobbleSend(.suspended) }
        if reply.status == 429 { return ScrobbleSend(.wait, waitSec: 60) }
        if reply.status != 200 { return ScrobbleSend(reply.status >= 500 ? .retry : .refused) }
        guard let answer else { return ScrobbleSend(.retry) }
        // A listen that Last.fm ignored is not sent again: it would be ignored again (too old, or over the day's limit)
        let ignored = answer["scrobbles"]["@attr"]["ignored"].int ?? 0
        if ignored > 0 { log("scrobble: Last.fm ignored \(ignored) of \(listens.count)") }
        return ScrobbleSend(.sent)
    }

    func playingNow(_ credential: String, _ listen: Listen) async throws {
        _ = try await http.send(form: Self.form(Self.nowPlayingParams(credential, listen)))
    }

    /// The parameters of `track.scrobble` for [listens]; the signature is the server's to add.
    nonisolated static func scrobbleParams(_ session: String, _ listens: [Listen]) -> [(String, String)] {
        var params = [("method", "track.scrobble"), ("sk", session)]
        for (i, l) in listens.enumerated() {
            params.append(("artist[\(i)]", l.artist))
            params.append(("track[\(i)]", l.title))
            params.append(("timestamp[\(i)]", String(l.listenedAt)))
            if l.durationMs >= 1000 { params.append(("duration[\(i)]", String(l.durationMs / 1000))) }
        }
        return params
    }

    /// The parameters of `track.updateNowPlaying`.
    nonisolated static func nowPlayingParams(_ session: String, _ listen: Listen) -> [(String, String)] {
        var params = [("method", "track.updateNowPlaying"), ("sk", session), ("artist", listen.artist), ("track", listen.title)]
        if listen.durationMs >= 1000 { params.append(("duration", String(listen.durationMs / 1000))) }
        return params
    }

    /// [params] as a form, in the order of their names, every byte that is not a letter, a digit or `-._~` as `%XX`: the same text on every platform.
    nonisolated static func form(_ params: [(String, String)]) -> String {
        // Compared by UTF-8 bytes, as the other two platforms compare theirs
        params.sorted { Array($0.0.utf8).lexicographicallyPrecedes(Array($1.0.utf8)) }
            .map { "\(escape($0.0))=\(escape($0.1))" }.joined(separator: "&")
    }

    private nonisolated static func escape(_ text: String) -> String {
        let digits = Array("0123456789ABCDEF")
        var out = ""
        for byte in text.utf8 {
            let c = Character(UnicodeScalar(byte))
            if byte < 128, c.isASCII, c.isLetter || c.isNumber || "-._~".contains(c) {
                out.append(c)
            } else {
                out.append("%")
                out.append(digits[Int(byte >> 4)])
                out.append(digits[Int(byte & 15)])
            }
        }
        return out
    }
}
