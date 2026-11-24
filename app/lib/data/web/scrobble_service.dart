import 'dart:convert';

import 'package:http/http.dart' as http;

import 'scrobbler.dart';

/// How a connect went. [pending] is Last.fm only: the person has not yet allowed the app on its page.
enum ScrobbleConnect { ok, invalid, pending, offline }

/// The answer of a connect: with [ScrobbleConnect.ok], whose account it is ([user]) and what to keep to send with ([credential]).
class ScrobbleLogin {
  const ScrobbleLogin(this.result, {this.user, this.credential});

  final ScrobbleConnect result;
  final String? user;
  final String? credential;
}

/// How a send went; [ScrobbleSend.waitSec] is only read with [wait].
enum ScrobbleSent {
  sent,

  /// Not reached, or the service is in trouble: try again later, with growing waits.
  retry,

  /// Too often: wait [ScrobbleSend.waitSec] seconds.
  wait,

  /// The credential is not good any more: the person has to connect again.
  reauth,

  /// Something in it was refused: one listen at a time finds what.
  refused,

  /// Nothing more can be sent for now, and connecting again would not help (a key that was turned down, a wrong room key).
  suspended,
}

class ScrobbleSend {
  const ScrobbleSend(this.kind, {this.waitSec = 0});

  final ScrobbleSent kind;
  final int waitSec;
}

/// What differs between the places listens can be sent to; [Scrobbler] keeps what is the same (the counting, the queue, the
/// waits). A service does not throw: not being reached is an answer ([ScrobbleConnect.offline], [ScrobbleSent.retry]).
/// Kotlin and Swift counterparts: `ScrobbleService.kt`, `ScrobbleService.swift`.
abstract class ScrobbleService {
  /// The most listens one send takes.
  int get batch;

  /// Whether [secret], what the person gave (a token), makes a connection.
  Future<ScrobbleLogin> check(String secret);

  Future<ScrobbleSend> submit(String credential, List<Listen> listens);

  /// Tells what plays now. Throws when the service cannot be reached; the caller only logs it.
  Future<void> playingNow(String credential, Listen listen);
}

/// [ListenBrainz](https://listenbrainz.org): the token the person pastes is the credential.
class ListenBrainzService implements ScrobbleService {
  ListenBrainzService(this.http, this.version);

  final ScrobbleHttp http;
  final String version;

  static const batchSize = 100;
  static const _submit = '/1/submit-listens';

  @override
  int get batch => batchSize;

  @override
  Future<ScrobbleLogin> check(String secret) async {
    final clean = secret.trim();
    final ScrobbleReply reply;
    try {
      reply = await http('/1/validate-token', clean, null);
    } catch (_) {
      return const ScrobbleLogin(ScrobbleConnect.offline);
    }
    if (reply.status >= 500 || reply.status == 429) {
      return const ScrobbleLogin(ScrobbleConnect.offline);
    }
    Object? answer;
    try {
      answer = jsonDecode(reply.body);
    } catch (_) {
      answer = null;
    }
    final name = answer is Map ? answer['user_name'] : null;
    if (reply.status != 200 ||
        answer is! Map ||
        answer['valid'] != true ||
        name is! String ||
        name.isEmpty) {
      return const ScrobbleLogin(ScrobbleConnect.invalid);
    }
    return ScrobbleLogin(ScrobbleConnect.ok, user: name, credential: clean);
  }

  @override
  Future<ScrobbleSend> submit(String credential, List<Listen> listens) async {
    final ScrobbleReply reply;
    try {
      reply = await http(
        _submit,
        credential,
        body(listens.length == 1 ? 'single' : 'import', listens, version),
      );
    } catch (_) {
      return const ScrobbleSend(ScrobbleSent.retry);
    }
    if (reply.status >= 500) return const ScrobbleSend(ScrobbleSent.retry);
    if (reply.status == 200) return const ScrobbleSend(ScrobbleSent.sent);
    if (reply.status == 429) {
      return ScrobbleSend(ScrobbleSent.wait, waitSec: reply.resetInSec ?? 60);
    }
    if (reply.status == 401) return const ScrobbleSend(ScrobbleSent.reauth);
    return const ScrobbleSend(ScrobbleSent.refused);
  }

  @override
  Future<void> playingNow(String credential, Listen listen) async {
    await http(_submit, credential, body('playing_now', [listen], version));
  }

