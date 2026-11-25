import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// Why the server could not be asked, or what it said that stops a sync.
enum SyncFailure {
  /// No network, or the server did not answer in time.
  offline,

  /// The server wants its key and this phone has none, or the wrong one.
  unauthorized,

  /// The proof of the library's key was refused.
  forbidden,
  tooBig,
  tooOften,

  /// The server has no place for libraries (an old server, or one without a bucket).
  unavailable,

  /// The library was changed by another phone while this one was at it: ask again.
  changed,

  /// There is no library under this key.
  missing,

  /// The server said something that makes no sense.
  server,
}

class SyncException implements Exception {
  const SyncException(this.failure, [this.detail]);

  final SyncFailure failure;
  final String? detail;

  @override
  String toString() => 'SyncException(${failure.name}${detail == null ? '' : ', $detail'})';
}

/// A sealed library as the server holds it, and the tag ([etag]) that says which one it is.
class SyncBlob {
  const SyncBlob(this.bytes, this.etag);

  final Uint8List bytes;
  final String etag;
}

class SyncVersion {
  const SyncVersion({required this.at, required this.size});

  /// When the server put it away (milliseconds since 1970); also what names it.
  final int at;
  final int size;
}

/// What the sync engine asks of the server: sealed libraries by name. Nothing here reads them.
abstract interface class SyncTransport {
  /// The library, or null when there is none under [docId].
  Future<SyncBlob?> get(String docId);

  /// Puts [bytes] in place of the library the tag [ifMatch] names, or as the first one when it is null. Throws
  /// [SyncFailure.changed] when another phone got there first.
  Future<String> put(String docId, String token, Uint8List bytes, {String? ifMatch});

  /// The older libraries the server kept, the latest first.
  Future<List<SyncVersion>> versions(String docId);

  Future<Uint8List?> version(String docId, int at);

  /// Takes the library and its older versions off the server.
  Future<void> delete(String docId, String token);
}

class HttpSyncTransport implements SyncTransport {
  HttpSyncTransport({required this.server, required this.headers, http.Client? client}) : _client = client ?? http.Client();

  /// The address of the server, and what each call must carry (its key).
  final String Function() server;
  final Future<Map<String, String>> Function() headers;
  final http.Client _client;

  static const _timeout = Duration(seconds: 25);

  Uri _uri(String path) {
    final base = server().trim().replaceAll(RegExp(r'/+$'), '');
    if (!base.startsWith('http://') && !base.startsWith('https://')) throw const SyncException(SyncFailure.unavailable);
    return Uri.parse('$base/sync/$path');
  }

  Future<http.Response> _send(String method, String path, {Map<String, String> extra = const {}, Uint8List? body}) async {
    final request = http.Request(method, _uri(path))..headers.addAll({...await headers(), ...extra});
    if (body != null) request.bodyBytes = body;
    final http.Response reply;
    try {
      reply = await http.Response.fromStream(await _client.send(request).timeout(_timeout));
    } on SyncException {
      rethrow;
    } on Object {
      throw const SyncException(SyncFailure.offline);
    }
    return reply;
  }

  SyncException _failure(http.Response reply) => switch (reply.statusCode) {
    401 => const SyncException(SyncFailure.unauthorized),
    403 => const SyncException(SyncFailure.forbidden),
    404 => const SyncException(SyncFailure.missing),
    412 || 428 => const SyncException(SyncFailure.changed),
    413 => const SyncException(SyncFailure.tooBig),
    429 => const SyncException(SyncFailure.tooOften),
    503 => const SyncException(SyncFailure.unavailable),
    final code when code >= 500 => SyncException(SyncFailure.offline, '$code'),
    final code => SyncException(SyncFailure.server, '$code'),
  };

  @override
  Future<SyncBlob?> get(String docId) async {
    final reply = await _send('GET', docId);
    if (reply.statusCode == 404) return _onlyOurs(reply) ? null : throw const SyncException(SyncFailure.unavailable);
    if (reply.statusCode != 200) throw _failure(reply);
    // A server that does not know the route gives its web page for any address
    if (!_onlyOurs(reply)) throw const SyncException(SyncFailure.unavailable);
    return SyncBlob(reply.bodyBytes, reply.headers['etag'] ?? '');
  }

  /// A server without the route answers with its web page; ours never sends a page.
  bool _onlyOurs(http.Response reply) => !(reply.headers['content-type'] ?? '').contains('html');

  @override
  Future<String> put(String docId, String token, Uint8List bytes, {String? ifMatch}) async {
    final reply = await _send(
      'PUT',
      docId,
      extra: {'X-Sync-Token': token, if (ifMatch == null) 'If-None-Match': '*' else 'If-Match': ifMatch, 'Content-Type': 'application/octet-stream'},
      body: bytes,
    );
    if (reply.statusCode != 200) throw _failure(reply);
    return reply.headers['etag'] ?? '';
  }

  @override
  Future<List<SyncVersion>> versions(String docId) async {
    final reply = await _send('GET', '$docId/versions');
    if (reply.statusCode == 404) return const [];
    if (reply.statusCode != 200) throw _failure(reply);
    return _parseVersions(reply.body);
  }

  @override
  Future<Uint8List?> version(String docId, int at) async {
    final reply = await _send('GET', '$docId/v/${at.toString().padLeft(13, '0')}');
    if (reply.statusCode == 404) return null;
    if (reply.statusCode != 200) throw _failure(reply);
    return reply.bodyBytes;
  }

  @override
  Future<void> delete(String docId, String token) async {
    final reply = await _send('DELETE', docId, extra: {'X-Sync-Token': token});
    if (reply.statusCode != 204 && reply.statusCode != 404) throw _failure(reply);
  }

  static List<SyncVersion> _parseVersions(String body) {
    try {
      return [
        for (final item in (jsonDecode(body) as List).cast<Map<String, Object?>>())
          SyncVersion(at: (item['t'] as num).toInt(), size: (item['size'] as num?)?.toInt() ?? 0),
      ];
    } on Object {
      throw const SyncException(SyncFailure.server, 'versions');
    }
  }
}
