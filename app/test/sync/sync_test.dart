import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/data/sync/sync_client.dart';
import 'package:sapoche/data/sync/sync_controller.dart';
import 'package:sapoche/data/sync/sync_crypto.dart';
import 'package:sapoche/data/sync/sync_doc.dart';
import 'package:sapoche/data/sync/sync_merge.dart';

import 'sync_harness.dart';

SyncDoc doc({Map<String, int> likes = const {}, Map<String, SyncPlaylist> playlists = const {}, Set<Listen> history = const {}, int cleared = 0}) =>
    SyncDoc(likes: {...likes}, playlists: {...playlists}, history: {...history}, historyClearedAt: cleared);

SyncPlaylist list(String name, List<String> songs, {int at = 1, String? folder}) =>
    SyncPlaylist(name: name, createdAt: 1, updatedAt: at, songs: songs, folder: folder);

void main() {
  group('key and seal', () {
    // Made with node:crypto (hkdfSync) from the key of 32 bytes 0x00..0x1f, so that the package under it cannot change what it derives
    const code = 'AAAQEAYEAUDAOCAJBIFQYDIOB4IBCEQTCQKRMFYYDENBWHA5DYPQ';
    const docId = 'ad524039f860f4605f03f70c664c494da5d3af60974bfef9d96793f5c29b955b';
    const token = '0d3a49d20311730d1b6f679f40dc948e3c262c47cdda8c5b26ef0d06a5ae34f0';

    test('a key written as a code reads back, whatever the case, spaces and dashes', () {
      final key = SyncKey.generate();
      expect(key.code.length, 52);
      expect(SyncKey.parse(key.code)?.code, key.code);
      expect(SyncKey.parse(key.display.toLowerCase())?.code, key.code);
      expect(SyncKey.parse(key.display.replaceAll('-', ' '))?.code, key.code);
      expect(SyncKey.fromText('Look: ${key.link} ok')?.code, key.code);
      expect(SyncKey.parse('too short'), isNull);
      expect(SyncKey.parse('1' * 52), isNull);
    });

    test('the name, proof and seal differ and are the same for the same key', () async {
      final key = SyncKey.generate();
      final a = await key.derive();
      final b = await key.derive();
      expect(a.docId, b.docId);
      expect(a.docId.length, 64);
      expect(a.token.length, 64);
      expect(a.docId, isNot(a.token));
      expect((await SyncKey.generate().derive()).docId, isNot(a.docId));
    });

    test('the key of bytes 0 to 31 gives the name and proof that node:crypto gives', () async {
      final secrets = await SyncKey.parse(code)!.derive();
      expect(secrets.docId, docId);
      expect(secrets.token, token);
      expect(SyncKey.parse(code)!.code, code);
    });

    test('a library opens with its key, not with another, and not when touched', () async {
      final secrets = await SyncKey.generate().derive();
      final library = doc(likes: {'a': 5}, playlists: {'p': list('Mix', ['a', 'b'])});
      final sealed = await SyncSeal.seal(library, secrets);
      expect(sealed[0], 1);
      final back = await SyncSeal.open(sealed, secrets);
      expect(back.likes, {'a': 5});
      expect(back.playlists['p']?.songs, ['a', 'b']);
      expect(String.fromCharCodes(sealed), isNot(contains('Mix')));
      await expectLater(SyncSeal.open(sealed, await SyncKey.generate().derive()), throwsFormatException);
      final touched = [...sealed]..[40] ^= 1;
      await expectLater(SyncSeal.open(touched, secrets), throwsFormatException);
      await expectLater(SyncSeal.open([1, 2, 3], secrets), throwsFormatException);
    });
  });

  group('merge', () {
    test('without a base nothing is removed: the two are joined', () {
      final m = mergeDocs(local: doc(likes: {'a': 1}), remote: doc(likes: {'b': 2}), now: 9);
      expect(m.likes, {'a': 1, 'b': 2});
    });

    test('a like taken away here goes, one taken away there goes, one put in stays', () {
      final base = doc(likes: {'a': 1, 'b': 2, 'c': 3});
      final m = mergeDocs(base: base, local: doc(likes: {'b': 2, 'c': 3, 'd': 4}), remote: doc(likes: {'a': 1, 'b': 2, 'e': 5}), now: 9);
      // a: away here. c: away there. d: new here. e: new there
      expect(m.likes.keys.toSet(), {'b', 'd', 'e'});
    });

    test('a playlist renamed on one side and given a song on the other keeps both', () {
      final base = doc(playlists: {'p': list('Old', ['a'])});
      final m = mergeDocs(
        base: base,
        local: doc(playlists: {'p': list('New', ['a'], at: 5)}),
        remote: doc(playlists: {'p': list('Old', ['a', 'b'], at: 4)}),
        now: 9,
      );
      expect(m.playlists['p']?.name, 'New');
      expect(m.playlists['p']?.songs, ['a', 'b']);
    });

    test('songs put in on both sides join, what this side took out goes, the order is the server\'s', () {
      final base = doc(playlists: {'p': list('P', ['a', 'b', 'c'])});
      final m = mergeDocs(
        base: base,
        local: doc(playlists: {'p': list('P', ['a', 'c', 'x'], at: 5)}),
        remote: doc(playlists: {'p': list('P', ['c', 'b', 'a', 'y'], at: 4)}),
        now: 9,
      );
      expect(m.playlists['p']?.songs, ['c', 'a', 'y', 'x']);
    });

    test('moving songs about on one side is taken when the other did not touch the list', () {
      final base = doc(playlists: {'p': list('P', ['a', 'b', 'c'])});
      final m = mergeDocs(
        base: base,
        local: doc(playlists: {'p': list('P', ['c', 'a', 'b'], at: 5)}),
        remote: doc(playlists: {'p': list('P', ['a', 'b', 'c'])}),
        now: 9,
      );
      expect(m.playlists['p']?.songs, ['c', 'a', 'b']);
    });

    test('a playlist deleted on one side goes, unless the other changed it', () {
      final base = doc(playlists: {'p': list('P', ['a']), 'q': list('Q', ['a'])});
      final m = mergeDocs(
        base: base,
        local: doc(), // both deleted here
        remote: doc(playlists: {'p': list('P', ['a']), 'q': list('Q', ['a', 'b'], at: 4)}),
        now: 9,
      );
      expect(m.playlists.keys, ['q']);
      expect(m.playlists['q']?.songs, ['a', 'b']);
    });

    test('a playlist deleted there and changed here is kept', () {
      final base = doc(playlists: {'p': list('P', ['a'])});
      final m = mergeDocs(base: base, local: doc(playlists: {'p': list('P', ['a', 'z'], at: 5)}), remote: doc(), now: 9);
      expect(m.playlists['p']?.songs, ['a', 'z']);
    });

    test('a folder that is gone leaves its playlists without one', () {
      final base = SyncDoc(folders: {'f': const SyncFolder(name: 'F', createdAt: 1, updatedAt: 1)}, playlists: {'p': list('P', [], folder: 'f')});
      final m = mergeDocs(base: base, local: SyncDoc(playlists: {'p': list('P', [], folder: 'f')}), remote: base, now: 9);
      expect(m.folders, isEmpty);
      expect(m.playlists['p']?.folder, isNull);
    });

    test('listens join by song and time and the clear of someone else cuts the older ones', () {
      final base = doc(history: {('a', 1), ('b', 2)});
      final joined = mergeDocs(base: base, local: doc(history: {('a', 1), ('b', 2), ('c', 3)}), remote: doc(history: {('a', 1), ('b', 2), ('d', 4)}), now: 9);
      expect(joined.history, {('a', 1), ('b', 2), ('c', 3), ('d', 4)});
      final cut = mergeDocs(base: base, local: doc(history: {('a', 1), ('b', 2), ('e', 6)}), remote: doc(history: {('a', 1), ('b', 2), ('f', 7)}, cleared: 5), now: 9);
      expect(cut.history, {('e', 6), ('f', 7)});
      expect(cut.historyClearedAt, 5);
    });

    test('only the latest 2000 listens are kept', () {
      final many = {for (var i = 0; i < 2100; i++) ('s$i', i)};
      expect(mergeDocs(local: doc(history: many), remote: doc(), now: 9).history.length, 2000);
    });

    test('a loss is too much when over twenty and over a third', () {
      final had = doc(likes: {for (var i = 0; i < 100; i++) 'l$i': i});
      expect(SyncLoss.between(had, doc(likes: {for (var i = 0; i < 70; i++) 'l$i': i})).tooMuch(had), isFalse);
      expect(SyncLoss.between(had, doc(likes: {for (var i = 0; i < 60; i++) 'l$i': i})).tooMuch(had), isTrue);
      final few = doc(likes: {for (var i = 0; i < 10; i++) 'l$i': i});
      expect(SyncLoss.between(few, doc()).tooMuch(few), isFalse);
    });
  });

  group('phones', () {
    late FakeServer server;
    late Clock clock;
    late Phone a;
    late Phone b;

    setUp(() {
      server = FakeServer();
      clock = Clock();
      a = Phone('A', server, clock);
      b = Phone('B', server, clock);
    });

    Future<void> connect() async {
      expect(await a.sync.enable(), isNull);
      expect(await b.sync.join(a.sync.key!), isNull);
    }

    test('a second phone gets what the first keeps, in the order it was liked', () async {
      a.store
        ..setLiked(song('x'), true)
        ..setLiked(song('y'), true)
        ..createPlaylist('Road', [song('x'), song('z')]);
      await connect();
      expectSame(a, b);
      expect(b.playlists, {'Road': ['x', 'z']});
      expect(b.store.liked().map((t) => t.videoId), a.store.liked().map((t) => t.videoId));
      expect(a.sync.deviceCount, greaterThanOrEqualTo(1));
    });

    test('the server holds nothing a person can read', () async {
      a.store.setLiked(song('x', 'A Very Distinct Title'), true);
      await connect();
      for (final bytes in server.blobs.values) {
        expect(utf8.decode(bytes, allowMalformed: true), isNot(contains('Distinct')));
      }
    });

    test('a like taken away on one phone is taken away on the other and does not come back', () async {
      a.store
        ..setLiked(song('x'), true)
        ..setLiked(song('y'), true);
      await connect();
      b.store.setLiked(song('x'), false);
      for (var i = 0; i < 10; i++) {
        await b.syncNow();
        await a.syncNow();
      }
      expect(a.likes, {'y'});
      expect(b.likes, {'y'});
    });

    test('changes made apart, offline, are both kept', () async {
      a.store
        ..setLiked(song('x'), true)
        ..setLiked(song('y'), true)
        ..createPlaylist('Mix', [song('x')]);
      await connect();
      final id = a.store.playlists().single.id;
      a.store.renamePlaylist(id, 'Gym');
      a.store.setLiked(song('x'), false);
      b.store
        ..addToPlaylist(b.store.playlists().single.id, [song('y')])
        ..setLiked(song('w'), true);
      await a.syncNow();
      await b.syncNow();
      await a.syncNow();
      expectSame(a, b);
      expect(a.playlists, {'Gym': ['x', 'y']});
      expect(a.likes, {'y', 'w'});
      expect(a.store.playlists().length, 1, reason: 'no playlist twice');
    });

    test('a phone that was off for long takes what it missed and does not bring back what was deleted', () async {
      a.store
        ..setLiked(song('x'), true)
        ..createPlaylist('Old', [song('x')])
        ..createPlaylist('Keep', [song('x')]);
      await connect();
      final c = Phone('C', server, clock);
      expect(await c.sync.join(a.sync.key!), isNull);
      // C is away; A deletes a playlist and a like, B adds
      a.store
        ..deletePlaylist(a.store.playlists().firstWhere((p) => p.name == 'Old').id)
        ..setLiked(song('x'), false);
      await a.syncNow();
      b.store.setLiked(song('n'), true);
      await b.syncNow();
      await c.syncNow();
      await a.syncNow();
      for (final p in [a, b, c]) {
        expect(p.playlists.keys, ['Keep']);
        expect(p.likes, {'n'});
      }
    });

    test('a playlist deleted on one phone while another put a song in it stays', () async {
      a.store.createPlaylist('P', [song('x')]);
      await connect();
      a.store.deletePlaylist(a.store.playlists().single.id);
      b.store.addToPlaylist(b.store.playlists().single.id, [song('y')]);
      await a.syncNow();
      await b.syncNow();
      await a.syncNow();
      expect(a.playlists, {'P': ['x', 'y']});
      expect(b.playlists, {'P': ['x', 'y']});
    });

    test('folders and the playlists in them are carried', () async {
      final folder = a.store.createFolder('Trips');
      final p = a.store.createPlaylist('Beach', [song('x')]);
      a.store.setPlaylistFolder(p, folder);
      await connect();
      expect(b.store.folders().map((f) => f.name), ['Trips']);
      expect(b.store.playlists().single.folderId, b.store.folders().single.id);
      a.store.deleteFolder(folder);
      await a.syncNow();
      await b.syncNow();
      expect(b.store.folders(), isEmpty);
      expect(b.store.playlists().single.folderId, isNull);
    });

    test('clearing the history on one phone clears it on the other, and listens after it stay', () async {
      a.store
        ..recordListen(song('x'))
        ..recordListen(song('y'));
      await connect();
      expect(b.store.listens().length, 2);
      a.store.clearHistory();
      a.sync.historyCleared();
      a.store.recordListen(song('z'));
      await a.syncNow();
      await b.syncNow();
      expect(b.store.listens().map((l) => l.track.videoId), ['z']);
      await a.syncNow();
      expect(a.store.listens().map((l) => l.track.videoId), ['z']);
    });

    test('blocks and marks are carried, and taken away', () async {
      a.store
        ..block('song', 'x', 'X')
        ..setTasteMark('quiet_artist', 'abc', 'Abc', on: true);
      await connect();
      expect(b.store.blocked().map((e) => e.key), ['x']);
      expect(b.store.tasteMarks().map((e) => e.key), ['abc']);
      b.store.unblock('song', 'x');
      await b.syncNow();
      await a.syncNow();
      expect(a.store.blocked(), isEmpty);
    });

    test('the first sync of a phone that has things joins them and removes nothing', () async {
      a.store.setLiked(song('x'), true);
      b.store.setLiked(song('y'), true);
      await a.sync.enable();
      await b.sync.join(a.sync.key!);
      await a.syncNow();
      expect(a.likes, {'x', 'y'});
      expect(b.likes, {'x', 'y'});
      expect(b.sync.firstCopy, isNotNull);
    });

    test('undoing the first sync takes the phone back and stops syncing', () async {
      a.store.setLiked(song('x'), true);
      b.store
        ..setLiked(song('y'), true)
        ..createPlaylist('Mine', [song('y')]);
      await a.sync.enable();
      await b.sync.join(a.sync.key!);
      expect(b.likes, {'x', 'y'});
      await b.sync.undoFirst();
      expect(b.likes, {'y'});
      expect(b.playlists, {'Mine': ['y']});
      expect(b.sync.enabled, isFalse);
      expect(b.keys.code, isNull);
    });

    test('a joiner with a code that has no library is told so and changes nothing', () async {
      b.store.setLiked(song('y'), true);
      expect(await b.sync.join(SyncKey.generate()), SyncFailure.missing);
      expect(b.sync.enabled, isFalse);
      expect(server.blobs, isEmpty);
    });

    test('a change by another phone between the read and the write is met by reading again', () async {
      a.store.setLiked(song('x'), true);
      await connect();
      a.store.setLiked(song('y'), true);
      server.beforePut = () async {
        b.store.setLiked(song('w'), true);
        await b.syncNow();
      };
      await a.syncNow();
      expect(a.sync.phase, SyncPhase.idle);
      await b.syncNow();
      expect(a.likes, {'x', 'y', 'w'});
      expect(b.likes, {'x', 'y', 'w'});
    });

    test('a run that stops after the write and before the library is changed is made good by the next', () async {
      a.store.setLiked(song('x'), true);
      await connect();
      b.store
        ..setLiked(song('w'), true)
        ..createPlaylist('Fresh', [song('w')]);
      await b.syncNow();
      // A applies, but the app is killed half way: the phone has its own state and nothing of what was written
      final snapshotBefore = a.store.snapshot();
      final dying = Phone('A2', server, clock);
      dying.store.merge(snapshotBefore);
      dying.keys.code = a.keys.code;
      dying.state.text = a.state.text;
      await a.syncNow();
      expect(a.likes, {'x', 'w'});
      await dying.sync.load();
      await dying.syncNow();
      expect(dying.likes, {'x', 'w'});
      expect(dying.playlists, {'Fresh': ['w']});
    });

    test('a run that is killed right after a playlist was made does not make it twice', () async {
      b.store.createPlaylist('Fresh', [song('w')]);
      await b.sync.enable();
      a.library.killAfterCreate = true;
      await a.sync.join(b.sync.key!);
      expect(a.sync.phase, SyncPhase.failed);
      expect(a.playlists, {'Fresh': ['w']});
      final again = await a.restart();
      await again.syncNow();
      await b.syncNow();
      expect(a.store.playlists().length, 1);
      expect(b.store.playlists().length, 1);
    });

    test('a playlist of the same name on both phones is one playlist on the first sync', () async {
      a.store.createPlaylist('Gym', [song('x')]);
      b.store.createPlaylist('Gym', [song('y')]);
      await connect();
      await a.syncNow();
      expect(a.playlists, {'Gym': ['x', 'y']});
      expect(b.playlists, {'Gym': ['x', 'y']});
    });

    test('a change that would take away most of the library waits for the person', () async {
      for (var i = 0; i < 60; i++) {
        a.store.setLiked(song('s$i'), true);
      }
      await connect();
      for (var i = 0; i < 50; i++) {
        a.store.setLiked(song('s$i'), false);
      }
      await a.syncNow();
      expect(a.sync.phase, SyncPhase.refused);
      expect(a.sync.refused?.fromHere, isTrue);
      await b.syncNow();
      expect(b.likes.length, 60, reason: 'nothing went up');
      await a.syncNow(force: true);
      expect(a.sync.phase, SyncPhase.idle);
      await b.syncNow(force: true);
      expect(b.likes.length, 10);
    });

    test('what another phone would take away is also asked about', () async {
      for (var i = 0; i < 60; i++) {
        a.store.setLiked(song('s$i'), true);
      }
      await connect();
      for (var i = 0; i < 50; i++) {
        a.store.setLiked(song('s$i'), false);
      }
      await a.syncNow(force: true);
      await b.syncNow();
      expect(b.sync.phase, SyncPhase.refused);
      expect(b.sync.refused?.fromHere, isFalse);
      expect(b.likes.length, 60);
      await b.syncNow(force: true);
      expect(b.likes.length, 10);
    });

    test('an older version of the library can be put back everywhere', () async {
      a.store
        ..setLiked(song('x'), true)
        ..setLiked(song('y'), true);
      await connect();
      a.store.setLiked(song('x'), false);
      await a.syncNow();
      final versions = await a.sync.versions();
      expect(versions, isNotEmpty);
      // The newest old one is the library before the like was taken away
      expect(await a.sync.restoreVersion(versions.first), isNull);
      expect(a.likes, {'x', 'y'});
      await b.syncNow();
      expect(b.likes, {'x', 'y'});
    });

    test('with no network the phone stays as it is and says why', () async {
      a.store.setLiked(song('x'), true);
      await connect();
      server.down = SyncFailure.offline;
      a.store.setLiked(song('y'), true);
      await a.syncNow();
      expect(a.sync.phase, SyncPhase.failed);
      expect(a.sync.failure, SyncFailure.offline);
      expect(a.likes, {'x', 'y'});
      server.down = null;
      await a.syncNow();
      await b.syncNow();
      expect(b.likes, {'x', 'y'});
    });

    test('a library that was deleted from the server is put up again from the phone', () async {
      a.store.setLiked(song('x'), true);
      await connect();
      server.blobs.clear();
      await a.syncNow();
      expect(a.likes, {'x'});
      expect(server.blobs, isNotEmpty);
    });

    test('nothing is put up when nothing changed', () async {
      a.store.setLiked(song('x'), true);
      await connect();
      final puts = server.puts;
      await a.syncNow();
      await a.syncNow();
      expect(server.puts, puts);
    });

    test('a restart keeps the base, so that a deletion made before it still goes', () async {
      a.store
        ..setLiked(song('x'), true)
        ..setLiked(song('y'), true);
      await connect();
      a.store.setLiked(song('x'), false);
      final again = await a.restart();
      await again.syncNow();
      await b.syncNow();
      expect(b.likes, {'y'});
    });

    test('turning sync off can take the copy from the server too', () async {
      a.store.setLiked(song('x'), true);
      await connect();
      await a.sync.disable(deleteRemote: true);
      expect(server.blobs, isEmpty);
      expect(a.likes, {'x'});
      expect(a.keys.code, isNull);
    });
  });
}
