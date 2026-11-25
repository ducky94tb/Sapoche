import 'package:flutter/foundation.dart';

/// A playlist as the synced library keeps it. [uid] (the key it is stored under) is made by the sync engine and is the same on
/// every phone; the id a phone's own database gave it means nothing elsewhere.
@immutable
class SyncPlaylist {
  const SyncPlaylist({
    required this.name,
    required this.createdAt,
    required this.updatedAt,
    this.folder,
    this.songs = const [],
  });

  final String name;

  /// The uid of its folder, or null.
  final String? folder;
  final int createdAt;
  final int updatedAt;
  final List<String> songs;

  factory SyncPlaylist.fromJson(Map<String, Object?> json) => SyncPlaylist(
    name: json['name'] as String? ?? '',
    folder: json['folder'] as String?,
    createdAt: (json['createdAt'] as num?)?.toInt() ?? 0,
    updatedAt: (json['updatedAt'] as num?)?.toInt() ?? 0,
    songs: [for (final id in json['songs'] as List? ?? const []) id as String],
  );

  Map<String, Object?> toJson() => {
    'name': name,
    if (folder != null) 'folder': folder,
    'createdAt': createdAt,
    'updatedAt': updatedAt,
    'songs': songs,
  };

  SyncPlaylist copyWith({
    String? name,
    Object? folder = _keep,
    int? createdAt,
    int? updatedAt,
    List<String>? songs,
  }) => SyncPlaylist(
    name: name ?? this.name,
    folder: identical(folder, _keep) ? this.folder : folder as String?,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    songs: songs ?? this.songs,
  );

  /// What a person can see of it: times do not count, so a rename and back is no change.
  @override
  bool operator ==(Object other) =>
      other is SyncPlaylist && other.name == name && other.folder == folder && listEquals(other.songs, songs);

  @override
  int get hashCode => Object.hash(name, folder, Object.hashAll(songs));
}

const Object _keep = Object();

@immutable
class SyncFolder {
  const SyncFolder({required this.name, required this.createdAt, required this.updatedAt});

  final String name;
  final int createdAt;
  final int updatedAt;

  factory SyncFolder.fromJson(Map<String, Object?> json) => SyncFolder(
    name: json['name'] as String? ?? '',
    createdAt: (json['createdAt'] as num?)?.toInt() ?? 0,
    updatedAt: (json['updatedAt'] as num?)?.toInt() ?? 0,
  );

  Map<String, Object?> toJson() => {'name': name, 'createdAt': createdAt, 'updatedAt': updatedAt};

  @override
  bool operator ==(Object other) => other is SyncFolder && other.name == name;

  @override
  int get hashCode => name.hashCode;
}

/// A song or artist the person blocked, or a mark they put on the taste: [label] is what the screen shows.
@immutable
class SyncMark {
  const SyncMark({required this.label, required this.at});

  final String label;
  final int at;

  @override
  bool operator ==(Object other) => other is SyncMark && other.label == label;

  @override
  int get hashCode => label.hashCode;
}

/// One listen: which song and when. A set of these is the history.
typedef Listen = (String id, int at);

/// Another phone that syncs this library: what it calls itself and when it last did.
@immutable
class SyncDevice {
  const SyncDevice({required this.label, required this.seenAt});

  final String label;
  final int seenAt;
}

/// The library as it is kept on the server, sealed: what a person keeps (likes, playlists, folders, history, what was blocked
/// or marked on the taste) with the details of every song they point to. The same shape serves a snapshot of one phone, the
/// copy the last sync left ("base") and the merge of them; see `sync_merge.dart`.
class SyncDoc {
  SyncDoc({
    Map<String, Map<String, Object?>>? songs,
    Map<String, int>? likes,
    Map<String, SyncFolder>? folders,
    Map<String, SyncPlaylist>? playlists,
    Set<Listen>? history,
    this.historyClearedAt = 0,
    Map<String, SyncMark>? blocked,
    Map<String, SyncMark>? marks,
    Map<String, SyncDevice>? devices,
  }) : songs = songs ?? {},
       likes = likes ?? {},
       folders = folders ?? {},
       playlists = playlists ?? {},
       history = history ?? {},
       blocked = blocked ?? {},
       marks = marks ?? {},
       devices = devices ?? {};