  /// The ask that submits [batch] as [type]: `single`, `import` or `playing_now` (which carries no time).
  static String body(String type, List<Listen> batch, String version) =>
      jsonEncode({
        'listen_type': type,
        'payload': [
          for (final l in batch)
            {
              if (type != 'playing_now') 'listened_at': l.listenedAt,
              'track_metadata': {
                'artist_name': l.artist,
                'track_name': l.title,
                'additional_info': {
                  'media_player': 'Sapoche',
                  'submission_client': 'Sapoche',
                  'submission_client_version': version,
                  if (!l.videoId.startsWith('local:')) ...{
                    'music_service': 'youtube.com',
                    'origin_url':
                        'https://music.youtube.com/watch?v=${l.videoId}',
                  },
                  if (l.durationMs > 0) 'duration_ms': l.durationMs,
                },
              },
            },
        ],
      });
}

/// Asks Last.fm through the room server, which signs for the app (see `server/src/lastfm.ts`): [form] is the call, as a form.
typedef LastFmHttp = Future<ScrobbleReply> Function(String form);

/// Last.fm through the room server, which is on the same address as the web app, so the key in the page's own storage goes
/// with each call: [server] and [headers] are asked for at each call, because the key can be set while the page is open.
LastFmHttp roomLastFmHttp(
  http.Client client, {
  required String Function() server,
  required Map<String, String> Function() headers,
}) => (form) async {
  final reply = await client.post(
    Uri.parse('${server()}/lastfm'),
    headers: {
      ...headers(),
      'Content-Type': 'application/x-www-form-urlencoded',
    },
    body: form,
  );
  return ScrobbleReply(reply.statusCode, body: reply.body);
};

/// [Last.fm](https://www.last.fm). The person is never asked for a password: [begin] gets a token and the page where it is
/// allowed, and once it is, [check] turns it into a session key, which is the credential. Every call goes to the room
/// server, so the app never holds the API key or its secret.
class LastFmService implements ScrobbleService {
  LastFmService(this.http, {this.log});

  final LastFmHttp http;
  final void Function(String)? log;

  static const batchSize = 50;

  @override
  int get batch => batchSize;

  /// The token to allow and the address where to allow it; no token when the server has no Last.fm ([unavailable]) or cannot be reached.
  Future<({String? token, String? url, bool unavailable})> begin() async {
    final ScrobbleReply reply;
    try {
      reply = await http(form([('method', 'auth.getToken')]));
    } catch (_) {
      return (token: null, url: null, unavailable: false);
    }
    if (reply.status == 503) return (token: null, url: null, unavailable: true);
    final answer = _object(reply.body);
    final token = answer?['token'];
    final url = answer?['url'];
    if (reply.status == 200 &&
        token is String &&
        token.isNotEmpty &&
        url is String &&
        url.isNotEmpty) {
      return (token: token, url: url, unavailable: false);
    }
    return (token: null, url: null, unavailable: false);
  }

  @override
  Future<ScrobbleLogin> check(String secret) async {
    final ScrobbleReply reply;
    try {
      reply = await http(
        form([('method', 'auth.getSession'), ('token', secret.trim())]),
      );
    } catch (_) {
      return const ScrobbleLogin(ScrobbleConnect.offline);
    }
    final answer = _object(reply.body);
    final session = answer?['session'];
    final key = session is Map ? session['key'] : null;
    final name = session is Map ? session['name'] : null;
    if (reply.status == 200 &&
        key is String &&
        key.isNotEmpty &&
        name is String &&
        name.isNotEmpty) {
      return ScrobbleLogin(ScrobbleConnect.ok, user: name, credential: key);
    }
    return switch (_code(answer)) {
      14 => const ScrobbleLogin(ScrobbleConnect.pending),
      11 || 16 || 29 => const ScrobbleLogin(ScrobbleConnect.offline),
      null => ScrobbleLogin(
        reply.status == 400 || reply.status == 403
            ? ScrobbleConnect.invalid
            : ScrobbleConnect.offline,
      ),
      _ => const ScrobbleLogin(ScrobbleConnect.invalid),
    };
  }

