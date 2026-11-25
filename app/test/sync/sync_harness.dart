import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/data/models.dart';
import 'package:sapoche/data/music_models.dart';
import 'package:sapoche/data/sync/sync_client.dart';
import 'package:sapoche/data/sync/sync_controller.dart';
import 'package:sapoche/data/sync/sync_local.dart';
import 'package:sapoche/data/web/library_store.dart';

Track song(String id, [String? title]) => Track(videoId: id, title: title ?? 'Song $id', artist: 'Artist', durMs: 180000);

/// The library of a phone for the engine: the browser's store, which does the same as the databases of the phones.
class StoreLibrary implements SyncLibrary {
  StoreLibrary(this.store);

  final LibraryStore store;

  /// Makes [libraryChanged] of a controller hear every change, as the app does.
  @override
  Future<String> snapshot() async => store.snapshot();

  @override
  Future<void> merge(String json) async => store.merge(json);

  @override
  Future<void> setLiked(Track track, bool liked) async => store.setLiked(track, liked);

  @override
  Future<void> clearHistory() async => store.clearHistory();

  @override
  Future<void> unblock(BlockedItem item) async => store.unblock(item.kind, item.key);

  @override
  Future<void> unmark(String kind, String key) async => store.setTasteMark(kind, key, '', on: false);

  @override
  Future<int> createFolder(String name) async => store.createFolder(name);

  @override
  Future<void> renameFolder(int id, String name) async => store.renameFolder(id, name);

  @override
  Future<void> deleteFolder(int id) async => store.deleteFolder(id);

  @override
  Future<void> setPlaylistFolder(int id, int? folderId) async => store.setPlaylistFolder(id, folderId);

  /// The app is killed right after the next playlist is made.
  var killAfterCreate = false;

  @override
  Future<int> createPlaylist(String name, List<Track> tracks) async {
    final id = store.createPlaylist(name, tracks);
    if (killAfterCreate) {
      killAfterCreate = false;
      throw StateError('killed');
    }
    return id;
  }

  @override
  Future<void> renamePlaylist(int id, String name) async => store.renamePlaylist(id, name);

  @override
  Future<void> deletePlaylist(int id) async => store.deletePlaylist(id);

  @override
  Future<int> addToPlaylist(int id, List<Track> tracks) async => store.addToPlaylist(id, tracks);

  @override
  Future<void> removeFromPlaylist(int id, String videoId) async => store.removeFromPlaylist(id, videoId);

  @override
  Future<void> movePlaylistItem(int id, String videoId, int toIndex) async => store.movePlaylistItem(id, videoId, toIndex);
}

/// The server: sealed libraries by name, with the tags and the older copies the real one keeps.
class FakeServer implements SyncTransport {
  final blobs = <String, Uint8List>{};
  final tokens = <String, String>{};
  final old = <String, List<(int, Uint8List)>>{};
  var _tag = 0;
  var clock = 1000;
  var puts = 0;
  var gets = 0;

  /// Runs once between a read and the write that follows it: another phone getting in.
  Future<void> Function()? beforePut;
  SyncFailure? down;

  String _etag(String id) => '"${blobs[id].hashCode}-$_tag"';

  @override
  Future<SyncBlob?> get(String docId) async {
    if (down != null) throw SyncException(down!);
    gets++;
    final bytes = blobs[docId];
    return bytes == null ? null : SyncBlob(bytes, _etag(docId));
  }

  @override
  Future<String> put(String docId, String token, Uint8List bytes, {String? ifMatch}) async {
    if (down != null) throw SyncException(down!);
    final hook = beforePut;
    beforePut = null;
    if (hook != null) await hook();
    final current = blobs[docId];
    if (current != null && tokens[docId] != token) throw const SyncException(SyncFailure.forbidden);
    if (ifMatch == null ? current != null : current == null || ifMatch != _etag(docId)) throw const SyncException(SyncFailure.changed);
    if (current != null) (old[docId] ??= []).insert(0, (clock++, current));
    if ((old[docId]?.length ?? 0) > 10) old[docId]!.removeLast();
    blobs[docId] = bytes;
    tokens[docId] = token;
    _tag++;
    puts++;
    return _etag(docId);
  }

  @override
  Future<List<SyncVersion>> versions(String docId) async => [
    for (final (at, bytes) in old[docId] ?? const <(int, Uint8List)>[]) SyncVersion(at: at, size: bytes.length),
  ];

  @override
  Future<Uint8List?> version(String docId, int at) async => (old[docId] ?? const []).where((e) => e.$1 == at).map((e) => e.$2).firstOrNull;

  @override
  Future<void> delete(String docId, String token) async {
    if (tokens[docId] != token) throw const SyncException(SyncFailure.forbidden);
    blobs.remove(docId);
    old.remove(docId);
  }
}

class MemoryKeys implements SyncKeyStore {
  String? code;

  @override
  Future<String?> read() async => code;

  @override
  Future<void> write(String? code) async => this.code = code;
}

class MemoryState implements SyncStateStore {
  String? text;

  @override
  Future<String?> read() async => text;

  @override
  Future<void> write(String text) async => this.text = text;
}

/// One phone: a library, the engine over it, and what the engine keeps.
class Phone {
  Phone(this.name, this.server, this.clock, {SyncTransport? transport})
    : store = LibraryStore(nowMs: () => clock.now += 1) {
    library = StoreLibrary(store);
    keys = MemoryKeys();
    state = MemoryState();
    sync = SyncController(
      library: library,
      transport: transport ?? server,
      keys: keys,
      state: state,
      deviceLabel: () => name,
      nowMs: () => clock.now += 1,
      settle: const Duration(milliseconds: 1),
    );
  }

  final String name;
  final FakeServer server;
  final Clock clock;
  final LibraryStore store;
  late final StoreLibrary library;
  late final MemoryKeys keys;
  late final MemoryState state;
  late final SyncController sync;

  Set<String> get likes => store.likedIds();

  Map<String, List<String>> get playlists => {
    for (final p in store.playlists()) p.name: [for (final t in store.playlistTracks(p.id)) t.videoId],
  };

  Future<void> syncNow({bool force = false}) => sync.syncNow(force: force);

  /// The same phone started again: what it remembered is read back.
  Future<SyncController> restart() async {
    final again = SyncController(
      library: library,
      transport: server,
      keys: keys,
      state: state,
      deviceLabel: () => name,
      nowMs: () => clock.now += 1,
      settle: const Duration(milliseconds: 1),
    );
    await again.load();
    return again;
  }
}

class Clock {
  var now = 1700000000000;
}

String pretty(Object? value) => const JsonEncoder.withIndent(' ').convert(value);

void expectSame(Phone a, Phone b) {
  expect(a.likes, b.likes, reason: 'likes');
  expect(a.playlists, b.playlists, reason: 'playlists');
}
