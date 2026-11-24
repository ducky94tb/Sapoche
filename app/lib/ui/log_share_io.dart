import 'dart:convert';
import 'dart:typed_data';

import 'package:share_plus/share_plus.dart';

/// Hands the log to the system's share sheet as a text file ([name]), which Zalo, Messenger, mail and the cloud drives all take.
Future<void> shareLogFile(String name, String text) async {
  await SharePlus.instance.share(
    ShareParams(
      files: [XFile.fromData(Uint8List.fromList(utf8.encode(text)), mimeType: 'text/plain', name: name)],
      fileNameOverrides: [name],
      subject: name,
    ),
  );
}
