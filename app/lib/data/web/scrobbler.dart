import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models.dart';
import 'job.dart';
import 'listen_tracker.dart';
import 'scrobble_service.dart';

export 'scrobble_service.dart';

/// One song heard, as it is sent: [listenedAt] is when it began (seconds since 1970), the names are the cleaned ones.
class Listen {
  const Listen({
    required this.listenedAt,
    required this.videoId,
    required this.title,
    required this.artist,
    required this.durationMs,
  });

  final int listenedAt;
  final String videoId;
  final String title;
  final String artist;
  final int durationMs;

  Map<String, Object> toJson() => {
    'listenedAt': listenedAt,
    'videoId': videoId,
    'title': title,
    'artist': artist,
    'durationMs': durationMs,
  };
}

/// What the settings page shows: [pending] listens wait to be sent; [reconnect] says the token was refused and a new one is needed.
class ScrobbleStatus {
  const ScrobbleStatus({
    required this.connected,
    this.user,
    required this.nowPlaying,
    required this.pending,
    required this.reconnect,
  });

  final bool connected;
  final String? user;
  final bool nowPlaying;
  final int pending;
  final bool reconnect;
}

/// How the service answered: its [status], and with a 429 how many seconds until it takes the next ask ([resetInSec]).
class ScrobbleReply {
  const ScrobbleReply(this.status, {this.body = '', this.resetInSec});

  final int status;
  final String body;
  final int? resetInSec;
}

/// Asks the service: a GET when [body] is null, else a POST of it. Throws when there is no network.
typedef ScrobbleHttp = Future<ScrobbleReply> Function(
  String path,
  String token,
  String? body,
);

/// [ListenBrainz](https://listenbrainz.org) over the real network; it lets any page ask.
ScrobbleHttp listenBrainzHttp(
  http.Client client, {
  String base = 'https://api.listenbrainz.org',
}) => (path, token, body) async {
  final headers = {
    'Authorization': 'Token $token',
    if (body != null) 'Content-Type': 'application/json',
  };
  final uri = Uri.parse('$base$path');
  final reply = body == null
      ? await client.get(uri, headers: headers)
      : await client.post(uri, headers: headers, body: body);
  return ScrobbleReply(
    reply.statusCode,
    body: reply.body,
    resetInSec: int.tryParse(reply.headers['x-ratelimit-reset-in'] ?? ''),
  );
};

/// Where the token and the rest are kept; the token apart, so the platform can put it somewhere safer than the queue.
abstract class ScrobbleStorage {
  String? get token;
  set token(String? value);
  String? loadState();
  void saveState(String text);
}

/// Sends what this phone plays to one [service] ([ListenBrainz](https://listenbrainz.org) or [Last.fm](https://www.last.fm)),
/// once the person has connected it. There is one of these for each, with a queue and counter of its own, so that one that
/// fails does not hold the other. Without a connection it does nothing, and nothing goes out.
///
/// It follows the player through [watch]: a song counts after half of it or four minutes, whichever is first, and never
/// when it is thirty seconds or less (the rule of ListenBrainz and Last.fm, stricter than the history's, so it has a
/// tracker of its own). A song that counts is written to a queue kept on the phone and sent at once; with no network, or
/// when the service is busy, it stays there and is sent later, many at a time, for 14 days or 1000 listens.
/// "Playing now" goes out a few seconds after a song starts, if the person wants it. Only the song goes out: nothing of
/// the room, its members or who added the song.
///
/// Dart counterpart of `Scrobbler.kt`.
class Scrobbler {
  Scrobbler({
    required this.storage,
    required this.service,
    required this.namer,
    required this.mono,
    required this.wall,
    this.log,
  }) {
    final text = storage.loadState();
    if (text != null) {
      try {
        final saved = jsonDecode(text) as Map<String, dynamic>;
        _user = saved['user'] as String?;
        _nowPlaying = saved['nowPlaying'] as bool? ?? true;
        _reconnect = saved['reconnect'] as bool? ?? false;
        for (final item in (saved['listens'] as List<dynamic>? ?? const [])) {
          final m = item as Map<String, dynamic>;
          final at = (m['listenedAt'] as num?)?.toInt();
          final id = m['videoId'] as String?;
          if (at == null || id == null) continue;
          _listens.add(
            Listen(
              listenedAt: at,
              videoId: id,
              title: m['title'] as String? ?? '',
              artist: m['artist'] as String? ?? '',
              durationMs: (m['durationMs'] as num?)?.toInt() ?? 0,
            ),
          );
        }
      } catch (_) {
        // A queue that cannot be read is a queue that is empty
      }
    }
    _trim();
  }

