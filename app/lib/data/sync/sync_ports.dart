import 'package:shared_preferences/shared_preferences.dart';

import '../backend.dart';
import '../models.dart';
import '../music_models.dart';
import 'sync_client.dart';
import 'sync_controller.dart';
import 'sync_local.dart';

/// The library of this phone, as the app's [Backend] keeps it: the same on Android, iPhone and in a browser.
class BackendLibrary implements SyncLibrary {
  const BackendLibrary(this._backend);

  final Backend _backend;

  @override
  Future<String> snapshot() => _backend.librarySnapshot();

  @override
  Future<void> merge(String json) => _backend.libraryMerge(json);

  @override
  Future<void> setLiked(Track track, bool liked) => _backend.setLiked(track, liked);

  @override
  Future<void> clearHistory() => _backend.clearHistory();

  @override
  Future<void> unblock(BlockedItem item) => _backend.unblock(item);

  @override
  Future<void> unmark(String kind, String key) => _backend.tasteMark(kind, key, '', on: false);

  @override
  Future<int> createFolder(String name) => _backend.createFolder(name);

  @override
  Future<void> renameFolder(int id, String name) => _backend.renameFolder(id, name);

  @override
  Future<void> deleteFolder(int id) => _backend.deleteFolder(id);

  @override
  Future<void> setPlaylistFolder(int id, int? folderId) => _backend.setPlaylistFolder(id, folderId);

  @override
  Future<int> createPlaylist(String name, List<Track> tracks) => _backend.createPlaylist(name, tracks);

  @override
  Future<void> renamePlaylist(int id, String name) => _backend.renamePlaylist(id, name);

  @override
  Future<void> deletePlaylist(int id) => _backend.deletePlaylist(id);

  @override
  Future<int> addToPlaylist(int id, List<Track> tracks) => _backend.addToPlaylist(id, tracks);

  @override
  Future<void> removeFromPlaylist(int id, String videoId) => _backend.removeFromPlaylist(id, videoId);

  @override
  Future<void> movePlaylistItem(int id, String videoId, int toIndex) => _backend.movePlaylistItem(id, videoId, toIndex);
}

class BackendKeyStore implements SyncKeyStore {
  const BackendKeyStore(this._backend);

  final Backend _backend;

  @override
  Future<String?> read() => _backend.syncKey();

  @override
  Future<void> write(String? code) => _backend.setSyncKey(code);
}

/// What the engine remembers between runs, in the preferences of the app.
class PrefsSyncState implements SyncStateStore {
  const PrefsSyncState();

  static const _key = 'sync.state';

  @override
  Future<String?> read() async => (await SharedPreferences.getInstance()).getString(_key);

  @override
  Future<void> write(String text) async => (await SharedPreferences.getInstance()).setString(_key, text);
}

/// The sync controller of the app: the server is the room server, with the key the room connection uses.
SyncController createSyncController({
  required Backend backend,
  required String Function() server,
  required String Function() deviceLabel,
}) => SyncController(
  library: BackendLibrary(backend),
  transport: HttpSyncTransport(
    server: server,
    headers: () async {
      final key = await backend.serverKey();
      return key.isEmpty ? const {} : {'X-Sapoche-Key': key};
    },
  ),
  keys: BackendKeyStore(backend),
  state: const PrefsSyncState(),
  deviceLabel: deviceLabel,
);
