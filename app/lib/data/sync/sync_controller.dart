import 'dart:async';
import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';

import 'sync_apply.dart';
import 'sync_client.dart';
import 'sync_crypto.dart';
import 'sync_doc.dart';
import 'sync_local.dart';
import 'sync_merge.dart';

/// Where the sync key is kept: the keychain on an iPhone, the app's own preferences elsewhere.
abstract interface class SyncKeyStore {
  Future<String?> read();
  Future<void> write(String? code);
}

/// Where the engine keeps what it must remember between runs (one text).
abstract interface class SyncStateStore {
  Future<String?> read();
  Future<void> write(String text);
}

enum SyncPhase { off, idle, syncing, failed, refused }

/// A copy of the library of this phone taken before something that could change a lot of it.
class SyncSafety {
  const SyncSafety({required this.at, required this.kind, required this.data});

  /// `first` (before the first merge) or `restore` (before an older version was put back).
  final String kind;
  final int at;

  /// gzip of the JSON of a [SyncDoc], in base64.
  final String data;
}

/// Keeps the library of this phone and the sealed copy on the server alike: reads the one, merges with the other (see
/// [mergeDocs]) and puts what came out in both. Nothing else decides what a sync does; this only runs it, one at a time.
class SyncController extends ChangeNotifier {
  SyncController({
    required this._library,
    required this._transport,
    required this._keys,
    required this._state,
    required String Function() deviceLabel,
    int Function()? nowMs,
    this.settle = const Duration(seconds: 5),
  }) : _label = deviceLabel,
       _now = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  final SyncLibrary _library;
  final SyncTransport _transport;
  final SyncKeyStore _keys;
  final SyncStateStore _state;
  final String Function() _label;
  final int Function() _now;

  /// How long after a change of the library a sync waits, so that a run of changes makes one.
  final Duration settle;

  /// A device that has not been heard of for this long is no longer listed.
  static const _deviceStale = Duration(days: 120);

  /// The time after which a device is told to the others again though nothing else changed.
  static const _beat = Duration(hours: 12);

  /// How often a run starts over because another phone wrote at the same time.
  static const _tries = 3;

  SyncKey? _key;
  SyncSecrets? _secrets;
  SyncDoc? _base;
  String? _etag;
  var _map = UidMap();
  var _deviceId = '';
  var _lastSync = 0;
  var _deviceCount = 0;
  var _pendingClear = 0;
  var _saved = false;
  var _cardDismissed = false;
  var _safety = <SyncSafety>[];
  var _phase = SyncPhase.off;
  SyncFailure? _failure;
  SyncRefused? _refused;
  Timer? _timer;
  Future<void>? _running;
  var _again = false;
  var _quietUntil = 0;
  var _loaded = false;

  // ------------------------------------------------------------------ what the screen shows

  bool get enabled => _key != null;
  SyncPhase get phase => _phase;

  /// Why the last run failed (while [phase] is `failed`).
  SyncFailure? get failure => _failure;

  /// The change that waits for the person's word (while [phase] is `refused`).
  SyncRefused? get refused => _refused;

  /// When the last run ended well, or null.
  DateTime? get lastSync => _lastSync == 0 ? null : DateTime.fromMillisecondsSinceEpoch(_lastSync);

  /// How many phones the library has been synced from lately, this one included.
  int get deviceCount => _deviceCount;

  /// The key, to be written down or shown to another phone.
  SyncKey? get key => _key;

  /// The person said they have kept the recovery code.
  bool get recoverySaved => _saved;

  /// The card in the library that offers sync is to be shown: sync is off and the person has not sent it away.
  bool get offerCard => _loaded && _key == null && !_cardDismissed;

  /// The person does not want the card in the library again.
  Future<void> dismissCard() async {
    _cardDismissed = true;
    await _save();
    notifyListeners();
  }

  /// What was kept before the first merge, which can be undone.
  SyncSafety? get firstCopy => _safety.where((s) => s.kind == 'first').firstOrNull;

  // ------------------------------------------------------------------ start and stop

  /// Reads the key and what was remembered; syncs when there is a key.
  Future<void> load() async {
    try {
      final code = await _keys.read();
      _key = code == null ? null : SyncKey.parse(code);
      _secrets = await _key?.derive();
      final text = await _state.read();
      if (text != null) _readState(jsonDecode(text) as Map<String, Object?>);
    } on Object {
      // What cannot be read is as if it were not there: the next sync makes it again from the server
    }
    if (_deviceId.isEmpty) _deviceId = UidMap.newUid();
    _loaded = true;
    _phase = _key == null ? SyncPhase.off : SyncPhase.idle;
    notifyListeners();
    if (_key != null) unawaited(syncNow());
  }