  @override
  Future<ScrobbleSend> submit(String credential, List<Listen> listens) async {
    final ScrobbleReply reply;
    try {
      reply = await http(form(scrobbleParams(credential, listens)));
    } catch (_) {
      return const ScrobbleSend(ScrobbleSent.retry);
    }
    final answer = _object(reply.body);
    final error = _code(answer);
    if (error != null) {
      return switch (error) {
        4 || 9 || 14 || 15 => const ScrobbleSend(ScrobbleSent.reauth),
        26 => const ScrobbleSend(ScrobbleSent.suspended),
        29 => const ScrobbleSend(ScrobbleSent.wait, waitSec: 60),
        11 || 16 => const ScrobbleSend(ScrobbleSent.retry),
        _ => const ScrobbleSend(ScrobbleSent.refused),
      };
    }
    // The room server did not take the call: its key is wrong, or it does not let this address ask so often
    if (reply.status == 401) return const ScrobbleSend(ScrobbleSent.suspended);
    if (reply.status == 429) {
      return const ScrobbleSend(ScrobbleSent.wait, waitSec: 60);
    }
    if (reply.status != 200) {
      return ScrobbleSend(
        reply.status >= 500 ? ScrobbleSent.retry : ScrobbleSent.refused,
      );
    }
    if (answer == null) return const ScrobbleSend(ScrobbleSent.retry);
    final scrobbles = answer['scrobbles'];
    final attr = scrobbles is Map ? scrobbles['@attr'] : null;
    final ignored = attr is Map ? int.tryParse('${attr['ignored']}') ?? 0 : 0;
    // A listen that Last.fm ignored is not sent again: it would be ignored again (too old, or over the day's limit)
    if (ignored > 0) {
      log?.call('scrobble: Last.fm ignored $ignored of ${listens.length}');
    }
    return const ScrobbleSend(ScrobbleSent.sent);
  }

  @override
  Future<void> playingNow(String credential, Listen listen) async {
    await http(form(nowPlayingParams(credential, listen)));
  }

  static Map<String, dynamic>? _object(String text) {
    try {
      final answer = jsonDecode(text);
      return answer is Map<String, dynamic> ? answer : null;
    } catch (_) {
      return null;
    }
  }

  static int? _code(Map<String, dynamic>? answer) {
    final code = answer?['error'];
    return code == null ? null : int.tryParse('$code');
  }

  /// The parameters of `track.scrobble` for [listens]; the signature is the server's to add.
  static List<(String, String)> scrobbleParams(
    String session,
    List<Listen> listens,
  ) => [
    ('method', 'track.scrobble'),
    ('sk', session),
    for (var i = 0; i < listens.length; i++) ...[
      ('artist[$i]', listens[i].artist),
      ('track[$i]', listens[i].title),
      ('timestamp[$i]', '${listens[i].listenedAt}'),
      if (listens[i].durationMs >= 1000)
        ('duration[$i]', '${listens[i].durationMs ~/ 1000}'),
    ],
  ];

  /// The parameters of `track.updateNowPlaying`.
  static List<(String, String)> nowPlayingParams(
    String session,
    Listen listen,
  ) => [
    ('method', 'track.updateNowPlaying'),
    ('sk', session),
    ('artist', listen.artist),
    ('track', listen.title),
    if (listen.durationMs >= 1000)
      ('duration', '${listen.durationMs ~/ 1000}'),
  ];

  /// [params] as a form, in the order of their names, every byte that is not a letter, a digit or `-._~` as `%XX`: the same text on every platform.
  static String form(List<(String, String)> params) {
    final sorted = [...params]..sort((a, b) => a.$1.compareTo(b.$1));
    return sorted.map((p) => '${_escape(p.$1)}=${_escape(p.$2)}').join('&');
  }

  static String _escape(String text) {
    const digits = '0123456789ABCDEF';
    final out = StringBuffer();
    for (final byte in utf8.encode(text)) {
      final plain =
          (byte >= 0x30 && byte <= 0x39) ||
          (byte >= 0x41 && byte <= 0x5A) ||
          (byte >= 0x61 && byte <= 0x7A) ||
          byte == 0x2D ||
          byte == 0x2E ||
          byte == 0x5F ||
          byte == 0x7E;
      if (plain) {
        out.writeCharCode(byte);
      } else {
        out
          ..write('%')
          ..write(digits[byte >> 4])
          ..write(digits[byte & 15]);
      }
    }
    return out.toString();
  }
}
