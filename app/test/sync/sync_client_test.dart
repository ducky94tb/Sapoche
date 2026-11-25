import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sapoche/data/sync/sync_client.dart';

HttpSyncTransport transport(MockClient client) => HttpSyncTransport(
  server: () => 'https://room.test/',
  headers: () async => {'X-Sapoche-Key': 'k'},
  client: client,
);

void main() {
  const id = 'ab';

  test('it asks the routes of the server with the key, the token and the condition', () async {
    final seen = <http.BaseRequest>[];
    final t = transport(MockClient((request) async {
      seen.add(request);
      return request.method == 'PUT' ? http.Response('', 200, headers: {'etag': '"2"'}) : http.Response.bytes([1, 2], 200, headers: {'etag': '"1"'});
    }));
    final blob = await t.get(id);
    expect(blob?.bytes, [1, 2]);
    expect(blob?.etag, '"1"');
    expect(await t.put(id, 'token', Uint8List.fromList([3]), ifMatch: '"1"'), '"2"');
    await t.put(id, 'token', Uint8List.fromList([3]));
    expect(seen[0].url.toString(), 'https://room.test/sync/ab');
    expect(seen[0].headers['X-Sapoche-Key'], 'k');
    expect(seen[1].headers['If-Match'], '"1"');
    expect(seen[1].headers['X-Sync-Token'], 'token');
    expect(seen[2].headers['If-None-Match'], '*');
  });

  test('what the server says becomes a reason', () async {
    Future<SyncFailure?> reason(int status, {Map<String, String> headers = const {}}) async {
      try {
        await transport(MockClient((_) async => http.Response('', status, headers: headers))).put(id, 't', Uint8List(1), ifMatch: 'x');
      } on SyncException catch (e) {
        return e.failure;
      }
      return null;
    }

    expect(await reason(401), SyncFailure.unauthorized);
    expect(await reason(403), SyncFailure.forbidden);
    expect(await reason(412), SyncFailure.changed);
    expect(await reason(413), SyncFailure.tooBig);
    expect(await reason(429), SyncFailure.tooOften);
    expect(await reason(503), SyncFailure.unavailable);
    expect(await reason(502), SyncFailure.offline);
  });

  test('no network is offline, no library is null, a web page is not a library', () async {
    await expectLater(
      transport(MockClient((_) async => throw http.ClientException('down'))).get(id),
      throwsA(isA<SyncException>().having((e) => e.failure, 'failure', SyncFailure.offline)),
    );
    expect(await transport(MockClient((_) async => http.Response('Not found', 404))).get(id), isNull);
    await expectLater(
      transport(MockClient((_) async => http.Response('<html></html>', 200, headers: {'content-type': 'text/html'}))).get(id),
      throwsA(isA<SyncException>().having((e) => e.failure, 'failure', SyncFailure.unavailable)),
    );
  });

  test('the older copies are listed and fetched by their time', () async {
    final t = transport(MockClient((request) async {
      if (request.url.path.endsWith('/versions')) return http.Response('[{"t":1700000000000,"size":10},{"t":5,"size":3}]', 200);
      return request.url.path.endsWith('/v/1700000000000') ? http.Response.bytes([9], 200) : http.Response('', 404);
    }));
    final versions = await t.versions(id);
    expect(versions.map((v) => v.at), [1700000000000, 5]);
    expect(await t.version(id, 1700000000000), [9]);
    expect(await t.version(id, 6), isNull);
  });
}