  /// Starts a library of its own from this phone, under a new key; the key is then to be written down ([key]).
  Future<SyncFailure?> enable() => _begin(SyncKey.generate(), mustExist: false);

  /// Joins the library of [key] (from another phone or a recovery code) and merges this phone's into it: nothing is removed.
  Future<SyncFailure?> join(SyncKey key) => _begin(key, mustExist: true);

  Future<SyncFailure?> _begin(SyncKey key, {required bool mustExist}) async {
    await _ready();
    final secrets = await key.derive();
    if (mustExist) {
      try {
        if (await _transport.get(secrets.docId) == null) return SyncFailure.missing;
      } on SyncException catch (e) {
        return e.failure;
      }
    }
    _key = key;
    _secrets = secrets;
    _base = null;
    _etag = null;
    _map = UidMap();
    _lastSync = 0;
    _saved = mustExist;
    _phase = SyncPhase.idle;
    await _keys.write(key.code);
    await _save();
    notifyListeners();
    await syncNow();
    return _phase == SyncPhase.failed ? _failure : null;
  }

  /// Stops syncing. The library stays on this phone; with [deleteRemote] the sealed copy goes from the server too, for every
  /// phone (they are told at their next sync that there is none, and put theirs up again).
  Future<void> disable({bool deleteRemote = false}) async {
    final secrets = _secrets;
    _timer?.cancel();
    if (deleteRemote && secrets != null) {
      try {
        await _transport.delete(secrets.docId, secrets.token);
      } on SyncException catch (e) {
        _failure = e.failure;
        _phase = SyncPhase.failed;
        notifyListeners();
        return;
      }
    }
    _key = null;
    _secrets = null;
    _base = null;
    _etag = null;
    _map = UidMap();
    _safety = [];
    _lastSync = 0;
    _deviceCount = 0;
    _pendingClear = 0;
    _phase = SyncPhase.off;
    await _keys.write(null);
    await _save();
    notifyListeners();
  }

  /// The person says the recovery code is kept somewhere safe.
  Future<void> markSaved() async {
    _saved = true;
    await _save();
    notifyListeners();
  }

  // ------------------------------------------------------------------ when to sync

  /// The library of this phone changed (a like, a playlist): sync a few seconds later. Changes the sync itself made do not count.
  void libraryChanged() {
    if (_key == null || _now() < _quietUntil) return;
    _timer?.cancel();
    _timer = Timer(settle, () => unawaited(syncNow()));
  }

  /// The person cleared the history: the others are told, since a listen that is gone from here is otherwise only a trimmed one.
  void historyCleared() {
    if (_key == null) return;
    _pendingClear = _now();
    unawaited(_save());
  }

  /// The app came back to the front or is leaving it: sync now.
  void appMoved() {
    if (_key != null) unawaited(syncNow());
  }

  /// Runs a sync, or lets the one that runs go once more when it was asked during it. With [force] a change that takes away a
  /// lot goes through (the person said so).
  Future<void> syncNow({bool force = false}) async {
    if (_key == null) return;
    _timer?.cancel();
    if (_running != null) {
      if (!force) _again = true;
      await _running;
      if (!force) return;
    }
    _running = _run(force).whenComplete(() => _running = null);
    await _running;
    while (_again && _key != null) {
      _again = false;
      _running = _run(false).whenComplete(() => _running = null);
      await _running;
    }
  }

  Future<void> _ready() async {
    if (!_loaded) await load();
    await _running;
  }

  Future<void> _run(bool force) async {
    _phase = SyncPhase.syncing;
    _failure = null;
    _refused = null;
    notifyListeners();
    try {
      for (var attempt = 0; attempt < _tries; attempt++) {
        try {
          await _once(force);
          _phase = SyncPhase.idle;
          break;
        } on SyncException catch (e) {
          if (e.failure != SyncFailure.changed || attempt == _tries - 1) rethrow;
        }
      }
    } on SyncRefused catch (e) {
      _refused = e;
      _phase = SyncPhase.refused;
      debugPrint('[sync] refused: $e');
    } on SyncException catch (e) {
      _failure = e.failure;
      _phase = SyncPhase.failed;
      debugPrint('[sync] failed: ${e.failure.name}');
    } on FormatException catch (e) {
      _failure = SyncFailure.server;
      _phase = SyncPhase.failed;
      debugPrint('[sync] failed: ${e.message}');
    } on Object catch (e) {
      _failure = SyncFailure.server;
      _phase = SyncPhase.failed;
      debugPrint('[sync] failed: ${e.runtimeType}');
    }
    notifyListeners();
  }

