import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'backend.dart';
import 'comments.dart';

/// The apps: the player, the room and the library live in Kotlin or Swift behind the platform channels.
Future<Backend> createBackend() async => NativeBackend();

/// A phone asks YouTube for comments itself, as it does for everything else: nothing is asked of the room's server.
CommentsTransport createCommentsTransport(Backend backend) {
  final client = http.Client();
  return (body) async {
    final reply = await client
        .post(
          Uri.https('www.youtube.com', '/youtubei/v1/next', {'prettyPrint': 'false'}),
          headers: {
            'Content-Type': 'application/json',
            // The name of a browser, as the Worker gives for the same ask: one kind of caller for YouTube to see
            'User-Agent': _userAgent,
          },
          body: body,
        )
        .timeout(const Duration(seconds: 20));
    if (reply.statusCode != 200) throw HttpException('YouTube answered ${reply.statusCode}');
    return utf8.decode(reply.bodyBytes);
  };
}

const _userAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36';
