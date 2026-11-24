import Foundation

/// Small settings that outlive a run: the room this device was in, its name, what the person chose in the app.
protocol KeyValueStore: AnyObject {
    func string(_ key: String) -> String?
    func int64(_ key: String) -> Int64?
    func bool(_ key: String) -> Bool?
    func set(_ value: String?, for key: String)
    func set(_ value: Int64, for key: String)
    func set(_ value: Bool, for key: String)
    func remove(_ key: String)
}

extension KeyValueStore {
    func bool(_ key: String, default value: Bool) -> Bool { bool(key) ?? value }
    func int64(_ key: String, default value: Int64) -> Int64 { int64(key) ?? value }
}

/// Settings kept in memory only, for tests.
final class MemoryStore: KeyValueStore {
    private var values: [String: Any] = [:]

    func string(_ key: String) -> String? { values[key] as? String }
    func int64(_ key: String) -> Int64? { values[key] as? Int64 }
    func bool(_ key: String) -> Bool? { values[key] as? Bool }
    func set(_ value: String?, for key: String) { values[key] = value }
    func set(_ value: Int64, for key: String) { values[key] = value }
    func set(_ value: Bool, for key: String) { values[key] = value }
    func remove(_ key: String) { values[key] = nil }
}

/// The diary of the native side, mirrored to the files of `DiaryFiles` (two that take every line, one that takes the key
/// lines alone), so that a line is there after iOS ended the app in the background. Lines reach the files in batches and
/// when the app leaves the screen. Before `start` (and in tests) lines stay in memory only.
final class EventLog: @unchecked Sendable {
    static let shared = EventLog()
    static let started = "---- process started ----"

    private static let batchLines = 25
    private static let batchSeconds: TimeInterval = 60

    private let lock = NSLock()
    private let format: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MM-dd HH:mm:ss.SSS"
        return f
    }()
    private var files: DiaryFiles?
    private var unwritten: [String] = []
    private var memory: [String] = []
    private var lastWrite = Date()

    /// The run before this one ended without a word of the app: a crash line of ours or a `[diagnostic]` line of MetricKit.
    private(set) var previousRunFailed = false

    /// Opens the files in [dir]. Called once, as early as the app can.
    func start(dir: URL, version: String = "") {
        lock.lock()
        let store = DiaryFiles(dir: dir)
        files = store
        let last = store.lastRun().reversed().prefix { !$0.contains(Self.started) }
        previousRunFailed = last.contains { $0.contains(" [crash] ") || $0.contains(" [diagnostic] ") }
        lock.unlock()
        add(.main, "log", Self.started + (version.isEmpty ? "" : " \(version)"))
    }

    static func d(_ tag: String, _ message: String) { shared.add(nil, tag, message) }
    static func e(_ tag: String, _ message: String) { shared.add(.error, tag, message) }
    static func w(_ tag: String, _ message: String) { shared.add(.warn, tag, message) }
    static func k(_ tag: String, _ message: String) { shared.add(.main, tag, message) }
    static func v(_ tag: String, _ message: String) { shared.add(.detail, tag, message) }

    func add(_ tag: String, _ message: String) { add(nil, tag, message) }

    private func add(_ level: LogLevel?, _ tag: String, _ message: String) {
        lock.lock()
        defer { lock.unlock() }
        let line = Diary.line(stamp: format.string(from: Date()), level: level ?? Diary.infer(tag: tag, message: message), tag: tag, message: message)
        if files == nil {
            memory.append(line)
            if memory.count > 2000 { memory.removeFirst(memory.count - 2000) }
            return
        }
        unwritten.append(line)
        if unwritten.count >= Self.batchLines || Date().timeIntervalSince(lastWrite) > Self.batchSeconds { flushLocked() }
    }

    /// Writes what is waiting; called when the app leaves the screen, before iOS may end it.
    func flush() {
        lock.lock()
        flushLocked()
        lock.unlock()
    }

    private func flushLocked() {
        if !unwritten.isEmpty { files?.append(unwritten) }
        unwritten.removeAll()
        lastWrite = Date()
    }

    /// Every line there is, oldest first.
    func lines() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        flushLocked()
        return files?.readAll() ?? memory
    }

    func clear() {
        lock.lock()
        unwritten.removeAll()
        memory.removeAll()
        files?.clear()
        lock.unlock()
        add(.main, "log", "the log was cleared")
    }
}

/// Where the room server is and the key it asks for. Entered by the person on first use, so that no secret has to be
/// built into the app.
struct ServerConfig: Equatable {
    var server: String = ""
    var key: String = ""

    /// There is an address to talk to.
    var isSet: Bool { URL(string: server)?.host != nil }

    /// Headers that every call to the room server must carry.
    var authHeaders: [String: String] { key.isEmpty ? [:] : ["X-Sapoche-Key": key] }

    static func load(_ store: KeyValueStore) -> ServerConfig {
        ServerConfig(server: store.string("server_url") ?? "", key: store.string("server_key") ?? "")
    }

    func save(to store: KeyValueStore) {
        store.set(server, for: "server_url")
        store.set(key, for: "server_key")
    }

    /// A web address cleaned of spaces and a closing slash; an address without a scheme is taken to be https.
    static func clean(_ address: String) -> String {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        if !text.isEmpty && !text.contains("://") { text = "https://" + text }
        return text
    }
}

/// An error the UI shows as a message: a song that could not play, a queue that is full.
struct ControllerError: Equatable {
    let code: String
    let message: String
}
