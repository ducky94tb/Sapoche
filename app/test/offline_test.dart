import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/data/backend.dart';
import 'package:sapoche/data/models.dart';

import 'fake_backend.dart';
import 'pump_app.dart';

/// Playlists and folders kept on the phone: the round button beside Play, the question when it is switched off, the
/// mark in the library and the switch for mobile data.
void main() {
  const songA = Track(videoId: 'aaaaaaaaaaa', title: 'Alpha', artist: 'Ann', durMs: 100000);
  const songB = Track(videoId: 'bbbbbbbbbbb', title: 'Beta', artist: 'Ben', durMs: 100000);

  Future<FakeBackend> openLibrary(WidgetTester tester, {void Function(FakeBackend b)? prepare}) async {
    final (backend, _) = await pumpApp(tester);
    backend.playlistNames[1] = 'Road trip';
    backend.playlistSongs[1] = [songA, songB];
    prepare?.call(backend);
    backend.emit(const StateEvent(RoomSnapshot()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Library'));
    await tester.pumpAndSettle();
    backend.emit(const LibraryEvent());
    await tester.pumpAndSettle();
    return backend;
  }

  Future<FakeBackend> openPlaylist(WidgetTester tester, {void Function(FakeBackend b)? prepare, String? folder}) async {
    final backend = await openLibrary(tester, prepare: prepare);
    if (folder != null) {
      await tester.tap(find.text(folder));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.text('Road trip'));
    await tester.pumpAndSettle();
    return backend;
  }

  testWidgets('switching a playlist on keeps it and downloads the songs it has', (tester) async {
    final backend = await openPlaylist(tester);
    await tester.tap(find.byTooltip('Download'));
    await tester.pumpAndSettle();
    expect(backend.calls, contains('playlistOffline 1 true'));
    expect(backend.calls, contains('download aaaaaaaaaaa,bbbbbbbbbbb metered=false'));
    expect(find.text('Downloading 2 songs'), findsOneWidget);
    expect(find.byTooltip('Downloading 0 of 2'), findsOneWidget, reason: 'the ring of a playlist on its way');

    backend.downloadList
      ..clear()
      ..addAll([
        const DownloadEntry(track: songA, state: DownloadState.done, bytes: 1),
        const DownloadEntry(track: songB, state: DownloadState.done, bytes: 1),
      ]);
    backend.emit(const DownloadsEvent(DownloadBatch(done: 2, total: 2)));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Downloaded'), findsOneWidget);
  });

  testWidgets('on mobile data the person may let the songs wait for Wi-Fi', (tester) async {
    final backend = await openPlaylist(tester, prepare: (b) => b.metered = true);
    await tester.tap(find.byTooltip('Download'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Wait for Wi-Fi'));
    await tester.pumpAndSettle();
    expect(backend.calls, contains('playlistOffline 1 true'), reason: 'the playlist stays kept');
    expect(backend.calls, isNot(contains('download aaaaaaaaaaa,bbbbbbbbbbb metered=true')));
    expect(find.text('The songs will download on Wi-Fi'), findsOneWidget);
  });

  testWidgets('with mobile data allowed for kept playlists nothing is asked', (tester) async {
    final backend = await openPlaylist(
      tester,
      prepare: (b) => b
        ..metered = true
        ..storageInfo = const StorageInfo(offlineCellular: true),
    );
    await tester.tap(find.byTooltip('Download'));
    await tester.pumpAndSettle();
    expect(find.text('Wait for Wi-Fi'), findsNothing);
    expect(backend.calls, contains('download aaaaaaaaaaa,bbbbbbbbbbb metered=true'));
  });

  testWidgets('switching off asks whether the downloaded songs go', (tester) async {
    final backend = await openPlaylist(
      tester,
      prepare: (b) => b
        ..offlinePlaylists.add(1)
        ..removable = 2
        ..downloadList.addAll([
          const DownloadEntry(track: songA, state: DownloadState.done, bytes: 1),
          const DownloadEntry(track: songB, state: DownloadState.done, bytes: 1),
        ]),
    );
    await tester.tap(find.byTooltip('Downloaded'));
    await tester.pumpAndSettle();
    expect(find.text('Stop downloading this playlist?'), findsOneWidget);
    expect(find.textContaining('Remove the 2 downloaded songs'), findsOneWidget);
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(backend.calls, contains('playlistOffline 1 false remove'));
    expect(find.byTooltip('Download'), findsOneWidget);
  });

  testWidgets('switching off can keep the songs, and asks nothing when none would go', (tester) async {
    final backend = await openPlaylist(
      tester,
      prepare: (b) => b
        ..offlinePlaylists.add(1)
        ..removable = 1,
    );
    await tester.tap(find.byTooltip('Downloading 0 of 2'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Keep songs'));
    await tester.pumpAndSettle();
    expect(backend.calls, contains('playlistOffline 1 false'));

    backend.removable = 0;
    await tester.tap(find.byTooltip('Download'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Downloading 0 of 2'));
    await tester.pumpAndSettle();
    expect(find.text('Stop downloading this playlist?'), findsNothing);
    expect(backend.calls.where((c) => c == 'playlistOffline 1 false'), hasLength(2));
  });

  testWidgets('a playlist kept by its folder says so and is not switched off alone', (tester) async {
    final backend = await openPlaylist(
      tester,
      prepare: (b) => b
        ..folderNames[1] = 'Trips'
        ..playlistFolders[1] = 1
        ..offlineFolders.add(1),
      folder: 'Trips',
    );
    await tester.tap(find.byTooltip('Downloading 0 of 2'));
    await tester.pumpAndSettle();
    expect(find.text('Downloaded with the folder Trips'), findsOneWidget);
    expect(backend.calls.where((c) => c.startsWith('playlistOffline')), isEmpty);
  });

  testWidgets('a folder is switched on from its page and marked in the library', (tester) async {
    final backend = await openLibrary(
      tester,
      prepare: (b) => b
        ..folderNames[1] = 'Trips'
        ..playlistFolders[1] = 1,
    );
    // The tile of the Downloaded list has the same icon
    final before = find.byIcon(Icons.download_done_rounded).evaluate().length;
    await tester.tap(find.text('Trips'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Download'));
    await tester.pumpAndSettle();
    expect(backend.calls, contains('folderOffline 1 true'));
    expect(backend.calls, contains('download aaaaaaaaaaa,bbbbbbbbbbb metered=false'));
    // The playlist in it is marked as kept
    expect(find.byIcon(Icons.download_done_rounded), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.download_done_rounded), findsNWidgets(before + 1), reason: 'the folder in the library');
  });

  testWidgets('Delete all on the Downloaded page lets the kept playlists go', (tester) async {
    final backend = await openLibrary(
      tester,
      prepare: (b) => b
        ..offlinePlaylists.add(1)
        ..downloadList.addAll([
          const DownloadEntry(track: songA, state: DownloadState.done, bytes: 1),
          const DownloadEntry(track: songB, state: DownloadState.done, bytes: 1),
        ]),
    );
    await tester.tap(find.text('Downloaded').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete all'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(backend.calls, contains('clearDownloads'));
    expect(backend.offlinePlaylists, isEmpty);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Road trip'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Download'), findsOneWidget, reason: 'the playlist no longer keeps itself whole');
  });

  testWidgets('the menu of a playlist no longer has a one-off Download all', (tester) async {
    await openPlaylist(tester);
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    expect(find.text('Download all'), findsNothing);
  });

  testWidgets('kept playlists may come on mobile data, by a switch in the settings', (tester) async {
    final (backend, _) = await pumpApp(tester);
    backend.emit(const StateEvent(RoomSnapshot()));
    await tester.pumpAndSettle();
    await openTopic(tester, 'storage');
    await tester.scrollUntilVisible(find.text('Download on mobile data'), 200);
    await tester.tap(find.text('Download on mobile data'));
    await tester.pumpAndSettle();
    expect(backend.calls, contains('offlineCellular true'));
  });
}
