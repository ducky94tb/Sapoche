import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One song heard, as it is sent: [listenedAt] is when it began (seconds since 1970), the names are the cleaned ones.
struct Listen: Equatable {
    var listenedAt: Int64
    var videoId: String
    var title: String
    var artist: String
    var durationMs: Int64
}

/// What the settings page shows: [pending] listens wait to be sent; [reconnect] says the token was refused and a new one is needed.
struct ScrobbleStatus: Equatable {
    var connected: Bool
    var user: String?
    var nowPlaying: Bool
    var pending: Int
    var reconnect: Bool
}

/// How the service answered: its [status], and with a 429 how many seconds until it takes the next ask ([resetInSec]).
struct ScrobbleReply {
    var status: Int
    var body: String = ""
    var resetInSec: Int?
}

/// Asks the service: a GET when [body] is nil, else a POST of it. Throws when there is no network.
protocol ScrobbleHTTP {
    func send(path: String, token: String, body: String?) async throws -> ScrobbleReply
}

/// Where the token and the rest are kept; the token apart, so the platform can put it somewhere safer than the queue.
protocol ScrobbleStorage: AnyObject {
    var token: String? { get set }
    func loadState() -> String?
    func saveState(_ text: String)
}

enum ScrobbleConnect: Equatable {
    case ok, invalid, offline
}

/// [ListenBrainz](https://listenbrainz.org) over the real network.
struct ListenBrainzHTTP: ScrobbleHTTP {
    var client: HTTPClient = URLSessionHTTP()
    var base = "https://api.listenbrainz.org"

    func send(path: String, token: String, body: String?) async throws -> ScrobbleReply {
        guard let url = URL(string: base + path) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpMethod = "POST"
            request.httpBody = Data(body.utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let reply = try await client.send(request)
        return ScrobbleReply(status: reply.status, body: reply.text, resetInSec: reply.headers["x-ratelimit-reset-in"].flatMap { Int($0) })
    }
}

/// Sends what this phone plays to [ListenBrainz](https://listenbrainz.org), once the person has pasted a token of theirs.
/// Without a token it does nothing, and nothing goes out.
///
/// It follows the player through [watch]: a song counts after half of it or four minutes, whichever is first, and never
/// when it is thirty seconds or less (the rule of ListenBrainz and Last.fm, stricter than the history's, so it has a
/// tracker of its own). A song that counts is written to a queue kept on the phone and sent at once; with no network, or
/// when the service is busy, it stays there and is sent later, many at a time, for 14 days or 1000 listens.
/// "Playing now" goes out a few seconds after a song starts, if the person wants it. Only the song goes out: nothing of
/// the room, its members or who added the song.
///
/// Kotlin and Dart counterparts: `Scrobbler.kt`, `scrobbler.dart`.
@MainActor
final class Scrobbler {
    /// A song counts after this long of playing, or half of it when that is less.
    static let heardMs: Int64 = 4 * 60_000
    /// A song of this length or less never counts.
    static let minSongMs: Int64 = 30_000
    static let announceDelayMs: Int64 = 5_000
    static let batch = 100
    static let maxListens = 1000
    static let maxAgeSec: Int64 = 14 * 24 * 3600
    static let retryMinMs: Int64 = 15_000
    static let retryMaxMs: Int64 = 5 * 60_000
    private static let submit = "/1/submit-listens"

    private let storage: ScrobbleStorage
    private let http: ScrobbleHTTP
    private let scope: Scope
    private let time: TimeSource
    /// The title and the artist to send for a song: the cleaned names.
    private let namer: (TrackRef) -> (title: String, artist: String)
    private let version: String
    private let wall: () -> Int64
    private let log: (String) -> Void

    private var user: String?
    private var nowPlaying = true
    private var reconnect = false
    private var listens: [Listen] = []

    private var tracker: ListenTracker!
    private var current: TrackRef?
    private var startedAt: Int64?
    private var lastDurationMs: Int64 = 0
    private var due: Job?
    private var announceJob: Job?
    private var sender: Job?

