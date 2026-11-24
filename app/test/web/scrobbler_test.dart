import 'dart:convert';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/data/models.dart';
import 'package:sapoche/data/web/scrobbler.dart';

// The cases of ScrobblerTest.kt, for the Dart copy

class _Storage implements ScrobbleStorage {
  @override
  String? token = 'tok';
  String? state;
  @override
  String? loadState() => state;
  @override
  void saveState(String text) => state = text;
}

void main() {
  late FakeAsync async;
  late _Storage storage;
  late List<ScrobbleReply?> replies;
  late List<(String path, String token, String? body)> asked;
  const song = Track(videoId: 'vid1', title: 'Song (Official Video)', artist: 'Artist - Topic', durMs: 200000);
  const ok = ScrobbleReply(200, body: '{"status":"ok"}');

  /// Answers from [replies] in turn (the last one for ever); one that is null is a failure to reach the service.
  Future<ScrobbleReply> http(String path, String token, String? body) async {
    asked.add((path, token, body));
    final reply = replies.length > 1 ? replies.removeAt(0) : replies.firstOrNull;
    if (reply == null) throw const SocketException('no network');
    return reply;
  }

  List<Map<String, dynamic>> submitted() => [
    for (final a in asked)
      if (a.$1 == '/1/submit-listens') jsonDecode(a.$3!) as Map<String, dynamic>,
  ];

  Scrobbler scrobbler([_Storage? s]) => Scrobbler(
    storage: s ?? storage,
    service: ListenBrainzService(http, '1.50.0'),
    namer: (t) => (t.title.replaceAll(' (Official Video)', ''), t.artist.replaceAll(' - Topic', '')),
    mono: () => async.elapsed.inMilliseconds,
    wall: () => 1700000000000 + async.elapsed.inMilliseconds,
  );

  void pass(int ms) {
    async.elapse(Duration(milliseconds: ms));
    async.flushMicrotasks();
  }

  int pending(_Storage s) => ((jsonDecode(s.state!) as Map)['listens'] as List).length;

  // The scrobbler makes its timers inside the fake zone, so each test builds its own world there
  void scrobbleTest(String name, void Function() body) => test(name, () {
    fakeAsync((a) {
      async = a;
      storage = _Storage();
      replies = [ok];
      asked = [];
      body();
    });
  });

  test('the bodies are the same on every platform', () {
    final vectors = jsonDecode(File('../native/sync/src/test/resources/scrobble_vectors.json').readAsStringSync()) as Map<String, dynamic>;
    final version = vectors['version'] as String;
    for (final c in (vectors['cases'] as List).cast<Map<String, dynamic>>()) {
      final listens = [
        for (final l in (c['listens'] as List).cast<Map<String, dynamic>>())
          Listen(listenedAt: l['listenedAt'] as int, videoId: l['videoId'] as String, title: l['title'] as String, artist: l['artist'] as String, durationMs: l['durationMs'] as int),
      ];
      expect(jsonDecode(ListenBrainzService.body(c['type'] as String, listens, version)), c['body'], reason: c['name'] as String);
    }
  });

  scrobbleTest('without a token nothing is counted and nothing goes out', () {
    final empty = _Storage()..token = null;
    final s = scrobbler(empty);
    s.watch(song, true, 200000);
    pass(600000);
    expect(asked, isEmpty);
    expect(empty.state, isNull);
    expect(s.status().connected, isFalse);
  });

  scrobbleTest('a good token is kept with the name of its owner', () {
    final empty = _Storage()..token = null;
    replies = [const ScrobbleReply(200, body: '{"code":200,"message":"Token valid.","valid":true,"user_name":"tvh"}')];
    final s = scrobbler(empty);
    ScrobbleConnect? result;
    s.connect(' tok \n').then((r) => result = r);
    pass(0);
    expect(result, ScrobbleConnect.ok);
    expect(empty.token, 'tok');
    expect(s.status().user, 'tvh');
    expect(asked[0].$2, 'tok');
  });

  scrobbleTest('a token that is not good is not kept, and no network is told apart', () {
    final empty = _Storage()..token = null;
    final s = scrobbler(empty);
    ScrobbleConnect? result;
    void connect(ScrobbleReply? reply) {
      replies = [reply];
      s.connect('bad').then((r) => result = r);
      pass(0);
    }

    connect(const ScrobbleReply(200, body: '{"code":200,"message":"Token invalid.","valid":false}'));
    expect(result, ScrobbleConnect.invalid);
    connect(const ScrobbleReply(401, body: '{"code":401}'));
    expect(result, ScrobbleConnect.invalid);
    connect(null);
    expect(result, ScrobbleConnect.offline);
    connect(const ScrobbleReply(503));
    expect(result, ScrobbleConnect.offline);
    expect(empty.token, isNull);
  });

  scrobbleTest('a song is shown playing a few seconds in and sent once it counts, at the time it began', () {
    final s = scrobbler();
    pass(1000);
    s.watch(song, true, 200000);
    pass(4000);
    expect(submitted(), isEmpty, reason: 'not yet: a song skipped at once must not show');
    pass(1100);
    expect(submitted().map((b) => b['listen_type']), ['playing_now']);
    pass(95000); // 100 s of playing: half the song
    final sent = submitted().last;
    expect(sent['listen_type'], 'single');
    final listen = (sent['payload'] as List).single as Map<String, dynamic>;
    expect(listen['listened_at'], 1700000001);
    expect(listen['track_metadata']['track_name'], 'Song');
    expect(listen['track_metadata']['artist_name'], 'Artist');
    expect(s.status().pending, 0);
    s.disconnect();
  });

  scrobbleTest('a song left before the mark is not sent, and a paused one does not count', () {
    final s = scrobbler();
    s.watch(song, true, 200000);
    pass(60000);
    s.watch(song, false, 200000);
    pass(600000);
    s.watch(null, false, 0);
    expect(submitted().every((b) => b['listen_type'] == 'playing_now'), isTrue);
    expect(s.status().pending, 0);
  });

  scrobbleTest('playing now is left out when the person does not want it', () {
    final s = scrobbler();
    s.setNowPlaying(false);
    s.watch(song, true, 200000);
    pass(20000);
    expect(submitted(), isEmpty);
    s.disconnect();
  });

  scrobbleTest('with no network the listens wait on the phone and go together when it is back', () {
    replies = [null];
    final s = scrobbler();
    s.setNowPlaying(false);
    s.watch(song, true, 200000);
    pass(100000);
    s.watch(const Track(videoId: 'vid2', title: 'Two', artist: 'B', durMs: 100000), true, 100000);
    pass(50000);
    s.watch(null, false, 0);
    expect(s.status().pending, 2);
    expect(pending(storage), 2, reason: 'kept on the phone');
    replies = [ok];
    pass(5 * 60000);
    expect(s.status().pending, 0);
    final sent = submitted().last;
    expect(sent['listen_type'], 'import');
    expect(sent['payload'], hasLength(2));
    s.disconnect();
  });

  scrobbleTest('what waited when the app was closed is sent when it opens', () {
    storage.state = '{"listens":[{"listenedAt":1700000000,"videoId":"a","title":"A","artist":"B","durationMs":1000}]}';
    final s = scrobbler();
    expect(s.status().pending, 1);
    s.resume();
    pass(1);
    expect(s.status().pending, 0);
    expect(submitted(), hasLength(1));
  });

  scrobbleTest('a busy service is waited for as long as it says', () {
    replies = [const ScrobbleReply(429, resetInSec: 30), ok];
    final s = scrobbler();
    s.setNowPlaying(false);
    s.watch(song, true, 200000);
    pass(100100);
    expect(submitted(), hasLength(1));
    pass(30000);
    expect(submitted(), hasLength(1), reason: '31 s: not before it said');
    pass(2000);
    expect(submitted(), hasLength(2));
    expect(s.status().pending, 0);
    s.disconnect();
  });

  scrobbleTest('a token that is refused stops it and asks to connect again, keeping the listens', () {
    replies = [const ScrobbleReply(401)];
    final s = scrobbler();
    s.setNowPlaying(false);
    s.watch(song, true, 200000);
    pass(100100);
    final status = s.status();
    expect(status.reconnect, isTrue);
    expect(status.pending, 1);
    pass(600000);
    expect(submitted(), hasLength(1), reason: 'no more asks with a token that is refused');
    s.watch(song, true, 200000);
    expect(submitted(), hasLength(1));
  });

  scrobbleTest('when the service refuses a batch the listens go one by one and only the bad one is dropped', () {
    storage.state = '''{"listens":[
      {"listenedAt":1700000000,"videoId":"a","title":"A","artist":"B","durationMs":1000},
      {"listenedAt":1700000001,"videoId":"b","title":"","artist":"B","durationMs":1000},
      {"listenedAt":1700000002,"videoId":"c","title":"C","artist":"B","durationMs":1000}]}''';
    replies = [const ScrobbleReply(400), ok, const ScrobbleReply(400), ok];
    final s = scrobbler();
    s.resume();
    pass(1);
    expect(s.status().pending, 0);
    expect(submitted().map((b) => b['listen_type']), ['import', 'single', 'single', 'single']);
  });

  scrobbleTest('disconnecting forgets the token and the queue and stops everything', () {
    replies = [null];
    final s = scrobbler();
    s.setNowPlaying(false);
    s.watch(song, true, 200000);
    pass(100100);
    expect(s.status().pending, 1);
    s.disconnect();
    expect(storage.token, isNull);
    expect(pending(storage), 0);
    final asks = asked.length;
    pass(600000);
    expect(asked, hasLength(asks));
  });

  scrobbleTest('listens older than two weeks and beyond a thousand are dropped', () {
    const now = 1700000000;
    final old = [for (var i = 1; i <= 3; i++) '{"listenedAt":${now - 15 * 24 * 3600 + i},"videoId":"o$i","title":"T","artist":"A","durationMs":1}'];
    final recent = [for (var i = 1; i <= 1005; i++) '{"listenedAt":${now - i},"videoId":"r$i","title":"T","artist":"A","durationMs":1}'];
    storage.state = '{"listens":[${[...old, ...recent].join(',')}]}';
    replies = [null];
    expect(scrobbler().status().pending, 1000);
  });
}