  Future<void> _once(bool force) async {
    final secrets = _secrets!;
    final localLib = LocalLibrary.fromJson(await _library.snapshot());
    final blob = await _transport.get(secrets.docId);
    final remote = blob == null ? null : await SyncSeal.open(blob.bytes, secrets);
    // A library the server no longer has was deleted from another phone: this one puts its own up again, losing nothing
    final base = remote == null ? null : _base;
    if (base == null && remote != null) _adoptByName(localLib, remote);
    final local = _map.toDoc(localLib);

    if (base != null && !force) {
      final loss = SyncLoss.between(base, local);
      if (loss.tooMuch(base)) throw SyncRefused(loss, fromHere: true);
    }
    if (base == null && !local.isEmpty) await _keepCopy('first', local);

    final merged = mergeDocs(base: base, local: local, remote: remote ?? SyncDoc(), now: _now(), localClearedAt: _pendingClear);
    final etag = await _publish(secrets, merged, remote, blob?.etag);

    if (base != null && !force) {
      final loss = SyncLoss.between(local, merged);
      if (loss.tooMuch(local)) throw SyncRefused(loss, fromHere: false);
    }
    final othersCleared = base != null && _pendingClear == 0 && merged.historyClearedAt > base.historyClearedAt;
    _quietUntil = _now() + 4000;
    await applyMerged(
      library: _library,
      local: localLib,
      merged: merged,
      map: _map,
      clearHistory: othersCleared,
      saveMap: _save,
    );
    _quietUntil = _now() + 4000;
    await _remember(merged, etag);
  }

  /// The first time this phone meets a library, a playlist or folder of the same name on both sides is taken for one (as a
  /// restored backup does), and so is one whose making a killed run did not get to note: they are joined, not made twice.
  void _adoptByName(LocalLibrary local, SyncDoc remote) {
    void adopt(Map<String, int> map, Iterable<(int, String)> mine, Map<String, String> remoteNames) {
      final bound = map.values.toSet();
      for (final (id, name) in mine) {
        if (bound.contains(id)) continue;
        final uid = remoteNames.entries.where((e) => e.value == name && !map.containsKey(e.key)).map((e) => e.key).firstOrNull;
        if (uid != null) map[uid] = id;
      }
    }

    adopt(_map.playlists, [for (final p in local.playlists) (p.id, p.name)], {for (final e in remote.playlists.entries) e.key: e.value.name});
    adopt(_map.folders, [for (final f in local.folders) (f.id, f.name)], {for (final e in remote.folders.entries) e.key: e.value.name});
  }

  /// Puts [merged] on the server unless it says what the server already has; gives the tag of what is there after.
  Future<String> _publish(SyncSecrets secrets, SyncDoc merged, SyncDoc? remote, String? etag) async {
    final now = _now();
    final mine = remote?.devices[_deviceId];
    final stale = mine == null || now - mine.seenAt > _beat.inMilliseconds;
    if (remote != null && etag != null && !stale && _sameContent(merged, remote)) {
      return etag;
    }
    merged.devices[_deviceId] = SyncDevice(label: _label(), seenAt: now);
    merged.devices.removeWhere((_, d) => now - d.seenAt > _deviceStale.inMilliseconds);
    final sealed = await SyncSeal.seal(merged, secrets);
    debugPrint('[sync] put ${sealed.length} bytes: likes ${merged.likes.length}, playlists ${merged.playlists.length}');
    return _transport.put(secrets.docId, secrets.token, sealed, ifMatch: etag);
  }

  bool _sameContent(SyncDoc a, SyncDoc b) =>
      jsonEncode((a.toJson()..remove('devices'))) == jsonEncode((b.toJson()..remove('devices')));

  Future<void> _remember(SyncDoc merged, String etag) async {
    _base = SyncDoc(
      likes: merged.likes,
      folders: merged.folders,
      playlists: merged.playlists,
      history: merged.history,
      historyClearedAt: merged.historyClearedAt,
      blocked: merged.blocked,
      marks: merged.marks,
    );
    _etag = etag;
    _lastSync = _now();
    _deviceCount = merged.devices.length;
    _pendingClear = 0;
    await _save();
  }