    init(storage: ScrobbleStorage, http: ScrobbleHTTP, scope: Scope, time: TimeSource,
         namer: @escaping (TrackRef) -> (title: String, artist: String), version: String,
         wall: @escaping () -> Int64, log: @escaping (String) -> Void = { _ in }) {
        self.storage = storage
        self.http = http
        self.scope = scope
        self.time = time
        self.namer = namer
        self.version = version
        self.wall = wall
        self.log = log
        if let text = storage.loadState(), let saved = JSON.parse(text) {
            user = saved["user"].string
            nowPlaying = saved["nowPlaying"].bool ?? true
            reconnect = saved["reconnect"].bool ?? false
            listens = saved["listens"].array.compactMap { item in
                guard let at = item["listenedAt"].int64, let id = item["videoId"].string else { return nil }
                return Listen(listenedAt: at, videoId: id, title: item["title"].string ?? "", artist: item["artist"].string ?? "",
                              durationMs: item["durationMs"].int64 ?? 0)
            }
        }
        trim()
        tracker = ListenTracker(heard: { [weak self] id, durationMs in self?.heard(id, durationMs) },
                                heardAfterMs: Self.heardMs, minDurationMs: Self.minSongMs)
    }

    private var connected: Bool { storage.token != nil }

    func status() -> ScrobbleStatus {
        ScrobbleStatus(connected: connected, user: user, nowPlaying: nowPlaying, pending: listens.count, reconnect: reconnect)
    }

    /// Checks the token with the service and, if it is good, keeps it and sends what waits.
    func connect(_ token: String) async -> ScrobbleConnect {
        let clean = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let reply: ScrobbleReply
        do {
            reply = try await http.send(path: "/1/validate-token", token: clean, body: nil)
        } catch {
            return .offline
        }
        if reply.status >= 500 || reply.status == 429 { return .offline }
        let answer = JSON.parse(reply.body)
        guard reply.status == 200, answer?["valid"].bool == true, let name = answer?["user_name"].string, !name.isEmpty else { return .invalid }
        storage.token = clean
        user = name
        reconnect = false
        save()
        log("scrobble: connected as \(name)")
        send()
        return .ok
    }

    /// Forgets the token and drops what had not been sent.
    func disconnect() {
        storage.token = nil
        user = nil
        reconnect = false
        listens.removeAll()
        save()
        reset()
        log("scrobble: disconnected")
    }

    func setNowPlaying(_ on: Bool) {
        nowPlaying = on
        if !on { announceJob?.cancel() }
        save()
    }

    /// The app is open: sends what waited while it was not.
    func resume() { send() }

    /// The player's state: the song it has loaded (nil for none), whether it plays, and its length. Called at every
    /// change of it, and cheap when nothing is connected.
    func watch(_ track: TrackRef?, playing: Bool, durationMs: Int64) {
        if !connected || reconnect {
            if current != nil { reset() }
            return
        }
        let now = time.nowMs()
        if track?.videoId != current?.videoId {
            // Counts the song that is ending, if it just passed the mark, so `current` still has to be that one
            tracker.begin(songId: track?.videoId, durationMs: max(durationMs, 0), now: now)
            current = track
            startedAt = nil
            announceJob?.cancel()
        }
        guard let song = current else { return }
        lastDurationMs = max(durationMs, 0)
        tracker.setDuration(lastDurationMs)
        tracker.setPlaying(playing, now: now)
        if playing && startedAt == nil {
            startedAt = wall()
            if nowPlaying { announce(song) }
        }
        schedule()
    }

    private func reset() {
        // Before the tracker is told, so that a song it counts on its way out is not queued
        current = nil
        tracker.begin(songId: nil, durationMs: 0, now: time.nowMs())
        startedAt = nil
        due?.cancel()
        announceJob?.cancel()
        sender?.cancel()
    }

