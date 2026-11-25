import 'dart:async';
import 'dart:convert';

import '../models.dart';
import '../music_models.dart';
import 'wire.dart';

/// Where the library is kept between visits: one document, read when the app starts and written after a change.
abstract interface class LibraryDisk {
  Future<String?> read();
  Future<void> write(String json);
}

/// What a person keeps in the app: songs they liked, what they listened to and their playlists, in memory with the
/// whole of it saved to [disk] a moment after each change. Dart counterpart of `LibraryStore.kt` and `LibraryStore.swift`
/// for the parts a browser has (no downloads and no files on the device).
///
/// [tracks] holds the details of every song something points to, so lists can be shown without the network; a song
/// nothing points to any more is dropped.
class LibraryStore {
  LibraryStore({this.disk, String? stored, int Function()? nowMs, this.saveAfter = const Duration(milliseconds: 400)})
    : _now = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch) {
    if (stored != null) {
      try {
        _load(jsonDecode(stored) as Map<String, Object?>);
      } on Object {
        // A document that cannot be read is an empty library, as a database that cannot be opened would be
      }
    }
  }

  final LibraryDisk? disk;
  final Duration saveAfter;
  final int Function() _now;

  /// Called after every change, so a screen that shows the library can refresh.
  void Function()? onChanged;

  static const recentLimit = 100;
  static const historyKeep = 2000;
  static const skipsKeep = 300;
  static const maxPlaylist = 500;
  static const maxName = 60;
  static const coverParts = 4;

  final _tracks = <String, Track>{};
  // Liked songs by id, with the time they were liked
  final _likes = <String, int>{};
  // One entry per listen, oldest first
  final _history = <(String, int, String?)>[];
  // Songs left after a few seconds, oldest first
  final _skips = <(String, int, String?)>[];
  // What was asked not to be offered, the latest last
  final _blocked = <_Blocked>[];
  // What the person told the taste (see TasteMarks), the latest last
  final _marks = <_Blocked>[];
  // What YouTube listed beside a seed song, by the seed's id
  final _suggestions = <String, _Cached>{};
  final _playlists = <_Playlist>[];
  final _folders = <_Folder>[];
  var _nextId = 1;
  Timer? _saving;
  var _dirty = false;

  /// The name given to a playlist or folder that has none; the app sets it to the language of the screen.
  String Function() unnamed = () => 'Untitled';

  // ------------------------------------------------------------------ likes

  /// Liked songs, the most recently liked first.
  List<Track> liked() {
    final ids = _likes.keys.toList()
      ..sort((a, b) {
        final byTime = _likes[b]!.compareTo(_likes[a]!);
        return byTime != 0 ? byTime : a.compareTo(b);
      });
    return [for (final id in ids) _tracks[id]!];
  }

  /// Liked songs with the time each was liked, the latest first: what the taste is worked out from.
  List<HistoryEntry> likedEntries() => [
    for (final t in liked())
      HistoryEntry(track: t, at: DateTime.fromMillisecondsSinceEpoch(_likes[t.videoId]!), plays: 1),
  ];

  /// Ids of the liked songs.
  Set<String> likedIds() => _likes.keys.toSet();

  void setLiked(Track track, bool liked) {
    if (liked) {
      _remember(track);
      // Liking a song that is already liked keeps the time it was first liked
      _likes.putIfAbsent(track.videoId, _now);
    } else {
      _likes.remove(track.videoId);
      _dropUnused();
    }
    _changed();
  }

  // ------------------------------------------------------------------ history

  /// Songs heard, once each, the one heard last first.
  List<HistoryEntry> recent({int limit = recentLimit}) {
    final last = <String, int>{};
    final plays = <String, int>{};
    for (final (id, at, _) in _history) {
      if (at >= (last[id] ?? 0)) last[id] = at;
      plays[id] = (plays[id] ?? 0) + 1;
    }
    final ids = last.keys.toList()
      ..sort((a, b) {
        final byTime = last[b]!.compareTo(last[a]!);
        return byTime != 0 ? byTime : a.compareTo(b);
      });
    return [
      for (final id in ids.take(limit))
        HistoryEntry(track: _tracks[id]!, at: DateTime.fromMillisecondsSinceEpoch(last[id]!), plays: plays[id]!),
    ];
  }

  /// [track] was heard. Only the last [historyKeep] listens are kept.
  void recordListen(Track track, {String? source}) {
    _remember(track);
    _history.add((track.videoId, _now(), source));
    if (_history.length > historyKeep) _history.removeRange(0, _history.length - historyKeep);
    _dropUnused();
    _changed();
  }

  /// Every listen, the latest first, each with its own time: what the taste is worked out from.
  List<HistoryEntry> listens({int limit = historyKeep}) => [
    for (final (id, at, source) in _history.reversed.take(limit))
      HistoryEntry(track: _tracks[id]!, at: DateTime.fromMillisecondsSinceEpoch(at), plays: 1, source: source),
  ];

  /// Ids of the songs heard since [since] (ms since the epoch).
  Set<String> heardSince(int since) => {
    for (final (id, at, _) in _history)
      if (at >= since) id,
  };

  /// [track] was left after a few seconds. Only the last [skipsKeep] are kept. It is not announced: nothing shows it.
  void recordSkip(Track track, {String? source}) {
    _remember(track);
    _skips.add((track.videoId, _now(), source));
    if (_skips.length > skipsKeep) _skips.removeRange(0, _skips.length - skipsKeep);
    _dropUnused();
    _save();
  }

  /// Songs left after a few seconds, the latest first, each time one entry.
  List<HistoryEntry> skipped() => [
    for (final (id, at, source) in _skips.reversed)
      HistoryEntry(track: _tracks[id]!, at: DateTime.fromMillisecondsSinceEpoch(at), plays: 1, source: source),
  ];

  /// For each source, the songs heard and the songs left after a few seconds since [since] (ms since the epoch); a row
  /// from before sources is [ListenSource.chosen].
  List<SourceStats> sourceStats(int since) {
    final heard = <String, int>{};
    final skipped = <String, int>{};
    for (final (_, at, source) in _history) {
      if (at >= since) heard.update(source ?? ListenSource.chosen, (n) => n + 1, ifAbsent: () => 1);
    }
    for (final (_, at, source) in _skips) {
      if (at >= since) skipped.update(source ?? ListenSource.chosen, (n) => n + 1, ifAbsent: () => 1);
    }
    return [
      for (final source in {...heard.keys, ...skipped.keys}.toList()..sort())
        SourceStats(source: source, heard: heard[source] ?? 0, skipped: skipped[source] ?? 0),
    ];
  }

  void clearHistory() {
    _history.clear();
    // What was left is part of the listening a person asked to forget
    _skips.clear();
    _dropUnused();
    _changed();
  }

  // ------------------------------------------------------------------ blocked

  /// Blocks a `song` (key: video id) or an `artist` (key: `Taste.artistKey`); blocking again changes the label.
  void block(String kind, String key, String label) {
    _blocked.removeWhere((b) => b.kind == kind && b.key == key);
    _blocked.add(_Blocked(kind, key, label, _now()));
    _changed();
  }

  void unblock(String kind, String key) {
    _blocked.removeWhere((b) => b.kind == kind && b.key == key);
    _changed();
  }

  /// What was blocked, the latest first.
  List<BlockedItem> blocked() => [
    for (final b in _blocked.reversed) BlockedItem(kind: b.kind, key: b.key, label: b.label),
  ];

  // ------------------------------------------------------------------ taste marks

  /// What the person told the taste (see [TasteMarks]), the latest first.
  List<TasteMark> tasteMarks() => [
    for (final m in _marks.reversed) TasteMark(kind: m.kind, key: m.key, label: m.label, at: m.at),
  ];

  /// Puts a mark on the taste ([on]), or takes it off. A mark of the same kind and key is replaced.
  void setTasteMark(String kind, String key, String label, {required bool on}) {
    _marks.removeWhere((m) => m.kind == kind && m.key == key);
    if (on) _marks.add(_Blocked(kind, key, label, _now()));
    _changed();
  }

  // ------------------------------------------------------------------ suggestions

  /// What was kept for [seed], or null.
  ({List<TrackRef> tracks, int fetchedAt})? cachedSuggestions(String seed) {
    final kept = _suggestions[seed];
    return kept == null ? null : (tracks: kept.tracks, fetchedAt: kept.fetchedAt);
  }

  void putSuggestions(String seed, List<TrackRef> tracks, int at) {
    _suggestions[seed] = _Cached(tracks, at);
    _changed();
  }

  /// Forgets what was kept for every seed but [seeds].
  void keepSuggestionsFor(Iterable<String> seeds) {
    final keep = seeds.toSet();
    if (_suggestions.keys.every(keep.contains)) return;
    _suggestions.removeWhere((seed, _) => !keep.contains(seed));
    _save();
  }

  // ------------------------------------------------------------------ playlists

  /// Playlists, the one changed last first.
  List<SavedPlaylist> playlists() {
    final sorted = [..._playlists]..sort((a, b) {
      final byTime = b.updatedAt.compareTo(a.updatedAt);
      return byTime != 0 ? byTime : b.id.compareTo(a.id);
    });
    return [
      for (final p in sorted)
        SavedPlaylist(
          id: p.id,
          name: p.name,
          count: p.items.length,
          thumbs: _coverThumbs(p),
          folderId: p.folderId,
        ),
    ];
  }

  /// The pictures of the first songs, each once: what the cover of a playlist is made of.
  List<String> _coverThumbs(_Playlist p) {
    final thumbs = <String>[];
    for (final id in p.items) {
      final thumb = _tracks[id]?.thumb;
      if (thumb != null && !thumbs.contains(thumb)) thumbs.add(thumb);
      if (thumbs.length == coverParts) break;
    }
    return thumbs;
  }

  /// The songs of a playlist in order; empty when there is no such playlist.
  List<Track> playlistTracks(int id) => [
    for (final songId in _playlist(id)?.items ?? const <String>[]) _tracks[songId]!,
  ];

  /// Makes a playlist, with [tracks] in it if given, and returns its id.
  int createPlaylist(String name, List<Track> tracks) {
    final at = _now();
    final playlist = _Playlist(_nextId++, _cleanName(name), at, at);
    _playlists.add(playlist);
    _append(playlist, tracks);
    _changed();
    return playlist.id;
  }

  void renamePlaylist(int id, String name) => _change(id, (p) => p.name = _cleanName(name));

  /// Deletes the playlist; the songs stay wherever else they are kept.
  void deletePlaylist(int id) {
    _playlists.removeWhere((p) => p.id == id);
    _dropUnused();
    _changed();
  }

  /// Adds songs at the end; those already in the playlist are left where they are. Returns how many were added.
  int addToPlaylist(int id, List<Track> tracks) {
    var added = 0;
    _change(id, (p) => added = _append(p, tracks));
    return added;
  }

  void removeFromPlaylist(int id, String videoId) => _change(id, (p) {
    p.items.remove(videoId);
    _dropUnused();
  });

  /// Puts a song at place [toIndex] (0 is the top) of the playlist.
  void movePlaylistItem(int id, String videoId, int toIndex) => _change(id, (p) {
    if (!p.items.remove(videoId)) return;
    p.items.insert(toIndex.clamp(0, p.items.length), videoId);
  });

  int _append(_Playlist p, List<Track> tracks) {
    var added = 0;
    for (final track in tracks) {
      if (p.items.length >= maxPlaylist) break;
      if (p.items.contains(track.videoId)) continue;
      _remember(track);
      p.items.add(track.videoId);
      added++;
    }
    return added;
  }

  /// Runs [change] on one playlist, stamps it as changed and announces it.
  void _change(int id, void Function(_Playlist p) change) {
    final playlist = _playlist(id);
    if (playlist == null) return;
    change(playlist);
    playlist.updatedAt = _now();
    _changed();
  }

  _Playlist? _playlist(int id) {
    for (final p in _playlists) {
      if (p.id == id) return p;
    }
    return null;
  }

  // ------------------------------------------------------------------ folders

  /// Folders, the one changed last first.
  List<PlaylistFolder> folders() {
    final sorted = [..._folders]..sort((a, b) {
      final byTime = b.updatedAt.compareTo(a.updatedAt);
      return byTime != 0 ? byTime : b.id.compareTo(a.id);
    });
    return [for (final f in sorted) PlaylistFolder(id: f.id, name: f.name)];
  }

  /// Makes a folder and returns its id.
  int createFolder(String name) {
    final at = _now();
    final folder = _Folder(_nextId++, _cleanName(name), at);
    _folders.add(folder);
    _changed();
    return folder.id;
  }

  void renameFolder(int id, String name) {
    final folder = _folder(id);
    if (folder == null) return;
    folder
      ..name = _cleanName(name)
      ..updatedAt = _now();
    _changed();
  }

  /// Deletes the folder; its playlists stay, out of any folder.
  void deleteFolder(int id) {
    for (final p in _playlists) {
      if (p.folderId == id) p.folderId = null;
    }
    _folders.removeWhere((f) => f.id == id);
    _changed();
  }

  /// Puts the playlist in the folder, or out of any with a null [folderId]. The playlist is not counted as changed, but
  /// the folder is.
  void setPlaylistFolder(int id, int? folderId) {
    final playlist = _playlist(id);
    if (playlist == null) return;
    final at = _now();
    for (final folder in {playlist.folderId, folderId}) {
      if (folder != null) _folder(folder)?.updatedAt = at;
    }
    playlist.folderId = folderId;
    _changed();
  }

  _Folder? _folder(int id) {
    for (final f in _folders) {
      if (f.id == id) return f;
    }
    return null;
  }

  // ------------------------------------------------------------------ keeping

  String _cleanName(String name) {
    final clean = name.trim();
    if (clean.isEmpty) return unnamed();
    return clean.length > maxName ? clean.substring(0, maxName) : clean;
  }

  void _remember(Track track) {
    final prev = _tracks[track.videoId];
    _tracks[track.videoId] = Track(
      videoId: track.videoId,
      title: track.title,
      artist: track.artist,
      thumb: track.thumb,
      durMs: track.durMs > 0 ? track.durMs : (prev?.durMs ?? 0),
      explicit: track.explicit || (prev?.explicit ?? false),
      year: track.year ?? prev?.year,
    );
  }

  void _dropUnused() {
    final used = {
      ..._likes.keys,
      for (final (id, _, _) in _history) id,
      for (final (id, _, _) in _skips) id,
      for (final p in _playlists) ...p.items,
    };
    _tracks.removeWhere((id, _) => !used.contains(id));
  }

  void _changed() {
    onChanged?.call();
    _save();
  }

  /// Writes the library after the pause, without telling the screens: nothing they show changed.
  void _save() {
    if (disk == null) return;
    _dirty = true;
    _saving?.cancel();
    _saving = Timer(saveAfter, flush);
  }

  // ------------------------------------------------------------------ sync

  /// The library as the sync engine reads it (see `Backend.librarySnapshot`): songs once each, then likes, playlists and
  /// folders with their ids here, listens, blocks and marks.
  String snapshot() {
    final used = {..._likes.keys, for (final p in _playlists) ...p.items, for (final h in _history) h.$1};
    return jsonEncode({
      'songs': {
        for (final id in used)
          if (_tracks[id] case final t? when !t.isLocal) id: _songJson(t),
      },
      'liked': [for (final e in _likes.entries) {'id': e.key, 'at': e.value}],
      'playlists': [
        for (final p in _playlists)
          {
            'id': p.id,
            'name': p.name,
            'folderId': p.folderId,
            'createdAt': p.createdAt,
            'updatedAt': p.updatedAt,
            'songs': p.items,
          },
      ],
      'folders': [
        for (final f in _folders) {'id': f.id, 'name': f.name, 'createdAt': f.updatedAt, 'updatedAt': f.updatedAt},
      ],
      'history': [for (final (id, at, _) in _history) {'id': id, 'at': at}],
      'blocked': [for (final b in _blocked) {'kind': b.kind, 'key': b.key, 'label': b.label, 'at': b.at}],
      'marks': [for (final m in _marks) {'kind': m.kind, 'key': m.key, 'label': m.label, 'at': m.at}],
    });
  }

  static Map<String, Object?> _songJson(Track t) => {
    'title': t.title,
    'artist': t.artist,
    'thumb': t.thumb,
    'durMs': t.durMs,
    if (t.explicit) 'explicit': true,
    if (t.year != null) 'year': t.year,
  };

  /// Adds what [json] holds (`songs`, `liked`, `history`, `blocked`, `marks`) with the times it gives; what is here stays.
  /// Listens beyond the limit go by time, the oldest first.
  void merge(String json) {
    final root = (jsonDecode(json) as Map).cast<String, Object?>();
    final songs = (root['songs'] as Map? ?? const {}).cast<String, Object?>();
    Track? song(String id) {
      final m = (songs[id] as Map?)?.cast<String, Object?>();
      final title = m?['title'] as String?;
      if (m == null || title == null || title.trim().isEmpty || id.isEmpty || id.length > 32) return null;
      return Track(
        videoId: id,
        title: title,
        artist: m['artist'] as String? ?? '',
        thumb: m['thumb'] as String?,
        durMs: (m['durMs'] as num?)?.toInt() ?? 0,
        explicit: m['explicit'] == true,
        year: m['year'] as String?,
      );
    }

    for (final item in root['liked'] as List? ?? const []) {
      final like = (item as Map).cast<String, Object?>();
      final track = song(like['id'] as String);
      if (track == null) continue;
      _remember(track);
      _likes.putIfAbsent(track.videoId, () => (like['at'] as num).toInt());
    }
    final seen = {for (final (id, at, _) in _history) (id, at)};
    for (final item in root['history'] as List? ?? const []) {
      final listen = (item as Map).cast<String, Object?>();
      final track = song(listen['id'] as String);
      final at = (listen['at'] as num).toInt();
      if (track == null || !seen.add((track.videoId, at))) continue;
      _remember(track);
      _history.add((track.videoId, at, null));
    }
    _history.sort((a, b) => a.$2.compareTo(b.$2));
    if (_history.length > historyKeep) _history.removeRange(0, _history.length - historyKeep);
    for (final item in root['blocked'] as List? ?? const []) {
      final b = (item as Map).cast<String, Object?>();
      if (!_blocked.any((o) => o.kind == b['kind'] && o.key == b['key'])) {
        _blocked.add(_Blocked(b['kind'] as String, b['key'] as String, b['label'] as String? ?? '', (b['at'] as num?)?.toInt() ?? 0));
      }
    }
    for (final item in root['marks'] as List? ?? const []) {
      final m = (item as Map).cast<String, Object?>();
      if (!_marks.any((o) => o.kind == m['kind'] && o.key == m['key'])) {
        _marks.add(_Blocked(m['kind'] as String, m['key'] as String, m['label'] as String? ?? '', (m['at'] as num?)?.toInt() ?? 0));
      }
    }
    _dropUnused();
    _changed();
  }

  /// Writes what changed now rather than after the pause, for a page that is going away.
  Future<void> flush() async {
    if (!_dirty) return;
    _dirty = false;
    _saving?.cancel();
    await disk?.write(jsonEncode(_toJson()));
  }

  Map<String, Object?> _toJson() => {
    'v': 3,
    'next': _nextId,
    'tracks': [
      for (final t in _tracks.values)
        [t.videoId, t.title, t.artist, t.thumb, t.durMs, if (t.explicit || t.year != null) ...[t.explicit, t.year]],
    ],
    'likes': [for (final e in _likes.entries) [e.key, e.value]],
    'history': [for (final (id, at, source) in _history) [id, at, source]],
    'skips': [for (final (id, at, source) in _skips) [id, at, source]],
    'blocked': [
      for (final b in _blocked) [b.kind, b.key, b.label, b.at],
    ],
    'marks': [
      for (final m in _marks) [m.kind, m.key, m.label, m.at],
    ],
    'suggestions': {
      for (final e in _suggestions.entries)
        e.key: {
          'at': e.value.fetchedAt,
          'tracks': [
            for (final t in e.value.tracks)
              [t.videoId, t.title, t.artist, t.thumb, t.durMs, if (t.explicit || t.year != null) ...[t.explicit, t.year]],
          ],
        },
    },
    'playlists': [
      for (final p in _playlists)
        {'id': p.id, 'name': p.name, 'created': p.createdAt, 'updated': p.updatedAt, 'folder': p.folderId, 'items': p.items},
    ],
    'folders': [
      for (final f in _folders) {'id': f.id, 'name': f.name, 'updated': f.updatedAt},
    ],
  };

  void _load(Map<String, Object?> json) {
    for (final row in json['tracks'] as List) {
      final t = row as List;
      _tracks[t[0] as String] = Track(
        videoId: t[0] as String,
        title: t[1] as String,
        artist: t[2] as String,
        thumb: t[3] as String?,
        durMs: (t[4] as num).toInt(),
        explicit: t.length > 5 && t[5] == true,
        year: t.length > 6 ? t[6] as String? : null,
      );
    }
    for (final row in json['likes'] as List) {
      final l = row as List;
      _likes[l[0] as String] = (l[1] as num).toInt();
    }
    for (final row in json['history'] as List) {
      final h = row as List;
      // A row written before version 3 has no source
      _history.add((h[0] as String, (h[1] as num).toInt(), h.length > 2 ? h[2] as String? : null));
    }
    // A document written before the taste had none of these
    for (final row in json['skips'] as List? ?? const []) {
      final h = row as List;
      _skips.add((h[0] as String, (h[1] as num).toInt(), h.length > 2 ? h[2] as String? : null));
    }
    for (final row in json['blocked'] as List? ?? const []) {
      final b = row as List;
      _blocked.add(_Blocked(b[0] as String, b[1] as String, b[2] as String, (b[3] as num).toInt()));
    }
    for (final row in json['marks'] as List? ?? const []) {
      final m = row as List;
      _marks.add(_Blocked(m[0] as String, m[1] as String, m[2] as String, (m[3] as num).toInt()));
    }
    (json['suggestions'] as Map<String, Object?>? ?? const {}).forEach((seed, value) {
      final m = value as Map<String, Object?>;
      _suggestions[seed] = _Cached([
        for (final row in m['tracks'] as List)
          TrackRef(
            (row as List)[0] as String,
            row[1] as String,
            row[2] as String,
            row[3] as String?,
            (row[4] as num).toInt(),
            explicit: row.length > 5 && row[5] == true,
            year: row.length > 6 ? row[6] as String? : null,
          ),
      ], (m['at'] as num).toInt());
    });
    for (final p in json['playlists'] as List) {
      final m = p as Map<String, Object?>;
      _playlists.add(
        _Playlist(
          (m['id'] as num).toInt(),
          m['name'] as String,
          (m['created'] as num).toInt(),
          (m['updated'] as num).toInt(),
        )
          ..folderId = (m['folder'] as num?)?.toInt()
          ..items.addAll((m['items'] as List).cast<String>()),
      );
    }
    for (final f in json['folders'] as List) {
      final m = f as Map<String, Object?>;
      _folders.add(_Folder((m['id'] as num).toInt(), m['name'] as String, (m['updated'] as num).toInt()));
    }
    _nextId = (json['next'] as num).toInt();
  }
}

class _Playlist {
  _Playlist(this.id, this.name, this.createdAt, this.updatedAt);

  final int id;
  String name;
  final int createdAt;
  int updatedAt;
  int? folderId;
  final items = <String>[];
}

class _Folder {
  _Folder(this.id, this.name, this.updatedAt);

  final int id;
  String name;
  int updatedAt;
}

class _Blocked {
  _Blocked(this.kind, this.key, this.label, this.at);

  final String kind;
  final String key;
  final String label;
  final int at;
}

class _Cached {
  _Cached(this.tracks, this.fetchedAt);

  final List<TrackRef> tracks;
  final int fetchedAt;
}
