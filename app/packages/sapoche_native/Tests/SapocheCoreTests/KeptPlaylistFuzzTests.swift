import XCTest
@testable import SapocheCore

/// Random sequences of everything a person can do to playlists, folders, likes and downloads, with the rules of kept
/// playlists checked from outside after every step (the oracle is worked out from the public lists, not from the SQL).
final class KeptPlaylistFuzzTests: XCTestCase {
    private struct Rng {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func below(_ n: Int) -> Int { Int(next() % UInt64(max(n, 1))) }
        mutating func chance(_ percent: Int) -> Bool { below(100) < percent }
        mutating func pick<T>(_ items: [T]) -> T? { items.isEmpty ? nil : items[below(items.count)] }
    }

    private func song(_ n: Int) -> TrackRef {
        TrackRef(videoId: "v\(n)", title: "Title \(n)", artist: "Artist", thumb: nil, durMs: 200_000)
    }

    /// The songs of kept playlists, worked out from the public lists.
    private func kept(_ store: LibraryStore) async throws -> Set<String> {
        let folders = Dictionary(uniqueKeysWithValues: try await store.folders().map { ($0.id, $0.offline) })
        var songs = Set<String>()
        for list in try await store.playlists() where list.offline || (list.folderId.flatMap { folders[$0] } ?? false) {
            songs.formUnion(try await store.playlistTracks(list.id).map(\.videoId))
        }
        return songs
    }

    private func states(_ store: LibraryStore) async throws -> [String: String] {
        Dictionary(uniqueKeysWithValues: try await store.downloads().map { ($0.track.videoId, $0.state) })
    }

    /// What must hold whatever was done: nothing waits that no kept playlist and no like asks for, and what a run for kept
    /// playlists would fetch is only ever kept songs not on the list yet.
    private func check(_ store: LibraryStore, _ log: [String], seed: UInt64, file: StaticString = #filePath, line: UInt = #line) async throws {
        let keptSongs = try await kept(store)
        let liked = try await store.likedIds()
        let listed = try await states(store)
        let orphans = listed.filter { $0.value == LibraryStore.waiting && !keptSongs.contains($0.key) && !liked.contains($0.key) }.keys.sorted()
        XCTAssertEqual(orphans, [], "waiting with nothing asking for it; seed \(seed); steps: \(log.suffix(6))", file: file, line: line)
        let toFetch = Set(try await store.offlineToDownload().map(\.videoId))
        XCTAssertTrue(toFetch.isSubset(of: keptSongs), "a song that is not kept would be fetched; seed \(seed)", file: file, line: line)
        XCTAssertTrue(toFetch.isDisjoint(with: Set(listed.keys)), "a song already listed would be asked again; seed \(seed)", file: file, line: line)
        let anyKept = try await store.hasOffline()
        let lists = try await store.playlists()
        let folders = try await store.folders()
        let keptFolders = Set(folders.filter(\.offline).map(\.id))
        XCTAssertEqual(anyKept, lists.contains { $0.offline || ($0.folderId.map(keptFolders.contains) ?? false) }, "hasOffline; seed \(seed)", file: file, line: line)
        let tracksKept = try await store.nextDownload(LibraryStore.waiting, keptOnly: true)
        if let id = tracksKept { XCTAssertTrue(keptSongs.contains(id), "a run for kept playlists took \(id); seed \(seed)", file: file, line: line) }
    }

    /// A folder of three full playlists (the worst case the plan names): switching it on, going through every song the way a run
    /// does, and switching it off with removing must each take seconds at most, and leave nothing behind.
    func testAFolderOfThreeFullPlaylistsIsKeptAndLetGoInTime() async throws {
        let store = try LibraryStore(path: ":memory:")
        let folder = try await store.createFolder("Trips")
        for list in 0..<3 {
            let songs = (0..<500).map { song(list * 500 + $0) }
            let id = try await store.createPlaylist("P\(list)", songs)
            try await store.setPlaylistFolder(id, folder)
        }
        let start = Date()
        _ = try await store.setFolderOffline(folder, true)
        let wanted = try await store.offlineToDownload()
        XCTAssertEqual(wanted.count, 1500)
        try await store.requestDownloads(wanted, waiting: true)
        var taken = 0
        while let id = try await store.nextDownload(LibraryStore.waiting, keptOnly: true) {
            _ = try await store.pendingDownloads(LibraryStore.waiting, keptOnly: true)
            try await store.finishDownload(id, bytes: 1)
            taken += 1
        }
        XCTAssertEqual(taken, 1500)
        let removable = try await store.offlineRemovable(playlistId: nil, folderId: folder, keepLiked: false)
        XCTAssertEqual(removable, 1500)
        let dropped = try await store.setFolderOffline(folder, false, remove: true)
        XCTAssertEqual(dropped.count, 1500)
        let rest = try await store.downloads()
        XCTAssertEqual(rest.count, 0)
        let seconds = Date().timeIntervalSince(start)
        print("1500 songs kept, fetched in order and let go: \(seconds) s")
        XCTAssertLessThan(seconds, 20)
    }

