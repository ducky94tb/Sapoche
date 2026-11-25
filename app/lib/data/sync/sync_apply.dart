import 'dart:convert';

import '../models.dart';
import '../music_models.dart';
import 'sync_doc.dart';
import 'sync_local.dart';

/// Brings the library of this phone, as [local] is, to what [merged] says, with the commands it already has for each thing, so
/// that a screen showing the library, the downloads of kept playlists and the like follow as they do for a touch. [map] says
/// which id of this phone is which uid, and learns the ids of what is made here.
///
/// It can be run again after it stopped half way: each step looks at what is there and does what is still to do.
/// [clearHistory] is set when someone else cleared the history, which then goes before the listens are put back.
Future<void> applyMerged({
  required SyncLibrary library,
  required LocalLibrary local,
  required SyncDoc merged,
  required UidMap map,
  bool clearHistory = false,
  Future<void> Function()? saveMap,
}) async {
  Track track(String id) {
    final song = merged.songs[id] ?? local.songs[id] ?? const <String, Object?>{};
    return Track.fromMap({...song, 'videoId': id, 'title': song['title'] ?? ''});
  }

  final here = {for (final p in local.playlists) p.id: p};
  final hereFolders = {for (final f in local.folders) f.id: f};

  // Folders first, as the playlists point to them
  for (final entry in merged.folders.entries) {
    final id = map.folders[entry.key];
    if (id == null || !hereFolders.containsKey(id)) {
      map.folders[entry.key] = await library.createFolder(entry.value.name);
      await saveMap?.call();
    } else if (hereFolders[id]!.name != entry.value.name) {
      await library.renameFolder(id, entry.value.name);
    }
  }

  for (final entry in merged.playlists.entries) {
    final want = entry.value;
    final folderId = want.folder == null ? null : map.folders[want.folder];
    final id = map.playlists[entry.key];
    final have = id == null ? null : here[id];
    if (have == null) {
      final made = await library.createPlaylist(want.name, [for (final s in want.songs) track(s)]);
      map.playlists[entry.key] = made;
      await saveMap?.call();
      if (folderId != null) await library.setPlaylistFolder(made, folderId);
      continue;
    }
    if (have.name != want.name) await library.renamePlaylist(have.id, want.name);
    if (have.folderId != folderId) await library.setPlaylistFolder(have.id, folderId);
    await _setSongs(library, have, want.songs, track);
  }

  for (final p in local.playlists) {
    final uid = map.playlistUid(p.id);
    if (uid == null || !merged.playlists.containsKey(uid)) await library.deletePlaylist(p.id);
  }
  for (final f in local.folders) {
    final uid = map.folderUid(f.id);
    if (uid == null || !merged.folders.containsKey(uid)) await library.deleteFolder(f.id);
  }

  // Likes, listens, blocks and marks that are new here come in one go, with the times they had
  for (final id in local.liked.keys) {
    if (!merged.likes.containsKey(id)) await library.setLiked(track(id), false);
  }
  for (final key in local.blocked.keys) {
    if (!merged.blocked.containsKey(key)) await library.unblock(_item(key, local.blocked[key]!));
  }
  for (final key in local.marks.keys) {
    if (!merged.marks.containsKey(key)) await library.unmark(key.substring(0, key.indexOf('|')), key.substring(key.indexOf('|') + 1));
  }
  if (clearHistory) await library.clearHistory();
  final heard = clearHistory ? <Listen>{} : local.history;
  final newLikes = {for (final e in merged.likes.entries) if (!local.liked.containsKey(e.key)) e.key: e.value};
  final newListens = merged.history.difference(heard);
  final newBlocked = {for (final e in merged.blocked.entries) if (!local.blocked.containsKey(e.key)) e.key: e.value};
  final newMarks = {for (final e in merged.marks.entries) if (!local.marks.containsKey(e.key)) e.key: e.value};
  if (newLikes.isEmpty && newListens.isEmpty && newBlocked.isEmpty && newMarks.isEmpty) return;
  final ids = {...newLikes.keys, for (final (id, _) in newListens) id};
  await library.merge(
    jsonEncode({
      'app': 'sapoche',
      'version': 1,
      'songs': SyncDoc.songsOf(ids, [merged.songs, local.songs]),
      'liked': [
        for (final e in newLikes.entries) {'id': e.key, 'at': e.value},
      ],
      'history': [
        for (final (id, at) in newListens) {'id': id, 'at': at},
      ],
      'blocked': _marks(newBlocked),
      'marks': _marks(newMarks),
    }),
  );
}

BlockedItem _item(String key, SyncMark mark) {
  final cut = key.indexOf('|');
  return BlockedItem(kind: key.substring(0, cut), key: key.substring(cut + 1), label: mark.label);
}

List<Map<String, Object?>> _marks(Map<String, SyncMark> marks) => [
  for (final e in marks.entries)
    {'kind': e.key.substring(0, e.key.indexOf('|')), 'key': e.key.substring(e.key.indexOf('|') + 1), 'label': e.value.label, 'at': e.value.at},
];

/// Makes the songs of [have] the songs [want], in that order: takes out what is not wanted, puts in what is missing at the
/// end, then moves what is out of place.
Future<void> _setSongs(SyncLibrary library, LocalPlaylist have, List<String> want, Track Function(String) track) async {
  if (_same(have.songs, want)) return;
  final wanted = want.toSet();
  var order = [...have.songs];
  for (final id in have.songs) {
    if (!wanted.contains(id)) {
      await library.removeFromPlaylist(have.id, id);
      order.remove(id);
    }
  }
  final missing = [for (final id in want) if (!order.contains(id)) id];
  if (missing.isNotEmpty) {
    await library.addToPlaylist(have.id, [for (final id in missing) track(id)]);
    order = [...order, ...missing];
  }
  for (var i = 0; i < want.length; i++) {
    if (order[i] == want[i]) continue;
    await library.movePlaylistItem(have.id, want[i], i);
    order
      ..remove(want[i])
      ..insert(i, want[i]);
  }
}

bool _same(List<String> a, List<String> b) => a.length == b.length && [for (var i = 0; i < a.length; i++) a[i] == b[i]].every((e) => e);