    private func schedule() {
        due?.cancel()
        guard let wait = tracker.msUntilHeard(time.nowMs()) else { return }
        due = scope.launch { [weak self] in
            guard let self else { return }
            try await self.time.sleep(ms: wait)
            self.tracker.check(self.time.nowMs())
            self.schedule()
        }
    }

    private func heard(_ id: String, _ durationMs: Int64) {
        guard let song = current, song.videoId == id else { return }
        let names = namer(song)
        listens.append(Listen(listenedAt: (startedAt ?? wall()) / 1000, videoId: id, title: names.title, artist: names.artist,
                              durationMs: durationMs > 0 ? durationMs : song.durMs))
        trim()
        save()
        log("scrobble: '\(names.title)' queued (\(listens.count) waiting)")
        send()
    }

    /// Tells the service what plays, a few seconds in, so a song that is skipped at once is not shown.
    private func announce(_ song: TrackRef) {
        announceJob?.cancel()
        announceJob = scope.launch { [weak self] in
            guard let self else { return }
            try await self.time.sleep(ms: Self.announceDelayMs)
            guard let token = self.storage.token else { return }
            let names = self.namer(song)
            let duration = self.lastDurationMs > 0 ? self.lastDurationMs : song.durMs
            let listen = Listen(listenedAt: 0, videoId: song.videoId, title: names.title, artist: names.artist, durationMs: duration)
            do {
                _ = try await self.http.send(path: Self.submit, token: token, body: Self.body("playing_now", [listen], version: self.version))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                self.log("scrobble: playing now not sent: \(error.localizedDescription)")
            }
        }
    }

    private func trim() {
        let oldest = wall() / 1000 - Self.maxAgeSec
        let before = listens.count
        listens.removeAll { $0.listenedAt < oldest }
        if listens.count > Self.maxListens { listens.removeFirst(listens.count - Self.maxListens) }
        if listens.count < before { log("scrobble: \(before - listens.count) old listens dropped") }
    }

    private func save() {
        var state: [String: Any] = [
            "nowPlaying": nowPlaying, "reconnect": reconnect,
            "listens": listens.map {
                ["listenedAt": $0.listenedAt, "videoId": $0.videoId, "title": $0.title, "artist": $0.artist, "durationMs": $0.durationMs] as [String: Any]
            },
        ]
        if let user { state["user"] = user }
        storage.saveState(JSONText.encode(state))
    }

    /// Sends the queue, a batch at a time, until it is empty; goes on trying later while the service cannot be reached.
    private func send() {
        if sender?.isActive == true || listens.isEmpty || !connected || reconnect { return }
        sender = scope.launch { [weak self] in
            guard let self else { return }
            var wait = Self.retryMinMs
            var size = Self.batch
            while !self.listens.isEmpty {
                guard let token = self.storage.token else { return }
                let batch = Array(self.listens.prefix(size))
                var reply: ScrobbleReply?
                do {
                    reply = try await self.http.send(path: Self.submit, token: token,
                                                     body: Self.body(batch.count == 1 ? "single" : "import", batch, version: self.version))
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    reply = nil
                }
                if let reply, reply.status == 200 {
                    self.listens.removeFirst(batch.count)
                    self.save()
                    wait = Self.retryMinMs
                } else if let reply, reply.status == 401 {
                    self.reconnect = true
                    self.save()
                    self.log("scrobble: the token was refused")
                    return
                } else if let reply, reply.status == 429 {
                    try await self.time.sleep(ms: Int64(reply.resetInSec ?? 60) * 1000 + 1000)
                } else if let reply, reply.status < 500 {
                    if batch.count > 1 {
                        // The service refused something in it: one at a time (until the queue is empty) finds what, and only that is dropped
                        size = 1
                    } else {
                        self.log("scrobble: '\(batch[0].title)' refused (\(reply.status)), dropped")
                        self.listens.removeFirst()
                        self.save()
                    }
                } else {
                    try await self.time.sleep(ms: wait)
                    wait = min(wait * 2, Self.retryMaxMs)
                }
            }
        }
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
