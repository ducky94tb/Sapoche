import Foundation

/// How serious a line of the diary is. Mirrors `Diary.kt` (and `app/lib/data/log_line.dart`); the three read the same
/// `diary_levels.json`. `E`, `W` and `K` are the key lines, kept in a small file that noise never pushes out of.
enum LogLevel: Character, CaseIterable {
    case error = "E", warn = "W", main = "K", info = "I", detail = "D"

    var isKey: Bool { self == .error || self == .warn || self == .main }
}

/// The shared shape of a line: `MM-dd HH:mm:ss.SSS L [tag] message`.
enum Diary {
    private static let stampLength = "MM-dd HH:mm:ss.SSS".count

    static func line(stamp: String, level: LogLevel, tag: String, message: String) -> String {
        "\(stamp) \(level.rawValue) [\(tag)] \(message)"
    }

    /// The level written in [line], or nil for a line of the old shape or a stray one.
    static func levelOf(_ line: String) -> LogLevel? {
        let chars = Array(line.prefix(stampLength + 4))
        guard chars.count == stampLength + 4, chars[2] == "-", chars[5] == " ", chars[stampLength] == " ",
              chars[stampLength + 2] == " ", chars[stampLength + 3] == "[" else { return nil }
        return LogLevel(rawValue: chars[stampLength + 1])
    }

    private static let detailTags: Set<String> = ["http"]
    private static let detailPrefixes = ["drift="]
    private static let detailParts = ["bandwidth estimate"]
    private static let errorTags: Set<String> = ["crash", "error", "diagnostic"]
    private static let errorParts = ["player error", "uncaught", "the player failed"]
    private static let warnParts = [
        "failed", "could not", "giving up", "did not load", "weak network", "stalled", "no answer", "rejected", "refused",
        "reconnecting", "closed:", "server error", "unparsable", "found nothing", "no radio",
    ]
    private static let mainPrefixes = [
        "connected to ", "listening on my own", "back to listening on my own", "following the room again", "advanced locally to",
        "following '", "prepared '", "---- process started", "the sound was taken", "the interruption", "the output changed", "the output went away",
    ]

    /// The level of a line written without one. First match wins, from the loudest.
    static func infer(tag: String, message: String) -> LogLevel {
        let text = message.lowercased()
        if detailTags.contains(tag) || detailPrefixes.contains(where: { text.hasPrefix($0) }) || detailParts.contains(where: { text.contains($0) }) {
            return .detail
        }
        if errorTags.contains(tag) || errorParts.contains(where: { text.contains($0) }) { return .error }
        if tag == "exit" { return message.contains("reason=CRASH") || message.contains("reason=ANR") ? .error : .warn }
        if warnParts.contains(where: { text.contains($0) }) { return .warn }
        if mainPrefixes.contains(where: { text.hasPrefix($0) }) { return .main }
        return .info
    }
}

/// The diary on disk: `sapoche.log` and `sapoche.1.log` take every line, one after the other (when the first is full it
/// becomes the second and the old second is gone), and `sapoche-key.log` takes the key lines alone, so that a minute of
/// noise never pushes a failure out of reach. Not thread safe: `EventLog` holds the lock.
final class DiaryFiles {
    private let current: URL
    private let older: URL
    private let key: URL
    private let maxBytes: Int
    private let maxKeyBytes: Int
    private let fm = FileManager.default

    init(dir: URL, maxBytes: Int = 1_000_000, maxKeyBytes: Int = 256_000) {
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        current = dir.appendingPathComponent("sapoche.log")
        older = dir.appendingPathComponent("sapoche.1.log")
        key = dir.appendingPathComponent("sapoche-key.log")
        self.maxBytes = maxBytes
        self.maxKeyBytes = maxKeyBytes
        // A file of the old shape (no date, no level) is not worth reading beside the new ones
        if let first = read(current).first, Diary.levelOf(first) == nil { try? fm.removeItem(at: current) }
    }

    func append(_ lines: [String]) {
        guard !lines.isEmpty else { return }
        let text = Data((lines.joined(separator: "\n") + "\n").utf8)
        if size(current) > 0, size(current) + text.count > maxBytes {
            try? fm.removeItem(at: older)
            try? fm.moveItem(at: current, to: older)
        }
        write(text, to: current)
        let keys = lines.filter { Diary.levelOf($0)?.isKey == true }
        if !keys.isEmpty {
            write(Data((keys.joined(separator: "\n") + "\n").utf8), to: key)
            if size(key) > maxKeyBytes { trimKey() }
        }
    }

    /// Every line there is, oldest first: the key lines that the full files no longer reach, then the full files.
    func readAll() -> [String] {
        let full = read(older) + read(current)
        let seen = Set(full)
        return read(key).filter { !seen.contains($0) } + full
    }

    /// The lines at the end of the newest full file: [maxBytes] at most.
    func lastRun(maxBytes: Int = 64 * 1024) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: current) else { return [] }
        defer { try? handle.close() }
        let length = Int((try? handle.seekToEnd()) ?? 0)
        let from = max(0, length - maxBytes)
        try? handle.seek(toOffset: UInt64(from))
        let data = (try? handle.readToEnd()) ?? Data()
        let all = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        return from > 0 ? Array(all.dropFirst()) : all
    }

    func clear() {
        for url in [current, older, key] { try? fm.removeItem(at: url) }
    }

    private func trimKey() {
        let all = read(key)
        let kept = all.dropFirst(all.count / 2)
        try? Data((kept.joined(separator: "\n") + "\n").utf8).write(to: key, options: .atomic)
    }

    private func size(_ url: URL) -> Int {
        ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
    }

    private func write(_ data: Data, to url: URL) {
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    private func read(_ url: URL) -> [String] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }
}
