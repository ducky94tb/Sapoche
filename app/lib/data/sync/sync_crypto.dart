import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:cryptography/cryptography.dart';

import 'sync_doc.dart';

/// The key that opens a library on the server: 32 random bytes, written as 52 letters and digits (base32) in groups of four.
/// It is the only thing that names the library, so whoever has it can read and change it; nothing else (no name, no email).
class SyncKey {
  const SyncKey._(this._bytes);

  final Uint8List _bytes;

  static const _length = 32;
  static const _alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  static final _random = Random.secure();

  static SyncKey generate() => SyncKey._(Uint8List.fromList([for (var i = 0; i < _length; i++) _random.nextInt(256)]));

  /// The key a [code] holds, as written by [display] or [code]: case, spaces and dashes do not matter. Null when it is none.
  static SyncKey? parse(String text) {
    final clean = text.toUpperCase().replaceAll(RegExp(r'[\s-]'), '');
    if (clean.length != 52) return null;
    var bits = 0;
    var value = 0;
    final out = <int>[];
    for (final unit in clean.codeUnits) {
      final digit = _alphabet.indexOf(String.fromCharCode(unit));
      if (digit < 0) return null;
      value = (value << 5) | digit;
      bits += 5;
      if (bits >= 8) {
        bits -= 8;
        out.add((value >> bits) & 0xff);
        value &= (1 << bits) - 1;
      }
    }
    return out.length == _length ? SyncKey._(Uint8List.fromList(out)) : null;
  }

  /// 52 characters.
  String get code {
    final out = StringBuffer();
    var bits = 0;
    var value = 0;
    for (final byte in _bytes) {
      value = (value << 8) | byte;
      bits += 8;
      while (bits >= 5) {
        bits -= 5;
        out.write(_alphabet[(value >> bits) & 31]);
        value &= (1 << bits) - 1;
      }
    }
    if (bits > 0) out.write(_alphabet[(value << (5 - bits)) & 31]);
    return out.toString();
  }

  /// The code in groups of four, easier to read out and to copy by eye.
  String get display => [for (var i = 0; i < 52; i += 4) code.substring(i, i + 4)].join('-');

  /// The link that sets up another phone: it opens the app (or the web page) with this key.
  String get link => 'sapoche://sync?k=$code';

  /// The key in a link, or in text with a code in it; null when there is none.
  static SyncKey? fromText(String text) {
    final found = RegExp(r'sapoche://sync\?\S*?k=([A-Za-z2-7-]+)').firstMatch(text);
    return parse(found?.group(1) ?? text);
  }

  /// What the key gives: the name of the library on the server, the proof that a writer may change it, the key that seals it.
  Future<SyncSecrets> derive() async {
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
    Future<List<int>> part(String info) async =>
        (await (await hkdf.deriveKey(secretKey: SecretKey(_bytes), info: utf8.encode('sapoche-sync/$info'))).extractBytes());
    String hex(List<int> bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return SyncSecrets(docId: hex(await part('doc')), token: hex(await part('write')), seal: SecretKey(await part('seal')));
  }
}

class SyncSecrets {
  const SyncSecrets({required this.docId, required this.token, required this.seal});

  /// 64 hex characters: the name of the library on the server.
  final String docId;

  /// 64 hex characters: what a request shows to be let write.
  final String token;
  final SecretKey seal;
}

/// Seals a library for the server and opens it again: JSON, packed with gzip, then AES-256-GCM. What goes up is one byte of
/// format, the nonce (12 bytes), the sealed bytes and the tag (16 bytes); the server sees nothing else.
class SyncSeal {
  const SyncSeal._();

  static const _format = 1;
  static const _nonceBytes = 12;
  static const _tagBytes = 16;
  static final _aes = AesGcm.with256bits();
  static final _aad = utf8.encode('sapoche-sync/1');

  static Future<Uint8List> seal(SyncDoc doc, SyncSecrets secrets, {List<int>? nonce}) async {
    final packed = GZipEncoder().encode(utf8.encode(jsonEncode(doc.toJson())));
    final box = await _aes.encrypt(packed, secretKey: secrets.seal, nonce: nonce, aad: _aad);
    return Uint8List.fromList([_format, ...box.nonce, ...box.cipherText, ...box.mac.bytes]);
  }

  /// The library in [bytes]; throws [FormatException] when it was sealed with another key, was touched, or is not one of ours.
  static Future<SyncDoc> open(List<int> bytes, SyncSecrets secrets) async {
    if (bytes.length < 1 + _nonceBytes + _tagBytes || bytes[0] != _format) {
      throw const FormatException('Not a Sapoche library');
    }
    try {
      final box = SecretBox(
        bytes.sublist(1 + _nonceBytes, bytes.length - _tagBytes),
        nonce: bytes.sublist(1, 1 + _nonceBytes),
        mac: Mac(bytes.sublist(bytes.length - _tagBytes)),
      );
      final packed = await _aes.decrypt(box, secretKey: secrets.seal, aad: _aad);
      final json = jsonDecode(utf8.decode(GZipDecoder().decodeBytes(packed)));
      return SyncDoc.fromJson((json as Map).cast<String, Object?>());
    } on FormatException {
      rethrow;
    } on Object {
      throw const FormatException('Cannot be opened with this key');
    }
  }
}