  // ------------------------------------------------------------------ the safety net

  /// The older libraries the server kept.
  Future<List<SyncVersion>> versions() async {
    final secrets = _secrets;
    return secrets == null ? const [] : _transport.versions(secrets.docId);
  }

  /// Puts the library the server kept at [version] in place of this one, on the server and on this phone; the other phones
  /// take it at their next sync like any change. A copy of this phone's library is kept first.
  Future<SyncFailure?> restoreVersion(SyncVersion version) async {
    await _ready();
    final secrets = _secrets;
    if (secrets == null) return null;
    _phase = SyncPhase.syncing;
    notifyListeners();
    try {
      final bytes = await _transport.version(secrets.docId, version.at);
      if (bytes == null) throw const SyncException(SyncFailure.missing);
      final old = await SyncSeal.open(bytes, secrets);
      final localLib = LocalLibrary.fromJson(await _library.snapshot());
      await _keepCopy('restore', _map.toDoc(localLib));
      final current = await _transport.get(secrets.docId);
      old.devices[_deviceId] = SyncDevice(label: _label(), seenAt: _now());
      final etag = await _transport.put(secrets.docId, secrets.token, await SyncSeal.seal(old, secrets), ifMatch: current?.etag);
      _quietUntil = _now() + 4000;
      await applyMerged(library: _library, local: localLib, merged: old, map: _map, clearHistory: true, saveMap: _save);
      await _remember(old, etag);
      _phase = SyncPhase.idle;
      notifyListeners();
      return null;
    } on SyncException catch (e) {
      _failure = e.failure;
      _phase = SyncPhase.failed;
      notifyListeners();
      return e.failure;
    }
  }

  /// Takes the library of this phone back to what it was before the first merge, and stops syncing (the server keeps its copy).
  Future<void> undoFirst() async {
    final copy = firstCopy;
    if (copy == null) return;
    final doc = SyncDoc.fromJson((jsonDecode(utf8.decode(GZipDecoder().decodeBytes(base64Decode(copy.data)))) as Map).cast<String, Object?>());
    final localLib = LocalLibrary.fromJson(await _library.snapshot());
    _quietUntil = _now() + 4000;
    await applyMerged(library: _library, local: localLib, merged: doc, map: _map, clearHistory: true, saveMap: _save);
    await disable();
  }

  Future<void> _keepCopy(String kind, SyncDoc local) async {
    final packed = GZipEncoder().encode(utf8.encode(jsonEncode(local.toJson())));
    _safety = [
      SyncSafety(at: _now(), kind: kind, data: base64Encode(Uint8List.fromList(packed))),
      ..._safety.where((s) => s.kind != kind),
    ];
    await _save();
  }

  // ------------------------------------------------------------------ what is remembered

  void _readState(Map<String, Object?> json) {
    final base = json['base'];
    _base = base == null ? null : SyncDoc.fromJson((base as Map).cast<String, Object?>());
    _etag = json['etag'] as String?;
    _map = UidMap.fromJson((json['map'] as Map?)?.cast<String, Object?>() ?? const {});
    _deviceId = json['device'] as String? ?? '';
    _lastSync = (json['lastSync'] as num?)?.toInt() ?? 0;
    _deviceCount = (json['devices'] as num?)?.toInt() ?? 0;
    _pendingClear = (json['pendingClear'] as num?)?.toInt() ?? 0;
    _saved = json['saved'] == true;
    _cardDismissed = json['cardDismissed'] == true;
    _safety = [
      for (final s in json['safety'] as List? ?? const [])
        SyncSafety(kind: (s as Map)['kind'] as String, at: (s['at'] as num).toInt(), data: s['data'] as String),
    ];
  }

  Future<void> _save() => _state.write(
    jsonEncode({
      'base': _base?.toJson(),
      'etag': _etag,
      'map': _map.toJson(),
      'device': _deviceId,
      'lastSync': _lastSync,
      'devices': _deviceCount,
      'pendingClear': _pendingClear,
      'saved': _saved,
      'cardDismissed': _cardDismissed,
      'safety': [
        for (final s in _safety) {'kind': s.kind, 'at': s.at, 'data': s.data},
      ],
    }),
  );

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
