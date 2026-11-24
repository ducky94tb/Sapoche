import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:share_plus/share_plus.dart';
import 'package:web/web.dart' as web;

/// Hands the log to the share sheet of the browser when it can share files (phones), and downloads it otherwise.
Future<void> shareLogFile(String name, String text) async {
  final bytes = Uint8List.fromList(utf8.encode(text));
  final navigator = web.window.navigator;
  final file = web.File([bytes.toJS].toJS, name, web.FilePropertyBag(type: 'text/plain'));
  if ((navigator as JSObject).has('canShare') && navigator.canShare(web.ShareData(files: [file].toJS))) {
    await SharePlus.instance.share(
      ShareParams(files: [XFile.fromData(bytes, mimeType: 'text/plain', name: name)], fileNameOverrides: [name]),
    );
    return;
  }
  final url = web.URL.createObjectURL(web.Blob([bytes.toJS].toJS, web.BlobPropertyBag(type: 'text/plain')));
  final link = web.document.createElement('a') as web.HTMLAnchorElement
    ..href = url
    ..download = name;
  link.click();
  web.URL.revokeObjectURL(url);
}
