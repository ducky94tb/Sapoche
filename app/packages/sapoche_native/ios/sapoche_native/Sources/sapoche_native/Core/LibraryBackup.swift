import Foundation

/// The file a library is saved to and read back from: plain JSON, so that a person can look inside it. Songs are
/// listed once, and likes, playlists and listens point to them by video id. The same format as the Android app's, so
/// a library can move from one phone to the other.
enum LibraryBackup {
    /// The file is not a backup of ours, or is one from a newer app.
    struct FormatError: Error, LocalizedError {
        let message: String

        var errorDescription: String? { message }
    }

    private static let app = "sapoche"
    /// What backups say when the app wrote them as Unison: still read, since they are how a library moved to the renamed app.
    private static let formerApp = "unison"
    private static let version = 1
    private static let maxId = 32
    private static let maxText = 300

    static func toJson(_ backup: LibraryStore.Backup, at: Int64) -> String {
        var songs: [String: Any] = [:]
        backup.liked.forEach { note($0.track, into: &songs) }
        backup.listens.forEach { note($0.track, into: &songs) }
        backup.playlists.forEach { $0.tracks.forEach { note($0, into: &songs) } }
        let root: [String: Any] = [
            "app": app,
            "version": version,
            "exportedAt": at,
            "songs": songs,
            "liked": backup.liked.map { ["id": $0.track.videoId, "at": $0.at] as [String: Any] },
            "playlists": backup.playlists.map {
                ["name": $0.name, "createdAt": $0.createdAt, "updatedAt": $0.updatedAt, "folder": $0.folder ?? NSNull(), "songs": $0.tracks.map(\.videoId)] as [String: Any]
            },
            "history": backup.listens.map { ["id": $0.track.videoId, "at": $0.at] as [String: Any] },
        ]
        return JSONText.encode(root)
    }

    private static func note(_ track: TrackRef, into songs: inout [String: Any]) {
        var obj: [String: Any] = ["title": track.title, "artist": track.artist, "thumb": track.thumb ?? NSNull(), "durMs": track.durMs]
        if track.explicit { obj["explicit"] = true }
        if let year = track.year { obj["year"] = year }
        songs[track.videoId] = obj
    }

    /// What the sync reads: the same songs, likes and listens as [toJson], and the playlists and folders with the ids they have on
    /// this phone, what was blocked and the marks on the taste. Not a file for a person to keep, and no version of its own.
    static func snapshotJson(_ snapshot: LibraryStore.Snapshot) -> String {
        var songs: [String: Any] = [:]
        snapshot.liked.forEach { note($0.track, into: &songs) }
        snapshot.listens.forEach { note($0.track, into: &songs) }
        snapshot.playlists.forEach { $0.tracks.forEach { note($0, into: &songs) } }
        func marked(_ list: [LibraryStore.Marked]) -> [[String: Any]] {
            list.map { ["kind": $0.kind, "key": $0.key, "label": $0.label, "at": $0.at] }
        }
        let root: [String: Any] = [
            "songs": songs,
            "liked": snapshot.liked.map { ["id": $0.track.videoId, "at": $0.at] as [String: Any] },
            "playlists": snapshot.playlists.map {
                ["id": $0.id, "name": $0.name, "folderId": $0.folderId ?? NSNull(), "createdAt": $0.createdAt, "updatedAt": $0.updatedAt,
                 "songs": $0.tracks.map(\.videoId)] as [String: Any]
            },
            "folders": snapshot.folders.map { ["id": $0.id, "name": $0.name, "createdAt": $0.createdAt, "updatedAt": $0.updatedAt] as [String: Any] },
            "history": snapshot.listens.map { ["id": $0.track.videoId, "at": $0.at] as [String: Any] },
            "blocked": marked(snapshot.blocked),
            "marks": marked(snapshot.marks),
        ]
        return JSONText.encode(root)
    }

    /// Reads a file written by [toJson]. References to songs the file does not describe are skipped.
    static func fromJson(_ text: String) throws -> LibraryStore.Backup {
        guard let root = JSON.parse(text), root.object != nil, [app, formerApp].contains(root.at("app").string ?? "") else { throw FormatError(message: "Not a Sapoche backup") }
        if (root.at("version").int ?? 0) > version { throw FormatError(message: "Made by a newer version of Sapoche") }
        guard let table = root.at("songs").object else { throw FormatError(message: "Not a Sapoche backup") }
        var songs: [String: TrackRef] = [:]
        for (id, value) in table {
            let song = JSON(value)
            let title = String((song.at("title").string ?? "").prefix(maxText))
            if id.trimmingCharacters(in: .whitespaces).isEmpty || id.count > maxId || title.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            let thumb = song.at("thumb").string.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
            let year = song.at("year").string.flatMap { $0.count == 4 && $0.allSatisfy { $0.isASCII && $0.isNumber } ? $0 : nil }
            songs[id] = TrackRef(videoId: id, title: title, artist: String((song.at("artist").string ?? "").prefix(maxText)),
                                 thumb: thumb, durMs: max(song.at("durMs").int64 ?? 0, 0),
                                 explicit: song.at("explicit").bool ?? false, year: year)
        }
        func entries(_ list: JSON) -> [LibraryStore.Entry] {
            list.array.compactMap { item in
                item.object == nil ? nil : songs[item.at("id").string ?? ""].map { LibraryStore.Entry(track: $0, at: item.at("at").int64 ?? 0) }
            }
        }
        let playlists = root.at("playlists").array.filter { $0.object != nil }.map { playlist in
            LibraryStore.SavedPlaylist(
                name: playlist.at("name").string ?? "",
                createdAt: playlist.at("createdAt").int64 ?? 0,
                updatedAt: playlist.at("updatedAt").int64 ?? 0,
                tracks: playlist.at("songs").array.compactMap { songs[$0.string ?? ""] },
                folder: playlist.at("folder").string.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : String($0.prefix(maxText)) }
            )
        }
        /// The blocks or marks of the sync (a file a person keeps has none); an entry without a kind or key is skipped.
        func marked(_ list: JSON) -> [LibraryStore.Marked] {
            list.array.compactMap { item in
                let kind = String((item.at("kind").string ?? "").prefix(maxId))
                let key = String((item.at("key").string ?? "").prefix(maxText))
                if item.object == nil || kind.trimmingCharacters(in: .whitespaces).isEmpty || key.trimmingCharacters(in: .whitespaces).isEmpty { return nil }
                return LibraryStore.Marked(kind: kind, key: key, label: String((item.at("label").string ?? "").prefix(maxText)), at: item.at("at").int64 ?? 0)
            }
        }
        return LibraryStore.Backup(liked: entries(root.at("liked")), playlists: playlists, listens: entries(root.at("history")),
                                   blocked: marked(root.at("blocked")), marks: marked(root.at("marks")))
    }
}