    func testRandomThingsDoneToKeptPlaylistsNeverLeaveWhatNobodyAsksFor() async throws {
        for seed in UInt64(1)...UInt64(60) {
            let store = try LibraryStore(path: ":memory:")
            var rng = Rng(state: seed)
            var log: [String] = []
            for _ in 0..<80 {
                let lists = try await store.playlists()
                let folders = try await store.folders()
                switch rng.below(15) {
                case 0:
                    let n = rng.below(6)
                    let songs = (0..<n).map { _ in song(rng.below(14)) }
                    _ = try await store.createPlaylist("P", songs)
                    log.append("create \(n)")
                case 1:
                    if let list = rng.pick(lists) {
                        let songs = (0..<(1 + rng.below(3))).map { _ in song(rng.below(14)) }
                        _ = try await store.addToPlaylist(list.id, songs)
                        log.append("add \(list.id)")
                    }
                case 2:
                    if let list = rng.pick(lists), let id = rng.pick(try await store.playlistTracks(list.id)) {
                        try await store.removeFromPlaylist(list.id, id.videoId)
                        log.append("remove \(id.videoId) from \(list.id)")
                    }
                case 3:
                    if let list = rng.pick(lists) { try await store.deletePlaylist(list.id); log.append("delete \(list.id)") }
                case 4:
                    _ = try await store.createFolder("F"); log.append("folder")
                case 5:
                    if let folder = rng.pick(folders) { try await store.deleteFolder(folder.id); log.append("delete folder \(folder.id)") }
                case 6:
                    if let list = rng.pick(lists) {
                        let folder = rng.chance(25) ? nil : rng.pick(folders)?.id
                        try await store.setPlaylistFolder(list.id, folder)
                        log.append("move \(list.id) to \(String(describing: folder))")
                    }
                case 7, 8:
                    if let list = rng.pick(lists) {
                        let on = rng.chance(60)
                        let remove = rng.chance(40)
                        let expected = try await store.offlineRemovable(playlistId: list.id, folderId: nil, keepLiked: false)
                        let before = try await states(store).filter { $0.value == LibraryStore.done }.count
                        let mine = try await store.playlistTracks(list.id).map(\.videoId)
                        let dropped = try await store.setPlaylistOffline(list.id, on, remove: remove)
                        let after = try await states(store).filter { $0.value == LibraryStore.done }.count
                        if !on {
                            let keptNow = try await kept(store)
                            let still = try await states(store).filter { mine.contains($0.key) && !keptNow.contains($0.key) && ($0.value == LibraryStore.waiting || $0.value == LibraryStore.queued) }.keys.sorted()
                            XCTAssertEqual(still, [], "stopping must stop what is still to come; seed \(seed)")
                        }
                        if !on && remove { XCTAssertEqual(before - after, expected, "the question said \(expected); seed \(seed)") }
                        if on { XCTAssertEqual(dropped, []) }
                        log.append("playlist \(list.id) \(on ? "on" : "off")\(remove ? " remove" : "")")
                    }
                case 9:
                    if let folder = rng.pick(folders) {
                        let on = rng.chance(60)
                        let remove = rng.chance(40)
                        let expected = try await store.offlineRemovable(playlistId: nil, folderId: folder.id, keepLiked: false)
                        let before = try await states(store).filter { $0.value == LibraryStore.done }.count
                        _ = try await store.setFolderOffline(folder.id, on, remove: remove)
                        let after = try await states(store).filter { $0.value == LibraryStore.done }.count
                        if !on && remove { XCTAssertEqual(before - after, expected, "the question said \(expected); seed \(seed)") }
                        log.append("folder \(folder.id) \(on ? "on" : "off")\(remove ? " remove" : "")")
                    }
                case 10:
                    let id = song(rng.below(14))
                    try await store.setLiked(id, rng.chance(60)); log.append("like \(id.videoId)")
                case 11:
                    // The job for kept playlists asks for what is to come
                    try await store.requestDownloads(try await store.offlineToDownload(), waiting: true); log.append("job asks")
                case 12:
                    // ...and fetches some of it
                    if let id = try await store.nextDownload(LibraryStore.waiting, keptOnly: true) {
                        try await store.finishDownload(id, bytes: 1); log.append("fetched \(id)")
                    }
                case 13:
                    if let id = rng.pick(try await store.downloads().map(\.track.videoId)) {
                        try await store.removeDownload(id); log.append("remove download \(id)")
                    }
                default:
                    if rng.chance(10) {
                        try await store.clearDownloads()
                        let none = try await store.hasOffline()
                        XCTAssertFalse(none, "after Delete all nothing is kept; seed \(seed)")
                        log.append("delete all")
                        break
                    }
                    // A song asked for by hand
                    let id = song(rng.below(14))
                    try await store.requestDownloads([id])
                    // Half of what is asked for by hand is not fetched yet
                    if rng.chance(50) { try await store.finishDownload(id.videoId, bytes: 1) }
                    log.append("by hand \(id.videoId)")
                }
                try await check(store, log, seed: seed)
            }
        }
    }
}
