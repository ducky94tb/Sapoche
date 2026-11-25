import 'package:flutter/foundation.dart';

import 'sync_doc.dart';

/// Three-way merge of the libraries of two phones, given the copy the last sync left ([base]).
///
/// What this phone changed since is told by comparing [local] with [base]; what the others changed is [remote] against it.
/// So nothing needs to remember who deleted what: a phone that was off for a month compares with its own last copy.
/// A change on one side only is taken; when both sides changed the same thing, an addition beats a removal (a song too many
/// is better than a song lost). Without a [base] (the first sync of a phone) nothing is removed, and the two are joined.
SyncDoc mergeDocs({
  SyncDoc? base,
  required SyncDoc local,
  required SyncDoc remote,
  required int now,
  int localClearedAt = 0,
  int historyKeep = 2000,
}) {
  final b = base ?? SyncDoc();

  final likes = _mergeSet<int>(b.likes, local.likes, remote.likes);
  final blocked = _mergeSet<SyncMark>(b.blocked, local.blocked, remote.blocked);
  final marks = _mergeSet<SyncMark>(b.marks, local.marks, remote.marks);

  final folders = _mergeKeyed<SyncFolder>(b.folders, local.folders, remote.folders, (bf, l, r) {
    final localNewer = l.updatedAt >= r.updatedAt;
    return SyncFolder(
      name: _pick(bf?.name, l.name, r.name, localNewer),
      createdAt: l.createdAt < r.createdAt ? l.createdAt : r.createdAt,
      updatedAt: localNewer ? l.updatedAt : r.updatedAt,
    );
  });
  final playlists = _mergeKeyed<SyncPlaylist>(b.playlists, local.playlists, remote.playlists, _bothPlaylists);
  // A folder that was deleted leaves its playlists out of any folder
  for (final e in playlists.entries.toList()) {
    if (e.value.folder != null && !folders.containsKey(e.value.folder)) {
      playlists[e.key] = e.value.copyWith(folder: null);
    }
  }

  // Listens only grow, but for the limit that cuts off the oldest, and a clear that someone asked for
  final cleared = localClearedAt > 0 || (base != null && base.history.isNotEmpty && local.history.isEmpty);
  final clearedAt = [remote.historyClearedAt, if (cleared) (localClearedAt > 0 ? localClearedAt : now)].reduce((a, c) => a > c ? a : c);
  final history = {
    ...remote.history,
    ...local.history.difference(b.history),
  }.where((e) => e.$2 >= clearedAt).toList()..sort((a, c) => c.$2.compareTo(a.$2));

  final doc = SyncDoc(
    likes: likes,
    folders: folders,
    playlists: playlists,
    history: history.take(historyKeep).toSet(),
    historyClearedAt: clearedAt,
    blocked: blocked,
    marks: marks,
    devices: {...remote.devices},
  );
  doc.songs.addAll(SyncDoc.songsOf(doc.referenced, [remote.songs, local.songs]));
  return doc;
}

/// A set of things with a value each (likes with their time; blocks): the three-way rule of "added here or kept there".
Map<String, V> _mergeSet<V>(Map<String, V> base, Map<String, V> local, Map<String, V> remote) {
  final merged = <String, V>{};
  for (final key in {...base.keys, ...local.keys, ...remote.keys}) {
    final inBase = base.containsKey(key);
    final inLocal = local.containsKey(key);
    final inRemote = remote.containsKey(key);
    if (inLocal && !inBase) {
      merged[key] = inRemote ? remote[key] as V : local[key] as V;
    } else if (inRemote && !(inBase && !inLocal)) {
      merged[key] = remote[key] as V;
    }
  }
  return merged;
}

/// Things with an identity of their own (playlists, folders): [both] joins the two versions of one that both sides still have.
Map<String, T> _mergeKeyed<T>(
  Map<String, T> base,
  Map<String, T> local,
  Map<String, T> remote,
  T Function(T? base, T local, T remote) both,
) {
  final merged = <String, T>{};
  for (final key in {...base.keys, ...local.keys, ...remote.keys}) {
    final b = base[key];
    final l = local[key];
    final r = remote[key];
    final T? result;
    if (l == null) {
      // Not here: new there, or deleted here (kept all the same when they changed it meanwhile)
      result = b == null || r == null ? r : (r == b ? null : r);
    } else if (r == null) {
      // Not there: new here, or deleted there (kept when it was changed here meanwhile)
      result = b == null || l != b ? l : null;
    } else {
      result = both(b, l, r);
    }
    if (result != null) merged[key] = result;
  }
  return merged;
}

/// The side that changed a value wins; when both did, [localNewer] says whose change came last.
T _pick<T>(T? base, T local, T remote, bool localNewer) {
  if (local == remote) return local;
  if (base == local) return remote;
  if (base == remote) return local;
  return localNewer ? local : remote;
}

SyncPlaylist _bothPlaylists(SyncPlaylist? base, SyncPlaylist l, SyncPlaylist r) {
  final localNewer = l.updatedAt >= r.updatedAt;
  final List<String> songs;
  if (base != null && listEquals(r.songs, base.songs)) {
    songs = l.songs;
  } else if (base != null && listEquals(l.songs, base.songs)) {
    songs = r.songs;
  } else {
    // Both moved: the order of the server, without what this phone took out, and what it put in at the end
    final before = base?.songs.toSet() ?? const <String>{};
    final took = before.difference(l.songs.toSet());
    final there = r.songs.toSet();
    songs = [
      for (final id in r.songs)
        if (!took.contains(id)) id,
      for (final id in l.songs)
        if (!before.contains(id) && !there.contains(id)) id,
    ];
  }
  return SyncPlaylist(
    name: _pick(base?.name, l.name, r.name, localNewer),
    folder: _pick(base?.folder, l.folder, r.folder, localNewer),
    createdAt: l.createdAt < r.createdAt ? l.createdAt : r.createdAt,
    updatedAt: localNewer ? l.updatedAt : r.updatedAt,
    songs: songs,
  );
}

/// What a merge would take away on this phone, as the person would see it.
class SyncLoss {
  const SyncLoss({required this.likes, required this.playlists});

  final int likes;
  final int playlists;

  /// More than a person takes out by hand in a sitting: over 20 and over a third of what there was.
  static const minCount = 20;

  SyncLoss.between(SyncDoc from, SyncDoc to)
    : likes = from.likes.keys.where((k) => !to.likes.containsKey(k)).length,
      playlists = from.playlists.keys.where((k) => !to.playlists.containsKey(k)).length;

  bool tooMuch(SyncDoc from) => _big(likes, from.likes.length) || _big(playlists, from.playlists.length);

  static bool _big(int lost, int had) => lost > minCount && lost * 10 > had * 3;
}

/// A change that would take away a lot at once; the person is asked before it goes on.
class SyncRefused implements Exception {
  const SyncRefused(this.loss, {required this.fromHere});

  final SyncLoss loss;

  /// The change is this phone's (what it would send), not the others' (what it would take).
  final bool fromHere;

  @override
  String toString() => 'SyncRefused(likes ${loss.likes}, playlists ${loss.playlists}, ${fromHere ? 'to the server' : 'from the server'})';
}