  /// A song counts after this long of playing, or half of it when that is less.
  static const heardMs = 4 * 60000;

  /// A song of this length or less never counts.
  static const minSongMs = 30000;
  static const announceDelay = Duration(seconds: 5);
  static const maxListens = 1000;
  static const maxAgeSec = 14 * 24 * 3600;
  static const retryMin = Duration(seconds: 15);
  static const retryMax = Duration(minutes: 5);

  final ScrobbleStorage storage;
  final ScrobbleService service;

  /// The title and the artist to send for a song: the cleaned names.
  final (String title, String artist) Function(Track) namer;
  final int Function() mono;
  final int Function() wall;
  final void Function(String)? log;

  String? _user;
  bool _nowPlaying = true;
  bool _reconnect = false;
  final _listens = <Listen>[];

  late final _tracker = ListenTracker(
    heard: _heard,
    heardAfterMs: heardMs,
    minDurationMs: minSongMs,
  );
  Track? _current;
  int? _startedAt;
  int _lastDurationMs = 0;
  Job? _due;
  Job? _announce;
  Job? _sender;

  bool get _connected => storage.token != null;

  ScrobbleStatus status() => ScrobbleStatus(
    connected: _connected,
    user: _user,
    nowPlaying: _nowPlaying,
    pending: _listens.length,
    reconnect: _reconnect,
  );

  /// Checks [secret] (the token the person gave) with the service and, if it is good, keeps what it gives and sends what waits.
  Future<ScrobbleConnect> connect(String secret) async {
    final login = await service.check(secret);
    final credential = login.credential;
    if (login.result != ScrobbleConnect.ok) return login.result;
    if (credential == null) return ScrobbleConnect.invalid;
    storage.token = credential;
    _user = login.user;
    _reconnect = false;
    _save();
    log?.call('scrobble: connected as ${login.user}');
    _send();
    return ScrobbleConnect.ok;
  }

  /// Forgets the token and drops what had not been sent.
  void disconnect() {
    storage.token = null;
    _user = null;
    _reconnect = false;
    _listens.clear();
    _save();
    _reset();
    log?.call('scrobble: disconnected');
  }

  void setNowPlaying(bool on) {
    _nowPlaying = on;
    if (!on) _announce?.cancel();
    _save();
  }

  /// The app is open: sends what waited while it was not.
  void resume() => _send();

  /// The player's state: the song it has loaded (null for none), whether it plays, and its length. Called at every
  /// change of it, and cheap when nothing is connected.
  void watch(Track? track, bool playing, int durationMs) {
    if (!_connected || _reconnect) {
      if (_current != null) _reset();
      return;
    }
    final now = mono();
    if (track?.videoId != _current?.videoId) {
      // Counts the song that is ending, if it just passed the mark, so `_current` still has to be that one
      _tracker.begin(track?.videoId, durationMs < 0 ? 0 : durationMs, now);
      _current = track;
      _startedAt = null;
      _announce?.cancel();
    }
    final song = _current;
    if (song == null) return;
    _lastDurationMs = durationMs < 0 ? 0 : durationMs;
    _tracker.setDuration(_lastDurationMs);
    _tracker.setPlaying(playing, now);
    if (playing && _startedAt == null) {
      _startedAt = wall();
      if (_nowPlaying) _announceSong(song);
    }
    _schedule();
  }

