import 'dart:convert';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/data/web/scrobbler.dart';

// The cases of LastFmServiceTest.kt, for the Dart copy

class _Storage implements ScrobbleStorage {
  @override
  String? token = 'sk';
  String? state;
  @override
  String? loadState() => state;
  @override
  void saveState(String text) => state = text;
}

void main() {
  late List<ScrobbleReply?> replies;
  late List<String> asked;
  late List<String> logged;
  late LastFmService service;
  const one = [
    Listen(
      listenedAt: 1700000000,
      videoId: 'a',
      title: 'A',
      artist: 'B',
      durationMs: 200000,
    ),
  ];

  /// Answers from [replies] in turn (the last one for ever); a null is a failure to reach the server.
  Future<ScrobbleReply> http(String form) async {
    asked.add(form);
    final reply = replies.length > 1 ? replies.removeAt(0) : replies.firstOrNull;
    if (reply == null) throw const SocketException('no network');
    return reply;
  }

  setUp(() {
    replies = [];
    asked = [];
    logged = [];
    service = LastFmService(http, log: logged.add);
  });

  ScrobbleReply reply(int status, String body) => ScrobbleReply(status, body: body);

  test('the forms are the same on every platform', () {
    final vectors =
        jsonDecode(File('../native/sync/src/test/resources/lastfm_vectors.json').readAsStringSync()) as Map<String, dynamic>;
    for (final c in (vectors['cases'] as List).cast<Map<String, dynamic>>()) {
      final listens = [
        for (final l in (c['listens'] as List).cast<Map<String, dynamic>>())
          Listen(
            listenedAt: l['listenedAt'] as int,
            videoId: l['videoId'] as String,
            title: l['title'] as String,
            artist: l['artist'] as String,
            durationMs: l['durationMs'] as int,
          ),
      ];
      final session = c['session'] as String;
      final params = c['kind'] == 'scrobble'
          ? LastFmService.scrobbleParams(session, listens)
          : LastFmService.nowPlayingParams(session, listens[0]);
      expect(LastFmService.form(params), c['form'], reason: c['name'] as String);
    }
  });

  test('a token comes with the page that allows it', () async {
    replies = [reply(200, '{"token":"t1","url":"https://www.last.fm/api/auth/?api_key=k&token=t1"}')];
    final begin = await service.begin();
    expect(begin.token, 't1');
    expect(begin.url, 'https://www.last.fm/api/auth/?api_key=k&token=t1');
    expect(asked, ['method=auth.getToken']);
  });

  test('a server without Last.fm and one that cannot be reached are told apart', () async {
    replies = [reply(503, 'Last.fm is not set up on this server')];
    expect((await service.begin()).unavailable, isTrue);
    replies = [null];
    final offline = await service.begin();
    expect(offline.token, isNull);
    expect(offline.unavailable, isFalse);
  });

  test('the session comes once the person has allowed it', () async {
    replies = [reply(200, '{"session":{"name":"tvh","key":"sk-1","subscriber":0}}')];
    final login = await service.check(' t1 ');
    expect(login.result, ScrobbleConnect.ok);
    expect(login.user, 'tvh');
    expect(login.credential, 'sk-1');
    expect(asked, ['method=auth.getSession&token=t1']);
  });

  test('a token not yet allowed is pending, and one gone or unreachable is not', () async {
    Future<ScrobbleConnect> check(ScrobbleReply? r) async {
      replies = [r];
      return (await service.check('t')).result;
    }

    expect(await check(reply(403, '{"error":14,"message":"Unauthorized Token - This token has not been authorized"}')), ScrobbleConnect.pending);
    expect(await check(reply(403, '{"error":15,"message":"This token has expired"}')), ScrobbleConnect.invalid);
    expect(await check(reply(403, '{"error":4}')), ScrobbleConnect.invalid);
    expect(await check(reply(500, '{"error":16}')), ScrobbleConnect.offline);
    expect(await check(reply(502, 'Last.fm cannot be reached')), ScrobbleConnect.offline);
    expect(await check(reply(401, 'Unauthorized')), ScrobbleConnect.offline);
    expect(await check(null), ScrobbleConnect.offline);
  });

  test('the answers of a scrobble', () async {
    Future<ScrobbleSend> send(ScrobbleReply? r) async {
      replies = [r];
      return service.submit('sk', one);
    }

    expect((await send(reply(200, '{"scrobbles":{"@attr":{"accepted":1,"ignored":0}}}'))).kind, ScrobbleSent.sent);
    expect((await send(reply(403, '{"error":9,"message":"Invalid session key"}'))).kind, ScrobbleSent.reauth);
    expect((await send(reply(403, '{"error":26,"message":"Suspended API key"}'))).kind, ScrobbleSent.suspended);
    final busy = await send(reply(429, '{"error":29,"message":"Rate limit exceeded"}'));
    expect(busy.kind, ScrobbleSent.wait);
    expect(busy.waitSec, 60);
    expect((await send(reply(500, '{"error":16}'))).kind, ScrobbleSent.retry);
    expect((await send(reply(503, ''))).kind, ScrobbleSent.retry);
    expect((await send(reply(400, '{"error":6,"message":"Invalid parameters"}'))).kind, ScrobbleSent.refused);
    expect((await send(reply(403, '{"error":13}'))).kind, ScrobbleSent.refused);
    expect((await send(null)).kind, ScrobbleSent.retry);
    // The server of the room, not Last.fm
    expect((await send(reply(401, 'Unauthorized'))).kind, ScrobbleSent.suspended);
    expect((await send(reply(429, 'Too many requests'))).kind, ScrobbleSent.wait);
  });

  test('a listen that Last.fm ignored is counted as sent and logged', () async {
    replies = [reply(200, '{"scrobbles":{"@attr":{"accepted":0,"ignored":1},"scrobble":{"ignoredMessage":{"code":"3","#text":"Timestamp too old"}}}}')];
    expect((await service.submit('sk', one)).kind, ScrobbleSent.sent);
    expect(logged.any((l) => l.contains('ignored 1 of 1')), isTrue, reason: '$logged');
  });

  // The scrobbler makes its timers inside the fake zone, so each of these builds its own world there
  void withScrobbler(void Function(FakeAsync async, _Storage storage, Scrobbler scrobbler) body, String state) {
    fakeAsync((async) {
      final storage = _Storage()..state = state;
      final scrobbler = Scrobbler(
        storage: storage,
        service: service,
        namer: (t) => (t.title, t.artist),
        mono: () => async.elapsed.inMilliseconds,
        wall: () => 1700000000000 + async.elapsed.inMilliseconds,
      );
      body(async, storage, scrobbler);
    });
  }

  void pass(FakeAsync async, int ms) {
    async.elapse(Duration(milliseconds: ms));
    async.flushMicrotasks();
  }

  const oneListen = '{"user":"tvh","listens":[{"listenedAt":1700000000,"videoId":"a","title":"A","artist":"B","durationMs":1000}]}';

  test('the queue of Last.fm goes in batches of fifty', () {
    final items = [for (var i = 0; i < 120; i++) '{"listenedAt":${1700000000 + i},"videoId":"v$i","title":"T$i","artist":"A","durationMs":200000}'];
    withScrobbler((async, storage, scrobbler) {
      replies = [reply(200, '{"scrobbles":{"@attr":{"accepted":50,"ignored":0}}}')];
      scrobbler.resume();
      pass(async, 1);
      expect(scrobbler.status().pending, 0);
      expect(asked.length, 3, reason: '50, 50 and 20');
      expect(RegExp(r'artist%5B\d+%5D=').allMatches(asked[0]).length, 50);
      expect(RegExp(r'artist%5B\d+%5D=').allMatches(asked[2]).length, 20);
    }, '{"listens":[${items.join(',')}]}');
  });

  test('a session key that Last.fm refused stops it and keeps the listens', () {
    withScrobbler((async, storage, scrobbler) {
      replies = [reply(403, '{"error":9,"message":"Invalid session key"}')];
      scrobbler.resume();
      pass(async, 1);
      expect(scrobbler.status().reconnect, isTrue);
      expect(scrobbler.status().pending, 1);
      expect(asked.length, 1);
    }, oneListen);
  });

  test('a key that Last.fm suspended is tried again at the next opening, not before', () {
    withScrobbler((async, storage, scrobbler) {
      replies = [reply(403, '{"error":26,"message":"Suspended API key"}')];
      scrobbler.resume();
      pass(async, 600000);
      expect(asked.length, 1, reason: 'not in a loop');
      expect(scrobbler.status().pending, 1);
      expect(scrobbler.status().reconnect, isFalse);
      replies = [reply(200, '{"scrobbles":{"@attr":{"accepted":1,"ignored":0}}}')];
      scrobbler.resume();
      pass(async, 1);
      expect(scrobbler.status().pending, 0);
    }, oneListen);
  });
}
