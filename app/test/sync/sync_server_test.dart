import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:sapoche/data/sync/sync_client.dart';

import 'sync_harness.dart';

/// Two phones over HTTP against a real Worker (`wrangler dev --local`): `SYNC_SERVER=http://127.0.0.1:8787 SYNC_KEY=<the
/// ROOM_KEY it was started with> flutter test test/sync/sync_server_test.dart`. Skipped without them, as it needs a server.
void main() {
  final server = const String.fromEnvironment('SYNC_SERVER');
  final key = const String.fromEnvironment('SYNC_KEY');

  test('two phones sync through the real server', skip: server.isEmpty ? 'SYNC_SERVER is not set' : null, () async {
    SyncTransport wire() => HttpSyncTransport(server: () => server, headers: () async => {'X-Sapoche-Key': key}, client: http.Client());
    final clock = Clock();
    final a = Phone('A', FakeServer(), clock, transport: wire());
    final b = Phone('B', FakeServer(), clock, transport: wire());
    a.store
      ..setLiked(song('x'), true)
      ..setLiked(song('y'), true)
      ..createPlaylist('Road', [song('x'), song('y')])
      ..recordListen(song('x'));
    expect(await a.sync.enable(), isNull);
    expect(await b.sync.join(a.sync.key!), isNull);
    expectSame(a, b);
    b.store.setLiked(song('x'), false);
    b.store.addToPlaylist(b.store.playlists().single.id, [song('z')]);
    await b.syncNow();
    await a.syncNow();
    expectSame(a, b);
    expect(a.likes, {'y'});
    expect(a.playlists, {'Road': ['x', 'y', 'z']});
    // The server keeps an older copy at most every few hours, so a short test has none to put back
    expect(await a.sync.versions(), isA<List<SyncVersion>>());
    await a.sync.disable(deleteRemote: true);
  });
}