  void _reset() {
    // Before the tracker is told, so that a song it counts on its way out is not queued
    _current = null;
    _tracker.begin(null, 0, mono());
    _startedAt = null;
    _due?.cancel();
    _announce?.cancel();
    _sender?.cancel();
  }

  void _schedule() {
    _due?.cancel();
    final wait = _tracker.msUntilHeard(mono());
    if (wait == null) return;
    _due = Job.launch((job) async {
      await job.delay(Duration(milliseconds: wait));
      _tracker.check(mono());
      _schedule();
    });
  }

  void _heard(String id, int durationMs) {
    final song = _current;
    if (song == null || song.videoId != id) return;
    final (title, artist) = namer(song);
    _listens.add(
      Listen(
        listenedAt: (_startedAt ?? wall()) ~/ 1000,
        videoId: id,
        title: title,
        artist: artist,
        durationMs: durationMs > 0 ? durationMs : song.durMs,
      ),
    );
    _trim();
    _save();
    log?.call("scrobble: '$title' queued (${_listens.length} waiting)");
    _send();
  }

  /// Tells the service what plays, a few seconds in, so a song that is skipped at once is not shown.
  void _announceSong(Track song) {
    _announce?.cancel();
    _announce = Job.launch((job) async {
      await job.delay(announceDelay);
      final token = storage.token;
      if (token == null) return;
      final (title, artist) = namer(song);
      final listen = Listen(
        listenedAt: 0,
        videoId: song.videoId,
        title: title,
        artist: artist,
        durationMs: _lastDurationMs > 0 ? _lastDurationMs : song.durMs,
      );
      try {
        await job.guard(service.playingNow(token, listen));
      } on Cancelled {
        rethrow;
      } catch (e) {
        log?.call('scrobble: playing now not sent: $e');
      }
    });
  }

  void _trim() {
    final oldest = wall() ~/ 1000 - maxAgeSec;
    final before = _listens.length;
    _listens.removeWhere((l) => l.listenedAt < oldest);
    if (_listens.length > maxListens) {
      _listens.removeRange(0, _listens.length - maxListens);
    }
    if (_listens.length < before) {
      log?.call('scrobble: ${before - _listens.length} old listens dropped');
    }
  }

  void _save() {
    storage.saveState(
      jsonEncode({
        if (_user != null) 'user': _user,
        'nowPlaying': _nowPlaying,
        'reconnect': _reconnect,
        'listens': [for (final l in _listens) l.toJson()],
      }),
    );
  }

  /// Sends the queue, a batch at a time, until it is empty; goes on trying later while the service cannot be reached.
  void _send() {
    if (_sender?.isActive == true ||
        _listens.isEmpty ||
        !_connected ||
        _reconnect) {
      return;
    }
    _sender = Job.launch((job) async {
      var wait = retryMin;
      var size = service.batch;
      while (_listens.isNotEmpty) {
        final token = storage.token;
        if (token == null) return;
        final sending = _listens.take(size).toList();
        final sent = await job.guard(service.submit(token, sending));
        switch (sent.kind) {
          case ScrobbleSent.sent:
            _listens.removeRange(0, sending.length);
            _save();
            wait = retryMin;
          case ScrobbleSent.reauth:
            _reconnect = true;
            _save();
            log?.call('scrobble: the token was refused');
            return;
          case ScrobbleSent.suspended:
            // Stops here; the next listen, or the app opened again, tries once more
            log?.call('scrobble: the service takes nothing for now');
            return;
          case ScrobbleSent.wait:
            await job.delay(Duration(seconds: sent.waitSec + 1));
          case ScrobbleSent.refused:
            if (sending.length > 1) {
              // The service refused something in it: one at a time (until the queue is empty) finds what, and only that is dropped
              size = 1;
            } else {
              log?.call("scrobble: '${sending[0].title}' refused, dropped");
              _listens.removeAt(0);
              _save();
            }
          case ScrobbleSent.retry:
            await job.delay(wait);
            wait = wait * 2 > retryMax ? retryMax : wait * 2;
        }
      }
    });
  }
}
