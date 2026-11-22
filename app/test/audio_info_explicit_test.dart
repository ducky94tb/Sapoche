import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/data/app_settings.dart';
import 'package:sapoche/data/backend.dart';
import 'package:sapoche/data/models.dart';
import 'package:sapoche/data/music_models.dart';
import 'package:sapoche/strings.dart';
import 'package:sapoche/ui/widgets/explicit_badge.dart';
import 'package:sapoche/ui/widgets/track_tile.dart';

import 'fake_backend.dart';
import 'landscape_test.dart' show resize;
import 'pump_app.dart';

Future<FakeBackend> _openPlayerWith(
  WidgetTester tester, {
  required PlayerStyle style,
  required QueueEntry entry,
  AudioFormat? audioFormat,
  bool video = false,
  SongRadio? radio,
}) async {
  final (backend, _) = await pumpApp(
    tester,
    prefs: {'player_style': style.name},
  );
  if (radio != null) backend.radioResult = radio;
  backend.emit(
    StateEvent(
      RoomSnapshot(
        phase: 'playing',
        index: 0,
        video: video,
        queue: [entry],
      ),
    ),
  );
  backend.emit(
    PositionEvent(
      PlayerPosition(
        playing: true,
        positionMs: 12000,
        durationMs: entry.durMs > 0 ? entry.durMs : 200000,
        audioFormat: audioFormat,
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pump(const Duration(milliseconds: 500));
  await tapMiniPlayer(tester);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 700));
  await tester.pump();
  return backend;
}

void main() {
  group('G1 actual audio format', () {
    testWidgets('Full cover shows live audioFormat and hides when null or video', (
      tester,
    ) async {
      const song = QueueEntry(
        id: 'q1',
        videoId: 'H4RELGc9su8',
        title: 'HUMBLE.',
        artist: 'Kendrick Lamar',
        durMs: 177000,
        addedBy: 'me',
      );
      final backend = await _openPlayerWith(
        tester,
        style: PlayerStyle.appleMusic,
        entry: song,
        audioFormat: const AudioFormat(codec: 'Opus', kbps: 131, hz: 48000),
      );
      expect(find.text('Opus · 131 kbps · 48 kHz'), findsOneWidget);
      expect(find.byIcon(Icons.graphic_eq_rounded), findsOneWidget);

      // Updating audioFormat updates the line live
      backend.emit(
        const PositionEvent(
          PlayerPosition(
            playing: true,
            positionMs: 14000,
            durationMs: 177000,
            audioFormat: AudioFormat(codec: 'AAC', kbps: 129, hz: 44100),
          ),
        ),
      );
      // One turn to deliver the event, one frame to draw it: no animation keeps frames coming now
      await tester.pump();
      await tester.pump();
      expect(find.text('AAC · 129 kbps · 44.1 kHz'), findsOneWidget);

      // Clearing audioFormat hides the quality line completely
      backend.emit(
        const PositionEvent(
          PlayerPosition(playing: true, positionMs: 16000, durationMs: 177000),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.byIcon(Icons.graphic_eq_rounded), findsNothing);
    });

    testWidgets('Full cover hides audioFormat when playing video', (
      tester,
    ) async {
      const song = QueueEntry(
        id: 'q1',
        videoId: 'H4RELGc9su8',
        title: 'HUMBLE.',
        artist: 'Kendrick Lamar',
        durMs: 177000,
        addedBy: 'me',
      );
      await _openPlayerWith(
        tester,
        style: PlayerStyle.appleMusic,
        entry: song,
        video: true,
        audioFormat: const AudioFormat(codec: 'Opus', kbps: 131, hz: 48000),
      );
      expect(find.byIcon(Icons.graphic_eq_rounded), findsNothing);
    });

    testWidgets('Settings shows about 128 kbps for Highest on iOS', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        await pumpApp(tester);
        await openTopic(tester, 'playback');
        final maxRow = find.byKey(const ValueKey('audio-quality-max'));
        expect(
          find.descendant(
            of: maxRow,
            matching: find.text(S.audioQualityMaxRateIos),
          ),
          findsOneWidget,
        );
      } finally {
        debugDefaultTargetPlatformOverride = null;
        // Clear the 20s iOS HomeShell timer before test teardown
        await tester.pump(const Duration(seconds: 21));
      }
    });
  });

  group('G2 explicit badge on track rows', () {
    testWidgets('TrackTile shows ExplicitBadge only for explicit tracks', (
      tester,
    ) async {
      final (backend, _) = await pumpApp(tester);
      backend.likedSongs = const [
        Track(
          videoId: 'H4RELGc9su8',
          title: 'HUMBLE.',
          artist: 'Kendrick Lamar',
          durMs: 177000,
          explicit: true,
          year: '2017',
        ),
        Track(
          videoId: 'o0yLdYf6OVY',
          title: 'Clean Song',
          artist: 'Clean Artist',
          durMs: 180000,
          explicit: false,
          year: '2024',
        ),
      ];
      backend.emit(const LibraryEvent());
      await tester.pumpAndSettle();

      await tester.tap(find.text(S.tabLibrary).last);
      await tester.pumpAndSettle();
      await tester.tap(find.text(S.likedSongs).last);
      await tester.pumpAndSettle();

      final tiles = find.byType(TrackTile);
      expect(tiles, findsNWidgets(2));
      expect(
        find.descendant(of: tiles.at(0), matching: find.byType(ExplicitBadge)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: tiles.at(1), matching: find.byType(ExplicitBadge)),
        findsNothing,
      );
      // Year is never shown on track rows
      expect(find.textContaining('2017'), findsNothing);
      expect(find.textContaining('2024'), findsNothing);
    });
  });

  group('G3 explicit badge and release year in player', () {
    const explicitTrack = QueueEntry(
      id: 'q1',
      videoId: 'H4RELGc9su8',
      title: 'HUMBLE.',
      artist: 'Kendrick Lamar',
      durMs: 177000,
      addedBy: 'me',
      explicit: true,
      year: '2017',
    );

    for (final style in PlayerStyle.values) {
      testWidgets('explicit badge shows in ${style.name}; year only in appleMusic', (
        tester,
      ) async {
        await _openPlayerWith(tester, style: style, entry: explicitTrack);
        expect(find.byType(ExplicitBadge), findsOneWidget);
        if (style == PlayerStyle.appleMusic) {
          expect(find.textContaining('2017'), findsOneWidget);
        } else {
          expect(find.textContaining('2017'), findsNothing);
        }
      });
    }

    testWidgets('falls back to radio(videoId) for old tracks without explicit or year', (
      tester,
    ) async {
      const legacy = QueueEntry(
        id: 'q1',
        videoId: 'H4RELGc9su8',
        title: 'HUMBLE.',
        artist: 'Kendrick Lamar',
        durMs: 177000,
        addedBy: 'me',
      );
      await _openPlayerWith(
        tester,
        style: PlayerStyle.appleMusic,
        entry: legacy,
        radio: const SongRadio(
          tracks: [
            MusicTrack(
              videoId: 'H4RELGc9su8',
              title: 'HUMBLE.',
              artist: 'Kendrick Lamar',
              durMs: 177000,
              explicit: true,
              year: '2017',
              isSong: true,
            ),
          ],
        ),
      );
      expect(find.byType(ExplicitBadge), findsOneWidget);
      expect(find.textContaining('2017'), findsOneWidget);
    });

    testWidgets('drops year before artist when line is tight in Full cover', (
      tester,
    ) async {
      await resize(tester, 320, 740);
      const longArtist = QueueEntry(
        id: 'q1',
        videoId: 'longartist1',
        title: 'Short',
        artist: 'Very Long Orchestra Featuring Several Collaborating Artists',
        durMs: 177000,
        addedBy: 'me',
        explicit: true,
        year: '2019',
      );
      await _openPlayerWith(
        tester,
        style: PlayerStyle.appleMusic,
        entry: longArtist,
      );
      expect(find.byType(ExplicitBadge), findsOneWidget);
      expect(find.textContaining('2019'), findsNothing);
    });
  });
}
