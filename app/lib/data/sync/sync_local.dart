import 'dart:convert';
import 'dart:math';

import '../models.dart';
import '../music_models.dart';
import 'sync_doc.dart';

/// What the sync engine asks of the library of this phone. The app's [Backend] does all of it (see `BackendLibrary`); the
/// tests give an in-memory one.
abstract interface class SyncLibrary {
  /// The library as JSON (see [LocalLibrary.fromJson]), read in one go.
  Future<String> snapshot();

  /// Adds what [json] holds: `songs`, `liked`, `history`, `blocked`, `marks`, in the shape of [LocalLibrary]. Keeps the times
  /// given; what is there already stays as it is.
  Future<void> merge(String json);

  Future<void> setLiked(Track track, bool liked);
  Future<void> clearHistory();
  Future<void> unblock(BlockedItem item);
  Future<void> unmark(String kind, String key);
  Future<int> createFolder(String name);
  Future<void> renameFolder(int id, String name);
  Future<void> deleteFolder(int id);
  Future<void> setPlaylistFolder(int id, int? folderId);
  Future<int> createPlaylist(String name, List<Track> tracks);
  Future<void> renamePlaylist(int id, String name);
  Future<void> deletePlaylist(int id);
  Future<int> addToPlaylist(int id, List<Track> tracks);
  Future<void> removeFromPlaylist(int id, String videoId);
  Future<void> movePlaylistItem(int id, String videoId, int toIndex);
}

class LocalPlaylist {
  const LocalPlaylist({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.updatedAt,
    this.folderId,
    this.songs = const [],
  });

  final int id;
  final String name;
  final int? folderId;
  final int createdAt;
  final int updatedAt;
  final List<String> songs;
}

class LocalFolder {
  const LocalFolder({required this.id, required this.name, required this.createdAt, required this.updatedAt});

  final int id;
  final String name;
  final int createdAt;
  final int updatedAt;
}

/// The library of this phone as its database holds it, with the ids that mean something here only.
class LocalLibrary {
  const LocalLibrary({
    this.songs = const {},
    this.liked = const {},
    this.playlists = const [],
    this.folders = const [],
    this.history = const {},
    this.blocked = const {},
    this.marks = const {},
  });

  final Map<String, Map<String, Object?>> songs;
  final Map<String, int> liked;
  final List<LocalPlaylist> playlists;
  final List<LocalFolder> folders;
  final Set<Listen> history;
  final Map<String, SyncMark> blocked;
  final Map<String, SyncMark> marks;

  /// Reads what the native side (or the browser's store) gives; throws [FormatException] when it is not that.
  factory LocalLibrary.fromJson(String text) {
    final Map<String, Object?> root;
    try {
      root = (jsonDecode(text) as Map).cast<String, Object?>();
    } on Object {
      throw const FormatException('Not a library');
    }
    List<Map<String, Object?>> list(String name) => [
      for (final item in root[name] as List? ?? const []) (item as Map).cast<String, Object?>(),
    ];
    int number(Object? value) => (value as num?)?.toInt() ?? 0;
    Map<String, SyncMark> marks(String name) => {
      for (final m in list(name)) '${m['kind']}|${m['key']}': SyncMark(label: m['label'] as String? ?? '', at: number(m['at'])),
    };
    return LocalLibrary(
      songs: {
        for (final e in ((root['songs'] as Map?) ?? const {}).entries) e.key as String: (e.value as Map).cast<String, Object?>(),
      },
      liked: {for (final l in list('liked')) l['id'] as String: number(l['at'])},
      playlists: [
        for (final p in list('playlists'))
          LocalPlaylist(
            id: number(p['id']),
            name: p['name'] as String? ?? '',
            folderId: (p['folderId'] as num?)?.toInt(),
            createdAt: number(p['createdAt']),
            updatedAt: number(p['updatedAt']),
            songs: [for (final id in p['songs'] as List? ?? const []) id as String],
          ),
      ],
      folders: [
        for (final f in list('folders'))
          LocalFolder(
            id: number(f['id']),
            name: f['name'] as String? ?? '',
            createdAt: number(f['createdAt']),
            updatedAt: number(f['updatedAt']),
          ),
      ],
      history: {for (final h in list('history')) (h['id'] as String, number(h['at']))},
      blocked: marks('blocked'),
      marks: marks('marks'),
    );
  }
}

/// Which id of the database of this phone is which playlist or folder of the synced library (by uid). Made by the sync engine
/// and kept beside the copy of the last sync; a playlist it has not seen gets a new uid.
class UidMap {
  UidMap({Map<String, int>? playlists, Map<String, int>? folders})
    : playlists = playlists ?? {},
      folders = folders ?? {};

  /// uid → id on this phone.
  final Map<String, int> playlists;
  final Map<String, int> folders;

  static final _random = Random.secure();

  static String newUid() => [for (var i = 0; i < 12; i++) _random.nextInt(256).toRadixString(16).padLeft(2, '0')].join();

  factory UidMap.fromJson(Map<String, Object?> json) => UidMap(
    playlists: {for (final e in ((json['playlists'] as Map?) ?? const {}).entries) e.key as String: (e.value as num).toInt()},
    folders: {for (final e in ((json['folders'] as Map?) ?? const {}).entries) e.key as String: (e.value as num).toInt()},
  );

  Map<String, Object?> toJson() => {'playlists': playlists, 'folders': folders};

  String? playlistUid(int id) => playlists.entries.where((e) => e.value == id).map((e) => e.key).firstOrNull;
  String? folderUid(int id) => folders.entries.where((e) => e.value == id).map((e) => e.key).firstOrNull;

  /// The synced form of [local]: playlists and folders by uid (new ones are given a uid and noted here), the entries that
  /// are only this phone's left out. What this phone no longer has is forgotten here.
  SyncDoc toDoc(LocalLibrary local) {
    final folderIds = {for (final f in local.folders) f.id};
    final playlistIds = {for (final p in local.playlists) p.id};
    folders.removeWhere((_, id) => !folderIds.contains(id));
    playlists.removeWhere((_, id) => !playlistIds.contains(id));
    final syncedFolders = {
      for (final f in local.folders) _uid(folders, f.id): SyncFolder(name: f.name, createdAt: f.createdAt, updatedAt: f.updatedAt),
    };
    final syncedPlaylists = {
      for (final p in local.playlists)
        _uid(playlists, p.id): SyncPlaylist(
          name: p.name,
          folder: p.folderId == null ? null : _uid(folders, p.folderId!),
          createdAt: p.createdAt,
          updatedAt: p.updatedAt,
          songs: p.songs,
        ),
    };
    return SyncDoc(
      songs: local.songs,
      likes: local.liked,
      folders: syncedFolders,
      playlists: syncedPlaylists,
      history: local.history,
      blocked: local.blocked,
      marks: local.marks,
    );
  }

  static String _uid(Map<String, int> map, int id) {
    for (final e in map.entries) {
      if (e.value == id) return e.key;
    }
    return _bind(map, id);
  }

  static String _bind(Map<String, int> map, int id) {
    final uid = newUid();
    map[uid] = id;
    return uid;
  }
}
