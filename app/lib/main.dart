import 'dart:async';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';

import 'app.dart';
import 'data/app_settings.dart';
import 'data/backend.dart';
import 'data/backend_factory.dart';
import 'data/calm.dart';
import 'data/comments.dart';
import 'data/error_log.dart';
import 'data/library_controller.dart';
import 'data/music_controller.dart';
import 'data/recent_rooms.dart';
import 'data/recent_searches.dart';
import 'data/room_controller.dart';
import 'data/sticker_licenses.dart';
import 'data/sticker_store.dart';
import 'data/sync/sync_controller.dart';
import 'data/sync/sync_ports.dart';
import 'data/update_controller.dart';
import 'frame_boost.dart';
import 'frame_stats.dart';
import 'ui/scope.dart';
import 'ui/widgets/cached_cover.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Flutter keeps up to 100 MB of decoded pictures; covers are small and a phone has better uses for the memory
  // (half of that where the effects are lightened: a weak phone has the least memory to spare)
  void sizeImageCache() =>
      PaintingBinding.instance.imageCache.maximumSizeBytes =
          (Calm.light.value ? 24 : 48) << 20;
  sizeImageCache();
  Calm.light.addListener(sizeImageCache);
  final Backend backend = await createBackend();
  // A widget that throws in a release build leaves nothing behind; this puts it in the log of the app
  ErrorLog(backend.note).install();
  // Before the first cover is asked for; without the folder the covers are only fetched
  CoverFiles.useFolder(
    await backend.cacheFolder().catchError((Object _) => null),
  );
  // The pictures inside music files on this phone are read by the native side
  CoverFiles.localCover = (id) => backend.localCover(id).catchError((Object _) => null);
  // Where there is no cable to read the frame statistics from, they go into the log of the app
  watchFrames(report: backend.note);
  final settings = await AppSettings.load();
  final recents = await RecentRooms.load();
  final searches = await RecentSearches.load();
  // The display runs at its fastest only while someone moves the screen
  FrameBoost(backend.setDisplayPace).start();
  final room = RoomController(backend, recents: recents)..start();
  // The native side keeps the picture too, but it is the person's choice that counts when the app opens
  room.shareAvatar(settings.avatar);
  final library = LibraryController(backend)..start();
  registerStickerLicenses();
  // The packs are files of the room server, which the room controller knows the address of
  final stickers = await StickerStore.load(server: () => room.profile.server, cacheFolder: backend.cacheFolder);
  final sync = createSyncController(
    backend: backend,
    server: () => room.profile.server,
    deviceLabel: () => kIsWeb ? 'Web' : (defaultTargetPlatform == TargetPlatform.iOS ? 'iPhone' : 'Android'),
  );
  // The library of this phone changes under the person's hand or while the screen is off: the sync looks a few seconds later
  backend.events.where((e) => e is LibraryEvent).listen((_) => sync.libraryChanged());
  library.onHistoryCleared = sync.historyCleared;
  WidgetsBinding.instance.addObserver(_SyncOnLifecycle(sync));
  unawaited(sync.load());
  runApp(
    SapocheApp(
      model: AppModel(
        sync: sync,
        room: room,
        settings: settings,
        recents: recents,
        library: library,
        searches: searches,
        music: MusicController(backend),
        comments: CommentsController(
          CommentsClient(
            createCommentsTransport(backend),
            region: () => PlatformDispatcher.instance.locale.countryCode ?? 'US',
          ),
        ),
        update: UpdateController(backend),
        stickers: stickers,
        clipboardHasPhotos: backend.clipboardHasPhotos,
        clipboardPhotos: backend.clipboardPhotos,
      ),
    ),
  );
}

/// Syncs when the app comes back to the front and when it goes away (an iPhone gives it a few seconds; the next run makes up).
class _SyncOnLifecycle with WidgetsBindingObserver {
  _SyncOnLifecycle(this._sync);

  final SyncController _sync;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed || state == AppLifecycleState.paused) _sync.appMoved();
  }
}