  static const version = 1;

  /// The details of each song named below, by video id: title, artist, thumb, durMs, explicit, year.
  final Map<String, Map<String, Object?>> songs;

  /// Liked songs by video id, with the time each was liked.
  final Map<String, int> likes;
  final Map<String, SyncFolder> folders;
  final Map<String, SyncPlaylist> playlists;
  final Set<Listen> history;

  /// The listens before this time were cleared by the person, on some phone.
  final int historyClearedAt;

  /// Blocked songs and artists, and marks on the taste, by `kind|key`.
  final Map<String, SyncMark> blocked;
  final Map<String, SyncMark> marks;
  final Map<String, SyncDevice> devices;

  bool get isEmpty =>
      likes.isEmpty && playlists.isEmpty && folders.isEmpty && history.isEmpty && blocked.isEmpty && marks.isEmpty;

  /// The video ids something in the document points to.
  Set<String> get referenced => {
    ...likes.keys,
    for (final p in playlists.values) ...p.songs,
    for (final (id, _) in history) id,
  };

  Map<String, Object?> toJson() => {
    'v': version,
    'songs': songs,
    'likes': likes,
    'folders': {for (final e in folders.entries) e.key: e.value.toJson()},
    'playlists': {for (final e in playlists.entries) e.key: e.value.toJson()},
    'history': [
      for (final (id, at) in history) [id, at],
    ],
    'historyClearedAt': historyClearedAt,
    'blocked': _marksJson(blocked),
    'marks': _marksJson(marks),
    'devices': {
      for (final e in devices.entries) e.key: {'label': e.value.label, 'seenAt': e.value.seenAt},
    },
  };

  /// Reads a document; throws [FormatException] when it is not one or comes from a newer app.
  factory SyncDoc.fromJson(Map<String, Object?> json) {
    if ((json['v'] as num?)?.toInt() case final v? when v > version) {
      throw const FormatException('Made by a newer version of Sapoche');
    }
    Map<String, Object?> map(Object? value) => (value as Map?)?.cast<String, Object?>() ?? const {};
    return SyncDoc(
      songs: {for (final e in map(json['songs']).entries) e.key: map(e.value)},
      likes: {for (final e in map(json['likes']).entries) e.key: (e.value as num).toInt()},
      folders: {for (final e in map(json['folders']).entries) e.key: SyncFolder.fromJson(map(e.value))},
      playlists: {for (final e in map(json['playlists']).entries) e.key: SyncPlaylist.fromJson(map(e.value))},
      history: {
        for (final item in json['history'] as List? ?? const []) ((item as List)[0] as String, (item[1] as num).toInt()),
      },
      historyClearedAt: (json['historyClearedAt'] as num?)?.toInt() ?? 0,
      blocked: _marksFrom(json['blocked']),
      marks: _marksFrom(json['marks']),
      devices: {
        for (final e in map(json['devices']).entries)
          e.key: SyncDevice(
            label: map(e.value)['label'] as String? ?? '',
            seenAt: (map(e.value)['seenAt'] as num?)?.toInt() ?? 0,
          ),
      },
    );
  }

  static List<List<Object?>> _marksJson(Map<String, SyncMark> marks) => [
    for (final e in marks.entries) [e.key, e.value.label, e.value.at],
  ];

  static Map<String, SyncMark> _marksFrom(Object? list) => {
    for (final item in list as List? ?? const [])
      (item as List)[0] as String: SyncMark(label: item[1] as String, at: (item[2] as num).toInt()),
  };

  /// What [referenced] points to in [from], for the documents a merge makes.
  static Map<String, Map<String, Object?>> songsOf(Set<String> ids, Iterable<Map<String, Map<String, Object?>>> from) {
    final found = <String, Map<String, Object?>>{};
    for (final table in from) {
      for (final id in ids) {
        final song = table[id];
        if (song != null) found.putIfAbsent(id, () => song);
      }
    }
    return found;
  }
}
